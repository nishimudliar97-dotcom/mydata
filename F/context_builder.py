def build_context(chunks):
    try:
        print("\nBuilding context from retrieved chunks...")
        context = ""

        for chunk in chunks:
            body = chunk.page_content.split("\n", 1)[1] if "\n" in chunk.page_content else chunk.page_content

            context += f"""
------------------------------
Chunk ID: {chunk.metadata.get('chunk_id')}
Document: {chunk.metadata.get('document')}
Category: {chunk.metadata.get('category')}
Heading: {chunk.metadata.get('heading')}
Pages: {chunk.metadata.get('page_start')} - {chunk.metadata.get('page_end')}

Body:
{body}
"""

    except Exception as e:
        print(f"An error occurred while building context: {e}")
        context = ""

    return context
