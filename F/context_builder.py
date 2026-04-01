def build_context(chunks):
    print("\nBuilding lightweight context from retrieved chunks...")
    context_parts = []

    for chunk in chunks:
        metadata = getattr(chunk, "metadata", {})

        chunk_id = metadata.get("chunk_id", "")
        heading = metadata.get("heading", "")
        document_id = metadata.get("document", "")
        category = metadata.get("category", "")

        block = f"""
[CHUNK_ID: {chunk_id}]
[DOCUMENT_ID: {document_id}]
[CATEGORY: {category}]
[HEADING: {heading}]
{chunk.page_content}
""".strip()

        context_parts.append(block)

    context = "\n\n" + ("\n" + "=" * 80 + "\n\n").join(context_parts)
    print(context)
    return context
