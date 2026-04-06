from typing import List, Dict, Any


def is_coverage_triggered_field(field: Dict[str, Any]) -> bool:
    return field.get("field_name", "").strip().lower() == "coverage triggered"


def build_query(field: Dict[str, Any]) -> str:
    """Constructs query based on operation type."""
    operation_type = field.get("operation_type", "").lower()

    if is_coverage_triggered_field(field):
        return " ".join([
            "coverage position",
            "interim coverage position",
            "covered in principle",
            "covered under",
            "policy responds under",
            "triggered coverage",
            "applicable coverage",
            "engaged coverage",
            "operative peril",
            "proximate cause",
            "indemnity position",
            field.get("description", "")
        ]).strip()

    if operation_type == "extract":
        return " ".join([
            field.get("field_name", ""),
            " ".join(field.get("possible_names", []))
            if isinstance(field.get("possible_names"), list)
            else field.get("possible_names", ""),
            field.get("description", "")
        ]).strip()

    elif operation_type == "summarize":
        return " ".join([
            " ".join(field.get("possible_names", []))
            if isinstance(field.get("possible_names"), list)
            else field.get("possible_names", "")
        ]).strip()

    else:
        raise ValueError(f"Unsupported operation_type: {operation_type}")


def rerank_coverage_triggered_chunks(chunks: List[Any]) -> List[Any]:
    positive_heading_terms = [
        "executive summary",
        "coverage position",
        "interim coverage position",
        "coverage analysis",
        "indemnity position",
        "operative peril",
        "proximate cause"
    ]

    positive_body_terms = [
        "covered in principle",
        "covered under",
        "responds under",
        "policy responds",
        "triggered under",
        "engaged by this event",
        "applicable coverage",
        "coverage position",
        "indemnity position",
        "operative peril",
        "proximate cause"
    ]

    negative_terms = [
        "sections in force",
        "schedule alignment",
        "policy schedule",
        "coverage schedule",
        "insuring clauses",
        "available sections"
    ]

    def score_chunk(chunk):
        metadata = getattr(chunk, "metadata", {}) or {}
        heading = str(metadata.get("heading", "")).lower()
        body = str(getattr(chunk, "page_content", "")).lower()

        score = 0

        for term in positive_heading_terms:
            if term in heading:
                score += 50

        for term in positive_body_terms:
            if term in body:
                score += 20

        for term in negative_terms:
            if term in heading:
                score -= 40
            if term in body:
                score -= 15

        if "pd and bi" in body or "pd & bi" in body:
            score += 25

        return score

    return sorted(chunks, key=score_chunk, reverse=True)


def extractor(vector_stores, field, default_k=3) -> List[Any]:
    """
    Retrieves and filters chunks from multiple vector stores based on field configuration.
    """
    query = build_query(field)
    categories = field.get("document_category", [])

    if not categories:
        raise ValueError("No document categories provided in field config.")

    final_results = []

    # ---------- Retrieval ----------
    for category in categories:
        if category not in vector_stores:
            print(f"[WARNING] No vector store found for category: {category}")
            continue

        print(f"[INFO] Retrieving from category: {category}")

        retriever = vector_stores[category]

        try:
            results = retriever.similarity_search(query, k=default_k)
            final_results.extend(results)
        except Exception as e:
            print(f"[ERROR] Retrieval failed for category {category}: {str(e)}")

    # ---------- Filtering ----------
    filtered_chunks = []
    seen_ids = set()

    for chunk in final_results:
        metadata = getattr(chunk, "metadata", {})

        # Validate category
        chunk_category = metadata.get("category")
        if chunk_category not in categories:
            continue

        # Deduplicate using chunk_id (preferred) or fallback to content hash
        chunk_id = metadata.get("chunk_id") or hash(chunk.page_content)

        if chunk_id in seen_ids:
            continue

        seen_ids.add(chunk_id)
        filtered_chunks.append(chunk)

    if is_coverage_triggered_field(field):
        filtered_chunks = rerank_coverage_triggered_chunks(filtered_chunks)
        filtered_chunks = filtered_chunks[:3]

    print(f"Total chunks after filtering: {len(filtered_chunks)}")
    # print("-"*50 + "\n")
    # for chunk in filtered_chunks:
    #     print(f"Chunk ID: {chunk.metadata['chunk_id']}")
    #     print(f"Document: {chunk.metadata['document']}")
    #     print(f"Heading: {chunk.metadata['heading']}")
    #     print(f"{chunk.page_content}")
    #     print(f"Pages: {chunk.metadata['page_start']} - {chunk.metadata['page_end']}")
    #     print(f"Bounding Box: {chunk.metadata['bbox']}")
    #     print(f"Category: {chunk.metadata['category']}")
    #     print(f"Lines: \n {chunk.metadata['lines']}")
    #     print("\n" + "="*50 + "\n")

    return filtered_chunks
