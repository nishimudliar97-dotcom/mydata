from typing import List, Dict, Any


def build_cause_query():
    """
    Query used to retrieve document chunks relevant to cause/circumstances of loss.
    """
    return (
        "circumstances of loss cause of loss incident cause "
        "water ingress wind damage roof leakage rain entry "
        "root cause source of damage"
    )


def retrieve_document_cause_chunks(vector_stores, default_k=5) -> List[Any]:
    """
    Retrieves relevant loss/cause chunks from Loss Adjuster Report vector store.
    """
    query = build_cause_query()
    final_results = []

    target_category = "Loss Adjuster Report"
    if target_category not in vector_stores:
        print(f"[WARNING] No vector store found for category: {target_category}")
        return []

    retriever = vector_stores[target_category]

    try:
        results = retriever.similarity_search(query, k=default_k)
        final_results.extend(results)
    except Exception as e:
        print(f"[ERROR] Cause document retrieval failed: {str(e)}")

    # Deduplicate by chunk_id
    filtered_chunks = []
    seen_ids = set()

    for chunk in final_results:
        metadata = getattr(chunk, "metadata", {})
        chunk_id = metadata.get("chunk_id") or hash(chunk.page_content)

        if chunk_id in seen_ids:
            continue

        seen_ids.add(chunk_id)
        filtered_chunks.append(chunk)

    return filtered_chunks


def build_cause_narrative_from_chunks(retrieved_chunks: List[Any]) -> str:
    """
    Build compact narrative text from retrieved document chunks.
    """
    if not retrieved_chunks:
        return ""

    parts = []

    for chunk in retrieved_chunks:
        metadata = chunk.metadata
        heading = metadata.get("heading", "")
        document = metadata.get("document", "")
        category = metadata.get("category", "")
        chunk_id = metadata.get("chunk_id", "")

        body = chunk.page_content
        if "\n" in body:
            split_body = body.split("\n", 1)
            if len(split_body) > 1:
                body = split_body[1]

        text = f"""
Chunk ID: {chunk_id}
Document: {document}
Category: {category}
Heading: {heading}
Body:
{body}
""".strip()

        parts.append(text)

    return "\n\n------------------------------\n\n".join(parts)


def retrieve_cause_code_candidates(cause_code_vector_store, cause_narrative: str, top_k=5) -> List[Any]:
    """
    Retrieves best matching cause code rows from cause code FAISS.
    """
    if not cause_narrative:
        return []

    try:
        return cause_code_vector_store.similarity_search(cause_narrative, k=top_k)
    except Exception as e:
        print(f"[ERROR] Cause code candidate retrieval failed: {str(e)}")
        return []


def build_cause_code_candidates_text(candidates: List[Any]) -> str:
    """
    Converts retrieved cause code candidate rows to prompt-friendly text.
    """
    if not candidates:
        return ""

    rows = []
    for idx, doc in enumerate(candidates, start=1):
        meta = doc.metadata
        rows.append(
            f"""Candidate {idx}:
cause_code_id: {meta.get("cause_code_id")}
cause_l1: {meta.get("cause_l1")}
cause_l2: {meta.get("cause_l2")}"""
        )

    return "\n\n".join(rows)
