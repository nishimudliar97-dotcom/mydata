def build_context(chunks, field_name=None):
    try:
        print("\nBuilding context from retrieved chunks...")
        context = ""

        # Safer limits for debugging prompt inflation
        # Coverage Triggered is the noisy field, so keep it tighter first
        if field_name == "Coverage Triggered":
            max_body_chars = 1200
        else:
            max_body_chars = 2500

        for chunk in chunks:
            page_content = chunk.page_content or ""

            # Expected format from your indexer:
            # Heading: <heading>\n\n<body>
            if "\n" in page_content:
                parts = page_content.split("\n", 1)
                body = parts[1]
            else:
                body = page_content

            print(f"Chunk {chunk.metadata.get('chunk_id')} body chars before trim: {len(body)}")

            if len(body) > max_body_chars:
                body = body[:max_body_chars]
                print(
                    f"Chunk {chunk.metadata.get('chunk_id')} body trimmed to: "
                    f"{len(body)} chars"
                )

            context += f"""
Chunk ID: {chunk.metadata.get('chunk_id')}
Document: {chunk.metadata.get('document')}
Category: {chunk.metadata.get('category')}
Heading: {chunk.metadata.get('heading')}

Body: {body}
------------------------------
"""

        print(f"Final built context chars: {len(context)}")

    except Exception as e:
        print(f"An error occurred while building context: {e}")
        context = ""

    return context
