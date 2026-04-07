field_name_normalized = field["field_name"].strip().lower()

if field_name_normalized == "cause code":
    cause_code_result = run_cause_code_pipeline(vector_stores)
    final_output[field["field_name"]] = cause_code_result
    print(f"Extracted Cause Code: {json.dumps(cause_code_result, indent=2)}")
    continue

retrieved_chunks = extractor(vector_stores, field)

if field_name_normalized == "financial indemnity":
    retrieved_chunks = rerank_financial_indemnity_chunks(retrieved_chunks)

debug_print_retrieved_chunks(field["field_name"], retrieved_chunks)

context = build_context(retrieved_chunks)

print(context)
print("\n \n \n")

if field_name_normalized == "financial indemnity":
    llm_result = run_financial_indemnity_llm(context)
    print(f"[DEBUG] Financial Indemnity parsed result before resolver: {json.dumps(llm_result, indent=2)}")

    resolved_output = resolve_line_bboxes(
        llm_result=llm_result,
        retrieved_chunks=retrieved_chunks
    )

    final_output[field["field_name"]] = resolved_output
    print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")
    continue

llm_result = run_llm(field, context)

if llm_result.get("Value") is not None and isinstance(llm_result["Value"], str):
    llm_result["Value"] = normalize_text(llm_result["Value"])

resolved_output = resolve_line_bboxes(
    llm_result=llm_result,
    retrieved_chunks=retrieved_chunks
)

final_output[field["field_name"]] = resolved_output
print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")
