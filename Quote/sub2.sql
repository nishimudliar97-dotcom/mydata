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
        v = str(value).strip().replace(",", "")
        if v == '':
            return 0
        return int(float(v))
    except Exception:
        return 0


def extract_value(raw_text, key):
    pattern = rf"^\s*{key}\s*:\s*(.*)$"
    match = re.search(pattern, raw_text, re.IGNORECASE | re.MULTILINE)
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
            return f"\n[PARSE_ERROR for {relative_path}: {parsed_obj.get('error')}]\n"

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
                return '\n\n'.join([
                    p.get('content', '')
                    for p in value_obj.get('pages', [])
                    if isinstance(p, dict)
                ])

        return str(value)

    except Exception as e:
        return f"\n[PARSE_EXCEPTION for {relative_path}: {str(e)}]\n"


def normalize_text_for_dates(text):
    text = text or ""
    text = text.replace("\r", "\n")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n+", "\n", text)
    return text


def parse_date_candidate(raw):
    raw = re.sub(r"\s+", " ", raw or "").strip()
    raw = raw.replace(" at ", " ")
    raw = raw.replace(",", ", ")

    raw = re.sub(r"\s+", " ", raw).strip()

    formats = [
        "%A, %B %d, %Y %I:%M %p",
        "%A, %B %d, %Y %H:%M",
        "%B %d, %Y %I:%M %p",
        "%B %d, %Y %H:%M",
        "%a, %d %b %Y %H:%M",
        "%a, %d %b %Y %I:%M %p",
        "%d %b %Y %H:%M",
        "%d %b %Y %I:%M %p",
        "%d %B %Y %H:%M",
        "%d %B %Y %I:%M %p",
        "%d/%m/%Y, %H:%M",
        "%d/%m/%Y %H:%M",
        "%m/%d/%Y, %H:%M",
        "%m/%d/%Y %H:%M",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d"
    ]

    for fmt in formats:
        try:
            return datetime.strptime(raw, fmt)
        except Exception:
            continue

    return None


def extract_email_dates_and_count(combined_text):
    text = normalize_text_for_dates(combined_text)

    date_candidates = []

    date_patterns = [
        r"Sent:\s*([A-Za-z]+,\s+[A-Za-z]+\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s*(?:AM|PM)?)",
        r"Sent:\s*([A-Za-z]+\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s*(?:AM|PM)?)",
        r"On\s+([A-Za-z]+,\s+\d{1,2}\s+[A-Za-z]+\s+\d{4}\s+at\s+\d{1,2}:\d{2})",
        r"On\s+([A-Za-z]+,\s+[A-Za-z]+\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM)?)",
        r"(\d{1,2}/\d{1,2}/\d{4},\s*\d{1,2}:\d{2})",
        r"(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2})",
        r"(\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2})",
        r"(\d{4}-\d{2}-\d{2})"
    ]

    for pattern in date_patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            raw = match.group(1)
            dt = parse_date_candidate(raw)
            if dt:
                date_candidates.append(dt)

    # Email chains normally have repeated From/Sent/Subject blocks.
    from_count = len(re.findall(r"(?im)^\s*From:\s+", text))
    sent_count = len(re.findall(r"(?im)^\s*Sent:\s+", text))
    subject_count = len(re.findall(r"(?im)^\s*Subject:\s+", text))
    wrote_count = len(re.findall(r"(?i)\bOn\s+.{0,120}?\bwrote:", text))
    forwarded_count = len(re.findall(r"(?i)-{2,}\s*Forwarded message\s*-{2,}", text))

    email_count = max(from_count, sent_count, subject_count, wrote_count, forwarded_count)

    # If dates are found but message blocks are not cleanly parsed, use date count as fallback.
    if email_count < len(date_candidates):
        email_count = len(date_candidates)

    # If multiple files exist and text exists, minimum should not be 1 unless truly only one message found.
    if email_count == 0 and len(text.strip()) > 200:
        email_count = 1

    if date_candidates:
        first_dt = min(date_candidates).strftime("%Y-%m-%d %H:%M")
        last_dt = max(date_candidates).strftime("%Y-%m-%d %H:%M")
    else:
        first_dt = None
        last_dt = None

    return first_dt, last_dt, email_count


