USE ROLE EXPERIMENT_TEAM_FULL;
USE DATABASE EXPERIMENT_TEAM_DB;
USE SCHEMA PUBLIC;
USE WAREHOUSE EXPERIMENT_TEAM_VWH;

CREATE OR REPLACE TABLE NTU_FOLDER_CONVERSATION_DISCOVERY_RESULTS (
    run_id STRING,
    processed_at TIMESTAMP_NTZ,

    account_folder_name STRING,
    folder_path STRING,

    file_count NUMBER,
    file_names STRING,
    file_paths STRING,

    ntu_reason STRING,
    ntu_confidence STRING,
    ntu_explanation STRING,
    granular_factor_summary STRING,

    raw_llm_output VARIANT,
    raw_llm_text STRING,
    raw_parsed_text STRING,

    status STRING,
    error_message STRING,
    parse_errors STRING
);

CREATE OR REPLACE PROCEDURE RUN_NTU_FOLDER_CONVERSATION_DISCOVERY_POC(
    STAGE_PATH STRING,
    LIMIT_FOLDERS INTEGER
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

SUPPORTED_EXTENSIONS = [".pdf", ".png"]

def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")

def normalize_stage_file_path(path):
    path = str(path)
    if not path.startswith("@"):
        path = "@" + path
    return path

def natural_sort_key(text):
    return [
        int(part) if part.isdigit() else part.lower()
        for part in re.split(r"(\d+)", str(text))
    ]

def is_supported_file(path):
    lower_path = str(path).lower()
    return any(lower_path.endswith(ext) for ext in SUPPORTED_EXTENSIONS)

def get_account_folder_name(file_path):
    """
    Returns first folder after Open_Market.
    Example:
    @OPEN_MARKET_QUOTE/Open_Market/A165060_Dyson_Holding/file.pdf
    -> A165060_Dyson_Holding
    """
    parts = file_path.strip("/").split("/")

    for i, part in enumerate(parts):
        if part.lower() == "open_market" and i + 1 < len(parts):
            return parts[i + 1]

    if len(parts) >= 2:
        return parts[-2]

    return "UNKNOWN_ACCOUNT_FOLDER"

def get_folder_path(file_path):
    """
    Returns folder path excluding file name.
    """
    if "/" in file_path:
        return file_path.rsplit("/", 1)[0]
    return file_path

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
        "granular_factor_summary": "Unable to parse structured factor summary from model output.",
        "inference_type": "Weakly inferred",
        "primary_evidence_points": [],
        "pricing_signals": [],
        "market_competition_signals": [],
        "layer_capacity_structure_signals": [],
        "terms_conditions_coverage_signals": [],
        "timing_placement_signals": [],
        "broker_client_preference_signals": [],
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

def build_primary_prompt(combined_text):
    return f"""
You are analyzing insurance quote discussion email chains.

CRITICAL CONTEXT:
- Every folder provided to you is already a confirmed NTU case.
- NTU means the quote was not taken up.
- The NTU reason will usually NOT be explicitly written.
- Your job is to infer the most likely NTU reason category from the full combined conversation.
- The combined conversation may contain multiple PDFs or PNGs from the same account folder.
- Treat all files in the folder as one insurance quote discussion / one NTU case.

BUSINESS OBJECTIVE:
We are running this over many NTU cases to discover repeated reason categories.
You must generate a category yourself based on the strongest commercial signals in the conversation.
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
  "granular_factor_summary": "",
  "inference_type": "",
  "primary_evidence_points": [],
  "pricing_signals": [],
  "market_competition_signals": [],
  "layer_capacity_structure_signals": [],
  "terms_conditions_coverage_signals": [],
  "timing_placement_signals": [],
  "broker_client_preference_signals": [],
  "supporting_factors": [],
  "alternative_possible_categories": [],
  "weak_or_not_supported_reasons": []
}}

STRICT RULES:
1. This folder is already an NTU case. Do not decide whether it is NTU.
2. You MUST infer a likely NTU reason category if the conversation contains quote discussion, broker negotiation, market response, pricing discussion, capacity discussion, layer discussion, terms discussion, or placement update.
3. Do NOT use phrases like "Unclear", "Insufficient evidence", "No clear reason", or "Not explicitly stated" as the primary category unless there is almost no useful commercial discussion.
4. The reason does NOT need to be explicit. It can be inferred from the behaviour of the discussion.
5. Create your own short category name based on the strongest evidence.
6. The category should be reusable across similar cases.
7. If evidence is indirect, still provide the best inferred category and reduce confidence.
8. Do not invent facts. Every evidence point must be grounded in the conversation text.
9. Do not simply summarize the email. Identify the likely NTU behaviour pattern.
10. Give a granular explanation, not a generic one.

EXPLANATION REQUIREMENTS:
The "ntu_explanation" must be detailed and specific.
It should explain:
- what the broker/client/market was asking for,
- what commercial tension appears in the discussion,
- whether there was pricing pressure, competing market pressure, layer mismatch, terms issue, timing issue, or capacity usefulness issue,
- why those signals make the selected category the most likely NTU reason,
- whether the inference is strong or only moderately inferred.

Do not write a generic sentence like:
"The broker prefers another market."

Instead, write a more granular explanation like:
"The conversation shows that the broker was comparing Convex's quote against another market's terms. The broker referenced a competing target/lead position and pushed for different pricing or structure, which suggests Convex's offered terms were not the preferred option. The likely NTU driver is therefore not simply a generic market preference, but a placement decision influenced by competing market terms and commercial competitiveness."

WHAT TO ANALYZE:
Use the following as analytical lenses, not fixed categories:
- Pricing: premium, rate cut, net price, commission, AP, target price, expiring price, market price, undercut
- Market competition: lead market, competing market, wholesale market, already placed, soft order, preferred market
- Layer/capacity/structure: attachment point, xs layer, primary/excess, line percentage, capacity size, tied lines, standalone/not standalone
- Terms/coverage: deductibles, sublimits, clauses, wording, exclusions, SRCC, CAT, NWS, AOP, T&Cs
- Timing/placement: late quote, quote open days, inception, placement already advanced, urgent renewal
- Broker/client preference: broker target, client focus, long-term relationship, preferred channel, request to improve terms
- Risk appetite: loss history, CAT exposure, geography, occupancy, engineering, values, risk changes

IMPORTANT:
The final "ntu_reason_category_llm" must be your own discovered category from the strongest signal.
The signal lists above are only to guide reasoning.

CONFIDENCE GUIDANCE:
- High: strong direct commercial signal.
- Medium-High: multiple strong indirect signals.
- Medium: plausible inference from meaningful signals.
- Low-Medium: weak inference from limited signals.
- Low: limited evidence, but still provide the best possible inferred category.

Combined parsed PDF/PNG/email-chain text:
{combined_text}
"""

def build_retry_prompt(combined_text):
    return f"""
You previously answered with an unclear or insufficient category.

That is not useful for this task.

CRITICAL CONTEXT:
- This folder is already confirmed as an NTU case.
- The NTU reason is usually implicit, not explicitly written.
- Your task is to infer the most plausible NTU reason category from the strongest commercial signals.
- You must create a specific category unless there is almost no quote or placement discussion.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason_category_llm": "",
  "ntu_reason_short_label": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "granular_factor_summary": "",
  "inference_type": "",
  "primary_evidence_points": [],
  "pricing_signals": [],
  "market_competition_signals": [],
  "layer_capacity_structure_signals": [],
  "terms_conditions_coverage_signals": [],
  "timing_placement_signals": [],
  "broker_client_preference_signals": [],
  "supporting_factors": [],
  "alternative_possible_categories": [],
  "weak_or_not_supported_reasons": []
}}

Instructions:
1. Do not say "Unclear", "Insufficient evidence", or "Not explicitly stated" as the main category.
2. Infer the likely NTU behaviour pattern.
3. Create a short business-friendly category name.
4. Ground the category in evidence from the conversation.
5. If evidence is indirect, reduce confidence, but still provide the best inferred category.
6. Make the explanation granular and specific.
7. Mention whether pricing, competing market, layer/capacity, terms, timing, broker/client preference, or risk appetite signals influenced the conclusion.

Combined conversation text:
{combined_text}
"""

def parse_single_file(session, file_path):
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

    return str(parsed_text)

def run(session, stage_path, limit_folders):
    run_id = str(uuid.uuid4())

    if limit_folders is None or limit_folders <= 0:
        limit_folders = 10

    all_files_raw = session.file.list(stage_path)

    supported_files = []
    for f in all_files_raw:
        file_path = normalize_stage_file_path(str(f.name))
        if is_supported_file(file_path):
            supported_files.append(file_path)

    supported_files = sorted(supported_files, key=natural_sort_key)

    grouped = {}

    for file_path in supported_files:
        account_folder_name = get_account_folder_name(file_path)
        folder_path = None

        parts = file_path.strip("/").split("/")
        for i, part in enumerate(parts):
            if part.lower() == "open_market" and i + 1 < len(parts):
                folder_path = "/".join(parts[:i + 2])
                break

        if folder_path is None:
            folder_path = get_folder_path(file_path)

        if account_folder_name not in grouped:
            grouped[account_folder_name] = {
                "account_folder_name": account_folder_name,
                "folder_path": folder_path,
                "files": []
            }

        grouped[account_folder_name]["files"].append(file_path)

    selected_groups = list(grouped.values())[:limit_folders]

    processed_count = 0
    error_count = 0

    for group in selected_groups:
        account_folder_name = group["account_folder_name"]
        folder_path = group["folder_path"]
        files = sorted(group["files"], key=natural_sort_key)

        file_names = [fp.split("/")[-1] for fp in files]
        file_paths = files

        parsed_sections = []
        parse_errors = []

        try:
            for idx, file_path in enumerate(files, start=1):
                try:
                    parsed_text = parse_single_file(session, file_path)

                    parsed_sections.append(
                        f"""
==============================
FILE {idx}: {file_path}
==============================
{parsed_text}
"""
                    )

                except Exception as file_err:
                    parse_errors.append(
                        f"{file_path}: {str(file_err)}"
                    )

            if len(parsed_sections) == 0:
                raise Exception("No files in this folder could be parsed successfully.")

            combined_parsed_text = "\n\n".join(parsed_sections)

            # Keep combined text smaller for POC
            combined_text_for_prompt = combined_parsed_text[:70000]

            prompt = build_primary_prompt(combined_text_for_prompt)

            llm_sql = f"""
                SELECT AI_COMPLETE(
                    '{MODEL_NAME}',
                    '{sql_escape(prompt)}',
                    OBJECT_CONSTRUCT(
                        'temperature', 0,
                        'max_tokens', 1800
                    )
                )::STRING AS llm_result
            """

            llm_row = session.sql(llm_sql).collect()[0]
            llm_text = llm_row["LLM_RESULT"]

            result_json = extract_json_from_llm(llm_text)

            category_value = result_json["ntu_reason_category_llm"] if "ntu_reason_category_llm" in result_json else ""

            if is_bad_unclear_category(category_value):
                retry_prompt = build_retry_prompt(combined_text_for_prompt)

                retry_sql = f"""
                    SELECT AI_COMPLETE(
                        '{MODEL_NAME}',
                        '{sql_escape(retry_prompt)}',
                        OBJECT_CONSTRUCT(
                            'temperature', 0,
                            'max_tokens', 1800
                        )
                    )::STRING AS retry_result
                """

                retry_row = session.sql(retry_sql).collect()[0]
                retry_text = retry_row["RETRY_RESULT"]

                retry_json = extract_json_from_llm(retry_text)

                result_json = retry_json
                llm_text = retry_text

            ntu_reason = result_json["ntu_reason_category_llm"] if "ntu_reason_category_llm" in result_json else "LLM category generation failed"
            ntu_confidence = result_json["ntu_confidence"] if "ntu_confidence" in result_json else "Low"
            ntu_explanation = result_json["ntu_explanation"] if "ntu_explanation" in result_json else "The model did not return the expected explanation field. Check raw_llm_text."
            granular_factor_summary = result_json["granular_factor_summary"] if "granular_factor_summary" in result_json else ""

            final_status = "SUCCESS"
            if len(parse_errors) > 0:
                final_status = "SUCCESS_WITH_FILE_PARSE_ERRORS"

            insert_sql = f"""
                INSERT INTO NTU_FOLDER_CONVERSATION_DISCOVERY_RESULTS
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(account_folder_name)}',
                    '{sql_escape(folder_path)}',
                    {len(files)},
                    '{sql_escape(json.dumps(file_names))}',
                    '{sql_escape(json.dumps(file_paths))}',
                    '{sql_escape(ntu_reason)}',
                    '{sql_escape(ntu_confidence)}',
                    '{sql_escape(ntu_explanation)}',
                    '{sql_escape(granular_factor_summary)}',
                    TRY_PARSE_JSON('{sql_escape(json.dumps(result_json))}'),
                    '{sql_escape(llm_text)}',
                    '{sql_escape(combined_parsed_text[:15000])}',
                    '{sql_escape(final_status)}',
                    NULL,
                    '{sql_escape(json.dumps(parse_errors))}'
            """

            session.sql(insert_sql).collect()
            processed_count += 1

        except Exception:
            error_count += 1
            full_error = traceback.format_exc()

            insert_error_sql = f"""
                INSERT INTO NTU_FOLDER_CONVERSATION_DISCOVERY_RESULTS
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(account_folder_name)}',
                    '{sql_escape(folder_path)}',
                    {len(files)},
                    '{sql_escape(json.dumps(file_names))}',
                    '{sql_escape(json.dumps(file_paths))}',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'ERROR',
                    '{sql_escape(full_error)}',
                    '{sql_escape(json.dumps(parse_errors))}'
            """

            session.sql(insert_error_sql).collect()

    return f"Run ID: {run_id}; processed_folders={processed_count}; errors={error_count}; selected_folders={len(selected_groups)}; total_supported_files={len(supported_files)}"
$$;

TRUNCATE TABLE NTU_FOLDER_CONVERSATION_DISCOVERY_RESULTS;

CALL RUN_NTU_FOLDER_CONVERSATION_DISCOVERY_POC(
  '@OPEN_MARKET_QUOTE/Open_Market',
  10
);

SELECT
    account_folder_name,
    folder_path,
    file_count,
    file_names,
    ntu_reason,
    ntu_confidence,
    ntu_explanation,
    granular_factor_summary,
    raw_llm_output,
    status,
    error_message,
    parse_errors
FROM NTU_FOLDER_CONVERSATION_DISCOVERY_RESULTS
ORDER BY processed_at DESC;
