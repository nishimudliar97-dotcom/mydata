def compute_total_expenses(expense_value):
    if expense_value is None:
        return None

    # If value is already a list, use it directly
    if isinstance(expense_value, list):
        items = expense_value
    else:
        # Split string into lines/items
        items = [item.strip() for item in str(expense_value).split("\n") if item.strip()]

        # Fallback: if everything is in one line separated by commas
        if len(items) == 1 and "," in items[0]:
            items = [item.strip() for item in items[0].split(",") if item.strip()]

    total = 0
    cleaned_items = []

    for item in items:
        cleaned_items.append(item)

        match = re.search(r':\s*([\d,]+(?:\.\d+)?)', item)
        if match:
            number_str = match.group(1).replace(",", "")
            number = float(number_str) if "." in number_str else int(number_str)
            total += number

    cleaned_items.append(f"Total Expenses: {int(total) if total == int(total) else total}")

    return cleaned_items
