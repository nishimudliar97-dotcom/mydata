from asyncio.windows_events import NULL
import json
import time

from Chunking.indexer_v2 import create_faiss_index
from Retriever.retriever_v2 import extractor
from Retriever.context_builder_v2 import build_context
from Retriever.llm import run_llm
from Fields.fields_loader import load_fields_from_json
from Chunking.document_processing_v2 import process_all_documents
import re
import unicodedata
from Database.Insert_Data import ingest_claim_core

from Retriever.coordinate_finder_v2 import (
    parse_llm_output,
    find_chunk_by_id,
    find_value_coordinates_in_chunk,
    build_field_output,
)

PDF_PATH = "./Documents/WRSECFCAS202610297"
FIELDS_JSON_PATH = "./Fields/fields.json"


def normalize_text(text):
    if(type(text) != str):
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


def runner():
    # Doc Ingestion and Indexing. [Working perfectly fine..............]
    all_chunks = []

    print("Loading PDF documents...")
    all_chunks = process_all_documents(PDF_PATH)
    print(f"Total chunks generated: {len(all_chunks)}")

    # print("\n" + "="*50 + "\n")
    # for chunk in all_chunks:
    #     print("Sample Chunk:")
    #     print(f"Chunk id: {chunk['chunk_id']}")
    #     print(f"Document: {chunk['document']}")
    #     print(f"Heading: {chunk['heading']}")
    #     print(chunk['text'])
    #     print(f"Pages: {chunk['page_start']} - {chunk['page_end']}")
    #     print(f"Bounding Box: {chunk['bbox']}")
    #     print(f"Category: {chunk['category']}")
    #     print(f"Lines: {chunk['lines']}")
    #     print("\n" + "="*50 + "\n")

    print("Creating FAISS Index...")
    vector_stores = create_faiss_index(all_chunks)
    print(f"Vector stores created for categories: {list(vector_stores.keys())}")
    print("Index created successfully!")
    # ------------------------------------------------------------------

    print("\nExtraction process started...")
    #Data Retrieval and Extraction using LLM.
    final_output = {}
    print("\nLoading fields to extract...")
    fields_list = load_fields_from_json(FIELDS_JSON_PATH)

    print(f"Fields to extract: {[field['field_name'] for field in fields_list]}")
    for field in fields_list:
        # if(field['operation_type'] != "summarize"):
        #     print(f"Skipping field: {field['field_name']}...")
        #     continue

        print(f"\nExtracting field: {field['field_name']}...")

        retrieved_chunks = extractor(vector_stores, field)

        context = build_context(retrieved_chunks)

        print(context)
        print("\n \n \n")

        raw_llm_output = run_llm(field, context)
        parsed_llm_output = parse_llm_output(raw_llm_output)

        extracted_value = parsed_llm_output.get("value")
        selected_chunk_id = parsed_llm_output.get("chunk_id")

        selected_chunk = find_chunk_by_id(retrieved_chunks, selected_chunk_id)
        coordinates = find_value_coordinates_in_chunk(selected_chunk, extracted_value)

        value = build_field_output(extracted_value, selected_chunk, coordinates)
        value["Value"] = normalize_text(value.get("Value"))

        final_output[field['field_name']] = value

        print(f"Extracted value for {field['field_name']}: {value}")

        time.sleep(120)  # Sleep for 2 minutes between requests to avoid rate limits

    print(f"Here is the output.........\n{final_output}")
    # ingest_status = ingest_claim_core(final_output)
    # print(f"Ingestion Status: {ingest_status}")
    # return final_output


if __name__ == "__main__":
    try:
        runner()
    except Exception as e:
        print(f"An error occurred: {e}")
