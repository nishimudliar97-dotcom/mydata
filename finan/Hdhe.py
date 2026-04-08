import json
import ast
import re

def clean_financial_indemnity_output(value):
    if value is None:
        return None

    # Step 1: unwrap string -> python object
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

    # Step 2: normalize structure into one dict
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

    # Step 3: clean values and compute total
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

        # remove currency codes
        val = re.sub(
            r'\b(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\b',
            '',
            val,
            flags=re.IGNORECASE
        )

        # remove currency symbols
        val = re.sub(r'[£$€₹¥]', '', val)

        # remove commas/spaces
        val = val.replace(",", "").strip()

        # keep only digits and decimal point
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

        else:
            cleaned[str(raw_key).strip()] = number
            total_indemnity += number

    if cleaned:
        cleaned["Total Indemnity"] = int(total_indemnity) if total_indemnity == int(total_indemnity) else total_indemnity

    return cleaned if cleaned else None
