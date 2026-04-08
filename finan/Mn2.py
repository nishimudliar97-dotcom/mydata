import ast
import re

def clean_financial_indemnity_output(value):
    if value is None:
        return None

    # Keep unwrapping if value is a string representation of Python object
    for _ in range(2):
        if isinstance(value, str):
            raw = value.strip()
            try:
                value = ast.literal_eval(raw)
            except Exception:
                break

    if isinstance(value, list):
        if not value:
            return None
        value = value[0]

    if not isinstance(value, dict):
        return value

    cleaned_dict = {}
    total_indemnity = 0

    for key, raw_val in value.items():
        if raw_val is None:
            continue

        val = str(raw_val).strip()

        # Remove currency words
        val = re.sub(r'\b(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\b', '', val, flags=re.IGNORECASE)

        # Remove symbols
        val = re.sub(r'[£$€₹¥]', '', val)

        # Remove commas/spaces
        val = val.replace(",", "").strip()

        # Keep only digits and decimal point
        numeric_part = re.sub(r"[^\d.]", "", val)

        if not numeric_part:
            continue

        number = float(numeric_part) if "." in numeric_part else int(numeric_part)

        cleaned_dict[key] = number
        total_indemnity += number

    if cleaned_dict:
        cleaned_dict["Total Indemnity"] = int(total_indemnity) if total_indemnity == int(total_indemnity) else total_indemnity

    return cleaned_dict if cleaned_dict else None
