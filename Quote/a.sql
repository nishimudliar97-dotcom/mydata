USE DATABASE EXPERIMENT_TEAM_DB;
USE SCHEMA PUBLIC;
USE WAREHOUSE EXPERIMENT_TEAM_VWH;

CREATE OR REPLACE TABLE NTU_QUOTE_FOLDER_ANALYSIS_RESULTS_V1 (
    RUN_ID STRING,
    PROCESSED_AT TIMESTAMP_NTZ,

    ACCOUNT_NAME STRING,
    INSURER_FOLDER_NAME STRING,
    FOLDER_PATH STRING,

    SUBMISSION_RECEIVED_DATE STRING,
    QUOTE_SENT_DATE STRING,
    NUMBER_OF_REQUOTES NUMBER,

    NTU_REASON STRING,
    NTU_SUBCATEGORY STRING,
    NTU_REASON_CONFIDENCE STRING,
    NTU_EXPLANATION STRING,
    NTU_SUMMARY STRING,

    FILE_COUNT NUMBER,
    FILE_NAMES STRING,

    RAW_LLM_OUTPUT VARIANT,
    STATUS STRING,
    ERROR_MESSAGE STRING
);

CREATE OR REPLACE PROCEDURE RUN_NTU_QUOTE_FOLDER_ANALYSIS_V1(
    STAGE_FOLDER_PATH STRING,
    MAX_FOLDERS NUMBER
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json
import re
import uuid
from datetime import datetime
from collections import defaultdict
from snowflake.snowpark import Session


# ---------------------------------------------------------------------
# Fixed controlled lists provided by business/user
# ---------------------------------------------------------------------

ALLOWED_NTU_REASONS = [
    "Size/Capacity no longer aligned",
    "Broker Client Preference",
    "Broker Client Preference - Preferred Market",
    "Broker Client Preference - PPL preference",
    "Competing market undercut",
    "Broker Preferred Market",
    "Defensive Posture",
    "Broker preference for another market",
    "Alternative Market Pursued",
    "Regulatory licensing issue",
    "Loss Development Concerns",
    "Risk appetite concern from CAT exposure",
    "Broker unable to meet client's target",
    "Risk appetite concern from loss history",
    "Broker Target Not Met",
    "Broker preference for competing market",
    "Competing market pricing",
    "Pricing pressure",
    "Broker preference for lead market"
]

ALLOWED_NTU_SUBCATEGORIES = [
    "Pricing",
    "Size/Capacity",
    "Broker / Client Preferred Market",
    "Limit / Line Size",
    "Underwriting Appetite",
    "Policy Terms / Conditions",
    "Late Quote / Timing",
    "Deductible",
    "Submit"
]


# ---------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------

def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")


def normalize_stage_path(stage_folder_path):
    """
    Input example:
      @OPEN_MARKET_QUOTE/Open_Market

    Output:
      stage_name  = @OPEN_MARKET_QUOTE
      root_prefix = Open_Market
    """
    p = str(stage_folder_path).strip()

    if not p.startswith("@"):
        p = "@" + p

    p = p.rstrip("/")

    parts = p.split("/", 1)

    stage_name = parts[0]
    root_prefix = ""

    if len(parts) > 1:
        root_prefix = parts[1].strip("/")

    return stage_name, root_prefix


def extract_relative_path(file_name, stage_name):
    """
    Snowpark session.file.list may return paths in slightly different forms.
    This converts them into the path expected by PARSE_DOCUMENT.
    """
    full = str(file_name)

    # Remove query params if any
    full = full.split("?")[0]

    # Case 1: already starts with @stage
    if full.startswith(stage_name + "/"):
        return full[len(stage_name) + 1:]

    # Case 2: contains the stage name somewhere
    marker = stage_name.replace("@", "") + "/"
    idx = full.find(marker)
    if idx >= 0:
        return full[idx + len(marker):]

    # Case 3: full database/schema/stage path
    # Try to locate OPEN_MARKET or first folder after stage name by fallback
    return full.lstrip("/")


def get_account_folder(relative_path, root_prefix):
    """
    Expected relative path:
      Open_Market/A165060_Dyson_Holding/Quote/file.pdf

    Account folder should be:
      A165060_Dyson_Holding
    """
    rp = relative_path.strip("/")

    if root_prefix:
        prefix = root_prefix.strip("/") + "/"
        if rp.startswith(prefix):
            rp = rp[len(prefix):]

    parts = rp.split("/")

    if len(parts) >= 1:
        return parts[0]

    return "UNKNOWN_FOLDER"


def safe_json_from_text(text):
    """
    LLM should return JSON only, but this makes parsing tolerant.
    """
    if text is None:
        return {}

    s = str(text).strip()

    # Remove code fences if returned
    s = s.replace("```json", "").replace("```", "").strip()

    try:
        return json.loads(s)
    except Exception:
        pass

    # Extract first JSON object
    m = re.search(r"\{.*\}", s, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(0))
        except Exception:
            return {}

    return {}


def as_string(value):
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def as_int(value):
    try:
        if value is None:
            return None
        return int(float(str(value).strip()))
    except Exception:
        return None


def clamp_to_allowed(value, allowed_list):
    """
    Force output into allowed list. If model gives near text but not exact,
    keep it only if exact match after lower/strip. Otherwise fallback to first.
    """
    if value is None:
        return None

    raw = str(value).strip()
    for allowed in allowed_list:
        if raw.lower() == allowed.lower():
            return allowed

    # soft contains match
    for allowed in allowed_list:
        if allowed.lower() in raw.lower() or raw.lower() in allowed.lower():
            return allowed

    return None


# ---------------------------------------------------------------------
# Snowflake Cortex helpers
# ---------------------------------------------------------------------

def parse_document_text(session, stage_name, relative_file_path):
    """
    Uses Snowflake Cortex PARSE_DOCUMENT.
    Works for PDFs/images if enabled in account.
    For DOC/DOCX, this will work only if your Snowflake account supports it.
    If DOC/DOCX is unsupported, the file will be logged as parse error.
    """
    stage_sql = sql_escape(stage_name)
    file_sql = sql_escape(relative_file_path)

    parse_sql = f"""
        SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
            '{stage_sql}',
            '{file_sql}',
            OBJECT_CONSTRUCT('mode', 'OCR')
        ) AS PARSED_DOC
    """

    row = session.sql(parse_sql).collect()[0]
    parsed = row["PARSED_DOC"]

    if parsed is None:
        return ""

    # PARSE_DOCUMENT can return VARIANT with content/text depending on account version
    if isinstance(parsed, dict):
        for key in ["content", "text", "pages"]:
            if key in parsed:
                v = parsed.get(key)
                if isinstance(v, list):
                    return "\n".join([as_string(x) for x in v])
                return as_string(v)

    parsed_str = as_string(parsed)

    # Try JSON string
    try:
        parsed_json = json.loads(parsed_str)
        if isinstance(parsed_json, dict):
            for key in ["content", "text"]:
                if key in parsed_json:
                    return as_string(parsed_json.get(key))
            if "pages" in parsed_json and isinstance(parsed_json["pages"], list):
                return "\n".join([as_string(x) for x in parsed_json["pages"]])
    except Exception:
        pass

    return parsed_str


def call_llm(session, prompt):
    """
    Uses SNOWFLAKE.CORTEX.COMPLETE.
    Change model here if needed.
    """
    prompt_sql = sql_escape(prompt)

    llm_sql = f"""
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            'llama3.1-70b',
            '{prompt_sql}'
        ) AS LLM_OUTPUT
    """

    row = session.sql(llm_sql).collect()[0]
    return row["LLM_OUTPUT"]


# ---------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------

def build_prompt(account_name, conversation_text, file_count, file_names):
    allowed_reasons = "\n".join([f"- {x}" for x in ALLOWED_NTU_REASONS])
    allowed_subcats = "\n".join([f"- {x}" for x in ALLOWED_NTU_SUBCATEGORIES])

    # Keep text bounded for first POC. Increase later if needed.
    text_for_llm = conversation_text[:90000]

    return f"""
You are analysing an insurance placement / quote email-chain for an NTU case.

Important business context:
- These are known NTU cases.
- The explicit phrase "NTU reason" may not appear in the document.
- Your task is to infer the most likely NTU reason category from the conversation.
- Use actual evidence from the conversation: pricing, premium, target pricing, market comparisons, line size, capacity, layer structure, quote changes, broker/client preference, deductible, policy terms, timing, risk appetite, loss history, CAT exposure, or quote competitiveness.
- Do not say "unclear" only because the document does not explicitly say NTU.
- If evidence is indirect, still infer the strongest likely reason and explain why.
- Do not invent categories outside the allowed lists.

Account / folder name:
{account_name}

Number of files combined for this account:
{file_count}

File names:
{file_names}

Allowed NTU_REASON values:
{allowed_reasons}

Allowed NTU_SUBCATEGORY values:
{allowed_subcats}

Fields to extract:

1. submission_received_date
Definition:
The earliest date in the conversation where the broker/client/submission party first sends the submission, renewal request, request to quote, modelling request, or placement opportunity to Convex.
Examples:
- If the first broker email says "we are pleased to present the underwriting submission" on 2 Aug 2024, use 2 Aug 2024.
- If the conversation starts with "please model" on 23 Oct 2025, use 23 Oct 2025.

2. quote_sent_date
Definition:
The first date on which Convex sends an actual quote/terms/line/premium back to the broker/client.
Look for Convex messages with phrases such as:
- "can quote"
- "we can offer"
- "can agree to"
- "happy to offer"
- "we would be looking for"
- quoted line/premium/layer terms
Use the earliest Convex quote date.

3. number_of_requotes
Definition:
Count how many separate times Convex sent quote terms or revised quote terms in the conversation.
Count only actual quote/requote messages from Convex, not broker requests.
A requote can be a changed premium, changed line, changed layer, changed capacity, changed deductible, changed subjectivity, or alternative quote option.
If Convex quoted once only, return 1.
If Convex quoted initial terms and later revised twice, return 3.

4. ntu_reason
Choose exactly one value from the allowed NTU_REASON list.

5. ntu_subcategory
Choose exactly one value from the allowed NTU_SUBCATEGORY list.

6. ntu_reason_confidence
Return one of: High, Medium, Low.

7. ntu_explanation
This must be detailed and granular.
Do not give generic wording.
Explain the actual chain of events and evidence:
- who asked for what,
- what Convex quoted,
- whether broker/client pushed for target pricing,
- whether another market/lead market/competing market was mentioned,
- whether capacity, layer, limit, premium, deductible, timing, or policy terms were the issue,
- how this evidence leads to the selected NTU_REASON and NTU_SUBCATEGORY.
Include important figures when present, such as quoted premium, target premium, line %, layer, limit, deductible, or competing market pricing.
If there are multiple quote/requote rounds, summarize the sequence.

8. ntu_summary
Short summary of the overall conversation in 3-5 sentences.

Return only valid JSON with exactly these keys:
{{
  "submission_received_date": "",
  "quote_sent_date": "",
  "number_of_requotes": 0,
  "ntu_reason": "",
  "ntu_subcategory": "",
  "ntu_reason_confidence": "",
  "ntu_explanation": "",
  "ntu_summary": ""
}}

Conversation text:
{text_for_llm}
"""


# ---------------------------------------------------------------------
# Main procedure
# ---------------------------------------------------------------------

def run(session: Session, stage_folder_path: str, max_folders: int):
    run_id = str(uuid.uuid4())
    processed_count = 0
    error_count = 0

    stage_name, root_prefix = normalize_stage_path(stage_folder_path)

    # Supports PDF, PNG/JPG/JPEG, DOC/DOCX.
    # DOC/DOCX depends on Snowflake PARSE_DOCUMENT support in your account.
    pattern = r".*\.(pdf|png|jpg|jpeg|doc|docx)$"

    files = session.file.list(stage_folder_path, pattern=pattern)

    folder_map = defaultdict(list)

    for f in files:
        relative_path = extract_relative_path(f.name, stage_name)
        account_folder = get_account_folder(relative_path, root_prefix)
        folder_map[account_folder].append(relative_path)

    # Stable order for batching
    selected_folders = sorted(folder_map.keys())[:int(max_folders)]

    if len(selected_folders) == 0:
        return f"Run ID: {run_id}; no folders/files selected from {stage_folder_path}"

    for account_name in selected_folders:
        folder_files = sorted(folder_map[account_name])
        file_count = len(folder_files)
        file_names = ", ".join([x.split("/")[-1] for x in folder_files])
        folder_path = f"{root_prefix}/{account_name}".strip("/")

        try:
            combined_parts = []

            for idx, relative_file_path in enumerate(folder_files, start=1):
                try:
                    parsed_text = parse_document_text(session, stage_name, relative_file_path)

                    if parsed_text is None or len(str(parsed_text).strip()) == 0:
                        parsed_text = ""

                    combined_parts.append(
                        f"\n\n================ FILE {idx}: {relative_file_path} ================\n\n"
                        + str(parsed_text)
                    )

                except Exception as file_parse_error:
                    combined_parts.append(
                        f"\n\n================ FILE {idx}: {relative_file_path} ================\n\n"
                        + f"[FILE_PARSE_ERROR: {str(file_parse_error)}]"
                    )

            conversation_text = "\n".join(combined_parts)

            if conversation_text is None or len(str(conversation_text).strip()) == 0:
                raise Exception("No parsed text found for this folder.")

            prompt = build_prompt(
                account_name=account_name,
                conversation_text=conversation_text,
                file_count=file_count,
                file_names=file_names
            )

            raw_llm = call_llm(session, prompt)
            parsed = safe_json_from_text(raw_llm)

            submission_received_date = as_string(parsed.get("submission_received_date"))
            quote_sent_date = as_string(parsed.get("quote_sent_date"))
            number_of_requotes = as_int(parsed.get("number_of_requotes"))

            ntu_reason_raw = as_string(parsed.get("ntu_reason"))
            ntu_subcategory_raw = as_string(parsed.get("ntu_subcategory"))

            ntu_reason = clamp_to_allowed(ntu_reason_raw, ALLOWED_NTU_REASONS)
            ntu_subcategory = clamp_to_allowed(ntu_subcategory_raw, ALLOWED_NTU_SUBCATEGORIES)

            # If LLM returned something invalid, keep the raw output visible but mark error.
            if ntu_reason is None:
                ntu_reason = ntu_reason_raw

            if ntu_subcategory is None:
                ntu_subcategory = ntu_subcategory_raw

            ntu_reason_confidence = as_string(parsed.get("ntu_reason_confidence"))
            ntu_explanation = as_string(parsed.get("ntu_explanation"))
            ntu_summary = as_string(parsed.get("ntu_summary"))

            insert_sql = f"""
                INSERT INTO NTU_QUOTE_FOLDER_ANALYSIS_RESULTS_V1 (
                    RUN_ID,
                    PROCESSED_AT,
                    ACCOUNT_NAME,
                    INSURER_FOLDER_NAME,
                    FOLDER_PATH,
                    SUBMISSION_RECEIVED_DATE,
                    QUOTE_SENT_DATE,
                    NUMBER_OF_REQUOTES,
                    NTU_REASON,
                    NTU_SUBCATEGORY,
                    NTU_REASON_CONFIDENCE,
                    NTU_EXPLANATION,
                    NTU_SUMMARY,
                    FILE_COUNT,
                    FILE_NAMES,
                    RAW_LLM_OUTPUT,
                    STATUS,
                    ERROR_MESSAGE
                )
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(account_name)}',
                    '{sql_escape(account_name)}',
                    '{sql_escape(folder_path)}',
                    '{sql_escape(submission_received_date)}',
                    '{sql_escape(quote_sent_date)}',
                    {number_of_requotes if number_of_requotes is not None else "NULL"},
                    '{sql_escape(ntu_reason)}',
                    '{sql_escape(ntu_subcategory)}',
                    '{sql_escape(ntu_reason_confidence)}',
                    '{sql_escape(ntu_explanation)}',
                    '{sql_escape(ntu_summary)}',
                    {file_count},
                    '{sql_escape(file_names)}',
                    TRY_PARSE_JSON('{sql_escape(json.dumps(parsed, ensure_ascii=False))}'),
                    'SUCCESS',
                    NULL
            """

            session.sql(insert_sql).collect()
            processed_count += 1

        except Exception as e:
            error_count += 1

            insert_error_sql = f"""
                INSERT INTO NTU_QUOTE_FOLDER_ANALYSIS_RESULTS_V1 (
                    RUN_ID,
                    PROCESSED_AT,
                    ACCOUNT_NAME,
                    INSURER_FOLDER_NAME,
                    FOLDER_PATH,
                    SUBMISSION_RECEIVED_DATE,
                    QUOTE_SENT_DATE,
                    NUMBER_OF_REQUOTES,
                    NTU_REASON,
                    NTU_SUBCATEGORY,
                    NTU_REASON_CONFIDENCE,
                    NTU_EXPLANATION,
                    NTU_SUMMARY,
                    FILE_COUNT,
                    FILE_NAMES,
                    RAW_LLM_OUTPUT,
                    STATUS,
                    ERROR_MESSAGE
                )
                SELECT
                    '{sql_escape(run_id)}',
                    CURRENT_TIMESTAMP(),
                    '{sql_escape(account_name)}',
                    '{sql_escape(account_name)}',
                    '{sql_escape(folder_path)}',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    {file_count},
                    '{sql_escape(file_names)}',
                    NULL,
                    'ERROR',
                    '{sql_escape(str(e))}'
            """

            session.sql(insert_error_sql).collect()

    return f"Run ID: {run_id}; processed={processed_count}; errors={error_count}; selected_folders={len(selected_folders)}"
$$;


CALL RUN_NTU_QUOTE_FOLDER_ANALYSIS_V1(
  '@OPEN_MARKET_QUOTE/Open_Market',
  5
);
