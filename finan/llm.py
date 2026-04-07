def _normalize_financial_indemnity_value(value):
    if not isinstance(value, list) or not value:
        return value

    first_item = value[0]
    if not isinstance(first_item, dict):
        return value

    normalized = {}

    for raw_key, raw_amount in first_item.items():
        if raw_amount is None:
            continue

        key = str(raw_key).strip().lower()
        key = key.replace("net", " ")
        key = key.replace("cbe", " ")
        key = " ".join(key.split())

        if key in ["pd", "property damage"]:
            normalized["Property Damage"] = raw_amount
        elif key in ["bi", "business interruption"]:
            normalized["Business Interruption"] = raw_amount
        elif key == "stock":
            normalized["Stock"] = raw_amount

    return [normalized] if normalized else None



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
            context=context,
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
            "Chunk_id": _pick(parsed, "Chunk_id", "chunk_id", "chunkId"),
            "lines": _pick(parsed, "lines", "Lines"),
        }

        if result["Value"] in ["NOT_FOUND", "NULL", "Null", "null"]:
            result["Value"] = None

        if result["lines"] is not None and not isinstance(result["lines"], list):
            result["lines"] = [str(result["lines"])]

        if field["field_name"] == "Financial Indemnity" and result["Value"] is not None:
            result["Value"] = _normalize_financial_indemnity_value(result["Value"])

        return result

    except Exception as e:
        print(f"An error occurred while running LLM: {e}")
        return {
            "Value": None,
            "Chunk_id": None,
            "lines": None,
        }
