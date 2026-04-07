import re


def normalize_text(text):
    if text is None:
        return ""
    text = str(text)
    text = text.strip().lower()
    text = re.sub(r"\s+", " ", text)
    return text


def find_chunk_by_id(retrieved_chunks, chunk_id):
    target = str(chunk_id).strip() if chunk_id is not None else ""
    for chunk in retrieved_chunks:
        current = str(chunk.metadata.get("chunk_id", "")).strip()
        if current == target:
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

    llm_compact = llm_norm.replace(" ", "")
    meta_compact = meta_norm.replace(" ", "")

    if llm_compact == meta_compact:
        return True

    if llm_compact in meta_compact:
        return True

    if meta_compact in llm_compact:
        return True

    return False


















def combine_bboxes_by_page(matches):
    """
    matches: list of dicts like:
    {
        "page": 1,
        "bbox": [x1, y1, x2, y2]
    }
    """
    page_groups = {}

    for item in matches:
        page = item["page"]
        bbox = item["bbox"]

        if page not in page_groups:
            page_groups[page] = []

        page_groups[page].append(bbox)

    combined = []

    for page, bboxes in page_groups.items():
        x1 = min(b[0] for b in bboxes)
        y1 = min(b[1] for b in bboxes)
        x2 = max(b[2] for b in bboxes)
        y2 = max(b[3] for b in bboxes)

        combined.append({
            "Page": page,
            "B_Box": [x1, y1, x2, y2]
        })

    return combined














def resolve_line_bboxes(llm_result, retrieved_chunks):
    """
    Returns:
    {
        "Value": ...,
        "Chunk_id": ...,
        "Document ID": ...,
        "Document Category": ...,
        "Coordinates": [...]
    }
    """
    print("[DEBUG] resolver input Value:", llm_result.get("Value"))
    print("[DEBUG] resolver input Chunk_id:", llm_result.get("Chunk_id"))
    print("[DEBUG] resolver input lines:", llm_result.get("lines"))

    matched_chunk = find_chunk_by_id(retrieved_chunks, llm_result.get("Chunk_id"))
    print("[DEBUG] matched_chunk found:", matched_chunk is not None)

    if not matched_chunk:
        return {
            "Value": llm_result.get("Value"),
            "Chunk_id": llm_result.get("Chunk_id"),
            "Document ID": None,
            "Document Category": None,
            "Coordinates": []
        }

    print("[DEBUG] matched_chunk metadata:", matched_chunk.metadata)

    document_id = (
        matched_chunk.metadata.get("document_id")
        or matched_chunk.metadata.get("document")
    )

    document_category = (
        matched_chunk.metadata.get("document_category")
        or matched_chunk.metadata.get("category")
    )

    lines_from_llm = llm_result.get("lines") or []
    metadata_lines = matched_chunk.metadata.get("lines", []) or []

    matched_bboxes = []

    for llm_line in lines_from_llm:
        for metadata_line in metadata_lines:
            metadata_text = metadata_line.get("text", "")
            if line_matches(llm_line, metadata_text):
                bbox = metadata_line.get("bbox")
                page = metadata_line.get("page")

                if bbox is not None and page is not None:
                    matched_bboxes.append({
                        "page": page,
                        "bbox": bbox
                    })

    coordinates = combine_bboxes_by_page(matched_bboxes) if matched_bboxes else []

    return {
        "Value": llm_result.get("Value"),
        "Chunk_id": llm_result.get("Chunk_id"),
        "Document ID": document_id,
        "Document Category": document_category,
        "Coordinates": coordinates
    }
