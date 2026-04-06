import json
import time
import re
import unicodedata

from Chunking.indexer_v2 import create_faiss_index
from Retriever.retriever_v2 import extractor
from Retriever.context_builder_v2 import build_context
from Retriever.llm import run_llm
from Retriever.line_bbox_resolver.py import resolve_line_bboxes
from Fields.fields_loader import load_fields_from_json
from Chunking.document_processing_v2 import process_all_documents
from Database.Insert_Data import ingest_claim_core

# Replacements for normalization
from Fields.replacements import replacements

PDF_PATH = "./Documents/ZNBECFIND202644912"
FIELDS_JSON_PATH = "./Fields/fields.json"


def normalize_text(text):
    if type(text) != str:
        return text

    text = unicodedata.normalize("NFKC", text)

    for k, v in replacements.items():
        text = text.replace(k, v)

    text = re.sub(r"\s+", " ", text)
    return text.strip()


def runner():
    # -----------------------------
    # Doc Ingestion and Indexing
    # -----------------------------
    all_chunks = []

    print("Loading PDF documents...")
    all_chunks = process_all_documents(PDF_PATH)
    print(f"Total chunks generated: {len(all_chunks)}")

    print("Creating FAISS Index...")
    vector_stores = create_faiss_index(all_chunks)
    print(f"Vector stores created for categories: {list(vector_stores.keys())}")
    print("Index created successfully!")

    # -----------------------------
    # Extraction Process
    # -----------------------------
    print("\nExtraction process started...")
    final_output = {}

    print("\nLoading fields to extract...")
    fields = load_fields_from_json(FIELDS_JSON_PATH)
    print(f"Fields to extract: {[field['field_name'] for field in fields]}")

    for field in fields:
        print(f"\nExtracting field: {field['field_name']}...")

        # If you want to test only Coverage Triggered, uncomment this:
        # if field["field_name"] != "Coverage Triggered":
        #     continue

        # For debugging Coverage Triggered, use fewer chunks first
        default_k = 1 if field["field_name"] == "Coverage Triggered" else 3

        retrieved_chunks = extractor(
            vector_stores=vector_stores,
            field=field,
            default_k=default_k
        )

        print(f"Retrieved chunks count for {field['field_name']}: {len(retrieved_chunks)}")
        for i, ch in enumerate(retrieved_chunks, 1):
            print(f"\n--- Retrieved Chunk {i} ---")
            print("chunk_id:", ch.metadata.get("chunk_id"))
            print("document:", ch.metadata.get("document"))
            print("category:", ch.metadata.get("category"))
            print("heading:", ch.metadata.get("heading"))
            print("page_start:", ch.metadata.get("page_start"))
            print("page_end:", ch.metadata.get("page_end"))
            print("chars in page_content:", len(ch.page_content))

        # Keep Coverage Triggered tighter for debugging
        if field["field_name"] == "Coverage Triggered":
            retrieved_chunks = retrieved_chunks[:1]
            print(f"Trimmed retrieved chunks for Coverage Triggered to: {len(retrieved_chunks)}")

        context = build_context(
            chunks=retrieved_chunks,
            field_name=field["field_name"]
        )

        print("Context characters:", len(context))
        print(context)
        print("\n" + "=" * 80 + "\n")

        llm_result = run_llm(field, context)

        if llm_result.get("Value") is not None:
            llm_result["Value"] = normalize_text(llm_result["Value"])

        resolved_output = resolve_line_bboxes(
            llm_result=llm_result,
            retrieved_chunks=retrieved_chunks
        )

        final_output[field["field_name"]] = resolved_output

        print(
            f"Extracted value for {field['field_name']}: "
            f"{json.dumps(resolved_output, indent=2, ensure_ascii=False)}"
        )

        # Keep the pause if you want, though your main issue looks request-size related
        time.sleep(180)

    print(f"Here is the output........\n{json.dumps(final_output, indent=2, ensure_ascii=False)}")

    # ingest_status = ingest_claim_core(final_output)
    # print(f"Ingestion Status: {ingest_status}")
    # return final_output


if __name__ == "__main__":
    try:
        runner()
    except Exception as e:
        print(f"An error occurred: {e}")
