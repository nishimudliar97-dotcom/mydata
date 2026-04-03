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


def line_match_score(llm_line, metadata_line):
    llm_norm = normalize_text(llm_line)
    meta_norm = normalize_text(metadata_line)

    if not llm_norm or not meta_norm:
        return 0

    if llm_norm == meta_norm:
        return 1000

    if llm_norm in meta_norm or meta_norm in llm_norm:
        return 800

    llm_tokens = set(llm_norm.split())
    meta_tokens = set(meta_norm.split())

    if not llm_tokens or not meta_tokens:
        return 0

    return len(llm_tokens.intersection(meta_tokens))


def merge_bboxes(bboxes):
    if not bboxes:
        return None

    x1 = min(b[0] for b in bboxes)
    y1 = min(b[1] for b in bboxes)
    x2 = max(b[2] for b in bboxes)
    y2 = max(b[3] for b in bboxes)

    return [x1, y1, x2, y2]


def find_best_match_from_position(llm_line, chunk_lines, start_index):
    best_idx = None
    best_score = 0

    for idx in range(start_index, len(chunk_lines)):
        meta_text = chunk_lines[idx].get("text", "")

        if not line_matches(llm_line, meta_text):
            continue

        score = line_match_score(llm_line, meta_text)
        if score > best_score:
            best_score = score
            best_idx = idx

            if score >= 1000:
                break

    return best_idx


def combine_bboxes_by_page(matched_lines):
    """
    Input:
    [
        {
            "Page": 1,
            "B_Box": [x1, y1, x2, y2],
            "Line_Text": "..."
        },
        ...
    ]

    Output:
    [
        {
            "Page": 1,
            "B_Box": [combined_x1, combined_y1, combined_x2, combined_y2]
        },
        {
            "Page": 2,
            "B_Box": [...]
        }
    ]
    """

    if not matched_lines:
        return []

    page_to_bboxes = {}

    for line in matched_lines:
        page = line.get("Page")
        bbox = line.get("B_Box")

        if page is None or not bbox:
            continue

        if page not in page_to_bboxes:
            page_to_bboxes[page] = []

        page_to_bboxes[page].append(bbox)

    combined_coordinates = []
    for page in sorted(page_to_bboxes.keys()):
        combined_coordinates.append({
            "Page": page,
            "B_Box": merge_bboxes(page_to_bboxes[page])
        })

    return combined_coordinates


def resolve_line_bboxes(llm_result, retrieved_chunks):
    """
    Final output format:
    {
        "Value": ...,
        "Chunk_id": ...,
        "Document ID": ...,
        "Document Category": ...,
        "Coordinates": [
            {
                "Page": 1,
                "B_Box": [x1, y1, x2, y2]
            },
            {
                "Page": 2,
                "B_Box": [x1, y1, x2, y2]
            }
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

    if not isinstance(llm_lines, list):
        llm_lines = [str(llm_lines)]

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

    matched_lines = []
    current_search_index = 0

    for llm_line in llm_lines:
        best_match_idx = find_best_match_from_position(
            llm_line=llm_line,
            chunk_lines=chunk_lines,
            start_index=current_search_index
        )

        if best_match_idx is None:
            best_match_idx = find_best_match_from_position(
                llm_line=llm_line,
                chunk_lines=chunk_lines,
                start_index=0
            )

        if best_match_idx is not None:
            matched_line = chunk_lines[best_match_idx]

            matched_lines.append({
                "Page": matched_line.get("page"),
                "B_Box": matched_line.get("bbox"),
                "Line_Text": matched_line.get("text"),
                "Order_Index": best_match_idx
            })

            current_search_index = best_match_idx + 1

    combined_coordinates = combine_bboxes_by_page(matched_lines)

    return {
        "Value": value,
        "Chunk_id": chunk_id,
        "Document ID": document_id,
        "Document Category": document_category,
        "Coordinates": combined_coordinates
    }
