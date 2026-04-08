def clean_financial_indemnity_output(value):
    if value is None:
        return None

    # If value is a string like:
    # "[{'Property Damage': 'GBP630,600', 'Business Interruption': 'GBP160,800'}]"
    # convert it into Python object first
    if isinstance(value, str):
        raw = value.strip()
        try:
            value = ast.literal_eval(raw)
        except Exception:
            return value

    # If value comes as list, take first dict
    if isinstance(value, list):
        if not value:
            return None
        value = value[0]

    # If after parsing it is not a dict, return as-is
    if not isinstance(value, dict):
        return value

    cleaned_dict = {}
    total_indemnity = 0

    for key, raw_val in value.items():
        if raw_val is None:
            continue

        val = str(raw_val).strip()

        # Remove currency words/symbols
        val = re.sub(r'\b(?:USD|EUR|GBP|INR|AUD|CAD|SGD|AED|CHF|ZAR|JPY|HKD)\b', '', val, flags=re.IGNORECASE)
        val = re.sub(r'[£$€₹¥]', '', val)

        # Remove commas and spaces
        val = val.replace(',', '').strip()

        # Keep only digits if possible
        numeric_part = re.sub(r'[^\d.]', '', val)

        if not numeric_part:
            continue

        # Convert to int if whole number else float
        if '.' in numeric_part:
            number = float(numeric_part)
        else:
            number = int(numeric_part)

        cleaned_dict[key] = number
        total_indemnity += number

    if cleaned_dict:
        cleaned_dict["Total Indemnity"] = int(total_indemnity) if total_indemnity == int(total_indemnity) else total_indemnity

    return cleaned_dict if cleaned_dict else None
