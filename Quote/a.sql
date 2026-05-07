CREATE OR REPLACE TABLE NTU_QUOTE_FOLDER_ANALYSIS_RESULTS_V2 (
    RUN_ID STRING,
    PROCESSED_AT TIMESTAMP_NTZ,

    ACCOUNT_NAME STRING,
    ACCOUNT_FOLDER STRING,

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

CREATE OR REPLACE PROCEDURE RUN_NTU_QUOTE_FOLDER_ANALYSIS_V2(
    STAGE_ROOT STRING,
    MAX_FOLDERS INTEGER,
    OFFSET_FOLDERS INTEGER
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json
import re
import uuid
from datetime import datetime


MODEL_NAME = "llama3.1-8b"


NTU_REASON_LIST = [
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


NTU_SUBCATEGORY_LIST = [
    "Pricing",
    "Size/Capacity",
    "Broker / Client Preferred Market",
    "Limit / Line Size",
    "Underwriting Appetite",
    "Policy Terms / Conditions",
    "Late Quote / Timing",
    "Deductible",
    "Submit",
    "Loss History",
    "CAT Exposure",
    "Regulatory / Licensing",
    "Layering / Structure",
    "Other"
]


def sql_escape(value):
    if value is None:
        return ""
    return str(value).replace("\\", "\\\\").replace("'", "''")


def split_stage_root(stage_root):
    """
    Input example:
        @OPEN_MARKET_QUOTE/Open_Market

    Output:
        stage_name_only = @OPEN_MARKET_QUOTE
        prefix = Open_Market
    """
    s = str(stage_root).strip()

    if not s.startswith("@"):
        s = "@" + s

    s = s.rstrip("/")

    parts = s.split("/", 1)

    stage_name_only = parts[0]

    if len(parts) > 1:
        prefix = parts[1].strip("/")
    else:
        prefix = ""

    return stage_name_only, prefix


def normalize_text(text):
    if text is None:
        return ""

    text = str(text)

    text = text.replace("\u0000", " ")
    text = re.sub(r"\r\n", "\n", text)
    text = re.sub(r"\r", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)

    return text.strip()


def extract_text_from_parse_result(value):
    """
    Handles different possible AI_PARSE_DOCUMENT return structures.
    """
    if value is None:
        return ""

    if isinstance(value, dict):
        for key in ["content", "text", "document_text", "parsed_text"]:
            if key in value and value.get(key):
                return str(value.get(key))

        return json.dumps(value)

    value_str = str(value)

    try:
        parsed = json.loads(value_str)
        if isinstance(parsed, dict):
            for key in ["content", "text", "document_text", "parsed_text"]:
                if key in parsed and parsed.get(key):
                    return str(parsed.get(key))
            return json.dumps(parsed)
    except Exception:
        pass

    return value_str


def parse_one_file(session, stage_name_only, relative_path):
    """
    Uses Snowflake Cortex AI_PARSE_DOCUMENT.
    This should work for PDF/images where AI_PARSE_DOCUMENT is enabled.
    DOC/DOCX are included in file discovery; if unsupported in the account,
    that file is skipped and the error is captured in the combined text.
    """
    stage_lit = sql_escape(stage_name_only)
    path_lit = sql_escape(relative_path)

    parse_sql = f"""
        SELECT AI_PARSE_DOCUMENT(
            TO_FILE('{stage_lit}', '{path_lit}'),
            OBJECT_CONSTRUCT('mode', 'LAYOUT')
        ) AS PARSED_DOC
    """

    try:
        rows = session.sql(parse_sql).collect()
        if not rows:
            return ""

        parsed_value = rows[0]["PARSED_DOC"]
        parsed_text = extract_text_from_parse_result(parsed_value)
        parsed_text = normalize_text(parsed_text)

        return parsed_text

    except Exception as e:
        return f"\n[FILE_PARSE_ERROR for {relative_path}: {str(e)}]\n"


def safe_json_from_llm(raw_text):
    if raw_text is None:
        return {}

    txt = str(raw_text).strip()

    txt = txt.replace("```json", "").replace("```", "").strip()

    first = txt.find("{")
    last = txt.rfind("}")

    if first >= 0 and last > first:
        txt = txt[first:last + 1]

    try:
        return json.loads(txt)
    except Exception:
        return {}


def build_prompt(account_folder, file_count, file_names, combined_text):
    ntu_reasons = "\n".join([f"- {x}" for x in NTU_REASON_LIST])
    ntu_subcats = "\n".join([f"- {x}" for x in NTU_SUBCATEGORY_LIST])

    max_chars = 55000
    text_for_llm = combined_text[:max_chars]

    prompt = f"""
You are analyzing an insurance quote / submission conversation for an NTU case.

Context:
- Every account folder is one insurance conversation.
- Multiple PDFs/images/docs inside the same folder belong to the same account conversation.
- The account is already known to be an NTU case.
- Your job is to infer the likely NTU reason from the conversation, not to search for an explicit sentence saying "NTU reason".
- Use commercial underwriting judgement based on evidence such as quote terms, pricing, line size, broker responses, target pricing, competing market references, layering changes, capacity issues, deductions, limits, deductible, timing, or policy terms.
- Do not say "unclear" unless there is almost no usable discussion.
- Prefer a best-fit reason from the allowed NTU reason list.
- Prefer a best-fit subcategory from the allowed subcategory list.

Account folder:
{account_folder}

File count:
{file_count}

File names:
{file_names}

Allowed NTU reasons:
{ntu_reasons}

Allowed NTU subcategories:
{ntu_subcats}

Fields to derive:

1. account_name:
Use the account folder name.

2. submission_received_date:
Find the earliest date where the broker/client/submission sender first requested or presented the submission, renewal, opportunity, modelling request, or quote request.
Examples:
- "We are pleased to present the underwriting submission..."
- "Please model..."
- "Can you advise your interest..."
- "We would like terms..."
Return the date as written or normalized if clear.
If not clear, return null.

3. quote_sent_date:
Find the first date on which Convex actually sent a quote, terms, line, premium, or binding/quotation indication.
Convex quote signals include:
- "Can quote"
- "We can offer"
- "Can agree to"
- "Line"
- "Premium"
- "net"
- "less"
- "Subject to"
Return the earliest Convex quote date.
If not clear, return null.

4. number_of_requotes:
Count how many separate times Convex sent or revised a quote/terms.
Count only actual quote/terms from Convex, not broker questions.
If Convex first quoted once and later changed/updated terms twice, return 3.
If only one Convex quote exists, return 1.
If no quote is found, return 0.

5. ntu_reason:
Choose exactly one from the allowed NTU reasons list.
Do not invent a new value.

6. ntu_subcategory:
Choose exactly one from the allowed NTU subcategories list.
Do not invent a new value.

7. ntu_reason_confidence:
Return one of:
- High
- Medium
- Low

8. ntu_explanation:
Give a granular explanation.
This should not be generic.
Mention actual figures, dates, quoted layers, premiums, line sizes, deductibles, broker/client target, competing market references, quote revisions, or specific negotiation points wherever present.
Explain why the chosen NTU reason is the best fit.
If the reason is pricing-related, mention the pricing comparison or premium/target evidence.
If the reason is capacity/layering-related, mention the layer, capacity, line size, or structure issue.
If the reason is broker/client preference, explain who appears to prefer what and why.
If the reason is underwriting appetite, mention the risk feature, loss history, CAT exposure, deductible, or terms evidence.

9. ntu_summary:
Summarize the full quote conversation in business terms.
Mention submission flow, quote flow, major discussions, and final likely NTU driver.

Return only valid JSON with exactly these keys:
{{
  "account_name": "...",
  "submission_received_date": "...",
  "quote_sent_date": "...",
  "number_of_requotes": 0,
  "ntu_reason": "...",
  "ntu_subcategory": "...",
  "ntu_reason_confidence": "High|Medium|Low",
  "ntu_explanation": "...",
  "ntu_summary": "..."
}}

Conversation text:
{text_for_llm}
"""
    return prompt


def call_llm(session, prompt):
    prompt_lit = sql_escape(prompt)

    llm_sql = f"""
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            '{MODEL_NAME}',
            '{prompt_lit}'
        ) AS LLM_OUTPUT
    """

    rows = session.sql(llm_sql).collect()

    if not rows:
        return ""

    return rows[0]["LLM_OUTPUT"]


def insert_result(
    session,
    run_id,
    account_name,
    account_folder,
    submission_received_date,
    quote_sent_date,
    number_of_requotes,
    ntu_reason,
    ntu_subcategory,
    ntu_reason_confidence,
    ntu_explanation,
    ntu_summary,
    file_count,
    file_names,
    raw_llm_output,
    status,
    error_message
):
    raw_json = "{}"

    try:
        if isinstance(raw_llm_output, dict):
            raw_json = json.dumps(raw_llm_output)
        else:
            raw_json = json.dumps({"raw": str(raw_llm_output) if raw_llm_output is not None else ""})
    except Exception:
        raw_json = json.dumps({"raw": ""})

    insert_sql = f"""
        INSERT INTO NTU_QUOTE_FOLDER_ANALYSIS_RESULTS_V2 (
            RUN_ID,
            PROCESSED_AT,
            ACCOUNT_NAME,
            ACCOUNT_FOLDER,
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
            NULLIF('{sql_escape(account_name)}', ''),
            NULLIF('{sql_escape(account_folder)}', ''),
            NULLIF('{sql_escape(submission_received_date)}', ''),
            NULLIF('{sql_escape(quote_sent_date)}', ''),
            TRY_TO_NUMBER(NULLIF('{sql_escape(number_of_requotes)}', '')),
            NULLIF('{sql_escape(ntu_reason)}', ''),
            NULLIF('{sql_escape(ntu_subcategory)}', ''),
            NULLIF('{sql_escape(ntu_reason_confidence)}', ''),
            NULLIF('{sql_escape(ntu_explanation)}', ''),
            NULLIF('{sql_escape(ntu_summary)}', ''),
            TRY_TO_NUMBER(NULLIF('{sql_escape(file_count)}', '')),
            NULLIF('{sql_escape(file_names)}', ''),
            PARSE_JSON('{sql_escape(raw_json)}'),
            NULLIF('{sql_escape(status)}', ''),
            NULLIF('{sql_escape(error_message)}', '')
    """

    session.sql(insert_sql).collect()


def run(session, stage_root, max_folders, offset_folders):
    run_id = str(uuid.uuid4())

    if max_folders is None:
        max_folders = 5

    if offset_folders is None:
        offset_folders = 0

    max_folders = int(max_folders)
    offset_folders = int(offset_folders)

    stage_name_only, prefix = split_stage_root(stage_root)

    processed_count = 0
    error_count = 0

    try:
        refresh_sql = f"ALTER STAGE {stage_name_only.replace('@', '')} REFRESH"
        try:
            session.sql(refresh_sql).collect()
        except Exception:
            pass

        folder_sql = f"""
            SELECT
                SPLIT_PART(RELATIVE_PATH, '/', 2) AS ACCOUNT_FOLDER,
                COUNT(*) AS FILE_COUNT,
                LISTAGG(RELATIVE_PATH, '||') WITHIN GROUP (ORDER BY RELATIVE_PATH) AS FILE_PATHS,
                LISTAGG(SPLIT_PART(RELATIVE_PATH, '/', -1), ', ') WITHIN GROUP (ORDER BY RELATIVE_PATH) AS FILE_NAMES
            FROM DIRECTORY({stage_name_only})
            WHERE RELATIVE_PATH ILIKE '{sql_escape(prefix)}/%'
              AND REGEXP_LIKE(RELATIVE_PATH, '.*[.](pdf|png|jpg|jpeg|doc|docx)$', 'i')
              AND ARRAY_SIZE(SPLIT(RELATIVE_PATH, '/')) >= 3
            GROUP BY SPLIT_PART(RELATIVE_PATH, '/', 2)
            ORDER BY ACCOUNT_FOLDER
            LIMIT {max_folders}
            OFFSET {offset_folders}
        """

        folder_rows = session.sql(folder_sql).collect()

        for row in folder_rows:
            account_folder = row["ACCOUNT_FOLDER"]
            file_count = row["FILE_COUNT"]
            file_paths_raw = row["FILE_PATHS"]
            file_names = row["FILE_NAMES"]

            try:
                if file_paths_raw is None or len(str(file_paths_raw).strip()) == 0:
                    insert_result(
                        session=session,
                        run_id=run_id,
                        account_name=account_folder,
                        account_folder=account_folder,
                        submission_received_date=None,
                        quote_sent_date=None,
                        number_of_requotes=None,
                        ntu_reason=None,
                        ntu_subcategory=None,
                        ntu_reason_confidence=None,
                        ntu_explanation=None,
                        ntu_summary=None,
                        file_count=file_count,
                        file_names=file_names,
                        raw_llm_output={},
                        status="ERROR",
                        error_message="No files found for folder"
                    )
                    error_count += 1
                    continue

                file_paths = str(file_paths_raw).split("||")
                combined_text_parts = []

                for file_path in file_paths:
                    file_path = file_path.strip()

                    if not file_path:
                        continue

                    parsed_text = parse_one_file(session, stage_name_only, file_path)

                    if parsed_text is not None and len(str(parsed_text).strip()) > 0:
                        combined_text_parts.append(
                            f"\n\n--- FILE: {file_path} ---\n{str(parsed_text)}"
                        )

                combined_text = normalize_text("\n".join(combined_text_parts))

                if combined_text is None or len(str(combined_text).strip()) == 0:
                    insert_result(
                        session=session,
                        run_id=run_id,
                        account_name=account_folder,
                        account_folder=account_folder,
                        submission_received_date=None,
                        quote_sent_date=None,
                        number_of_requotes=None,
                        ntu_reason=None,
                        ntu_subcategory=None,
                        ntu_reason_confidence=None,
                        ntu_explanation=None,
                        ntu_summary=None,
                        file_count=file_count,
                        file_names=file_names,
                        raw_llm_output={},
                        status="ERROR",
                        error_message="No readable text found after parsing folder files"
                    )
                    error_count += 1
                    continue

                prompt = build_prompt(
                    account_folder=account_folder,
                    file_count=file_count,
                    file_names=file_names,
                    combined_text=combined_text
                )

                raw_llm = call_llm(session, prompt)
                parsed_json = safe_json_from_llm(raw_llm)

                account_name = parsed_json.get("account_name") or account_folder
                submission_received_date = parsed_json.get("submission_received_date")
                quote_sent_date = parsed_json.get("quote_sent_date")
                number_of_requotes = parsed_json.get("number_of_requotes")
                ntu_reason = parsed_json.get("ntu_reason")
                ntu_subcategory = parsed_json.get("ntu_subcategory")
                ntu_reason_confidence = parsed_json.get("ntu_reason_confidence")
                ntu_explanation = parsed_json.get("ntu_explanation")
                ntu_summary = parsed_json.get("ntu_summary")

                insert_result(
                    session=session,
                    run_id=run_id,
                    account_name=account_name,
                    account_folder=account_folder,
                    submission_received_date=submission_received_date,
                    quote_sent_date=quote_sent_date,
                    number_of_requotes=number_of_requotes,
                    ntu_reason=ntu_reason,
                    ntu_subcategory=ntu_subcategory,
                    ntu_reason_confidence=ntu_reason_confidence,
                    ntu_explanation=ntu_explanation,
                    ntu_summary=ntu_summary,
                    file_count=file_count,
                    file_names=file_names,
                    raw_llm_output=parsed_json if parsed_json else {"raw": str(raw_llm)},
                    status="SUCCESS",
                    error_message=None
                )

                processed_count += 1

            except Exception as inner_e:
                insert_result(
                    session=session,
                    run_id=run_id,
                    account_name=account_folder,
                    account_folder=account_folder,
                    submission_received_date=None,
                    quote_sent_date=None,
                    number_of_requotes=None,
                    ntu_reason=None,
                    ntu_subcategory=None,
                    ntu_reason_confidence=None,
                    ntu_explanation=None,
                    ntu_summary=None,
                    file_count=file_count,
                    file_names=file_names,
                    raw_llm_output={},
                    status="ERROR",
                    error_message=str(inner_e)
                )
                error_count += 1

        return f"Run ID: {run_id}; processed={processed_count}; errors={error_count}; selected_folders={len(folder_rows)}; offset={offset_folders}; limit={max_folders}"

    except Exception as e:
        return f"FAILED Run ID: {run_id}; error={str(e)}"
$$;