def derive_rule_based_flags(combined_text, email_count):
    text = (combined_text or "").lower()

    flags = {
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
        "composite_multi_class_bundling": 0
    }

    # Pricing / competitor signals
    if any(x in text for x in [
        "undercut", "cheaper", "lower premium", "lower rate", "more competitive",
        "competitive quote", "market pricing", "too expensive", "way too expensive",
        "not going to get near", "won't get near", "cannot get near", "price is too high"
    ]):
        flags["competitor_undercut_significantly_on_price"] = 1

    if any(x in text for x in [
        "too expensive", "way too expensive", "technical price", "technical pricing",
        "target pricing", "target price", "pricing is likely to bind",
        "pricing which is likely to bind", "not going to get near", "won't get near",
        "premium too high", "rate too high"
    ]):
        flags["pricing_inelasticity"] = 1

    # Structure signals
    if any(x in text for x in [
        "quota share", "layered structure", "layered", "primary or excess",
        "primary", "excess", "attachment", "attach", "xs ", " x/s ",
        "layer", "layers further up", "vertical", "structure"
    ]):
        flags["layer_structure_mismatch"] = 1

    # Sublimit signals
    if any(x in text for x in [
        "sub-limit", "sublimit", "sub limits", "sub-limits", "flood sublimit",
        "wind sublimit", "eq sublimit", "named windstorm", "coverage restriction"
    ]):
        flags["restrictive_sub_limits"] = 1

    # Deductible signals
    if any(x in text for x in [
        "deductible", "retention", "sir", "self insured retention", "self-insured retention"
    ]):
        flags["deductible_mismatch"] = 1

    # Capacity / line size / order signals
    if any(x in text for x in [
        "capacity", "line size", "line %", "participation", "order", "share",
        "full order", "stretch", "quota share stretch", "increase to help fill",
        "available capacity", "smaller line", "line yesterday"
    ]):
        flags["order_size_participation_deficit"] = 1

    # Preferred/incumbent market signals
    if any(x in text for x in [
        "incumbent", "lead market", "led by", "beazley", "fm", "existing market",
        "current lead", "current market", "panel", "preferred market"
    ]):
        flags["preferred_market_partnerships"] = 1

    # Facility / line slip
    if any(x in text for x in [
        "facility", "line slip", "lineslip", "binder", "delegated", "pre-agreed"
    ]):
        flags["facility_line_slip_displacement"] = 1

    # Late quote signals
    if any(x in text for x in [
        "asap", "reply asap", "respond asap", "urgent", "urgently",
        "by cop", "cop friday", "close of play", "deadline",
        "please advise your interest by", "need your interest by",
        "bind today", "bind tomorrow", "last chance", "call with client"
    ]):
        flags["late_quote"] = 1

    # Negotiation fatigue
    if email_count >= 4 or any(x in text for x in [
        "further to my email", "following up", "chaser", "chasing",
        "any update", "still waiting", "back and forth", "again",
        "revised", "revision", "updated terms"
    ]):
        flags["negotiation_fatigue"] = 1

    # Broker switch / displacement
    if any(x in text for x in [
        "new broker", "broker changed", "switch broker", "different broker",
        "local office", "continue your contact through us"
    ]):
        flags["broker_switch_displacement"] = 1

    # Captive / securitization
    if any(x in text for x in [
        "captive", "self insure", "self-insure", "self insurance",
        "retained more risk", "risk financing", "securitization", "capital market"
    ]):
        flags["captive_expansion_securitization"] = 1

    # Composite / multi-class
    if any(x in text for x in [
        "multi-class", "multiclass", "composite", "package", "bundled",
        "combined placement", "property and casualty", "property and liability"
    ]):
        flags["composite_multi_class_bundling"] = 1

    return flags


