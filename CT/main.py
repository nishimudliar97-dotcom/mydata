from asyncio.windows_events import NULL
import json
import time
import re
import unicodedata

from Chunking.indexer_v2 import create_faiss_index
from Retriever.retriever_v2 import extractor
from Retriever.context_builder_v2 import build_context
from Retriever.llm import run_llm
from Retriever.line_bbox_resolver import resolve_line_bboxes
from Fields.fields_loader import load_fields_from_json
from Chunking.document_processing_v2 import process_all_documents
from Database.Insert_Data import ingest_claim_core

# Replacements for normalization
from Fields.replacements import replacements

PDF_PATH = "./Documents/TIFGCFZC202623489"
FIELDS_JSON_PATH = "./Fields/fields.json"


def normalize_text(text):
    if type(text) != str:
        return text

    text = unicodedata.normalize("NFKC", text)

    for k, v in replacements.items():
        text = text.replace(k, v)

    text = re.sub(r"\'s+", "", text)
    return text.strip()


def is_coverage_triggered_field(field_name: str) -> bool:
    return str(field_name).strip().lower() == "coverage triggered"


COVERAGE_ALIAS_MAP = {
    # Property Damage
    "property damage": "Property Damage",
    "pd": "Property Damage",
    "property damage all risks": "Property Damage",
    "property damage (all risks)": "Property Damage",
    "material damage": "Property Damage",
    "md": "Property Damage",
    "damage to property": "Property Damage",
    "buildings": "Property Damage",
    "building damage": "Property Damage",

    # Business Interruption
    "business interruption": "Business Interruption",
    "bi": "Business Interruption",
    "business interruption gross rentals": "Business Interruption",
    "business interruption - gross rentals": "Business Interruption",
    "gross rentals": "Business Interruption",
    "loss of rent": "Business Interruption",
    "loss of rental income": "Business Interruption",
    "alternative accommodation": "Business Interruption",
    "rent loss": "Business Interruption",
    "consequential loss": "Business Interruption",

    # Terrorism
    "terrorism": "Terrorism",
    "terror": "Terrorism",
    "terror cover": "Terrorism",
    "terrorism extension": "Terrorism",
    "terror pool": "Terrorism",

    # Property Owner's Liability
    "property owners liability": "Property Owner's Liability",
    "property owner's liability": "Property Owner's Liability",
    "property owner liability": "Property Owner's Liability",
    "pol": "Property Owner's Liability",
    "owners liability": "Property Owner's Liability",
    "owner's liability": "Property Owner's Liability",
    "public liability": "Property Owner's Liability",
    "third party liability": "Property Owner's Liability",
    "third party property damage": "Property Owner's Liability",
    "liability to third parties": "Property Owner's Liability",
    "premises liability": "Property Owner's Liability",

    # Machinery Breakdown
    "machinery breakdown": "Machinery Breakdown",
    "mb": "Machinery Breakdown",
    "equipment breakdown": "Machinery Breakdown",
    "mechanical breakdown": "Machinery Breakdown",
    "electrical breakdown": "Machinery Breakdown",

    # Contractors All Risk
    "contractors all risk": "Contractors All Risk",
    "car": "Contractors All Risk",
    "construction all risk": "Contractors All Risk",
    "erection all risk": "Contractors All Risk",
    "ear": "Contractors All Risk",
    "contract works": "Contractors All Risk",

    # Marine Cargo / Transit
    "marine cargo": "Marine Cargo / Transit",
    "goods in transit": "Marine Cargo / Transit",
    "git": "Marine Cargo / Transit",
    "transit": "Marine Cargo / Transit",
    "cargo": "Marine Cargo / Transit",
    "stock in transit": "Marine Cargo / Transit",
    "inland transit": "Marine Cargo / Transit",

    # Cyber
    "cyber": "Cyber",
    "cyber liability": "Cyber",
    "data breach": "Cyber",
    "ransomware": "Cyber",
    "network security": "Cyber",

    # Employer's Liability
    "employers liability": "Employer's Liability",
    "employer's liability": "Employer's Liability",
    "el": "Employer's Liability",
    "workmen compensation": "Employer's Liability",
    "workers compensation": "Employer's Liability",
    "employee injury liability": "Employer's Liability",

    # Fidelity Guarantee
    "fidelity guarantee": "Fidelity Guarantee",
    "fidelity": "Fidelity Guarantee",
    "employee dishonesty": "Fidelity Guarantee",
    "crime": "Fidelity Guarantee",
    "internal fraud": "Fidelity Guarantee",
    "embezzlement": "Fidelity Guarantee"
}


