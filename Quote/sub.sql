CREATE OR REPLACE PROCEDURE RUN_OPEN_MARKET_NTU_CLASSIFICATION(LIMIT_N_FOLDERS NUMBER)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
import re

STAGE_NAME = '@OPEN_MARKET_QUOTE'
ROOT_PATH = 'Open_Market/'
MODEL_NAME = 'claude-sonnet-4-5'

SUPPORTED_EXTENSIONS = (
    '.pdf', '.docx', '.pptx',
    '.png', '.jpg', '.jpeg', '.tif', '.tiff',
    '.txt', '.html'
)

OUTPUT_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_OUTPUT'
ERROR_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_ERROR_LOG'


def sql_escape(value):
    if value is None:
        return ''
    return str(value).replace("'", "''")


def is_supported_file(path):
    p = path.lower()
    return any(p.endswith(ext) for ext in SUPPORTED_EXTENSIONS)


def get_account_folder(relative_path):
    if not relative_path.startswith(ROOT_PATH):
        return None

    remaining = relative_path[len(ROOT_PATH):]
    parts = remaining.split('/')

    if len(parts) < 2:
        return None

    return parts[0]


def safe_int(value):
    try:
        if value is None:
            return 0
        v = str(value).strip()
        if v == '':
            return 0
        return int(float(v))
    except Exception:
        return 0


def parse_file_text(session, relative_path):
    try:
        q = f"""
            SELECT AI_PARSE_DOCUMENT(
                TO_FILE('{STAGE_NAME}', '{sql_escape(relative_path)}'),
                OBJECT_CONSTRUCT('mode', 'LAYOUT'),
                TRUE
            ) AS PARSED_DOC
        """

        row = session.sql(q).collect()[0]
        parsed = row['PARSED_DOC']

        if parsed is None:
            return ''

        try:
            parsed_obj = json.loads(str(parsed))
        except Exception:
            parsed_obj = parsed

        if isinstance(parsed_obj, dict) and parsed_obj.get('error'):
            return f"\\n[PARSE_ERROR for {relative_path}: {parsed_obj.get('error')}]\\n"

        if isinstance(parsed_obj, dict):
            value = parsed_obj.get('value')
        else:
            value = parsed_obj

        try:
            value_obj = json.loads(str(value))
        except Exception:
            value_obj = value

        if isinstance(value_obj, dict):
            if 'content' in value_obj:
                return value_obj.get('content') or ''

            if 'pages' in value_obj:
                return '\\n\\n'.join([
                    p.get('content', '')
                    for p in value_obj.get('pages', [])
                    if isinstance(p, dict)
                ])

        return str(value)

    except Exception as e:
        return f"\\n[PARSE_EXCEPTION for {relative_path}: {str(e)}]\\n"


