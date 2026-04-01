import json
import re
import unicodedata
from difflib import SequenceMatcher


def normalize_text(text):
    if type(text) != str:
        return text

    text = unicodedata.normalize("NFKC", text)

    replacements = {
        "\u202f": " ",
        "\u00a0": " ",
        "\u2011": "-",
        "\u2013": "-",
        "\u2014": "-",
    }

    for k, v in replacements.items():
        text = text.replace(k, v)

    text = re.sub(r"\s+", " ", text)
    return text.strip()


def normalize_for_match(text):
    if text is None:
        return ""

    text = normalize_text(text)
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "", text)
    return text.strip()


def parse_llm_output(raw_output):
    default_output = {"value": None, "chunk_id": None}

    if raw_output is None:
        return default_output

    if isinstance(raw_output, dict):
        data = raw_output
    else:
        raw_output = str(raw_output).strip()

        if raw_output.startswith("```json"):
            raw_output = raw_output[len("```json"):].strip()
        elif raw_output.startswith("```"):
            raw_output = raw_output[len("```"):].strip()

        if raw_output.endswith("```"):
            raw_output = raw_output[:-3].strip()

        try:
            data = json.loads(raw_output)
        except Exception:
            try:
                start = raw_output.find("{")
                end = raw_output.rfind("}")
                if start != -1 and end != -1:
                    data = json.loads(raw_output[start:end + 1])
                else:
                    return default_output
            except Exception:
                return default_output

    normalized_keys = {}
    for k, v in data.items():
        key = str(k).lower().replace(" ", "").replace("_", "")
        normalized_keys[key] = v

    value = normalized_keys.get("value")
    chunk_id = normalized_keys.get("chunkid")

    if isinstance(value, str) and value.strip().lower() in {"not_found", "null", "none"}:
        value = None

    if isinstance(chunk_id, str) and chunk_id.strip().lower() in {"not_found", "null", "none"}:
        chunk_id = None

    return {
        "value": value,
        "chunk_id": chunk_id,
    }


def find_chunk_by_id(retrieved_chunks, chunk_id):
    if not chunk_id:
        return None

    for chunk in retrieved_chunks:
        metadata = getattr(chunk, "metadata", {})
        if metadata.get("chunk_id") == chunk_id:
            return chunk

    return None


def merge_bboxes(bboxes):
    valid_bboxes = [bbox for bbox in bboxes if isinstance(bbox, list) and len(bbox) == 4]

    if not valid_bboxes:
        return None

    return [
        min(bbox[0] for bbox in valid_bboxes),
        min(bbox[1] for bbox in valid_bboxes),
        max(bbox[2] for bbox in valid_bboxes),
        max(bbox[3] for bbox in valid_bboxes),
    ]


def score_match(target_norm, candidate_norm):
    if not target_norm or not candidate_norm:
        return 0.0

    if target_norm == candidate_norm:
        return 1.0

    if target_norm in candidate_norm or candidate_norm in target_norm:
        return 0.98

    return SequenceMatcher(None, target_norm, candidate_norm).ratio()


def build_coordinate_objects_from_lines(lines_subset):
    page_to_bboxes = {}

    for line in lines_subset:
        page = line.get("page")
        bbox = line.get("bbox")

        if page is None or bbox is None:
            continue

        page_to_bboxes.setdefault(page, []).append(bbox)

    coordinates = []
    for page, bboxes in page_to_bboxes.items():
        merged_bbox = merge_bboxes(bboxes)
        if merged_bbox is not None:
            coordinates.append(
                {
                    "Page": page,
                    "B_Box": merged_bbox
                }
            )

    coordinates.sort(key=lambda x: x["Page"])
    return coordinates


def deduplicate_coordinates(coordinates):
    unique_coordinates = []
    seen = set()

    for coord in coordinates:
        page = coord.get("Page")
        bbox = coord.get("B_Box")

        if not isinstance(bbox, list) or len(bbox) != 4:
            continue

        key = (
            page,
            round(bbox[0], 4),
            round(bbox[1], 4),
            round(bbox[2], 4),
            round(bbox[3], 4),
        )

        if key not in seen:
            seen.add(key)
            unique_coordinates.append(coord)

    unique_coordinates.sort(key=lambda x: x["Page"])
    return unique_coordinates


def find_value_coordinates_in_chunk(chunk, extracted_value):
    if chunk is None or extracted_value is None:
        return []

    metadata = getattr(chunk, "metadata", {})
    lines = metadata.get("lines", [])

    if not isinstance(lines, list) or not lines:
        return []

    target_norm = normalize_for_match(extracted_value)

    if not target_norm:
        return []

    matched_coordinates = []

    # 1) Single line matching
    for line in lines:
        line_text = line.get("text", "")
        line_norm = normalize_for_match(line_text)
        score = score_match(target_norm, line_norm)

        if score >= 0.92:
            matched_coordinates.extend(build_coordinate_objects_from_lines([line]))

    # 2) Multi-line matching
    max_window = min(4, len(lines))
    for window_size in range(2, max_window + 1):
        for i in range(len(lines) - window_size + 1):
            line_group = lines[i:i + window_size]
            combined_text = " ".join(str(line.get("text", "")) for line in line_group)
            combined_norm = normalize_for_match(combined_text)
            score = score_match(target_norm, combined_norm)

            if score >= 0.90:
                matched_coordinates.extend(build_coordinate_objects_from_lines(line_group))

    # 3) Fallback best approximate group
    if not matched_coordinates:
        best_score = 0.0
        best_group = None

        for line in lines:
            line_text = line.get("text", "")
            line_norm = normalize_for_match(line_text)
            score = score_match(target_norm, line_norm)

            if score > best_score:
                best_score = score
                best_group = [line]

        for window_size in range(2, min(4, len(lines)) + 1):
            for i in range(len(lines) - window_size + 1):
                line_group = lines[i:i + window_size]
                combined_text = " ".join(str(line.get("text", "")) for line in line_group)
                combined_norm = normalize_for_match(combined_text)
                score = score_match(target_norm, combined_norm)

                if score > best_score:
                    best_score = score
                    best_group = line_group

        if best_group is not None and best_score >= 0.75:
            matched_coordinates.extend(build_coordinate_objects_from_lines(best_group))

    return deduplicate_coordinates(matched_coordinates)


def build_field_output(extracted_value, selected_chunk, coordinates):
    if selected_chunk is None:
        return {
            "Value": normalize_text(extracted_value) if extracted_value is not None else None,
            "Document Category": None,
            "Document ID": None,
            "Coordinates": []
        }

    metadata = getattr(selected_chunk, "metadata", {})

    return {
        "Value": normalize_text(extracted_value) if extracted_value is not None else None,
        "Document Category": metadata.get("category"),
        "Document ID": metadata.get("document"),
        "Coordinates": coordinates
    }
