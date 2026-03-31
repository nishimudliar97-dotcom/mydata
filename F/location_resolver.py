import re
import unicodedata
from difflib import SequenceMatcher


def normalize_text(text: str) -> str:
    if text is None:
        return ""

    text = unicodedata.normalize("NFKC", str(text))

    replacements = {
        "\u2010": "-",
        "\u2011": "-",
        "\u2012": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u00a0": " ",
        "\t": " ",
        "\n": " ",
        "\r": " ",
    }

    for k, v in replacements.items():
        text = text.replace(k, v)

    text = text.lower().strip()
    text = re.sub(r"\s+", " ", text)
    return text


def fuzzy_score(a: str, b: str) -> float:
    return SequenceMatcher(None, normalize_text(a), normalize_text(b)).ratio()


def find_chunk_by_id(retrieved_chunks, chunk_id):
    if not chunk_id:
        return None

    for chunk in retrieved_chunks:
        metadata = getattr(chunk, "metadata", {})
        if metadata.get("chunk_id") == chunk_id:
            return chunk

    return None


def _dedupe_coordinates(coords):
    seen = set()
    deduped = []

    for item in coords:
        page = item.get("Page")
        bbox = item.get("B_Box")

        if bbox is None:
            key = (page, None)
        else:
            key = (page, tuple(bbox))

        if key not in seen:
            seen.add(key)
            deduped.append(item)

    return deduped


def resolve_locations_for_value(chunk, value, evidence_text=None, fuzzy_threshold=0.88):
    """
    Returns a list like:
    [
        {"Page": 2, "B_Box": [x1, y1, x2, y2]},
        {"Page": 3, "B_Box": [x1, y1, x2, y2]}
    ]
    """
    if chunk is None:
        return []

    metadata = getattr(chunk, "metadata", {})
    lines = metadata.get("lines", [])

    if not lines:
        return []

    norm_value = normalize_text(value)
    norm_evidence = normalize_text(evidence_text)

    matches = []

    # 1) Exact / normalized evidence_text match on single line
    if norm_evidence:
        for line in lines:
            line_text = line.get("text", "")
            norm_line = normalize_text(line_text)

            if norm_evidence and norm_evidence in norm_line:
                matches.append({
                    "Page": line.get("page"),
                    "B_Box": line.get("bbox")
                })

        if matches:
            return _dedupe_coordinates(matches)

    # 2) Exact / normalized value match on single line
    if norm_value:
        for line in lines:
            line_text = line.get("text", "")
            norm_line = normalize_text(line_text)

            if norm_value and norm_value in norm_line:
                matches.append({
                    "Page": line.get("page"),
                    "B_Box": line.get("bbox")
                })

        if matches:
            return _dedupe_coordinates(matches)

    # 3) Adjacent two-line evidence_text match
    if norm_evidence and len(lines) > 1:
        for i in range(len(lines) - 1):
            line1 = lines[i]
            line2 = lines[i + 1]

            combined = f"{line1.get('text', '')} {line2.get('text', '')}"
            norm_combined = normalize_text(combined)

            if norm_evidence in norm_combined:
                matches.extend([
                    {"Page": line1.get("page"), "B_Box": line1.get("bbox")},
                    {"Page": line2.get("page"), "B_Box": line2.get("bbox")},
                ])

        if matches:
            return _dedupe_coordinates(matches)

    # 4) Adjacent two-line value match
    if norm_value and len(lines) > 1:
        for i in range(len(lines) - 1):
            line1 = lines[i]
            line2 = lines[i + 1]

            combined = f"{line1.get('text', '')} {line2.get('text', '')}"
            norm_combined = normalize_text(combined)

            if norm_value in norm_combined:
                matches.extend([
                    {"Page": line1.get("page"), "B_Box": line1.get("bbox")},
                    {"Page": line2.get("page"), "B_Box": line2.get("bbox")},
                ])

        if matches:
            return _dedupe_coordinates(matches)

    # 5) Fuzzy evidence_text fallback
    if norm_evidence:
        scored = []
        for line in lines:
            line_text = line.get("text", "")
            score = fuzzy_score(norm_evidence, line_text)
            scored.append((score, line))

        scored.sort(key=lambda x: x[0], reverse=True)

        if scored and scored[0][0] >= fuzzy_threshold:
            best_score = scored[0][0]

            for score, line in scored:
                if score >= best_score - 0.02:
                    matches.append({
                        "Page": line.get("page"),
                        "B_Box": line.get("bbox")
                    })

            if matches:
                return _dedupe_coordinates(matches)

    # 6) Fuzzy value fallback
    if norm_value:
        scored = []
        for line in lines:
            line_text = line.get("text", "")
            score = fuzzy_score(norm_value, line_text)
            scored.append((score, line))

        scored.sort(key=lambda x: x[0], reverse=True)

        if scored and scored[0][0] >= fuzzy_threshold:
            best_score = scored[0][0]

            for score, line in scored:
                if score >= best_score - 0.02:
                    matches.append({
                        "Page": line.get("page"),
                        "B_Box": line.get("bbox")
                    })

            if matches:
                return _dedupe_coordinates(matches)

    return []