def build_prompt(account_folder_name, combined_text):
    return f"""
You are an expert insurance underwriting placement analyst working on Convex NTU / decline reason discovery.

You will receive a combined email conversation for one account folder.
The folder may contain one or many files. Treat all files as one single conversation.

Your task:
1. Read the full conversation end-to-end.
2. Understand why Convex did not bind / did not write / was not selected / lost the opportunity / became NTU.
3. First produce a granular NTU explanation.
4. Then mark each NTU subcategory as 1 or 0 based only on the explanation and evidence in the conversation.
5. Multiple subcategories can be 1 at the same time.
6. Do not force a reason. If evidence is weak or absent, mark 0.
7. Extract earliest email date, latest email date, and approximate number of emails/messages in the chain.

NTU subcategory definitions:

1. COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE:
Mark 1 when the opportunity was lost because another insurer/market offered materially cheaper pricing, lower premium, better rate, or Convex was clearly beaten on price for a similar risk/layer.

2. PRICING_INELASTICITY:
Mark 1 when Convex had a technical price/rate requirement and could not or would not reduce pricing to meet broker/client target, even if competitor pricing is not explicitly named.

3. LAYER_STRUCTURE_MISMATCH:
Mark 1 when the broker wanted a structure such as quota share, primary, excess, attachment point, layer size, or vertical placement that Convex could not support or suggested changing.

4. RESTRICTIVE_SUB_LIMITS:
Mark 1 when Convex terms included restrictive sublimits or coverage restrictions on flood, wind, named windstorm, EQ, BI, CAT, contingent BI, or other key covers.

5. DEDUCTIBLE_MISMATCH:
Mark 1 when deductibles/SIR/retentions proposed by Convex were higher or different from what client/broker could accept, or when another market had better deductible terms.

6. ORDER_SIZE_PARTICIPATION_DEFICIT:
Mark 1 when the broker/client required a specific line size, participation percentage, capacity, quota share, or full order, but Convex could only offer less or could not support the requested stretch.

7. BROKER_SWITCH_DISPLACEMENT:
Mark 1 when a broker change, placement route change, new intermediary, or communication breakdown caused Convex to be displaced or not actively considered.

8. PREFERRED_MARKET_PARTNERSHIPS:
Mark 1 when broker/client preferred incumbent markets, panel markets, strategic carriers, lead markets, Beazley/FM/other named markets, or existing relationships over Convex.

9. FACILITY_LINE_SLIP_DISPLACEMENT:
Mark 1 when the account was placed into a facility, line slip, delegated arrangement, binder, pre-agreed placement, or operational placement channel bypassing individual Convex quote.

10. NEGOTIATION_FATIGUE:
Mark 1 when there are several back-and-forth emails, repeated pricing/structure revisions, long unresolved negotiation, or loss of momentum due to extended discussion.

11. LATE_QUOTE:
Mark 1 when Convex responded after broker deadline, after order was already completed, after another market was selected, or outside the practical bind window.

12. CAPTIVE_EXPANSION_SECURITIZATION:
Mark 1 when client retained more risk, used/expanded captive, self-insurance, risk financing, securitization, or capital market alternative.

13. COMPOSITE_MULTI_CLASS_BUNDLING:
Mark 1 when property risk was bundled with other lines/classes and Convex could not participate because the placement required a combined package.

Return output in EXACTLY this format.
Do not return JSON.
Do not return markdown.
Do not add extra keys.
Each flag must be 0 or 1.

COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE: 0
PRICING_INELASTICITY: 0
LAYER_STRUCTURE_MISMATCH: 0
RESTRICTIVE_SUB_LIMITS: 0
DEDUCTIBLE_MISMATCH: 0
ORDER_SIZE_PARTICIPATION_DEFICIT: 0
BROKER_SWITCH_DISPLACEMENT: 0
PREFERRED_MARKET_PARTNERSHIPS: 0
FACILITY_LINE_SLIP_DISPLACEMENT: 0
NEGOTIATION_FATIGUE: 0
LATE_QUOTE: 0
CAPTIVE_EXPANSION_SECURITIZATION: 0
COMPOSITE_MULTI_CLASS_BUNDLING: 0
DATE_OF_FIRST_CONVERSATION_STARTED: YYYY-MM-DD HH24:MI or null
DATE_OF_LAST_CONVERSATION: YYYY-MM-DD HH24:MI or null
NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN: 0
NTU_EXPLANATION_START
Write detailed granular explanation here.
NTU_EXPLANATION_END

Account folder name:
{account_folder_name}

Combined conversation text:
{combined_text[:100000]}
"""


def extract_value(raw_text, key):
    pattern = rf"{key}\\s*:\\s*(.*)"
    match = re.search(pattern, raw_text, re.IGNORECASE)
    if not match:
        return None
    return match.group(1).strip()


def extract_explanation(raw_text):
    pattern = r"NTU_EXPLANATION_START(.*?)NTU_EXPLANATION_END"
    match = re.search(pattern, raw_text, re.IGNORECASE | re.DOTALL)
    if match:
        return match.group(1).strip()

    # fallback if model misses markers
    idx = raw_text.upper().find("NTU_EXPLANATION")
    if idx >= 0:
        return raw_text[idx:].strip()

    return raw_text.strip()


