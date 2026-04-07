from Prompt.prompt_v4 import (
    SYSTEM_EXTRACTION_PROMPT,
    SYSTEM_SUMMARIZATION_PROMPT,
    SYSTEM_CAUSE_CODE_PROMPT,
    SYSTEM_FINANCIAL_INDEMNITY_PROMPT
)


def _extract_currency_amount(text: str):
    if not text:
        return None

    text = str(text)

    patterns = [
        r'((?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\s*[\d,]+(?:\.\d+)?)',
        r'((?:US\$|AU\$|C\$|S\$|HK\$|₹|£|€|\$)\s*[\d,]+(?:\.\d+)?)',
        r'([\d,]+(?:\.\d+)?\s*(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD))'
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return match.group(1).strip()

    return None


def _build_financial_indemnity_value_from_lines(lines):
    if not isinstance(lines, list):
        return None

    result = {}

    for line in lines:
        if not line:
            continue

        raw_line = str(line).strip()
        line_norm = raw_line.lower()

        amount = _extract_currency_amount(raw_line)
        if not amount:
            continue

        if re.search(r'\b(pd|property damage)\b', line_norm):
            result["Property Damage"] = amount
        elif re.search(r'\b(stock)\b', line_norm):
            result["Stock"] = amount
        elif re.search(r'\b(bi|business interruption)\b', line_norm):
            result["Business Interruption"] = amount

    return [result] if result else None


def run_financial_indemnity_llm(context: str):
    """
    Runs LLM only to identify the single best chunk and exact supporting lines
    for Financial Indemnity.
    """
    try:
        print("Running LLM for Financial Indemnity...")

        llm1, llm2 = _get_llms(temperature=0)

        prompt = ChatPromptTemplate.from_messages(
            [
                ("system", SYSTEM_FINANCIAL_INDEMNITY_PROMPT),
                ("human", "{context}")
            ]
        )

        chain = (
            {"context": RunnablePassthrough()}
            | prompt
            | llm2
            | StrOutputParser()
        )

        message = prompt.format_messages(context=context)
        full_prompt_text = "\n".join([msg.content for msg in message])

        encoding = tiktoken.encoding_for_model("gpt-oss-120b")
        tokens_message = encoding.encode(full_prompt_text)
        print(f"Total tokens in financial indemnity message: {len(tokens_message)}")
        print(f"Total characters in financial indemnity message: {len(full_prompt_text)}")

        raw_result = chain.invoke({"context": context})

        print(f"Raw Financial Indemnity LLM output: {raw_result}")

        json_text = _extract_json_block(raw_result)
        parsed = json.loads(json_text)

        result = {
            "Chunk_id": _pick(parsed, "Chunk_id", "chunk_id", "chunkId"),
            "lines": _pick(parsed, "lines", "Lines")
        }

        if result["lines"] is not None and not isinstance(result["lines"], list):
            result["lines"] = [str(result["lines"])]

        result["Value"] = _build_financial_indemnity_value_from_lines(result["lines"])

        return result

    except Exception as e:
        print(f"An error occurred while running Financial Indemnity LLM: {e}")
        return {
            "Value": None,
            "Chunk_id": None,
            "lines": None
        }
