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
from datetime import datetime

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

        v = v.replace(",", "")

        return int(float(v))
    except Exception:
        return 0


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

    idx = raw_text.upper().find("NTU_EXPLANATION")

    if idx >= 0:
        return raw_text[idx:].strip()

    return raw_text.strip()


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


def extract_email_dates_and_count(combined_text):
    text = combined_text or ""

    date_candidates = []

    patterns = [
        r"Sent:\\s*[A-Za-z]+,\\s*([A-Za-z]+\\s+\\d{1,2},\\s+\\d{4}\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM)?)",
        r"Sent:\\s*([A-Za-z]+\\s+\\d{1,2},\\s+\\d{4}\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM)?)",
        r"On\\s+[A-Za-z]+,\\s*(\\d{1,2}\\s+[A-Za-z]+\\s+\\d{4})\\s+at\\s+(\\d{1,2}:\\d{2})",
        r"On\\s+[A-Za-z]+,\\s*([A-Za-z]+\\s+\\d{1,2},\\s+\\d{4})\\s+at\\s+(\\d{1,2}:\\d{2}\\s*(?:AM|PM)?)",
        r"([A-Za-z]+,\\s+[A-Za-z]+\\s+\\d{1,2},\\s+\\d{4}\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM)?)",
        r"(\\d{1,2}/\\d{1,2}/\\d{4},\\s*\\d{1,2}:\\d{2})",
        r"(\\d{1,2}/\\d{1,2}/\\d{4}\\s+\\d{1,2}:\\d{2})",
        r"(\\d{4}-\\d{2}-\\d{2}\\s+\\d{1,2}:\\d{2})",
        r"(\\d{4}-\\d{2}-\\d{2})"
    ]

    formats = [
        "%B %d, %Y %I:%M %p",
        "%B %d, %Y %H:%M",
        "%A, %B %d, %Y %I:%M %p",
        "%A, %B %d, %Y %H:%M",
        "%d %b %Y %H:%M",
        "%d %B %Y %H:%M",
        "%d/%m/%Y, %H:%M",
        "%d/%m/%Y %H:%M",
        "%m/%d/%Y, %H:%M",
        "%m/%d/%Y %H:%M",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d"
    ]

    for pattern in patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            if len(match.groups()) == 2:
                raw = match.group(1) + " " + match.group(2)
            else:
                raw = match.group(1)

            raw = re.sub(r"\\s+", " ", raw).strip()

            for fmt in formats:
                try:
                    dt = datetime.strptime(raw, fmt)
                    date_candidates.append(dt)
                    break
                except Exception:
                    continue

    count_patterns = [
        r"\\bFrom:\\s+",
        r"\\bSent:\\s+",
        r"\\bSubject:\\s+",
        r"\\bOn\\s+[A-Za-z]+,\\s+.*?\\s+wrote:",
        r"\\bwrote:"
    ]

    counts = []

    for cp in count_patterns:
        counts.append(len(re.findall(cp, text, re.IGNORECASE | re.DOTALL)))

    email_count = max(counts) if counts else 0

    if email_count == 0 and len(text.strip()) > 200:
        email_count = 1

    if date_candidates:
        first_dt = min(date_candidates).strftime("%Y-%m-%d %H:%M")
        last_dt = max(date_candidates).strftime("%Y-%m-%d %H:%M")
    else:
        first_dt = None
        last_dt = None

    return first_dt, last_dt, email_count


