from Retriever.llm import run_llm, run_cause_code_llm, run_financial_indemnity_llm

def debug_print_retrieved_chunks(field_name, retrieved_chunks):
    print(f"\n[DEBUG] Retrieved chunks for field: {field_name}")
    print(f"[DEBUG] Total retrieved chunks: {len(retrieved_chunks)}")

    for idx, chunk in enumerate(retrieved_chunks, start=1):
        meta = getattr(chunk, "metadata", {})
        print("\n" + "=" * 80)
        print(f"[DEBUG] Chunk #{idx}")
        print(f"[DEBUG] chunk_id: {meta.get('chunk_id')}")
        print(f"[DEBUG] document: {meta.get('document')}")
        print(f"[DEBUG] category: {meta.get('category')}")
        print(f"[DEBUG] heading: {meta.get('heading')}")
        print(f"[DEBUG] pages: {meta.get('page_start')} - {meta.get('page_end')}")
        print(f"[DEBUG] content:\n{chunk.page_content}")
        print("=" * 80)


for field in fields:
    print(f"\nExtracting field: {field['field_name']}...")

    # New special handling for Cause Code
    if field["field_name"] == "Cause Code":
        cause_code_result = run_cause_code_pipeline(vector_stores)
        final_output[field["field_name"]] = cause_code_result
        print(f"Extracted Cause Code: {json.dumps(cause_code_result, indent=2)}")
        continue

    retrieved_chunks = extractor(vector_stores, field)

    debug_print_retrieved_chunks(field["field_name"], retrieved_chunks)

    context = build_context(retrieved_chunks)

    print(context)
    print("\n \n \n")

    # New special handling for Financial Indemnity
    if field["field_name"] == "Financial Indemnity":
        llm_result = run_financial_indemnity_llm(context)
        print(f"[DEBUG] Financial Indemnity parsed result: {json.dumps(llm_result, indent=2)}")

        resolved_output = resolve_line_bboxes(
            llm_result=llm_result,
            retrieved_chunks=retrieved_chunks
        )

        final_output[field["field_name"]] = resolved_output
        print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")
        continue

    llm_result = run_llm(field, context)

    if llm_result.get("Value") is not None:
        llm_result["Value"] = normalize_text(llm_result["Value"])

    resolved_output = resolve_line_bboxes(
        llm_result=llm_result,
        retrieved_chunks=retrieved_chunks
    )

    final_output[field["field_name"]] = resolved_output

    print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")

































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
