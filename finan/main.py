if field["field_name"].strip().lower() == "financial indemnity":
    llm_result = run_financial_indemnity_llm(context)
    print(f"[DEBUG] Financial Indemnity parsed result before resolver: {json.dumps(llm_result, indent=2)}")

    resolved_output = resolve_line_bboxes(
        llm_result=llm_result,
        retrieved_chunks=retrieved_chunks
    )

    final_output[field["field_name"]] = {
        "Value": resolved_output.get("Value") if resolved_output.get("Value") is not None else llm_result.get("Value"),
        "Chunk_id": resolved_output.get("Chunk_id") if resolved_output.get("Chunk_id") is not None else llm_result.get("Chunk_id"),
        "Document ID": resolved_output.get("Document ID"),
        "Document Category": resolved_output.get("Document Category"),
        "Coordinates": resolved_output.get("Coordinates", [])
    }

    print(f"Extracted value for {field['field_name']}: {json.dumps(final_output[field['field_name']], indent=2)}")
    continue
