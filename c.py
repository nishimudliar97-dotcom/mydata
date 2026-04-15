def compute_total_expenses(expense_value):
    if expense_value is None:
        return None

    value = expense_value

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

    total = 0
    cleaned = {}

    for raw_key, raw_val in merged.items():
        if raw_val is None:
            continue

        key = str(raw_key).strip()
        val = raw_val

        # if numeric already
        if isinstance(val, (int, float)):
            cleaned[key] = val
            total += val
            continue

        # if string numeric
        val_str = str(val).strip()
        numeric_part = re.sub(r"[^\d.]", "", val_str)

        if numeric_part:
            number = float(numeric_part) if "." in numeric_part else int(numeric_part)
            cleaned[key] = number
            total += number
        else:
            cleaned[key] = val

    cleaned["Total Expense"] = int(total) if total == int(total) else total

    return cleaned
