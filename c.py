def compute_total_expenses(expense_value):
    if expense_value is None:
        return None

    # Case 1: already a dict
    if isinstance(expense_value, dict):
        merged = expense_value

    # Case 2: list of dicts
    elif isinstance(expense_value, list):
        merged = {}
        for item in expense_value:
            if isinstance(item, dict):
                merged.update(item)

    # Case 3: string like:
    # "{Adjuster Fees/Disbursements: 18900, Disbursements: 1120, Forensics: 6750}"
    elif isinstance(expense_value, str):
        raw = expense_value.strip()

        if not raw:
            return None

        # remove outer curly braces if present
        if raw.startswith("{") and raw.endswith("}"):
            raw = raw[1:-1].strip()

        merged = {}

        # split by comma into key:value pairs
        pairs = [p.strip() for p in raw.split(",") if p.strip()]

        for pair in pairs:
            if ":" not in pair:
                continue

            key, val = pair.split(":", 1)
            key = key.strip().strip('"').strip("'")
            val = val.strip().strip('"').strip("'")

            numeric_part = re.sub(r"[^\d.]", "", val)

            if numeric_part:
                number = float(numeric_part) if "." in numeric_part else int(numeric_part)
                merged[key] = number
            else:
                merged[key] = val

    else:
        return expense_value

    if not merged:
        return None

    total = 0
    cleaned = {}

    for key, val in merged.items():
        cleaned[key] = val
        if isinstance(val, (int, float)):
            total += val

    cleaned["Total Expense"] = int(total) if total == int(total) else total

    return cleaned
