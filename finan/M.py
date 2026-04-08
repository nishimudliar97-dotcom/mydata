import re

def clean_financial_indemnity_output(value):
    """
    Cleans Financial Indemnity values only for final output.
    Removes currency symbols/codes and commas.
    Example:
    "$1,250,000" -> "1250000"
    "USD 450,000" -> "450000"
    """
    if not isinstance(value, list):
        return value

    cleaned_list = []

    for item in value:
        if not isinstance(item, dict):
            cleaned_list.append(item)
            continue

        cleaned_item = {}
        for key, raw_val in item.items():
            if raw_val is None:
                cleaned_item[key] = raw_val
                continue

            val = str(raw_val).strip()

            # remove common currency codes/symbols
            val = re.sub(r'\b(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\b', '', val, flags=re.IGNORECASE)
            val = re.sub(r'[₹£€$]', '', val)

            # remove commas and extra spaces
            val = val.replace(',', '').strip()

            cleaned_item[key] = val

        cleaned_list.append(cleaned_item)

    return cleaned_list




final_value = resolved_output.get("Value") if resolved_output.get("Value") is not None else llm_result.get("Value")
final_value = clean_financial_indemnity_output(final_value)

final_output[field["field_name"]] = {
    "Value": final_value,
    "Chunk_id": resolved_output.get("Chunk_id") if resolved_output.get("Chunk_id") is not None else llm_result.get("Chunk_id"),
    "Document ID": resolved_output.get("Document ID"),
    "Document Category": resolved_output.get("Document Category"),
    "Coordinates": resolved_output.get("Coordinates", [])
}

