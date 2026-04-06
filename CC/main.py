from asyncio.windows_events import NULL
import json
import time
import re
import unicodedata

from Chunking.indexer_v2 import create_faiss_index
from Retriever.retriever_v2 import extractor
from Retriever.context_builder_v2 import build_context
from Retriever.llm import run_llm, run_cause_code_llm
from Retriever.line_bbox_resolver import resolve_line_bboxes
from Fields.fields_loader import load_fields_from_json
from Chunking.document_processing_v2 import process_all_documents
from Database.Insert_Data import ingest_claim_core

from Fields.replacements import replacements

# New imports for Cause Code
from Database.cause_code_loader import load_cause_codes_from_db
from Retriever.cause_code_indexer import create_cause_code_faiss_index
from Retriever.cause_code_retriever import (
    retrieve_document_cause_chunks,
    build_cause_narrative_from_chunks,
    retrieve_cause_code_candidates,
    build_cause_code_candidates_text
)

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


def run_cause_code_pipeline(vector_stores):
    """
    Cause Code flow:
    1. Retrieve cause/circumstances chunks from document
    2. Build cause narrative
    3. Load cause codes from MySQL
    4. Build cause code FAISS
    5. Retrieve top candidate rows
    6. Ask LLM to choose best cause code
    """
    print("\nRunning Cause Code pipeline...")

    # Step 1: retrieve document chunks
    cause_doc_chunks = retrieve_document_cause_chunks(vector_stores, default_k=5)

    print(f"Retrieved cause-related document chunks: {len(cause_doc_chunks)}")

    # Step 2: build narrative
    cause_narrative = build_cause_narrative_from_chunks(cause_doc_chunks)
    print("\nCause Narrative:\n", cause_narrative)

    # Step 3: load cause codes from DB
    cause_code_rows = load_cause_codes_from_db()
    print(f"Loaded cause code rows from DB: {len(cause_code_rows)}")

    # Step 4: build cause code vector store
    cause_code_vector_store = create_cause_code_faiss_index(cause_code_rows)

    # Step 5: retrieve candidate cause codes
    cause_candidates = retrieve_cause_code_candidates(
        cause_code_vector_store=cause_code_vector_store,
        cause_narrative=cause_narrative,
        top_k=5
    )

    print(f"Retrieved cause code candidates: {len(cause_candidates)}")

    cause_candidates_text = build_cause_code_candidates_text(cause_candidates)
    print("\nCause Code Candidates:\n", cause_candidates_text)

    # Step 6: ask LLM
    llm_result = run_cause_code_llm(
        cause_narrative=cause_narrative,
        cause_candidates_text=cause_candidates_text
    )

    # Step 7: final structured output
    final_result = {
        "cause_code_id": llm_result.get("cause_code_id"),
        "cause_l1": llm_result.get("cause_l1"),
        "cause_l2": llm_result.get("cause_l2"),
        "matched_text": llm_result.get("matched_text"),
        "document_text": cause_narrative,
        "candidate_matches": [
            {
                "cause_code_id": doc.metadata.get("cause_code_id"),
                "cause_l1": doc.metadata.get("cause_l1"),
                "cause_l2": doc.metadata.get("cause_l2"),
            }
            for doc in cause_candidates
        ],
        "source_chunk_ids": [
            chunk.metadata.get("chunk_id") for chunk in cause_doc_chunks
        ]
    }

    return final_result


def runner():
    # Doc Ingestion and Indexing
    all_chunks = []

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

        # Keep your current temporary filter if you want
        # Remove this block later when you want all fields
        # if field['field_name'] != "Coverage Triggered":
        #     print(f"Skipping field: {field['field_name']} (only extracting 'Coverage Triggered' for now)")
        #     continue

        # New special handling for Cause Code
        if field["field_name"] == "Cause Code":
            cause_code_result = run_cause_code_pipeline(vector_stores)
            final_output[field["field_name"]] = cause_code_result
            print(f"Extracted Cause Code: {json.dumps(cause_code_result, indent=2)}")
            continue

        retrieved_chunks = extractor(vector_stores, field)

        context = build_context(retrieved_chunks)

        print(context)
        print("\n \n \n")

        llm_result = run_llm(field, context)

        if llm_result.get("Value") is not None:
            llm_result["Value"] = normalize_text(llm_result["Value"])

        resolved_output = resolve_line_bboxes(
            llm_result=llm_result,
            retrieved_chunks=retrieved_chunks
        )

        final_output[field["field_name"]] = resolved_output

        print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")

    print(f"Here is the output........\n{json.dumps(final_output, indent=2, ensure_ascii=False)}")

    # Uncomment when ready
    # ingest_status = ingest_claim_core(final_output)
    # print(f"Ingestion Status: {ingest_status}")

    # return final_output


if __name__ == "__main__":
    try:
        runner()
    except Exception as e:
        print(f"An error occurred: {e}")
