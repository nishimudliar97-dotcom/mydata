from typing import List, Dict, Any

def build_query(field: Dict[str, Any]) -> str:
    """Constructs query based on operation type."""
    operation_type = field.get("operation_type", "").lower()
    field_name = field.get("field_name", "").strip().lower()

    if field_name == "financial indemnity":
        return (
            "quantum current best estimate quantum current best estimates "
            "current best estimate totals and reserves total cbe and reserves "
            "total current reserves pd property damage stock bi business interruption "
            "net financial indemnity"
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






def rerank_financial_indemnity_chunks(chunks):
    priority_terms = [
        "quantum",
        "current best estimate",
        "totals and reserves",
        "total cbe and reserves",
        "total current",
        "property damage",
        "pd",
        "stock",
        "business interruption",
        "bi",
        "reserve"
    ]

    def score_chunk(chunk):
        text_parts = []

        if hasattr(chunk, "page_content") and chunk.page_content:
            text_parts.append(chunk.page_content.lower())

        metadata = getattr(chunk, "metadata", {}) or {}
        for key in ["heading", "sub_heading", "heading_path", "category", "document"]:
            value = metadata.get(key)
            if value:
                text_parts.append(str(value).lower())

        full_text = " ".join(text_parts)

        score = 0
        for term in priority_terms:
            if term in full_text:
                score += 1

        return score

    return sorted(chunks, key=score_chunk, reverse=True)