def classify_with_llm(session, account_folder_name, combined_text):
    prompt = build_prompt(account_folder_name, combined_text)

    q = f"""
        SELECT AI_COMPLETE(
            '{MODEL_NAME}',
            '{sql_escape(prompt)}'
        ) AS LLM_RESPONSE
    """

    row = session.sql(q).collect()[0]
    response = row['LLM_RESPONSE']

    if response is None:
        raise Exception("AI_COMPLETE returned NULL")

    raw = str(response).strip()

    result = {
        "competitor_undercut_significantly_on_price": safe_int(extract_value(raw, "COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE")),
        "pricing_inelasticity": safe_int(extract_value(raw, "PRICING_INELASTICITY")),
        "layer_structure_mismatch": safe_int(extract_value(raw, "LAYER_STRUCTURE_MISMATCH")),
        "restrictive_sub_limits": safe_int(extract_value(raw, "RESTRICTIVE_SUB_LIMITS")),
        "deductible_mismatch": safe_int(extract_value(raw, "DEDUCTIBLE_MISMATCH")),
        "order_size_participation_deficit": safe_int(extract_value(raw, "ORDER_SIZE_PARTICIPATION_DEFICIT")),
        "broker_switch_displacement": safe_int(extract_value(raw, "BROKER_SWITCH_DISPLACEMENT")),
        "preferred_market_partnerships": safe_int(extract_value(raw, "PREFERRED_MARKET_PARTNERSHIPS")),
        "facility_line_slip_displacement": safe_int(extract_value(raw, "FACILITY_LINE_SLIP_DISPLACEMENT")),
        "negotiation_fatigue": safe_int(extract_value(raw, "NEGOTIATION_FATIGUE")),
        "late_quote": safe_int(extract_value(raw, "LATE_QUOTE")),
        "captive_expansion_securitization": safe_int(extract_value(raw, "CAPTIVE_EXPANSION_SECURITIZATION")),
        "composite_multi_class_bundling": safe_int(extract_value(raw, "COMPOSITE_MULTI_CLASS_BUNDLING")),
        "date_of_first_conversation_started": extract_value(raw, "DATE_OF_FIRST_CONVERSATION_STARTED"),
        "date_of_last_conversation": extract_value(raw, "DATE_OF_LAST_CONVERSATION"),
        "no_of_emails_transferred_in_between": safe_int(extract_value(raw, "NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN")),
        "ntu_explanation": extract_explanation(raw)
    }

    if result["date_of_first_conversation_started"] in ("null", "NULL", "", None):
        result["date_of_first_conversation_started"] = None

    if result["date_of_last_conversation"] in ("null", "NULL", "", None):
        result["date_of_last_conversation"] = None

    return result, raw


