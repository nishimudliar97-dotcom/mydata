USE ROLE EXPERIMENT_TEAM_FULL;
USE DATABASE EXPERIMENT_TEAM_DB;
USE SCHEMA PUBLIC;
USE WAREHOUSE EXPERIMENT_TEAM_VWH;

CREATE OR REPLACE TABLE NTU_REASON_POC_RESULTS (
    run_id STRING,
    processed_at TIMESTAMP_NTZ,
    insurer_name STRING,
    folder_name STRING,
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

def get_folder_name(file_path):
    """
    Immediate parent folder of the PDF file.
    Example:
    @STAGE/Open_Market/A184429_Taylor_Preston/Submission/email.pdf
    -> Submission
    """
    parts = file_path.strip("/").split("/")
    if len(parts) >= 2:
        return parts[-2]
    return None

def get_insurer_name(file_path):
    """
    First folder after Open_Market.
    Example:
    @STAGE/Open_Market/A184429_Taylor_Preston/Submission/email.pdf
    -> A184429_Taylor_Preston
    """
    parts = file_path.strip("/").split("/")

    for i, part in enumerate(parts):
        if part.lower() == "open_market" and i + 1 < len(parts):
            return parts[i + 1]

    return get_folder_name(file_path)

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
        "ntu_reason_category_llm": "LLM category generation failed",
        "ntu_reason_short_label": "JSON parse failed",
        "ntu_confidence": "Low",
        "ntu_explanation": "The model did not return valid JSON. Check raw_llm_text for the actual response.",
        "inference_type": "Weakly inferred",
        "primary_evidence_points": [],
        "supporting_factors": [],
        "alternative_possible_categories": [],
        "weak_or_not_supported_reasons": [],
        "raw_text": raw_text
    }

def is_bad_unclear_category(category):
    if category is None:
        return True

    value = str(category).strip().lower()

    bad_values = [
        "",
        "unclear",
        "unclear / not explicitly evidenced",
        "unclear / insufficient evidence",
        "unclear / insufficient commercial signal",
        "not explicitly evidenced",
        "insufficient evidence",
        "no clear reason",
        "no reason provided",
        "not stated",
        "unknown"
    ]

    return value in bad_values

def build_primary_prompt(parsed_text_for_prompt):
    return f"""
You are analyzing insurance quote discussion email chains.

CRITICAL CONTEXT:
- Every document provided to you is already a confirmed NTU case.
- NTU means the quote was not taken up.
- The NTU reason will usually NOT be explicitly written.
- Your job is to infer the most likely NTU reason category from the commercial discussion.
- Do NOT answer "Unclear / not explicitly evidenced" just because the email does not explicitly state the NTU reason.

BUSINESS OBJECTIVE:
We are running this over many NTU cases to discover repeated reason categories.
You must generate a category yourself based on the strongest signals in the email chain.
Do not classify using a predefined fixed taxonomy.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason_category_llm": "",
  "ntu_reason_short_label": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "inference_type": "",
  "primary_evidence_points": [],
  "supporting_factors": [],
  "alternative_possible_categories": [],
  "weak_or_not_supported_reasons": []
}}

STRICT RULES:
1. This is already an NTU case. Do not decide whether it is NTU.
2. You MUST infer a likely NTU reason category if the email contains any quote discussion, broker negotiation, market response, pricing discussion, capacity discussion, layer discussion, terms discussion, or placement update.
3. Do NOT use phrases like:
   - "Unclear / not explicitly evidenced"
   - "Insufficient evidence"
   - "No clear reason"
   - "Not explicitly stated"
   as the primary category unless the document contains almost no commercial discussion at all.
4. The reason does NOT need to be explicit. It can be inferred from the behaviour of the discussion.
5. Create your own short category name based on the email evidence.
6. The category should be reusable across similar cases.
7. If evidence is indirect, still provide the best inferred category and reduce confidence.
8. Do not invent facts. Evidence points must be grounded in the email text.
9. Do not simply summarize the email. Identify the likely NTU behaviour pattern.

WHAT TO LOOK FOR:
Look for commercial signals such as:
- broker asking for lower premium, larger cut, rate reduction, or target pricing
- another insurer or lead market setting terms
- another market already placed or soft ordered
- quoted line being small, not useful, or conditional
- layer, attachment, capacity, or limit changing during the discussion
- quote being tied to another layer or not available standalone
- terms, deductibles, sublimits, exclusions, clauses, wording, or coverage being challenged
- late-stage discussion close to inception
- risk appetite concerns from exposure, occupancy, geography, CAT, losses, or engineering
- broker/client preference for another market, channel, structure, or programme design

IMPORTANT:
The above are only thinking signals, not fixed categories.
Generate your own category from the strongest signal in this document.

CATEGORY STYLE:
Good style examples:
- "Competing market undercut"
- "Lead market preference"
- "Layer structure no longer aligned"
- "Small line reduced placement value"
- "Restrictive tied-line quote"
- "Coverage terms mismatch"
- "Late-stage placement already advanced"
- "Risk appetite concern from CAT exposure"

Bad category examples:
- "Unclear"
- "Other"
- "General business reason"
- "Not explicitly evidenced"
- "No reason provided"

CONFIDENCE GUIDANCE:
- High: strong direct commercial signal.
- Medium-High: multiple strong indirect signals.
- Medium: plausible inference from some meaningful signals.
- Low-Medium: weak inference from limited signals.
- Low: limited evidence, but still provide the best possible inferred category.

FIELD GUIDANCE:
- "ntu_reason_category_llm": your discovered NTU category.
- "ntu_reason_short_label": 3 to 7 word label.
- "ntu_confidence": High, Medium-High, Medium, Low-Medium, or Low.
- "ntu_explanation": explain why this category is the most likely reason.
- "inference_type": use one of "Explicit", "Strongly inferred", "Moderately inferred", "Weakly inferred".
- "primary_evidence_points": short evidence points from the email chain.
- "supporting_factors": secondary signals that support the category.
- "alternative_possible_categories": other plausible categories not selected as primary.
- "weak_or_not_supported_reasons": reasons that should not be treated as primary.

Parsed PDF/email-chain text:
{parsed_text_for_prompt}
"""

