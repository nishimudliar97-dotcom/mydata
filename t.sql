CREATE OR REPLACE PROCEDURE RUN_NTU_REASON_POC(
    STAGE_PATH STRING,
    LIMIT_FILES INTEGER
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json
import uuid
import datetime
import re

def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")

def extract_json(text):
    if text is None:
        return {}

    text = str(text).strip()
    text = re.sub(r"^```json", "", text, flags=re.IGNORECASE).strip()
    text = re.sub(r"^```", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    try:
        return json.loads(text)
    except Exception:
        pass

    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except Exception:
            return {}

    return {}

def normalize_stage_file_path(path):
    """
    session.file.list() may return either:
    @DROPOBOX_OPEN_MARKET_V3/Open_Market/file.pdf

    or:
    dropbox_open_market_v3/Open_Market/file.pdf

    This function makes both usable.
    """
    path = str(path)

    if not path.startswith("@"):
        path = "@" + path

    return path

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
                    OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE),
                    TRUE
                ) AS parsed_doc
            """

            parsed_row = session.sql(parse_sql).collect()[0]
            parsed_doc_raw = parsed_row["PARSED_DOC"]

            if parsed_doc_raw is None:
                raise Exception("AI_PARSE_DOCUMENT returned NULL")

            if isinstance(parsed_doc_raw, str):
                parsed_obj = json.loads(parsed_doc_raw)
            else:
                parsed_obj = parsed_doc_raw

            parse_error = None
            parsed_value = parsed_obj

            if isinstance(parsed_obj, dict) and "error" in parsed_obj:
                parse_error = parsed_obj.get("error")
                parsed_value = parsed_obj.get("value")

            if parse_error:
                raise Exception(f"AI_PARSE_DOCUMENT error: {parse_error}")

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

            doc_text = "\n\n".join(doc_text_parts)
            doc_text = doc_text[:90000]

            prompt = f"""
You are analyzing insurance quote discussion email chains for known NTU cases.

Task:
Return ONLY valid JSON with exactly these keys:
- ntu_reason
- ntu_confidence
- ntu_explanation
- secondary_factors
- do_not_use_as_primary_reason

Rules:
1. The case is already known to be NTU. Do not decide whether it is NTU.
2. Infer the most likely NTU reason only from the email chain.
3. Do not force a reason if evidence is weak. Use "Unclear / not explicitly evidenced" if needed.
4. Prefer these categories where supported:
   - Price / premium competitiveness
   - Broker / lead market preference
   - Layer / structure mismatch
   - Limited capacity / line size
   - Terms / coverage mismatch
   - Restrictive quote condition
   - Timing / late quote
   - Risk appetite / exposure concern
   - Loss history / risk quality
5. Confidence must be one of: High, Medium-High, Medium, Low-Medium, Low.
6. Explanation must be concise but evidence-based.
7. secondary_factors must be an array of short strings.
8. do_not_use_as_primary_reason must be an array of short strings.

Email chain text:
{doc_text}
"""

            llm_sql = f"""
                SELECT AI_COMPLETE(
                    'claude-3-5-sonnet',
                    '{sql_escape(prompt)}',
                    TRUE
                ) AS llm_result
            """

            llm_row = session.sql(llm_sql).collect()[0]
            llm_result = llm_row["LLM_RESULT"]

            if isinstance(llm_result, str):
                try:
                    llm_outer = json.loads(llm_result)
                except Exception:
                    llm_outer = {"value": llm_result, "error": None}
            else:
                llm_outer = llm_result

            if isinstance(llm_outer, dict) and llm_outer.get("error"):
                raise Exception(f"AI_COMPLETE error: {llm_outer.get('error')}")

            if isinstance(llm_outer, dict) and "value" in llm_outer:
                llm_text = llm_outer.get("value")
            else:
                llm_text = llm_result

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
