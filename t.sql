USE ROLE EXPERIMENT_TEAM_FULL;
USE DATABASE EXPERIMENT_TEAM_DB;
USE SCHEMA PUBLIC;
USE WAREHOUSE EXPERIMENT_TEAM_VWH;

CREATE OR REPLACE TABLE NTU_REASON_POC_RESULTS (
    run_id STRING,
    processed_at TIMESTAMP_NTZ,
    file_name STRING,
    file_path STRING,
    ntu_reason STRING,
    ntu_confidence STRING,
    ntu_explanation STRING,
    raw_llm_output VARIANT,
    raw_llm_text STRING,
    raw_parsed_text STRING,
    status STRING,
    error_message STRING
);

CREATE OR REPLACE PROCEDURE RUN_NTU_REASON_POC(
    STAGE_PATH STRING,
    LIMIT_FILES INTEGER
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import uuid
import re
import traceback

MODEL_NAME = "llama3.1-8b"

def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")

def normalize_stage_file_path(path):
    path = str(path)
    if not path.startswith("@"):
        path = "@" + path
    return path

def extract_json_from_llm(text):
    raw_text = "" if text is None else str(text).strip()

    cleaned = raw_text
    cleaned = re.sub(r"^```json", "", cleaned, flags=re.IGNORECASE).strip()
    cleaned = re.sub(r"^```", "", cleaned).strip()
    cleaned = re.sub(r"```$", "", cleaned).strip()

    parsed = None

    try:
        parsed = json.loads(cleaned)
    except Exception:
        match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
        if match:
            try:
                parsed = json.loads(match.group(0))
            except Exception:
                parsed = None

    if isinstance(parsed, dict):
        return parsed

    return {
        "ntu_reason": "Unclear / not explicitly evidenced",
        "ntu_confidence": "Low",
        "ntu_explanation": "The model did not return valid JSON. Check raw_llm_text for the actual response.",
        "secondary_factors": [],
        "do_not_use_as_primary_reason": [],
        "raw_text": raw_text
    }

def run(session, stage_path, limit_files):
    run_id = str(uuid.uuid4())

    if limit_files is None or limit_files <= 0:
        limit_files = 10

    files = session.file.list(stage_path, pattern=r".*\.pdf$")
    selected_files = files[:limit_files]

    processed_count = 0
    error_count = 0

    for f in selected_files:
        original_file_path = str(f.name)
        file_path = normalize_stage_file_path(original_file_path)
        file_name = file_path.split("/")[-1]

        try:
            stage_dir = file_path.rsplit("/", 1)[0]
            rel_file = file_path.rsplit("/", 1)[1]

            parse_sql = f"""
                SELECT AI_PARSE_DOCUMENT(
                    TO_FILE('{sql_escape(stage_dir)}', '{sql_escape(rel_file)}'),
                    OBJECT_CONSTRUCT(
                        'mode', 'LAYOUT',
                        'page_split', TRUE
                    )
                )::STRING AS parsed_doc_text
            """

            parsed_row = session.sql(parse_sql).collect()[0]
            parsed_text = parsed_row["PARSED_DOC_TEXT"]

            if parsed_text is None or len(str(parsed_text).strip()) == 0:
                raise Exception("AI_PARSE_DOCUMENT returned empty text")

            parsed_text = str(parsed_text)

            # Keep text smaller for first POC
            parsed_text_for_prompt = parsed_text[:50000]

            prompt = f"""
You are analyzing insurance quote discussion email chains for known NTU cases.

Important context:
- NTU means the quote was not taken up.
- The case is already known to be NTU.
- Your task is only to infer the most likely NTU reason from the email chain.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "secondary_factors": [],
  "do_not_use_as_primary_reason": []
}}

Rules:
1. The case is already known to be NTU. Do not decide whether it is NTU.
2. Infer the most likely NTU reason only from the visible email chain text.
3. Do not force a reason if evidence is weak. Use "Unclear / not explicitly evidenced" if needed.
4. Prefer these NTU reason categories where supported:
   - Price / premium competitiveness
   - Broker / lead market preference
   - Layer / structure mismatch
   - Limited capacity / line size
   - Terms / coverage mismatch
   - Restrictive quote condition
   - Timing / late quote
   - Risk appetite / exposure concern
   - Loss history / risk quality
5. ntu_confidence must be one of:
   - High
   - Medium-High
   - Medium
   - Low-Medium
   - Low
6. ntu_explanation must be concise but evidence-based.
7. secondary_factors must be an array of short strings.
8. do_not_use_as_primary_reason must be an array of short strings.

Parsed PDF/email-chain text:
{parsed_text_for_prompt}
"""

            llm_sql = f"""
                SELECT AI_COMPLETE(
                    '{MODEL_NAME}',
                    '{sql_escape(prompt)}',
                    OBJECT_CONSTRUCT(
                        'temperature', 0,
                        'max_tokens', 1200
                    )
                )::STRING AS llm_result
            """

            llm_row = session.sql(llm_sql).collect()[0]
            llm_text = llm_row["LLM_RESULT"]

            result_json = extract_json_from_llm(llm_text)

            ntu_reason = result_json["ntu_reason"] if "ntu_reason" in result_json else "Unclear / not explicitly evidenced"
            ntu_confidence = result_json["ntu_confidence"] if "ntu_confidence" in result_json else "Low"
            ntu_explanation = result_json["ntu_explanation"] if "ntu_explanation" in result_json else ""

            insert_sql = f"""
                INSERT INTO NTU_REASON_POC_RESULTS
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(file_name)}',
                    '{sql_escape(file_path)}',
                    '{sql_escape(ntu_reason)}',
                    '{sql_escape(ntu_confidence)}',
                    '{sql_escape(ntu_explanation)}',
                    TRY_PARSE_JSON('{sql_escape(json.dumps(result_json))}'),
                    '{sql_escape(llm_text)}',
                    '{sql_escape(parsed_text[:10000])}',
                    'SUCCESS',
                    NULL
            """

            session.sql(insert_sql).collect()
            processed_count += 1

        except Exception as e:
            error_count += 1
            full_error = traceback.format_exc()

            insert_error_sql = f"""
                INSERT INTO NTU_REASON_POC_RESULTS
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(file_name)}',
                    '{sql_escape(file_path)}',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'ERROR',
                    '{sql_escape(full_error)}'
            """

            session.sql(insert_error_sql).collect()

    return f"Run ID: {run_id}; processed={processed_count}; errors={error_count}; selected={len(selected_files)}"
$$;

TRUNCATE TABLE NTU_REASON_POC_RESULTS;

CALL RUN_NTU_REASON_POC(
  '@DROPBOX_OPEN_MARKET_V3/Open_Market',
  3
);

SELECT
    file_name,
    ntu_reason,
    ntu_confidence,
    ntu_explanation,
    raw_llm_text,
    raw_parsed_text,
    status,
    error_message
FROM NTU_REASON_POC_RESULTS
ORDER BY processed_at DESC;