def build_prompt(account_folder_name, combined_text):
    return f"""
You are an expert insurance underwriting placement analyst working on Convex NTU reason classification.

VERY IMPORTANT BUSINESS CONTEXT:
Every account folder given to you is already confirmed as an NTU / not-taken-up / not-bound / not-written case.

Your job is NOT to decide whether this is an NTU case.
Your job is to infer the most likely NTU reason or reasons from the conversation.

You must not say:
- no NTU evidence
- not an NTU case
- successful placement
- no reason can be determined
- no indication of NTU

Even if the email chain does not explicitly say "NTU", infer the likely business reason from available signals:
- pricing comments
- broker deadlines
- competing market references
- capacity requests
- line size requests
- order size requests
- structure discussions
- primary / excess / quota share discussion
- deductible or sublimit terms
- incumbent or lead market references
- broker asking for interest but no final bind confirmation
- Convex saying pricing is expensive or unlikely to bind
- Convex only offering limited participation
- broker moving forward with another market
- long back-and-forth negotiation
- late response or missed timing

You must mark at least one of the 13 subcategory flags as 1.
Multiple flags can be 1 if the case supports more than one reason.

Do not be overly conservative.
Use best-fit commercial underwriting judgement.

NTU subcategory definitions:

1. COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE:
Mark 1 when the conversation suggests Convex lost because another insurer/market offered cheaper pricing, lower rate, better premium, or the broker had more competitive alternatives. Also mark 1 if Convex pricing is described as too expensive compared to market pricing.

2. PRICING_INELASTICITY:
Mark 1 when Convex had a technical price/rate requirement and could not or would not reduce pricing enough to meet broker/client target. Also mark 1 when Convex says pricing would be too expensive, not likely to bind, or far from market.

3. LAYER_STRUCTURE_MISMATCH:
Mark 1 when the broker wanted quota share, primary, excess, full limit, attachment point, or specific layer structure and Convex preferred or proposed a different structure.

4. RESTRICTIVE_SUB_LIMITS:
Mark 1 when terms include restrictive sublimits or coverage limitations on flood, wind, named windstorm, EQ, BI, CAT, contingent BI, or other key covers.

5. DEDUCTIBLE_MISMATCH:
Mark 1 when deductibles/SIR/retentions are too high, different from target, or less attractive than other markets.

6. ORDER_SIZE_PARTICIPATION_DEFICIT:
Mark 1 when broker/client requested a specific line size, participation percentage, capacity, quota share, or full order but Convex could only provide less, wanted a smaller line, or could not support the requested stretch.

7. BROKER_SWITCH_DISPLACEMENT:
Mark 1 when broker change, placement route change, communication gap, or another broker/channel caused Convex to be displaced or not properly engaged.

8. PREFERRED_MARKET_PARTNERSHIPS:
Mark 1 when broker/client appears to favour incumbent markets, existing carriers, panel markets, lead markets, Beazley/FM/other named markets, or strategic relationships.

9. FACILITY_LINE_SLIP_DISPLACEMENT:
Mark 1 when the account appears to be placed into a facility, line slip, delegated arrangement, binder, pre-agreed placement, or operational placement route bypassing individual Convex quote.

10. NEGOTIATION_FATIGUE:
Mark 1 when there are repeated follow-ups, multiple back-and-forth messages, repeated pricing/structure discussions, or the conversation loses momentum.

11. LATE_QUOTE:
Mark 1 when Convex response appears late versus broker deadline, after broker asks for urgent interest, after a COP/deadline, or when another market/order may already have progressed.

12. CAPTIVE_EXPANSION_SECURITIZATION:
Mark 1 when client retained more risk, used captive, self-insurance, risk financing, securitization, or capital-market alternative.

13. COMPOSITE_MULTI_CLASS_BUNDLING:
Mark 1 when property risk appears bundled into a multi-class placement where Convex could not participate due to product/class mismatch.

Output format rules:
Return output in EXACTLY this format.
Do not return JSON.
Do not return markdown.
Do not add extra keys.
Each flag must be 0 or 1.
At least one flag must be 1.

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
NTU_EXPLANATION_START
Write a detailed granular explanation of the inferred NTU reason.
Explain why each selected flag was marked as 1.
Mention concrete evidence from the email chain.
Do not say this is not an NTU case.
NTU_EXPLANATION_END

Account folder name:
{account_folder_name}

Combined conversation text:
{combined_text[:100000]}
"""


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

    first_date, last_date, email_count = extract_email_dates_and_count(combined_text)

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
        "date_of_first_conversation_started": first_date,
        "date_of_last_conversation": last_date,
        "no_of_emails_transferred_in_between": email_count,
        "ntu_explanation": extract_explanation(raw)
    }

    flag_keys = [
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
        "composite_multi_class_bundling"
    ]

    if sum([safe_int(result.get(k)) for k in flag_keys]) == 0:
        combined_lower = (combined_text or "").lower()

        if any(x in combined_lower for x in [
            "too expensive",
            "pricing",
            "premium",
            "rate",
            "market pricing",
            "not going to get near",
            "not get near",
            "price",
            "quote"
        ]):
            result["pricing_inelasticity"] = 1

        elif any(x in combined_lower for x in [
            "quota share",
            "primary",
            "excess",
            "layer",
            "attachment",
            " xs ",
            "structure"
        ]):
            result["layer_structure_mismatch"] = 1

        elif any(x in combined_lower for x in [
            "capacity",
            "line",
            "share",
            "participation",
            "order",
            "limit"
        ]):
            result["order_size_participation_deficit"] = 1

        elif email_count >= 5:
            result["negotiation_fatigue"] = 1

        else:
            result["pricing_inelasticity"] = 1

        result["ntu_explanation"] = (
            "This account is part of the confirmed NTU population. "
            "The model output did not strongly select a category, so a best-fit fallback was applied based on the available conversation signals. "
            + (result.get("ntu_explanation") or "")
        )

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
