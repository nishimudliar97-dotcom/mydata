import os
import json
import re
import tiktoken
from dotenv import load_dotenv

from Prompt.prompt_v4 import (
    SYSTEM_EXTRACTION_PROMPT,
    SYSTEM_SUMMARIZATION_PROMPT,
    SYSTEM_CAUSE_CODE_PROMPT
)

from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_groq import ChatGroq
from langchain_openai import AzureChatOpenAI

load_dotenv()

GROQ_API_KEY = os.getenv("GROQ_API_KEY_v2")
OPEN_API_KEY = os.getenv("OPEN_API_KEY")

AZURE_API_KEY = os.getenv("AZURE_OPENAI_KEY")
AZURE_API_ENDPOINT = os.getenv("AZURE_OPENAI_ENDPOINT")
AZURE_API_VERSION = os.getenv("api_version")


EXTRACTION_PROMPT = SYSTEM_EXTRACTION_PROMPT
SUMMARISATION_PROMPT = SYSTEM_SUMMARIZATION_PROMPT


USER_PROMPT = """
FIELD NAME:
{field_name}

FIELD DESCRIPTION:
{field_description}

OTHER POSSIBLE NAMES:
{field_possible_names}

VALUE FORMAT:
{value_format}

DOCUMENT CONTEXT:
{context}
""".strip()


CAUSE_CODE_USER_PROMPT = """
LOSS / CIRCUMSTANCES NARRATIVE:
{cause_narrative}

CANDIDATE CAUSE CODE ROWS:
{cause_candidates}
""".strip()


def _extract_json_block(text: str) -> str:
    if not isinstance(text, str):
        return ""

    text = text.strip()

    fenced_match = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    if fenced_match:
        return fenced_match.group(1).strip()

    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        return text[start:end + 1].strip()

    return text


def _pick(parsed, *keys):
    for key in keys:
        if key in parsed:
            return parsed.get(key)
    return None


def _get_llms(temperature=0):
    llm1 = ChatGroq(
        model="openai/gpt-oss-120b",
        api_key=GROQ_API_KEY,
        temperature=temperature
    )

    llm2 = AzureChatOpenAI(
        api_key=AZURE_API_KEY,
        api_version=AZURE_API_VERSION,
        azure_endpoint=AZURE_API_ENDPOINT,
        azure_deployment="gpt-4o-mini",
        temperature=temperature
    )

    return llm1, llm2


def run_llm(field, context):
    try:
        print(f"Running LLM for field: {field['field_name']}...")

        SYSTEM_PROMPT = EXTRACTION_PROMPT if field["operation_type"] == "extract" else SUMMARISATION_PROMPT
        temperature = 0 if field["operation_type"] == "extract" else 0.1

        llm1, llm2 = _get_llms(temperature=temperature)

        prompt = ChatPromptTemplate.from_messages(
            [
                ("system", SYSTEM_PROMPT),
                ("human", USER_PROMPT),
            ]
        )

        extraction_chain = (
            {
                "value_format": RunnablePassthrough(),
                "field_possible_names": RunnablePassthrough(),
                "field_name": RunnablePassthrough(),
                "field_description": RunnablePassthrough(),
                "context": RunnablePassthrough(),
            }
            | prompt
            | llm2
            | StrOutputParser()
        )

        message = prompt.format_messages(
            field_name=field["field_name"],
            field_description=field["description"],
            field_possible_names=field["possible_names"],
            value_format=field["value_format"],
            context=context
        )

        full_prompt_text = "\n".join([msg.content for msg in message])

        encoding = tiktoken.encoding_for_model("gpt-oss-120b")
        tokens_message = encoding.encode(full_prompt_text)
        print(f"Total tokens in the message: {len(tokens_message)}")
        print(f"Total Characters in the message: {len(full_prompt_text)}")
        print(f"Message: {full_prompt_text}")

        raw_result = extraction_chain.invoke(
            {
                "field_name": field["field_name"],
                "field_description": field["description"],
                "field_possible_names": field["possible_names"],
                "value_format": field["value_format"],
                "context": context,
            }
        )

        print(f"Raw LLM output: {raw_result}")

        json_text = _extract_json_block(raw_result)
        parsed = json.loads(json_text)

        result = {
            "Value": _pick(parsed, "Value", "value"),
            "Chunk_id": _pick(parsed, "Chunk_id", "chunk_id"),
            "lines": _pick(parsed, "lines", "Lines"),
        }

        if result["Value"] in ["NOT_FOUND", "NULL", "Null", "null"]:
            result["Value"] = None

        if result["lines"] is not None and not isinstance(result["lines"], list):
            result["lines"] = [str(result["lines"])]

        return result

    except Exception as e:
        print(f"An error occurred while running LLM: {e}")
        return {
            "Value": None,
            "Chunk_id": None,
            "lines": None,
        }


def run_cause_code_llm(cause_narrative: str, cause_candidates_text: str):
    """
    Runs cause-code mapping LLM.
    """
    try:
        print("Running LLM for Cause Code...")

        llm1, llm2 = _get_llms(temperature=0)

        prompt = ChatPromptTemplate.from_messages(
            [
                ("system", SYSTEM_CAUSE_CODE_PROMPT),
                ("human", CAUSE_CODE_USER_PROMPT),
            ]
        )

        chain = (
            {
                "cause_narrative": RunnablePassthrough(),
                "cause_candidates": RunnablePassthrough(),
            }
            | prompt
            | llm2
            | StrOutputParser()
        )

        message = prompt.format_messages(
            cause_narrative=cause_narrative,
            cause_candidates=cause_candidates_text
        )

        full_prompt_text = "\n".join([msg.content for msg in message])

        encoding = tiktoken.encoding_for_model("gpt-oss-120b")
        tokens_message = encoding.encode(full_prompt_text)
        print(f"Total tokens in cause-code message: {len(tokens_message)}")
        print(f"Total Characters in cause-code message: {len(full_prompt_text)}")
        print(f"Cause-code prompt: {full_prompt_text}")

        raw_result = chain.invoke(
            {
                "cause_narrative": cause_narrative,
                "cause_candidates": cause_candidates_text
            }
        )

        print(f"Raw Cause Code LLM output: {raw_result}")

        json_text = _extract_json_block(raw_result)
        parsed = json.loads(json_text)

        result = {
            "cause_code_id": _pick(parsed, "cause_code_id"),
            "cause_l1": _pick(parsed, "cause_l1"),
            "cause_l2": _pick(parsed, "cause_l2"),
            "matched_text": _pick(parsed, "matched_text")
        }

        return result

    except Exception as e:
        print(f"An error occurred while running Cause Code LLM: {e}")
        return {
            "cause_code_id": None,
            "cause_l1": None,
            "cause_l2": None,
            "matched_text": None
        }
