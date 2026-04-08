import json
import ast
import re

def clean_financial_indemnity_output(value):
    if value is None:
        return None

    # unwrap stringified JSON / python literal
    for _ in range(3):
        if isinstance(value, str):
            raw = value.strip()
            if not raw:
                return None

            parsed = None
            try:
                parsed = json.loads(raw)
            except Exception:
                pass

            if parsed is None:
                try:
                    parsed = ast.literal_eval(raw)
                except Exception:
                    pass

            if parsed is None:
                break

            value = parsed
        else:
            break

    merged = {}

    if isinstance(value, dict):
        merged = value

    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                for k, v in item.items():
                    merged[k] = v
    else:
        return value

    if not merged:
        return None

    cleaned = {}
    total_indemnity = 0

    for raw_key, raw_val in merged.items():
        if raw_val is None:
            continue

        key = str(raw_key).strip().lower()
        key = key.replace("net", "")
        key = key.replace("cbe", "")
        key = " ".join(key.split())

        val = str(raw_val).strip()

        val = re.sub(
            r'\b(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\b',
            '',
            val,
            flags=re.IGNORECASE
        )
        val = re.sub(r'[£$€₹¥]', '', val)
        val = val.replace(",", "").strip()
        numeric_part = re.sub(r"[^\d.]", "", val)

        if not numeric_part:
            continue

        number = float(numeric_part) if "." in numeric_part else int(numeric_part)

        if key in ["pd", "property damage"]:
            cleaned["Property Damage"] = number
            total_indemnity += number
        elif key in ["bi", "business interruption"]:
            cleaned["Business Interruption"] = number
            total_indemnity += number
        elif key == "stock":
            cleaned["Stock"] = number
            total_indemnity += number

    if cleaned:
        cleaned["Total Indemnity"] = int(total_indemnity) if total_indemnity == int(total_indemnity) else total_indemnity

    return cleaned if cleaned else None





















if field_name_normalized in ["financial indemnity", "financial indemnity breakdown"]:
    llm_result = run_financial_indemnity_llm(context)
    print(f"[DEBUG] Financial Indemnity parsed result before resolver: {json.dumps(llm_result, indent=2)}")

    resolved_output = resolve_line_bboxes(
        llm_result=llm_result,
        retrieved_chunks=retrieved_chunks
    )

    raw_final_value = resolved_output.get("Value")
    if raw_final_value is None:
        raw_final_value = llm_result.get("Value")

    print("[DEBUG] raw_final_value before cleaning =", raw_final_value)
    print("[DEBUG] type(raw_final_value) =", type(raw_final_value))

    final_value = clean_financial_indemnity_output(raw_final_value)

    print("[DEBUG] cleaned final_value =", final_value)
    print("[DEBUG] type(cleaned final_value) =", type(final_value))

    final_output[field["field_name"]] = {
        "Value": final_value,
        "Chunk_id": resolved_output.get("Chunk_id") if resolved_output.get("Chunk_id") is not None else llm_result.get("Chunk_id"),
        "Document ID": resolved_output.get("Document ID"),
        "Document Category": resolved_output.get("Document Category"),
        "Coordinates": resolved_output.get("Coordinates", [])
    }

    print(f"Extracted value for {field['field_name']}: {json.dumps(final_output[field['field_name']], indent=2)}")
    continue