def build_retry_prompt(parsed_text_for_prompt):
    return f"""
You previously answered with an unclear or insufficient category.

That is not useful for this task.

CRITICAL CONTEXT:
- This document is already confirmed as an NTU case.
- The NTU reason is usually implicit, not explicitly written.
- Your task is to infer the most plausible NTU reason category from the strongest commercial signals.
- You must create a specific category unless the document contains almost no quote or placement discussion.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason_category_llm": "",
  "ntu_reason_short_label": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "inference_type": "",
  "primary_evidence_points": [],
  "supporting_factors": [],
  "alternative_possible_categories": [],
  "weak_or_not_supported_reasons": []
}}

Instructions:
1. Do not say "Unclear", "Insufficient evidence", or "Not explicitly stated" as the main category.
2. Infer the likely NTU behaviour pattern.
3. Create a short business-friendly category name.
4. Ground the category in evidence from the email chain.
5. If evidence is indirect, reduce confidence, but still provide the best inferred category.
6. Separate primary reason from secondary factors.

Category style examples only, not fixed categories:
- competing market undercut
- lead market preference
- layer structure no longer aligned
- restrictive tied-line quote
- coverage terms mismatch
- small line reduced placement value
- late-stage placement already advanced
- pricing pressure from broker target
- capacity not useful enough
- terms not flexible enough

Email-chain text:
{parsed_text_for_prompt}
"""

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
        folder_name = get_folder_name(file_path)
        insurer_name = get_insurer_name(file_path)

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

            # Keep text smaller for POC
            parsed_text_for_prompt = parsed_text[:50000]

            prompt = build_primary_prompt(parsed_text_for_prompt)

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

            category_value = result_json["ntu_reason_category_llm"] if "ntu_reason_category_llm" in result_json else ""

            # Retry once if model gives unclear/non-useful category
            if is_bad_unclear_category(category_value):
                retry_prompt = build_retry_prompt(parsed_text_for_prompt)

                retry_sql = f"""
                    SELECT AI_COMPLETE(
                        '{MODEL_NAME}',
                        '{sql_escape(retry_prompt)}',
                        OBJECT_CONSTRUCT(
                            'temperature', 0,
                            'max_tokens', 1200
                        )
                    )::STRING AS retry_result
                """

                retry_row = session.sql(retry_sql).collect()[0]
                retry_text = retry_row["RETRY_RESULT"]

                retry_json = extract_json_from_llm(retry_text)
                retry_category = retry_json["ntu_reason_category_llm"] if "ntu_reason_category_llm" in retry_json else ""

                # Use retry response even if still weak, so raw text shows final attempt
                result_json = retry_json
                llm_text = retry_text
                category_value = retry_category

            ntu_reason = result_json["ntu_reason_category_llm"] if "ntu_reason_category_llm" in result_json else "LLM category generation failed"
            ntu_confidence = result_json["ntu_confidence"] if "ntu_confidence" in result_json else "Low"
            ntu_explanation = result_json["ntu_explanation"] if "ntu_explanation" in result_json else "The model did not return the expected explanation field. Check raw_llm_text."

            insert_sql = f"""
                INSERT INTO NTU_REASON_POC_RESULTS
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(insurer_name)}',
                    '{sql_escape(folder_name)}',
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
                    '{sql_escape(insurer_name)}',
                    '{sql_escape(folder_name)}',
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
    insurer_name,
    folder_name,
    file_name,
    ntu_reason,
    ntu_confidence,
    ntu_explanation,
    raw_llm_output,
    raw_llm_text,
    status,
    error_message
FROM NTU_REASON_POC_RESULTS
ORDER BY processed_at DESC;
