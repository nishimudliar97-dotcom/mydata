import os
from dotenv import load_dotenv
import tiktoken

from Prompt.prompt_v4 import SYSTEM_EXTRACTION_PROMPT, SYSTEM_SUMMARIZATION_PROMPT
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_groq import ChatGroq

load_dotenv()

GROQ_API_KEY = os.getenv("GROQ_API_KEY")
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


def _get_token_encoding():
    try:
        return tiktoken.encoding_for_model("gpt-4o")
    except Exception:
        return tiktoken.get_encoding("cl100k_base")


def _clean_llm_output(result: str) -> str:
    if not isinstance(result, str):
        return '{"value": null, "chunk_id": null}'

    result = result.strip()

    if result.startswith("```json"):
        result = result[len("```json"):].strip()
    elif result.startswith("```"):
        result = result[len("```"):].strip()

    if result.endswith("```"):
        result = result[:-3].strip()

    return result


def run_llm(field, context):
    try:
        print(f"Running LLM for field: {field['field_name']}...")

        SYSTEM_PROMPT = EXTRACTION_PROMPT if field["operation_type"] == "extract" else SUMMARISATION_PROMPT
        temperature = 0 if field["operation_type"] == "extract" else 0.2

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
            field_name=field["field_name"],
            field_description=field["description"],
            field_possible_names=field["possible_names"],
            value_format=field["value_format"],
            context=context,
        )

        full_prompt_text = "\n".join([msg.content for msg in message])

        encoding = _get_token_encoding()
        tokens_message = encoding.encode(full_prompt_text)

        print(f"Total tokens in the message: {len(tokens_message)}")
        print(f"Total characters in the message: {len(full_prompt_text)}")
        print(f"Message: {full_prompt_text}")

        result = extraction_chain.invoke(
            {
                "field_name": field["field_name"],
                "field_description": field["description"],
                "field_possible_names": field["possible_names"],
                "value_format": field["value_format"],
                "context": context,
            }
        )

        result = _clean_llm_output(result)
        return result

    except Exception as e:
        print(f"An error occurred while running LLM: {e}")
        return '{"value": null, "chunk_id": null}'
