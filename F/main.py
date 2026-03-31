import json
import re
import unicodedata

from Chunking.indexer_v2 import create_faiss_index
from Retriever.retriever_v2 import extractor
from Retriever.context_builder import build_context
from Retriever.llm import run_llm
from Retriever.location_resolver import find_chunk_by_id, resolve_locations_for_value
from Fields.fields_loader import load_fields_from_json
from Chunking.document_processing_v2 import process_all_documents
from Database.Insert_Data import ingest_claim_core

PDF_PATH = "./Documents/ZNBECFIND202644912"
FIELDS_JSON_PATH = "./Fields/fields.json"


def normalize_text(text: str) -> str:
    if text is None:
        return ""

    text = unicodedata.normalize("NFKC", str(text))

    replacements = {
        "\u202f": " ",
        "\u00a0": " ",
        "\u2010": "-",
        "\u2011": "-",
        "\u2012": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\t": " ",
        "\n": " ",
        "\r": " ",
    }

    for k, v in replacements.items():
        text = text.replace(k, v)

    text = re.sub(r"\s+", " ", text)
    return text.strip()


def runner():
    # DOC Ingestion and Indexing
    print("Loading PDF documents...")
    all_chunks = process_all_documents(PDF_PATH)
    print(f"Total chunks generated: {len(all_chunks)}")

    print("Creating FAISS Index...")
    vector_stores = create_faiss_index(all_chunks)
    print(f"Vector stores created for categories: {list(vector_stores.keys())}")
    print("Index created successfully!")

    print("\nExtraction process started...")
    final_output = {}

    print("\nLoading fields to extract...")
    fields = load_fields_from_json(FIELDS_JSON_PATH)
    print(f"Fields to extract: {[field['field_name'] for field in fields]}")

    for field in fields:
        print(f"\nExtracting field: {field['field_name']}...")

        retrieved_chunks = extractor(vector_stores, field)

        if not retrieved_chunks:
            final_output[field["field_name"]] = {
                "Value": None,
                "Document Category": None,
                "Document ID": None,
                "Coordinates": []
            }
            continue

        context = build_context(retrieved_chunks)

        llm_result = run_llm(field, context)

        chunk_id = llm_result.get("chunk_id")
        value = llm_result.get("value")
        evidence_text = llm_result.get("evidence_text")

        if isinstance(value, str):
            value = normalize_text(value)

        if isinstance(evidence_text, str):
            evidence_text = normalize_text(evidence_text)

        selected_chunk = find_chunk_by_id(retrieved_chunks, chunk_id)

        if selected_chunk is None or not value:
            final_output[field["field_name"]] = {
                "Value": None,
                "Document Category": None,
                "Document ID": None,
                "Coordinates": []
            }
            continue

        coordinates = resolve_locations_for_value(
            selected_chunk,
            value=value,
            evidence_text=evidence_text
        )

        metadata = getattr(selected_chunk, "metadata", {})

        final_output[field["field_name"]] = {
            "Value": value,
            "Document Category": metadata.get("category"),
            "Document ID": metadata.get("document_id"),
            "Coordinates": coordinates
        }

    print(f"\nHere is the output..........\n{json.dumps(final_output, indent=2)}")

    # Optional DB ingestion
    # ingest_status = ingest_claim_core(final_output)
    # print(f"Ingestion Status: {ingest_status}")

    return final_output


if __name__ == "__main__":
    try:
        runner()
    except Exception as e:
        print(f"An error occurred: {e}")
