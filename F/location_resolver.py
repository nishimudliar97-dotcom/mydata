import os
import re
import fitz  # PyMuPDF


def normalize_text(text):
    if text is None:
        return ""
    text = str(text)
    text = re.sub(r"\s+", " ", text.strip())
    return text.lower()


def rect_to_list(rect):
    return [float(rect.x0), float(rect.y0), float(rect.x1), float(rect.y1)]


def rect_intersects_line(rect, line_bbox, tolerance=2):
    if not line_bbox:
        return True

    lx0, ly0, lx1, ly1 = line_bbox
    expanded_line = fitz.Rect(lx0 - tolerance, ly0 - tolerance, lx1 + tolerance, ly1 + tolerance)
    return fitz.Rect(rect).intersects(expanded_line)


def find_pdf_path(pdf_root, document_name):
    for root, _, files in os.walk(pdf_root):
        for file in files:
            if file == document_name:
                return os.path.join(root, file)
    return None


def find_chunk_by_id(retrieved_chunks, chunk_id):
    for chunk in retrieved_chunks:
        if chunk.metadata.get("chunk_id") == chunk_id:
            return chunk
    return None


def search_exact_in_page(page, value):
    try:
        return page.search_for(value)
    except Exception:
        return []


def search_words_in_page(page, value):
    value_tokens = normalize_text(value).split()
    if not value_tokens:
        return []

    words = page.get_text("words")
    words = sorted(words, key=lambda w: (w[5], w[6], w[7], w[0]))

    matched_rects = []
    normalized_words = [normalize_text(w[4]) for w in words]

    i = 0
    while i <= len(words) - len(value_tokens):
        candidate = normalized_words[i:i + len(value_tokens)]
        if candidate == value_tokens:
            x0 = min(words[j][0] for j in range(i, i + len(value_tokens)))
            y0 = min(words[j][1] for j in range(i, i + len(value_tokens)))
            x1 = max(words[j][2] for j in range(i, i + len(value_tokens)))
            y1 = max(words[j][3] for j in range(i, i + len(value_tokens)))
            matched_rects.append(fitz.Rect(x0, y0, x1, y1))
            i += len(value_tokens)
        else:
            i += 1

    return matched_rects


def get_candidate_line_bboxes(chunk, page_number, value):
    candidate_lines = []
    lines = chunk.metadata.get("lines", []) or []
    norm_value = normalize_text(value)

    for line in lines:
        if line.get("page") != page_number:
            continue

        line_text = normalize_text(line.get("text", ""))
        if norm_value and norm_value in line_text:
            candidate_lines.append(line.get("bbox"))

    return candidate_lines


def resolve_value_coordinates(llm_result, retrieved_chunks, pdf_root):
    """
    Returns:
    {
        "Value": ...,
        "Document Category": ...,
        "Document ID": ...,
        "Chunk ID": ...,
        "Page Number": ...,
        "Coordinates": [
            {"Page": 2, "B_Box": [x1, y1, x2, y2]}
        ]
    }
    """

    empty_response = {
        "Value": None,
        "Document Category": None,
        "Document ID": None,
        "Chunk ID": None,
        "Page Number": None,
        "Coordinates": []
    }

    if not llm_result or not llm_result.get("Value") or not llm_result.get("Chunk ID"):
        return empty_response

    value = llm_result.get("Value")
    chunk_id = llm_result.get("Chunk ID")
    llm_page_number = llm_result.get("Page Number")

    chunk = find_chunk_by_id(retrieved_chunks, chunk_id)
    if not chunk:
        return {
            **empty_response,
            "Value": value,
            "Chunk ID": chunk_id
        }

    metadata = chunk.metadata
    document_id = metadata.get("document")
    document_category = metadata.get("category")
    page_start = metadata.get("page_start")
    page_end = metadata.get("page_end")

    pdf_path = find_pdf_path(pdf_root, document_id)
    if not pdf_path:
        return {
            "Value": value,
            "Document Category": document_category,
            "Document ID": document_id,
            "Chunk ID": chunk_id,
            "Page Number": llm_page_number,
            "Coordinates": []
        }

    candidate_pages = []
    if isinstance(llm_page_number, int) and page_start <= llm_page_number <= page_end:
        candidate_pages = [llm_page_number]
    else:
        candidate_pages = list(range(page_start, page_end + 1))

    coordinates = []

    doc = fitz.open(pdf_path)
    try:
        for page_number in candidate_pages:
            page = doc.load_page(page_number - 1)

            exact_rects = search_exact_in_page(page, value)

            candidate_line_bboxes = get_candidate_line_bboxes(chunk, page_number, value)

            filtered_exact = []
            if candidate_line_bboxes:
                for rect in exact_rects:
                    if any(rect_intersects_line(rect, line_bbox) for line_bbox in candidate_line_bboxes):
                        filtered_exact.append(rect)
            else:
                filtered_exact = exact_rects

            final_rects = filtered_exact

            if not final_rects:
                word_rects = search_words_in_page(page, value)

                if candidate_line_bboxes:
                    filtered_word_rects = []
                    for rect in word_rects:
                        if any(rect_intersects_line(rect, line_bbox) for line_bbox in candidate_line_bboxes):
                            filtered_word_rects.append(rect)
                    final_rects = filtered_word_rects
                else:
                    final_rects = word_rects

            for rect in final_rects:
                coordinates.append({
                    "Page": page_number,
                    "B_Box": rect_to_list(rect)
                })

            if coordinates:
                break

    finally:
        doc.close()

    return {
        "Value": value,
        "Document Category": document_category,
        "Document ID": document_id,
        "Chunk ID": chunk_id,
        "Page Number": llm_page_number,
        "Coordinates": coordinates
    }