def insert_result(session, account_folder_name, result, files_processed, raw_response):
    raw_json = sql_escape(json.dumps(result))

    first_date = result.get('date_of_first_conversation_started')
    last_date = result.get('date_of_last_conversation')

    first_date_sql = 'NULL' if first_date is None else "'" + sql_escape(first_date) + "'"
    last_date_sql = 'NULL' if last_date is None else "'" + sql_escape(last_date) + "'"

    q = f"""
        INSERT INTO {OUTPUT_TABLE} (
            ACCOUNT_FOLDER_NAME,

            COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE,
            PRICING_INELASTICITY,
            LAYER_STRUCTURE_MISMATCH,
            RESTRICTIVE_SUB_LIMITS,
            DEDUCTIBLE_MISMATCH,
            ORDER_SIZE_PARTICIPATION_DEFICIT,
            BROKER_SWITCH_DISPLACEMENT,
            PREFERRED_MARKET_PARTNERSHIPS,
            FACILITY_LINE_SLIP_DISPLACEMENT,
            NEGOTIATION_FATIGUE,
            LATE_QUOTE,
            CAPTIVE_EXPANSION_SECURITIZATION,
            COMPOSITE_MULTI_CLASS_BUNDLING,

            NTU_EXPLANATION,
            DATE_OF_FIRST_CONVERSATION_STARTED,
            DATE_OF_LAST_CONVERSATION,
            NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN,

            FILES_PROCESSED,
            RAW_LLM_RESPONSE
        )
        SELECT
            '{sql_escape(account_folder_name)}',

            {safe_int(result.get('competitor_undercut_significantly_on_price'))},
            {safe_int(result.get('pricing_inelasticity'))},
            {safe_int(result.get('layer_structure_mismatch'))},
            {safe_int(result.get('restrictive_sub_limits'))},
            {safe_int(result.get('deductible_mismatch'))},
            {safe_int(result.get('order_size_participation_deficit'))},
            {safe_int(result.get('broker_switch_displacement'))},
            {safe_int(result.get('preferred_market_partnerships'))},
            {safe_int(result.get('facility_line_slip_displacement'))},
            {safe_int(result.get('negotiation_fatigue'))},
            {safe_int(result.get('late_quote'))},
            {safe_int(result.get('captive_expansion_securitization'))},
            {safe_int(result.get('composite_multi_class_bundling'))},

            '{sql_escape(result.get('ntu_explanation'))}',
            {first_date_sql},
            {last_date_sql},
            {safe_int(result.get('no_of_emails_transferred_in_between'))},

            {files_processed},
            PARSE_JSON('{raw_json}')
    """

    session.sql(q).collect()


def insert_error(session, account_folder_name, error_message, raw_response, files_processed):
    q = f"""
        INSERT INTO {ERROR_TABLE} (
            ACCOUNT_FOLDER_NAME,
            ERROR_MESSAGE,
            RAW_LLM_RESPONSE,
            FILES_PROCESSED
        )
        SELECT
            '{sql_escape(account_folder_name)}',
            '{sql_escape(error_message)}',
            '{sql_escape(str(raw_response)[:10000])}',
            {files_processed}
    """
    session.sql(q).collect()


def main(session, LIMIT_N_FOLDERS):
    session.sql(f"TRUNCATE TABLE {OUTPUT_TABLE}").collect()
    session.sql(f"TRUNCATE TABLE {ERROR_TABLE}").collect()

    rows = session.sql(f"LIST {STAGE_NAME}/{ROOT_PATH}").collect()

    account_to_files = {}

    for r in rows:
        full_path = r['name']

        idx = full_path.find(ROOT_PATH)
        if idx < 0:
            continue

        relative_path = full_path[idx:]

        if not is_supported_file(relative_path):
            continue

        account_folder = get_account_folder(relative_path)

        if account_folder is None:
            continue

        account_to_files.setdefault(account_folder, []).append(relative_path)

    account_folders = sorted(account_to_files.keys())[:int(LIMIT_N_FOLDERS)]

    processed = 0
    failed = 0
    messages = []

    for account_folder in account_folders:
        raw_response = ''
        files = account_to_files.get(account_folder, [])

        try:
            all_text_parts = []

            for file_path in files:
                parsed_text = parse_file_text(session, file_path)

                if parsed_text and parsed_text.strip():
                    all_text_parts.append(
                        f"\\n\\n===== FILE: {file_path} =====\\n{parsed_text}"
                    )

            combined_text = "\\n".join(all_text_parts)

            if not combined_text.strip():
                failed += 1
                insert_error(session, account_folder, "no parsed text", '', len(files))
                messages.append(f"{account_folder}: FAILED - no parsed text")
                continue

            result, raw_response = classify_with_llm(session, account_folder, combined_text)

            insert_result(session, account_folder, result, len(files), raw_response)

            processed += 1
            messages.append(f"{account_folder}: processed {len(files)} files")

        except Exception as e:
            failed += 1
            insert_error(session, account_folder, str(e), raw_response, len(files))
            messages.append(f"{account_folder}: FAILED - {str(e)[:200]}")

    return f"Processed={processed}, Failed={failed}. Details: " + " | ".join(messages)
$$;
