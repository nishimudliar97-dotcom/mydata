import re


def normalize_text(text):
    if text is None:
        return ""
    text = str(text)
    text = text.strip().lower()
    text = re.sub(r"\s+", " ", text)
    return text


def find_chunk_by_id(retrieved_chunks, chunk_id):
    for chunk in retrieved_chunks:
        if chunk.metadata.get("chunk_id") == chunk_id:
            return chunk
    return None


def line_matches(llm_line, metadata_line):
    llm_norm = normalize_text(llm_line)
    meta_norm = normalize_text(metadata_line)

    if not llm_norm or not meta_norm:
        return False

    if llm_norm == meta_norm:
        return True

    if llm_norm in meta_norm:
        return True

    if meta_norm in llm_norm:
        return True

    return False


def resolve_line_bboxes(llm_result, retrieved_chunks):
    """
    Returns:
    {
        "Value": ...,
        "Chunk_id": ...,
        "Document ID": ...,
        "Document Category": ...,
        "Coordinates": [
            {"Page": 2, "B_Box": [x1, y1, x2, y2], "Line_Text": "..."}
        ]
    }
    """

    empty_response = {
        "Value": None,
        "Chunk_id": None,
        "Document ID": None,
        "Document Category": None,
        "Coordinates": []
    }

    if not llm_result:
        return empty_response

    value = llm_result.get("Value")
    chunk_id = llm_result.get("Chunk_id")
    llm_lines = llm_result.get("lines")

    if not value or not chunk_id or not llm_lines:
        return {
            **empty_response,
            "Value": value,
            "Chunk_id": chunk_id
        }

    chunk = find_chunk_by_id(retrieved_chunks, chunk_id)
    if not chunk:
        return {
            **empty_response,
            "Value": value,
            "Chunk_id": chunk_id
        }

    metadata = chunk.metadata
    document_id = metadata.get("document")
    document_category = metadata.get("category")
    chunk_lines = metadata.get("lines", []) or []

    coordinates = []
    used_indexes = set()

    for llm_line in llm_lines:
        best_match_idx = None

        for idx, meta_line in enumerate(chunk_lines):
            if idx in used_indexes:
                continue

            meta_text = meta_line.get("text", "")
            if line_matches(llm_line, meta_text):
                best_match_idx = idx
                break

        if best_match_idx is not None:
            used_indexes.add(best_match_idx)
            matched_line = chunk_lines[best_match_idx]

            coordinates.append({
                "Page": matched_line.get("page"),
                "B_Box": matched_line.get("bbox"),
                "Line_Text": matched_line.get("text")
            })

    return {
        "Value": value,
        "Chunk_id": chunk_id,
        "Document ID": document_id,
        "Document Category": document_category,
        "Coordinates": coordinates
    }
