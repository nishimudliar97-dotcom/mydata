CREATE OR REPLACE TABLE OPEN_MARKET_NTU_CLASSIFICATION_OUTPUT (
    ACCOUNT_FOLDER_NAME STRING,

    COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE NUMBER(1,0),
    PRICING_INELASTICITY NUMBER(1,0),
    LAYER_STRUCTURE_MISMATCH NUMBER(1,0),
    RESTRICTIVE_SUB_LIMITS NUMBER(1,0),
    DEDUCTIBLE_MISMATCH NUMBER(1,0),
    ORDER_SIZE_PARTICIPATION_DEFICIT NUMBER(1,0),
    BROKER_SWITCH_DISPLACEMENT NUMBER(1,0),
    PREFERRED_MARKET_PARTNERSHIPS NUMBER(1,0),
    FACILITY_LINE_SLIP_DISPLACEMENT NUMBER(1,0),
    NEGOTIATION_FATIGUE NUMBER(1,0),
    LATE_QUOTE NUMBER(1,0),
    CAPTIVE_EXPANSION_SECURITIZATION NUMBER(1,0),
    COMPOSITE_MULTI_CLASS_BUNDLING NUMBER(1,0),

    NTU_EXPLANATION STRING,
    DATE_OF_FIRST_CONVERSATION_STARTED STRING,
    DATE_OF_LAST_CONVERSATION STRING,
    NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN NUMBER,

    FILES_PROCESSED NUMBER,
    RAW_LLM_RESPONSE VARIANT,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


CREATE OR REPLACE TABLE OPEN_MARKET_NTU_CLASSIFICATION_ERROR_LOG (
    ACCOUNT_FOLDER_NAME STRING,
    ERROR_MESSAGE STRING,
    RAW_LLM_RESPONSE STRING,
    FILES_PROCESSED NUMBER,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


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
import ast

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
        return int(value)
    except Exception:
        return 0


def try_parse_json_or_python(value):
    if value is None:
        return None

    if isinstance(value, dict):
        return value

    if isinstance(value, list):
        return value

    txt = str(value).strip()

    try:
        return json.loads(txt)
    except Exception:
        pass

    try:
        return ast.literal_eval(txt)
    except Exception:
        pass

    return None


def extract_json_object_from_text(text):
    if text is None:
        raise Exception("Empty LLM response")

    txt = str(text).strip()

    txt = txt.replace("```json", "")
    txt = txt.replace("```", "")
    txt = txt.strip()

    parsed = try_parse_json_or_python(txt)

    if isinstance(parsed, dict):
        if "choices" in parsed:
            choices = parsed.get("choices") or []
            if len(choices) > 0:
                ch = choices[0]
                if isinstance(ch, dict):
                    msg = ch.get("messages") or ch.get("message") or ch.get("content")
                    if msg:
                        return extract_json_object_from_text(msg)

        return parsed

    if isinstance(parsed, list):
        if len(parsed) > 0:
            first = parsed[0]

            if isinstance(first, dict):
                if "messages" in first:
                    return extract_json_object_from_text(first["messages"])
                if "content" in first:
                    return extract_json_object_from_text(first["content"])
                return first

            if isinstance(first, str):
                return extract_json_object_from_text(first)

    first_brace = txt.find("{")
    last_brace = txt.rfind("}")

    if first_brace >= 0 and last_brace > first_brace:
        candidate = txt[first_brace:last_brace + 1]

        parsed_candidate = try_parse_json_or_python(candidate)

        if isinstance(parsed_candidate, dict):
            return parsed_candidate

        if isinstance(parsed_candidate, list) and len(parsed_candidate) > 0:
            if isinstance(parsed_candidate[0], dict):
                return parsed_candidate[0]

    raise Exception("Could not extract JSON object. First 1000 chars: " + txt[:1000])


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

        parsed_obj = try_parse_json_or_python(parsed)

        if isinstance(parsed_obj, dict) and parsed_obj.get('error'):
            return f"\\n[PARSE_ERROR for {relative_path}: {parsed_obj.get('error')}]\\n"

        value = parsed_obj.get('value') if isinstance(parsed_obj, dict) else parsed

        value_obj = try_parse_json_or_python(value)

        if isinstance(value_obj, dict):
            if 'content' in value_obj:
                return value_obj.get('content') or ''

            if 'pages' in value_obj:
                return '\\n\\n'.join([
                    p.get('content', '')
                    for p in value_obj.get('pages', [])
                    if isinstance(p, dict)
                ])

        if isinstance(value, str):
            return value

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

1. competitor_undercut_significantly_on_price:
Mark 1 when the opportunity was lost because another insurer/market offered materially cheaper pricing, lower premium, better rate, or Convex was clearly beaten on price for a similar risk/layer.

2. pricing_inelasticity:
Mark 1 when Convex had a technical price/rate requirement and could not or would not reduce pricing to meet broker/client target, even if competitor pricing is not explicitly named.

3. layer_structure_mismatch:
Mark 1 when the broker wanted a structure such as quota share, primary, excess, attachment point, layer size, or vertical placement that Convex could not support or suggested changing.

4. restrictive_sub_limits:
Mark 1 when Convex terms included restrictive sublimits or coverage restrictions on flood, wind, named windstorm, EQ, BI, CAT, contingent BI, or other key covers.

5. deductible_mismatch:
Mark 1 when deductibles/SIR/retentions proposed by Convex were higher or different from what client/broker could accept, or when another market had better deductible terms.

6. order_size_participation_deficit:
Mark 1 when the broker/client required a specific line size, participation percentage, capacity, quota share, or full order, but Convex could only offer less or could not support the requested stretch.

7. broker_switch_displacement:
Mark 1 when a broker change, placement route change, new intermediary, or communication breakdown caused Convex to be displaced or not actively considered.

8. preferred_market_partnerships:
Mark 1 when broker/client preferred incumbent markets, panel markets, strategic carriers, lead markets, Beazley/FM/other named markets, or existing relationships over Convex.

9. facility_line_slip_displacement:
Mark 1 when the account was placed into a facility, line slip, delegated arrangement, binder, pre-agreed placement, or operational placement channel bypassing individual Convex quote.

10. negotiation_fatigue:
Mark 1 when there are several back-and-forth emails, repeated pricing/structure revisions, long unresolved negotiation, or loss of momentum due to extended discussion.

11. late_quote:
Mark 1 when Convex responded after broker deadline, after order was already completed, after another market was selected, or outside the practical bind window.

12. captive_expansion_securitization:
Mark 1 when client retained more risk, used/expanded captive, self-insurance, risk financing, securitization, or capital market alternative.

13. composite_multi_class_bundling:
Mark 1 when property risk was bundled with other lines/classes and Convex could not participate because the placement required a combined package.

Date extraction:
- date_of_first_conversation_started = earliest email date found in the chain.
- date_of_last_conversation = latest email date found in the chain.
- no_of_emails_transferred_in_between = count of distinct emails/messages in the chain. Count visible From/Sent/On date wrote blocks as messages.

Return ONLY a single JSON object.
Do not return markdown.
Do not return explanation outside JSON.
Do not wrap the JSON in a list.
Do not use single quotes.
All property names must be enclosed in double quotes.

Return exactly this structure:

{{
  "competitor_undercut_significantly_on_price": 0,
  "pricing_inelasticity": 0,
  "layer_structure_mismatch": 0,
  "restrictive_sub_limits": 0,
  "deductible_mismatch": 0,
  "order_size_participation_deficit": 0,
  "broker_switch_displacement": 0,
  "preferred_market_partnerships": 0,
  "facility_line_slip_displacement": 0,
  "negotiation_fatigue": 0,
  "late_quote": 0,
  "captive_expansion_securitization": 0,
  "composite_multi_class_bundling": 0,
  "ntu_explanation": "detailed explanation here",
  "date_of_first_conversation_started": null,
  "date_of_last_conversation": null,
  "no_of_emails_transferred_in_between": 0
}}

Account folder name:
{account_folder_name}

Combined conversation text:
{combined_text[:100000]}
"""


def classify_with_llm(session, account_folder_name, combined_text):
    prompt = build_prompt(account_folder_name, combined_text)

    # Important: no options object here.
    # This avoids Snowflake wrapper responses like choices/messages.
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

    result = extract_json_object_from_text(response)

    if not isinstance(result, dict):
        raise Exception("LLM JSON was not an object. Raw response: " + str(response)[:1000])

    required_keys = [
        "competitor_undercut_significantly_on_price",
        "pricing_inelasticity",
        "layer_structure_mismatch",
        "restrictive_sub_limits",
        "deductible_mismatch",
        "order_size_participation_deficit",
        "broker_switch_displacement",
        "preferred_market_partnerships",
        "facility_line_slip_displacement",
        "negotiation_fatigue",
        "late_quote",
        "captive_expansion_securitization",
        "composite_multi_class_bundling",
        "ntu_explanation",
        "date_of_first_conversation_started",
        "date_of_last_conversation",
        "no_of_emails_transferred_in_between"
    ]

    for k in required_keys:
        if k not in result:
            result[k] = None if k.startswith("date_") else 0

    return result, str(response)


def insert_result(session, account_folder_name, result, files_processed):
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

    files_df = session.sql(f"LIST {STAGE_NAME}/{ROOT_PATH}")
    rows = files_df.collect()

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
                msg = "no parsed text"
                insert_error(session, account_folder, msg, '', len(files))
                messages.append(f"{account_folder}: FAILED - {msg}")
                continue

            result, raw_response = classify_with_llm(session, account_folder, combined_text)

            insert_result(session, account_folder, result, len(files))

            processed += 1
            messages.append(f"{account_folder}: processed {len(files)} files")

        except Exception as e:
            failed += 1
            insert_error(session, account_folder, str(e), raw_response, len(files))
            messages.append(f"{account_folder}: FAILED - {str(e)[:200]}")

    return f"Processed={processed}, Failed={failed}. Details: " + " | ".join(messages)
$$;
