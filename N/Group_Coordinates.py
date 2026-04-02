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
    """
    Higher score = better match
    Priority:
    1. exact normalized match
    2. one contains the other
    3. token overlap
    """
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

    overlap = len(llm_tokens.intersection(meta_tokens))
    return overlap


def merge_bboxes(bboxes):
    if not bboxes:
        return None

    x1 = min(b[0] for b in bboxes)
    y1 = min(b[1] for b in bboxes)
    x2 = max(b[2] for b in bboxes)
    y2 = max(b[3] for b in bboxes)

    return [x1, y1, x2, y2]


def are_consecutive_lines(prev_line, curr_line, y_tolerance=12):
    """
    Group lines only when:
    - they are on same page
    - vertical gap is small
    """
    if prev_line["Page"] != curr_line["Page"]:
        return False

    prev_bbox = prev_line.get("B_Box")
    curr_bbox = curr_line.get("B_Box")

    if not prev_bbox or not curr_bbox:
        return False

    prev_y2 = prev_bbox[3]
    curr_y1 = curr_bbox[1]
    vertical_gap = curr_y1 - prev_y2

    return -2 <= vertical_gap <= y_tolerance


def group_consecutive_lines(matched_lines):
    if not matched_lines:
        return []

    sorted_lines = sorted(
        matched_lines,
        key=lambda x: (
            x["Page"] if x["Page"] is not None else 10**9,
            x["Order_Index"] if x.get("Order_Index") is not None else 10**9,
            x["B_Box"][1] if x.get("B_Box") else 10**9,
            x["B_Box"][0] if x.get("B_Box") else 10**9,
        )
    )

    groups = []
    current_group = [sorted_lines[0]]

    for line in sorted_lines[1:]:
        prev_line = current_group[-1]

        if are_consecutive_lines(prev_line, line):
            current_group.append(line)
        else:
            groups.append(current_group)
            current_group = [line]

    groups.append(current_group)

    grouped_output = []
    for group in groups:
        group_bboxes = [line["B_Box"] for line in group if line.get("B_Box")]
        grouped_output.append({
            "Page": group[0]["Page"],
            "Combined_BBox": merge_bboxes(group_bboxes),
            "Lines": [
                {
                    "Page": line["Page"],
                    "B_Box": line["B_Box"],
                    "Line_Text": line["Line_Text"]
                }
                for line in group
            ]
        })

    return grouped_output


def find_best_match_from_position(llm_line, chunk_lines, start_index):
    """
    Search only forward from start_index.
    This preserves order and helps when same/similar lines repeat.
    """
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

            # exact match found, good enough to stop early
            if score >= 1000:
                break

    return best_idx


def resolve_line_bboxes(llm_result, retrieved_chunks):
    """
    Returns:
    {
        "Value": ...,
        "Chunk_id": ...,
        "Document ID": ...,
        "Document Category": ...,
        "Coordinates": [
            {"Page": 2, "B_Box": [...], "Line_Text": "..."}
        ],
        "Grouped_Coordinates": [
            {
                "Page": 2,
                "Combined_BBox": [...],
                "Lines": [...]
            }
        ]
    }
    """

    empty_response = {
        "Value": None,
        "Chunk_id": None,
        "Document ID": None,
        "Document Category": None,
        "Coordinates": [],
        "Grouped_Coordinates": []
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

    coordinates = []
    current_search_index = 0

    for llm_line in llm_lines:
        best_match_idx = find_best_match_from_position(
            llm_line=llm_line,
            chunk_lines=chunk_lines,
            start_index=current_search_index
        )

        if best_match_idx is None:
            # fallback: search entire chunk only if not found forward
            best_match_idx = find_best_match_from_position(
                llm_line=llm_line,
                chunk_lines=chunk_lines,
                start_index=0
            )

        if best_match_idx is not None:
            matched_line = chunk_lines[best_match_idx]

            coordinates.append({
                "Page": matched_line.get("page"),
                "B_Box": matched_line.get("bbox"),
                "Line_Text": matched_line.get("text"),
                "Order_Index": best_match_idx
            })

            # move forward so next line prefers later lines/pages
            current_search_index = best_match_idx + 1

    grouped_coordinates = group_consecutive_lines(coordinates)

    # remove internal ordering key from raw coordinates
    cleaned_coordinates = [
        {
            "Page": item["Page"],
            "B_Box": item["B_Box"],
            "Line_Text": item["Line_Text"]
        }
        for item in coordinates
    ]

    return {
        "Value": value,
        "Chunk_id": chunk_id,
        "Document ID": document_id,
        "Document Category": document_category,
        "Coordinates": cleaned_coordinates,
        "Grouped_Coordinates": grouped_coordinates
    }
