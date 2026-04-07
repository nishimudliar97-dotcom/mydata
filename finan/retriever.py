from typing import List, Dict, Any

def build_query(field: Dict[str, Any]) -> str:
    """Constructs query based on operation type."""
    operation_type = field.get("operation_type", "").lower()
    field_name = field.get("field_name", "").strip().lower()

    if field_name == "financial indemnity":
        return (
            "totals reserves total cbe reserves total current "
            "property damage pd stock bi business interruption "
            "net indemnity loss table reserve"
        )

    if operation_type == "extract":
        return " ".join([
            field.get("field_name", ""),
            " ".join(field.get("possible_names", [])) if isinstance(field.get("possible_names"), list) else field.get("possible_names", ""),
            field.get("description", "")
        ]).strip()

    elif operation_type == "summarize":
        return " ".join(
            field.get("possible_names", [])
            if isinstance(field.get("possible_names"), list)
            else [field.get("possible_names", "")]
        ).strip()

    else:
        raise ValueError(f"Unsupported operation_type: {operation_type}")
