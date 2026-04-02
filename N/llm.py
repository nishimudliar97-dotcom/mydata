import os
import json
import re
import tiktoken
from dotenv import load_dotenv
from asyncio.windows_events import NULL

from Prompt.prompt_v4 import SYSTEM_EXTRACTION_PROMPT, SYSTEM_SUMMARIZATION_PROMPT
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_groq import ChatGroq

load_dotenv()

GROQ_API_KEY = os.getenv("GROQ_API_KEY_v4")
OPEN_API_KEY = os.getenv("OPEN_API_KEY")

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


def run_llm(field, context):
    try:
        print(f"Running LLM for field: {field['field_name']}...")

        SYSTEM_PROMPT = EXTRACTION_PROMPT if field['operation_type'] == "extract" else SUMMARISATION_PROMPT
        temperature = 0 if field['operation_type'] == "extract" else 0.6

        llm = ChatGroq(
            model="openai/gpt-oss-120b",
            api_key=GROQ_API_KEY,
            temperature=temperature,
        )

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
            | llm
            | StrOutputParser()
        )

        message = prompt.format_messages(
            field_name=field['field_name'],
            field_description=field['description'],
            field_possible_names=field['possible_names'],
            value_format=field['value_format'],
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
                "field_name": field['field_name'],
                "field_description": field['description'],
                "field_possible_names": field['possible_names'],
                "value_format": field['value_format'],
                "context": context,
            }
        )

        print(f"Raw LLM output: {raw_result}")

        json_text = _extract_json_block(raw_result)
        parsed = json.loads(json_text)

        result = {
            "Value": parsed.get("Value"),
            "Chunk_id": parsed.get("Chunk_id"),
            "lines": parsed.get("lines"),
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
