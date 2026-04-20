from snowflake.snowpark.functions import ai_extract, ai_parse_document, to_file, current_timestamp
import json

stage_name = "INSURANCE_DOC_STAGE"
target_table = "LOSS_REPORT_EXTRACTED"

QUESTIONS = [
    "Extract the UCR value from this document. Return only the value.",
    "Extract the policy number from this document. Return only the value.",
    "Extract the UMR value from this document. Return only the value.",
]

def is_missing(value):
    if value is None:
        return True
    if isinstance(value, str) and value.strip().lower() in {"", "null", "none", "not found", "n/a"}:
        return True
    return False

def main(session):
    # Step 1: Read all files from stage
    stage_rows = session.sql(f"LIST @{stage_name}").collect()

    if not stage_rows:
        return session.create_dataframe([
            {
                "FILE_NAME": None,
                "UCR": None,
                "POLICY_NUMBER": None,
                "UMR": None,
                "STATUS": "INFO",
                "REASON": "No files found in stage"
            }
        ])

    # Step 2: Read already processed file names
    try:
        existing_rows = session.table(target_table).select("FILE_NAME").collect()
        existing_files = {row["FILE_NAME"] for row in existing_rows if row["FILE_NAME"]}
    except Exception:
        existing_files = set()

    results = []

    for row in stage_rows:
        full_path = row[0]

        # Normalize path
        if full_path.startswith(stage_name + "/"):
            relative_path = full_path[len(stage_name) + 1:]
        else:
            relative_path = full_path.split("/", 1)[1] if "/" in full_path else full_path

        lower_stage_prefix = stage_name.lower() + "/"
        if relative_path.lower().startswith(lower_stage_prefix):
            relative_path = relative_path[len(stage_name) + 1:]

        file_uri = f"@{stage_name}/{relative_path}"
        file_name = relative_path.split("/")[-1]

        # Step 3: Skip if already processed
        if file_name in existing_files:
            continue

        try:
            # Step 4: Parse scanned PDF
            parse_df = session.range(1).select(
                ai_parse_document(
                    to_file(file_uri),
                    mode="LAYOUT",
                    page_split=True,
                ).alias("PARSED_OUTPUT")
            )
            _ = parse_df.collect()[0]["PARSED_OUTPUT"]

            # Step 5: Extract fields
            extract_df = session.range(1).select(
                ai_extract(
                    to_file(file_uri),
                    QUESTIONS,
                ).alias("EXTRACTED_OUTPUT")
            )
            extracted_output = extract_df.collect()[0]["EXTRACTED_OUTPUT"]

            if isinstance(extracted_output, str):
                extracted_output = json.loads(extracted_output)

            response = extracted_output.get("response", {}) if isinstance(extracted_output, dict) else {}

            ucr = response.get(QUESTIONS[0])
            policy_number = response.get(QUESTIONS[1])
            umr = response.get(QUESTIONS[2])

            if is_missing(ucr) and is_missing(policy_number) and is_missing(umr):
                results.append({
                    "FILE_NAME": file_name,
                    "UCR": None,
                    "POLICY_NUMBER": None,
                    "UMR": None,
                    "STATUS": "SKIPPED",
                    "REASON": "Required fields not found"
                })
            else:
                results.append({
                    "FILE_NAME": file_name,
                    "UCR": ucr,
                    "POLICY_NUMBER": policy_number,
                    "UMR": umr,
                    "STATUS": "SUCCESS",
                    "REASON": None
                })

        except Exception as e:
            results.append({
                "FILE_NAME": file_name,
                "UCR": None,
                "POLICY_NUMBER": None,
                "UMR": None,
                "STATUS": "ERROR",
                "REASON": str(e)
            })

    # Step 6: Append only new processed rows
    if results:
        df = session.create_dataframe(results)
        df = df.with_column("EXTRACTED_AT", current_timestamp())
        df.write.mode("append").save_as_table(target_table)

    # Step 7: Return what got processed in this run
    if results:
        return session.create_dataframe(results)

    return session.create_dataframe([
        {
            "FILE_NAME": None,
            "UCR": None,
            "POLICY_NUMBER": None,
            "UMR": None,
            "STATUS": "INFO",
            "REASON": "No new files to process"
        }
    ])



CREATE OR REPLACE TABLE LOSS_REPORT_EXTRACTED (
    FILE_NAME STRING,
    UCR STRING,
    POLICY_NUMBER STRING,
    UMR STRING,
    STATUS STRING,
    REASON STRING,
    EXTRACTED_AT TIMESTAMP_NTZ
);





