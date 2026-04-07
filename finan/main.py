def normalize_financial_indemnity_value(value):
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




retrieved_chunks = extractor(vector_stores, field)

context = build_context(retrieved_chunks)

print(context)
print("\n \n \n")

llm_result = run_llm(field, context)

if field["field_name"] == "Financial Indemnity" and llm_result.get("Value") is not None:
    llm_result["Value"] = normalize_financial_indemnity_value(llm_result["Value"])
elif llm_result.get("Value") is not None and isinstance(llm_result["Value"], str):
    llm_result["Value"] = normalize_text(llm_result["Value"])

resolved_output = resolve_line_bboxes(
    llm_result=llm_result,
    retrieved_chunks=retrieved_chunks
)

final_output[field["field_name"]] = resolved_output

print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")
