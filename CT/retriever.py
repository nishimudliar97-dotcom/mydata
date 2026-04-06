from typing import List, Dict, Any


def build_query(field: Dict[str, Any]) -> str:
    """
    Constructs query based on operation type.
    """
    operation_type = field.get("operation_type", "").lower()

    if operation_type == "extract":
        return " ".join(
            [
                field.get("field_name", ""),
                " ".join(field.get("possible_names", []))
                if isinstance(field.get("possible_names", []), list)
                else field.get("possible_names", ""),
                field.get("description", "")
            ]
        ).strip()

    elif operation_type == "summarize":
        return " ".join(
            [
                field.get("field_name", ""),
                " ".join(field.get("possible_names", []))
                if isinstance(field.get("possible_names", []), list)
                else field.get("possible_names", ""),
                field.get("description", "")
            ]
        ).strip()

    else:
        raise ValueError(f"Unsupported operation_type: {operation_type}")


def extractor(
    vector_stores,
    field,
    default_k=3
) -> List[Any]:
    """
    Retrieves and filters chunks from multiple vector stores based on field configuration.
    """
    query = build_query(field)
    print(f"Query for {field['field_name']}: {query}")

    categories = field.get("document_category", [])
    if not categories:
        raise ValueError("No document categories provided in field config.")

    final_results = []

    # -------------------- Retrieval --------------------
    for category in categories:
        if category not in vector_stores:
            print(f"[WARNING] No vector store found for category: {category}")
            continue

        print(f"[INFO] Retrieving from category: {category}")

        retriever = vector_stores[category]

        try:
            results = retriever.similarity_search(query, k=default_k)
            print(f"Raw retrieved chunks from category {category}: {len(results)}")

            for i, r in enumerate(results, 1):
                print(
                    f"  Raw chunk {i} | "
                    f"id={r.metadata.get('chunk_id')} | "
                    f"heading={r.metadata.get('heading')} | "
                    f"document={r.metadata.get('document')} | "
                    f"chars={len(r.page_content)}"
                )

            final_results.extend(results)

        except Exception as e:
            print(f"[ERROR] Retrieval failed for category {category}: {str(e)}")

    # -------------------- Filtering --------------------
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

    print(f"Total chunks after filtering: {len(filtered_chunks)}")
    for chunk in filtered_chunks:
        print("-" * 50)
        print(f"Chunk ID: {chunk.metadata.get('chunk_id')}")
        print(f"Document: {chunk.metadata.get('document')}")
        print(f"Heading: {chunk.metadata.get('heading')}")
        print(f"Chars: {len(chunk.page_content)}")
        print(f"Pages: {chunk.metadata.get('page_start')} - {chunk.metadata.get('page_end')}")
        print(f"Category: {chunk.metadata.get('category')}")

    return filtered_chunks
