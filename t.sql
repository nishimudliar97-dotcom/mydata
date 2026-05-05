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

def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")

def extract_json(text):
    """
    Try to parse clean JSON from the LLM output.
    If the model returns markdown fences or extra text, extract the first JSON object.
    """
    if text is None:
        return {}

    text = str(text).strip()

    # Remove markdown fences if present
    text = re.sub(r"^```json", "", text, flags=re.IGNORECASE).strip()
    text = re.sub(r"^```", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    try:
        return json.loads(text)
    except Exception:
        pass

    # Fallback: find first JSON object
    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except Exception:
            return {}

    return {}

def normalize_stage_file_path(path):
    """
    session.file.list() can return:
    @STAGE/path/file.pdf
    or:
    stage/path/file.pdf

    Normalize to @STAGE/path/file.pdf.
    """
    path = str(path)

    if not path.startswith("@"):
        path = "@" + path

    return path

def parse_document_value(parsed_doc_raw):
    """
    AI_PARSE_DOCUMENT may return JSON string/object.
    Extract page content if page_split = TRUE.
    """
    if parsed_doc_raw is None:
        raise Exception("AI_PARSE_DOCUMENT returned NULL")

    if isinstance(parsed_doc_raw, str):
        parsed_obj = json.loads(parsed_doc_raw)
    else:
        parsed_obj = parsed_doc_raw

    parsed_value = parsed_obj

    # If parse function returns error/value wrapper
    if isinstance(parsed_obj, dict):
        if parsed_obj.get("error"):
            raise Exception("AI_PARSE_DOCUMENT error: " + str(parsed_obj.get("error")))
        if "value" in parsed_obj:
            parsed_value = parsed_obj.get("value")

    doc_text_parts = []

    if isinstance(parsed_value, dict) and "pages" in parsed_value:
        for page in parsed_value.get("pages", []):
            content = page.get("content", "")
            if content:
                doc_text_parts.append(content)

    elif isinstance(parsed_value, dict) and "content" in parsed_value:
        doc_text_parts.append(parsed_value.get("content", ""))

    else:
        doc_text_parts.append(str(parsed_value))

    return "\n\n".join(doc_text_parts)

def run(session, stage_path, limit_files):
    run_id = str(uuid.uuid4())

    if limit_files is None or limit_files <= 0:
        limit_files = 10

    # List PDFs from stage path
    files = session.file.list(stage_path, pattern=r".*\.pdf$")

    selected_files = files[:limit_files]

    processed_count = 0
    error_count = 0

    for f in selected_files:
        original_file_path = str(f.name)
        file_path = normalize_stage_file_path(original_file_path)
        file_name = file_path.split("/")[-1]

        try:
            # Example:
            # @DROPBOX_OPEN_MARKET_V3/Open_Market/folder/file.pdf
            # stage_dir = @DROPBOX_OPEN_MARKET_V3/Open_Market/folder
            # rel_file = file.pdf
            stage_dir = file_path.rsplit("/", 1)[0]
            rel_file = file_path.rsplit("/", 1)[1]

            parse_sql = f"""
                SELECT AI_PARSE_DOCUMENT(
                    TO_FILE('{sql_escape(stage_dir)}', '{sql_escape(rel_file)}'),
                    OBJECT_CONSTRUCT(
                        'mode', 'LAYOUT',
                        'page_split', TRUE
                    )
                ) AS parsed_doc
            """

            parsed_row = session.sql(parse_sql).collect()[0]
            parsed_doc_raw = parsed_row["PARSED_DOC"]

            doc_text = parse_document_value(parsed_doc_raw)

            # POC safety limit for prompt length.
            # Increase later if needed.
            doc_text = doc_text[:90000]

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
9. If there is pricing comparison, broker target premium, rate cut, cheaper competing market, or larger cut request, consider price competitiveness.
10. If there is lead market, broker already has lead terms, or another insurer driving the placement, consider broker / lead market preference.
11. If layer changed, alternative layer was requested, or quote only works with another layer, consider layer / structure mismatch or restrictive quote condition.
12. If quote line is very small, consider limited capacity / line size.
13. If SRCC, CAEQ, deductibles, sublimits, wording, or coverage changes are disputed, consider terms / coverage mismatch.
14. If losses are clean or risk is improving, mention that these should not be used as the primary reason.

Email chain text:
{doc_text}
"""

            # IMPORTANT FIX:
            # AI_COMPLETE third argument is model_parameters object, not TRUE.
            llm_sql = f"""
                SELECT AI_COMPLETE(
                    'claude-3-5-sonnet',
                    '{sql_escape(prompt)}',
                    OBJECT_CONSTRUCT(
                        'temperature', 0,
                        'max_tokens', 1200
                    )
                ) AS llm_result
            """

            llm_row = session.sql(llm_sql).collect()[0]
            llm_text = llm_row["LLM_RESULT"]

            result_json = extract_json(llm_text)

            ntu_reason = result_json.get("ntu_reason", "Unclear / not explicitly evidenced")
            ntu_confidence = result_json.get("ntu_confidence", "Low")
            ntu_explanation = result_json.get("ntu_explanation", "")

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
                    PARSE_JSON('{sql_escape(json.dumps(result_json))}'),
                    'SUCCESS',
                    NULL
            """

            session.sql(insert_sql).collect()
            processed_count += 1

        except Exception as e:
            error_count += 1

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
                    'ERROR',
                    '{sql_escape(str(e))}'
            """

            session.sql(insert_error_sql).collect()

    return f"Run ID: {run_id}; processed={processed_count}; errors={error_count}; selected={len(selected_files)}"
$$;

TRUNCATE TABLE NTU_REASON_POC_RESULTS;

CALL RUN_NTU_REASON_POC(
  '@DROPBOX_OPEN_MARKET_V3/Open_Market',
  10
);

SELECT
    file_name,
    ntu_reason,
    ntu_confidence,
    ntu_explanation,
    raw_llm_output,
    status,
    error_message
FROM NTU_REASON_POC_RESULTS
ORDER BY processed_at DESC;
