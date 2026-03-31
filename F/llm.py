import os
import json
import tiktoken
from dotenv import load_dotenv

from Prompt.prompt_v3 import SYSTEM_EXTRACTION_PROMPT, SYSTEM_SUMMARIZATION_PROMPT
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_groq import ChatGroq

load_dotenv()

GROQ_API_KEY = os.getenv("GROQ_API_KEY_V3")
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


def _safe_parse_json(raw_result: str) -> dict:
    raw_result = (raw_result or "").strip()

    try:
        parsed = json.loads(raw_result)
        if not isinstance(parsed, dict):
            raise ValueError("LLM output is not a JSON object.")

        return {
            "chunk_id": parsed.get("chunk_id"),
            "value": parsed.get("value"),
            "evidence_text": parsed.get("evidence_text"),
            "raw_output": raw_result
        }
    except Exception:
        return {
            "chunk_id": None,
            "value": None,
            "evidence_text": None,
            "raw_output": raw_result
        }


def run_llm(field, context):
    print(f"Running LLM for field: {field['field_name']}...")

    system_prompt = EXTRACTION_PROMPT if field["operation_type"] == "extract" else SUMMARISATION_PROMPT
    temperature = 0 if field["operation_type"] == "extract" else 0.6

    llm = ChatGroq(
        model="openai/gpt-oss-120b",
        api_key=GROQ_API_KEY,
        temperature=temperature,
    )

    prompt = ChatPromptTemplate.from_messages(
        [
            ("system", system_prompt),
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

    try:
        encoding = tiktoken.encoding_for_model("gpt-4o")
        tokens = encoding.encode(system_prompt + "\n" + USER_PROMPT + "\n" + context)
        print(f"Total tokens in the prompt: {len(tokens)}")
    except Exception:
        print("Unable to calculate token count for the prompt.")

    raw_result = extraction_chain.invoke(
        {
            "field_name": field["field_name"],
            "field_description": field["description"],
            "field_possible_names": field["possible_names"],
            "value_format": field["value_format"],
            "context": context,
        }
    )

    print("Raw LLM Output:")
    print(raw_result)

    parsed_result = _safe_parse_json(raw_result)

    print("Parsed LLM Output:")
    print(parsed_result)

    return parsed_result
