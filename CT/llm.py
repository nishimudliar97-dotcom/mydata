import os
import json
import re
import tiktoken

from dotenv import load_dotenv
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_groq import ChatGroq

from Prompt.prompt_v4 import SYSTEM_EXTRACTION_PROMPT, SYSTEM_SUMMARIZATION_PROMPT

load_dotenv()

GROQ_API_KEY = os.getenv("GROQ_API_KEY_v2")
OPEN_API_KEY = os.getenv("OPEN_AI_KEY")

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


def _pick(parsed, *keys):
    for key in keys:
        if key in parsed:
            return parsed.get(key)
    return None


def run_llm(field, context):
    try:
        print(f"Running LLM for field: {field['field_name']}...")

        system_prompt = (
            EXTRACTION_PROMPT
            if field["operation_type"] == "extract"
            else SUMMARISATION_PROMPT
        )

        temperature = 0 if field["operation_type"] == "extract" else 0.1

        llm = ChatGroq(
            model="openai/gpt-oss-120b",
            api_key=GROQ_API_KEY,
            temperature=temperature
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

        message = prompt.format_messages(
            field_name=field["field_name"],
            field_description=field["description"],
            field_possible_names=field["possible_names"],
            value_format=field["value_format"],
            context=context
        )

        full_prompt_text = "\n".join([msg.content for msg in message])

        # Token debug
        try:
            encoding = tiktoken.get_encoding("cl100k_base")
            tokens_message = encoding.encode(full_prompt_text)
            token_count = len(tokens_message)
        except Exception as e:
            print(f"Token encoding fallback warning: {e}")
            tokens_message = []
            token_count = -1

        user_prompt_text = USER_PROMPT.format(
            field_name=field["field_name"],
            field_description=field["description"],
            field_possible_names=field["possible_names"],
            value_format=field["value_format"],
            context=context
        )

        print(f"System prompt chars: {len(system_prompt)}")
        print(f"User prompt chars: {len(user_prompt_text)}")
        print(f"Context chars: {len(context)}")
        print(f"Field description chars: {len(field.get('description', ''))}")
        print(f"Possible names chars: {len(str(field.get('possible_names', '')))}")
        print(f"Value format chars: {len(str(field.get('value_format', '')))}")
        print(f"Total tokens in the message: {token_count}")
        print(f"Total characters in the message: {len(full_prompt_text)}")
        print(f"Message: {full_prompt_text}")

        # Hard stop before actual API call
        # Keep some safety margin below 8000
        if token_count != -1 and token_count > 7000:
            raise ValueError(
                f"Prompt too large before LLM call: {token_count} tokens "
                f"for field '{field['field_name']}'"
            )

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