def normalize_coverage_key(text: str) -> str:
    if text is None:
        return ""
    text = normalize_text(text)
    if not isinstance(text, str):
        return ""
    text = text.lower()
    text = re.sub(r"[\[\]\(\)\{\}]", " ", text)
    text = re.sub(r"[;,/|]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def split_coverage_candidates(value: str):
    if not value:
        return []

    text = str(value).strip()

    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]

    parts = re.split(r",|;|\band\b|&|\n", text, flags=re.IGNORECASE)
    return [p.strip(" '\"") for p in parts if p and p.strip()]


def canonicalize_coverage_value(value):
    if not value:
        return value

    candidates = split_coverage_candidates(value)
    canonical_values = []
    seen = set()

    for item in candidates:
        key = normalize_coverage_key(item)
        mapped = COVERAGE_ALIAS_MAP.get(key)

        if mapped is None:
            for alias, canonical in COVERAGE_ALIAS_MAP.items():
                if alias in key or key in alias:
                    mapped = canonical
                    break

        if mapped and mapped not in seen:
            seen.add(mapped)
            canonical_values.append(mapped)

    if not canonical_values:
        return value

    return "[" + ", ".join(canonical_values) + "]"


def looks_like_policy_listing_only(llm_result):
    lines = llm_result.get("lines") or []
    if not lines:
        return False

    joined = " ".join(str(x).lower() for x in lines)

    if "sections in force" in joined and not any(
        phrase in joined for phrase in [
            "covered in principle",
            "covered under",
            "responds under",
            "policy responds under",
            "triggered under",
            "engaged by this event",
            "applicable coverage",
            "coverage position",
            "indemnity position",
            "operative peril",
            "proximate cause"
        ]
    ):
        return True

    return False


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
    # --------------------------------------------------

    print("\nExtraction process started...")
    final_output = {}

    print("\nLoading fields to extract...")
    fields = load_fields_from_json(FIELDS_JSON_PATH)

    print(f"Fields to extract: {[field['field_name'] for field in fields]}")

    for field in fields:
        print(f"\nExtracting field: {field['field_name']}...")
        if field["field_name"] != "Coverage Triggered":
            print(f"Skipping field: {field['field_name']} (only extracting 'Coverage Triggered' for now)")
            continue

        retrieved_chunks = extractor(vector_stores, field)

        context = build_context(retrieved_chunks)

        print(context)
        print("\n \n \n")

        llm_result = run_llm(field, context)

        if llm_result.get("Value") is not None:
            llm_result["Value"] = normalize_text(llm_result["Value"])

        if is_coverage_triggered_field(field["field_name"]):
            if looks_like_policy_listing_only(llm_result):
                llm_result["Value"] = None
                llm_result["Chunk_id"] = None
                llm_result["lines"] = None
            elif llm_result.get("Value"):
                llm_result["Value"] = canonicalize_coverage_value(llm_result["Value"])

        resolved_output = resolve_line_bboxes(
            llm_result=llm_result,
            retrieved_chunks=retrieved_chunks
        )

        final_output[field["field_name"]] = resolved_output

        print(f"Extracted value for {field['field_name']}: {json.dumps(resolved_output, indent=2)}")

    print(f"Here is the output........\n{json.dumps(final_output, indent=2, ensure_ascii=False)}")

    # ingest_status = ingest_claim_core(final_output)
    # print(f"Ingestion Status: {ingest_status}")
    # return final_output


if __name__ == "__main__":
    try:
        runner()
    except Exception as e:
        print(f"An error occurred: {e}")