def build_prompt(account_folder_name, combined_text, first_date, last_date, email_count, rule_flags):
    return f"""
You are an expert insurance underwriting placement analyst working on Convex NTU reason classification.

VERY IMPORTANT:
Every account folder given to you is already a confirmed NTU / not-taken-up / not-bound / not-written case.
Do NOT decide whether it is NTU.
Do NOT say there is no NTU evidence.
Do NOT say this looks like a successful placement.
Your job is to infer the most likely reason Convex did not bind or did not win the placement.

EMAIL CHAIN CONTEXT:
Insurance email chains usually read bottom-to-top.
The oldest email is often lower in the chain.
The newest reply is often at the top.
So interpret the whole chain chronologically using the dates and reply blocks.

System-extracted conversation metadata:
FIRST_CONVERSATION_DATE: {first_date}
LAST_CONVERSATION_DATE: {last_date}
APPROX_EMAIL_COUNT: {email_count}

Rule-based signal hints already detected from the text:
COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE_HINT: {rule_flags["competitor_undercut_significantly_on_price"]}
PRICING_INELASTICITY_HINT: {rule_flags["pricing_inelasticity"]}
LAYER_STRUCTURE_MISMATCH_HINT: {rule_flags["layer_structure_mismatch"]}
RESTRICTIVE_SUB_LIMITS_HINT: {rule_flags["restrictive_sub_limits"]}
DEDUCTIBLE_MISMATCH_HINT: {rule_flags["deductible_mismatch"]}
ORDER_SIZE_PARTICIPATION_DEFICIT_HINT: {rule_flags["order_size_participation_deficit"]}
BROKER_SWITCH_DISPLACEMENT_HINT: {rule_flags["broker_switch_displacement"]}
PREFERRED_MARKET_PARTNERSHIPS_HINT: {rule_flags["preferred_market_partnerships"]}
FACILITY_LINE_SLIP_DISPLACEMENT_HINT: {rule_flags["facility_line_slip_displacement"]}
NEGOTIATION_FATIGUE_HINT: {rule_flags["negotiation_fatigue"]}
LATE_QUOTE_HINT: {rule_flags["late_quote"]}
CAPTIVE_EXPANSION_SECURITIZATION_HINT: {rule_flags["captive_expansion_securitization"]}
COMPOSITE_MULTI_CLASS_BUNDLING_HINT: {rule_flags["composite_multi_class_bundling"]}

Use these hints as supporting evidence, but still read the complete conversation and make final judgement.

NTU subcategory definitions:

1. COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE:
Mark 1 if another market appears cheaper, more competitive, already leading at better price, or Convex says it cannot get near market pricing.

2. PRICING_INELASTICITY:
Mark 1 if Convex pricing appears too high, target pricing cannot be met, Convex cannot reduce enough, or Convex says the price is unlikely to bind.

3. LAYER_STRUCTURE_MISMATCH:
Mark 1 if the broker wanted quota share / primary / excess / attachment / layer / layered structure, but Convex preference or appetite did not match.

4. RESTRICTIVE_SUB_LIMITS:
Mark 1 if sublimits or coverage restrictions appear to be a negative factor.

5. DEDUCTIBLE_MISMATCH:
Mark 1 if deductible, SIR, retention, or NatCat deductible appears to be a negative factor or mismatch.

6. ORDER_SIZE_PARTICIPATION_DEFICIT:
Mark 1 if broker wanted more capacity, a larger share, a specific line, or full participation but Convex could not support enough.

7. BROKER_SWITCH_DISPLACEMENT:
Mark 1 if broker/channel change, local office routing, or communication routing may have displaced Convex.

8. PREFERRED_MARKET_PARTNERSHIPS:
Mark 1 if incumbent/lead/named markets appear favoured or already had the order.

9. FACILITY_LINE_SLIP_DISPLACEMENT:
Mark 1 if the placement likely went through a facility, line slip, binder, or delegated channel.

10. NEGOTIATION_FATIGUE:
Mark 1 if there are repeated emails, chasers, follow-ups, several back-and-forths, or loss of momentum. If APPROX_EMAIL_COUNT is 4 or more, strongly consider marking this as 1.

11. LATE_QUOTE:
Mark 1 if broker requested urgent reply, ASAP response, COP deadline, client call, or interest by a certain date. Even if exact deadline comparison is unclear, urgency/deadline language is enough to mark 1.

12. CAPTIVE_EXPANSION_SECURITIZATION:
Mark 1 if risk retention/captive/self-insurance/capital market alternative appears.

13. COMPOSITE_MULTI_CLASS_BUNDLING:
Mark 1 if bundled/multi-class/composite placement appears.

Decision rules:
- At least one flag must be 1.
- Do not mark only PRICING_INELASTICITY unless pricing is clearly the main issue.
- If there is "ASAP", "COP", "deadline", "client call", or "advise interest by", LATE_QUOTE should usually be 1.
- If there are 4 or more email messages, NEGOTIATION_FATIGUE should usually be 1.
- If there is primary/excess/layer/quota-share language, LAYER_STRUCTURE_MISMATCH should usually be 1.
- If there is capacity/share/line/order/stretch language, ORDER_SIZE_PARTICIPATION_DEFICIT should usually be 1.
- Multiple flags are allowed and expected.

Return output in EXACTLY this format.
Do not return JSON.
Do not return markdown.
Do not add extra keys.

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
Write a detailed granular explanation.
Explain the likely NTU reason.
Explain why each selected flag was marked 1.
Mention evidence from the email chain.
Do not say this is not an NTU case.
NTU_EXPLANATION_END

Account folder name:
{account_folder_name}

Combined conversation text:
{combined_text[:100000]}
"""


def classify_with_llm(session, account_folder_name, combined_text):
    first_date, last_date, email_count = extract_email_dates_and_count(combined_text)
    rule_flags = derive_rule_based_flags(combined_text, email_count)

    prompt = build_prompt(
        account_folder_name,
        combined_text,
        first_date,
        last_date,
        email_count,
        rule_flags
    )

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

    # Apply deterministic signals as overrides/additions, not only fallback.
    # This prevents missing late quote / negotiation fatigue when clear phrases exist.
    for k in flag_keys:
        if rule_flags.get(k, 0) == 1:
            result[k] = 1

    # Prevent all-zero because every account is confirmed NTU.
    if sum([safe_int(result.get(k)) for k in flag_keys]) == 0:
        if email_count >= 4:
            result["negotiation_fatigue"] = 1
        elif rule_flags["late_quote"] == 1:
            result["late_quote"] = 1
        elif rule_flags["layer_structure_mismatch"] == 1:
            result["layer_structure_mismatch"] = 1
        elif rule_flags["order_size_participation_deficit"] == 1:
            result["order_size_participation_deficit"] = 1
        else:
            result["preferred_market_partnerships"] = 1

        result["ntu_explanation"] = (
            "This account is part of the confirmed NTU population. "
            "A best-fit NTU category was selected using deterministic email-chain signals because the model did not strongly select a category. "
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
                        f"\n\n===== FILE: {file_path} =====\n{parsed_text}"
                    )

            combined_text = "\n".join(all_text_parts)

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
