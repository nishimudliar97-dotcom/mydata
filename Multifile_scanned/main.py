import json
from typing import Any
from snowflake.snowpark.functions import ai_extract, ai_parse_document, to_file
from .config import load_config
from .session_manager import create_session

# Keep prompts simple. Avoid quotes like 'UCR:' inside the text.
QUESTIONS = [
    "Extract the UCR value from this document. Return only the value.",
    "Extract the policy number from this document. Return only the value.",
    "Extract the UMR value from this document. Return only the value.",
]


def safe_json(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def extract_text_preview(parsed_obj: Any) -> str:
    if not isinstance(parsed_obj, dict):
        return ""

    value_obj = parsed_obj.get("value", parsed_obj)

    if isinstance(value_obj, dict):
        pages = value_obj.get("pages", [])
        if isinstance(pages, list) and pages:
            texts = []
            for page in pages[:2]:
                if isinstance(page, dict):
                    txt = page.get("text", "")
                    if txt:
                        texts.append(txt[:700])
            return "\n\n".join(texts)

        if "text" in value_obj and isinstance(value_obj["text"], str):
            return value_obj["text"][:1200]

    return ""


def get_response_map(extracted_obj: Any) -> dict:
    if isinstance(extracted_obj, dict):
        return extracted_obj.get("response", {})
    return {}


def normalize_relative_path(stage_name: str, full_path: str) -> str:
    path = full_path.strip()

    if path.startswith("@"):
        path = path[1:]

    stage_prefix = f"{stage_name}/"
    if path.startswith(stage_prefix):
        path = path[len(stage_prefix):]

    lower_stage_prefix = f"{stage_name.lower()}/"
    if path.lower().startswith(lower_stage_prefix):
        path = path[len(lower_stage_prefix):]

    return path


def is_missing(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str) and value.strip().lower() in {"", "null", "none", "not found", "n/a"}:
        return True
    return False


def main() -> None:
    config = load_config()
    session = create_session(config)

    try:
        stage_rows = session.sql(f"LIST @{config.stage_name}").collect()

        if not stage_rows:
            print(f"No files found in stage @{config.stage_name}")
            return

        print(f"Found {len(stage_rows)} file(s) in stage @{config.stage_name}")

        for idx, row in enumerate(stage_rows, start=1):
            full_path = row[0]
            relative_path = normalize_relative_path(config.stage_name, full_path)
            file_uri = f"@{config.stage_name}/{relative_path}"

            print("\n" + "=" * 100)
            print(f"[{idx}/{len(stage_rows)}] Processing file")
            print(f"DEBUG full_path    : {full_path}")
            print(f"DEBUG relative_path: {relative_path}")
            print(f"DEBUG final file   : {file_uri}")

            try:
                # Step 1: Parse scanned PDF using OCR/layout mode
                parse_df = session.range(1).select(
                    ai_parse_document(
                        to_file(file_uri),
                        mode=config.parse_mode,
                        page_split=config.page_split,
                    ).alias("PARSED_OUTPUT")
                )

                parsed_output = safe_json(parse_df.collect()[0]["PARSED_OUTPUT"])

                print("\n--- PARSED PREVIEW ---")
                preview = extract_text_preview(parsed_output)
                print(preview if preview else "No preview text found")

                # Step 2: Extract target fields
                extract_df = session.range(1).select(
                    ai_extract(
                        to_file(file_uri),
                        QUESTIONS,
                    ).alias("EXTRACTED_OUTPUT")
                )

                extracted_output = safe_json(extract_df.collect()[0]["EXTRACTED_OUTPUT"])
                response = get_response_map(extracted_output)

                ucr = response.get(QUESTIONS[0])
                policy_number = response.get(QUESTIONS[1])
                umr = response.get(QUESTIONS[2])

                print("\n--- RAW EXTRACTION OUTPUT ---")
                print(json.dumps(extracted_output, indent=2, ensure_ascii=False))

                # If none of the required fields were found, skip the file
                if is_missing(ucr) and is_missing(policy_number) and is_missing(umr):
                    print("\n--- SKIPPED ---")
                    print("Required fields not found in this file. Skipping.")
                    continue

                print("\n--- CLEAN OUTPUT ---")
                print("UCR          :", ucr)
                print("Policy Number:", policy_number)
                print("UMR          :", umr)

            except Exception as e:
                print("\n--- SKIPPED DUE TO ERROR ---")
                print(f"File: {file_uri}")
                print(f"Reason: {str(e)}")
                continue

    finally:
        session.close()


if __name__ == "__main__":
    main()
