CREATE OR REPLACE PROCEDURE RUN_OPEN_MARKET_NTU_CLASSIFICATION_V3(LIMIT_N_FOLDERS NUMBER)
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

OUTPUT_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_V3_OUTPUT'
ERROR_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_V3_ERROR_LOG'


def sql_escape(value):
    if value is None:
        return ''
    return str(value).replace("'", "''")


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


def safe_date_diff_days(start_dt, end_dt):
    try:
        if start_dt is None or end_dt is None:
            return None
        return (end_dt.date() - start_dt.date()).days
    except Exception:
        return None


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


def extract_value(raw_text, key):
    pattern = rf"^\s*{key}\s*:\s*(.*)$"
    match = re.search(pattern, raw_text or '', re.IGNORECASE | re.MULTILINE)
    if not match:
        return None
    return match.group(1).strip()


def extract_explanation(raw_text):
    raw_text = raw_text or ''

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


def normalize_email_text(text):
    text = text or ""
    text = text.replace("\r", "\n")
    text = text.replace("\u00a0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def parse_date_candidate(raw):
    raw = raw or ""
    raw = raw.strip()

    raw = re.sub(r"\s+", " ", raw)
    raw = raw.replace(" at ", " ")
    raw = raw.replace(",", ", ")
    raw = re.sub(r"\s+", " ", raw).strip()

    raw = re.sub(r"(\d{1,2})(st|nd|rd|th)", r"\1", raw, flags=re.IGNORECASE)

    formats = [
        "%A, %B %d, %Y %I:%M %p",
        "%A, %B %d, %Y %H:%M",
        "%B %d, %Y %I:%M %p",
        "%B %d, %Y %H:%M",

        "%a, %d %b %Y %H:%M",
        "%a, %d %b %Y %I:%M %p",
        "%A, %d %B %Y %H:%M",
        "%A, %d %B %Y %I:%M %p",

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


def get_email_from_text(value):
    if value is None:
        return ''

    m = re.search(r"<([^>]+@[^>]+)>", value)
    if m:
        return m.group(1).strip().lower()

    m = re.search(r"([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})", value)
    if m:
        return m.group(1).strip().lower()

    return ''


def find_first_date_in_text(value):
    value = value or ""

    date_patterns = [
        r"([A-Za-z]{3,9},\s+\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?)",
        r"([A-Za-z]{3,9},\s+[A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?)",
        r"(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2})",
        r"([A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s*(?:AM|PM))",
        r"(\d{1,2}/\d{1,2}/\d{4},\s*\d{1,2}:\d{2})",
        r"(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2})",
        r"(\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2})",
        r"(\d{4}-\d{2}-\d{2})"
    ]

    for pattern in date_patterns:
        m = re.search(pattern, value, re.IGNORECASE)
        if m:
            dt = parse_date_candidate(m.group(1))
            if dt:
                return dt

    return None


def find_email_message_events(text):
    """
    Splits PDF-exported email chain into distinct email messages.

    Handles:
    1. Outlook style:
       From:
       Sent:
       Subject:

    2. Gmail style:
       On Wed, 21 Aug 2024 at 14:13, Richard <x@y.com> wrote:

    3. Rendered email header style:
       Matthew Askew <matthew.askew@convexin.com>       21 August 2024 at 14:31
       To:
       Subject:
    """

    text = normalize_email_text(text)
    events = []

    # 1. Outlook / forwarded style
    for m in re.finditer(r"(?im)^\s*From:\s*(.+)$", text):
        pos = m.start()
        sender_line = m.group(1).strip()
        window = text[pos:pos + 1500]

        date_match = re.search(r"(?im)^\s*(?:Sent|Date):\s*(.+)$", window)
        dt = None

        if date_match:
            dt = parse_date_candidate(date_match.group(1).strip())

        if dt is None:
            dt = find_first_date_in_text(window)

        sender_email = get_email_from_text(sender_line)

        if dt:
            events.append({
                "pos": pos,
                "dt": dt,
                "sender": sender_line,
                "sender_email": sender_email,
                "source": "from_header"
            })

    # 2. Gmail "On ... wrote:" style
    wrote_patterns = [
        r"(?is)\bOn\s+([A-Za-z]{3,9},\s+\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?),\s*(.{0,300}?)\s+wrote:",
        r"(?is)\bOn\s+([A-Za-z]{3,9},\s+[A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?),\s*(.{0,300}?)\s+wrote:"
    ]

    for wrote_pattern in wrote_patterns:
        for m in re.finditer(wrote_pattern, text):
            pos = m.start()
            raw_date = m.group(1).strip()
            sender_part = m.group(2).strip()

            dt = parse_date_candidate(raw_date)
            sender_email = get_email_from_text(sender_part)

            if dt:
                events.append({
                    "pos": pos,
                    "dt": dt,
                    "sender": sender_part,
                    "sender_email": sender_email,
                    "source": "on_wrote"
                })

    # 3. Rendered email header style
    line_iter = list(re.finditer(r"(?m)^.*<[^>]+@[^>]+>.*$", text))

    for m in line_iter:
        line = m.group(0).strip()
        lower_line = line.lower()

        if lower_line.startswith(("to:", "cc:", "bcc:", "from:", "subject:", "e:", "m:", "w:", "in:")):
            continue

        pos = m.start()
        window = text[max(0, pos - 400):pos + 1500]

        if not (
            re.search(r"(?im)^\s*To:\s*", window)
            or re.search(r"(?im)^\s*Subject:\s*", window)
            or re.search(r"(?im)^\s*Cc:\s*", window)
            or re.search(r"(?i)\b\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}", window)
        ):
            continue

        dt = find_first_date_in_text(window)
        sender_email = get_email_from_text(line)

        if dt and sender_email:
            events.append({
                "pos": pos,
                "dt": dt,
                "sender": line,
                "sender_email": sender_email,
                "source": "rendered_header"
            })

    # Deduplicate repeated detections from same email
    dedup = {}

    for e in events:
        key = (
            e["sender_email"].lower(),
            e["dt"].strftime("%Y-%m-%d %H:%M")
        )

        if key not in dedup:
            dedup[key] = e
        else:
            existing_rank = {
                "from_header": 3,
                "on_wrote": 2,
                "rendered_header": 1
            }.get(dedup[key]["source"], 0)

            new_rank = {
                "from_header": 3,
                "on_wrote": 2,
                "rendered_header": 1
            }.get(e["source"], 0)

            if new_rank > existing_rank:
                dedup[key] = e

    events = list(dedup.values())
    events.sort(key=lambda x: x["pos"])

    for i, e in enumerate(events):
        start = e["pos"]
        end = events[i + 1]["pos"] if i + 1 < len(events) else len(text)
        e["body"] = text[start:end]

    return events


def has_convex_quote_language(body):
    """
    Must represent actual Convex quote / terms / offer.
    Avoid matching broker's original requested order as Convex quote.
    """

    w = (body or "").lower()

    strong_quote_phrases = [
        "we can offer",
        "can offer a",
        "we are able to offer",
        "pleased to say we can offer",
        "we would be looking for",
        "would be looking for",
        "rough steer",
        "premium is annual",
        "less 20%",
        "less 15%",
        "less 12.5%",
        "open until inception",
        "open 30 days",
        "risk warranty",
        "subject to",
        "ncg",
        "sndilr",
        "terms are",
        "our terms",
        "our quote",
        "quotation",
        "quote is",
        "offer a 5%",
        "offer a 7.5%",
        "offer a line",
        "line on the clf",
        "line on the usd",
        "line on the eur"
    ]

    if any(p in w for p in strong_quote_phrases):
        return True

    numeric_quote_patterns = [
        r"\bwe\s+can\s+offer\s+\d+(\.\d+)?%\s+line\b",
        r"\b\d+(\.\d+)?%\s+line\s+on\s+the\b",
        r"\b@\s*(usd|eur|gbp|clf|cad|aud|dkk)?\s*[\d,]+",
        r"\bxs\b",
        r"\bx/s\b"
    ]

    matched = 0

    for pattern in numeric_quote_patterns:
        if re.search(pattern, w, re.IGNORECASE):
            matched += 1

    return matched >= 2


def extract_conversation_metadata(combined_text):
    """
    Business meaning:
    - first conversation started = earliest distinct email/message date
    - first Convex quote sent = earliest distinct Convex email where Convex actually gives quote/offer/terms
    - email count = count of distinct email messages in the chain
    """

    text = normalize_email_text(combined_text)
    events = find_email_message_events(text)

    first_dt = None
    first_quote_dt = None
    quote_candidates = []

    if events:
        first_dt = min([e["dt"] for e in events])

    for e in events:
        sender_email = (e.get("sender_email") or "").lower()
        body = e.get("body") or ""

        if "@convexin.com" in sender_email and has_convex_quote_language(body):
            quote_candidates.append(e)

    if quote_candidates:
        first_quote_dt = min([e["dt"] for e in quote_candidates])

    email_count = len(events)

    if email_count == 0:
        fallback_dates = []

        for m in re.finditer(
            r"(?i)(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}|\d{1,2}/\d{1,2}/\d{4},\s*\d{1,2}:\d{2})",
            text
        ):
            dt = parse_date_candidate(m.group(1))
            if dt:
                fallback_dates.append(dt)

        if fallback_dates:
            first_dt = min(fallback_dates)
            email_count = len(set([x.strftime("%Y-%m-%d %H:%M") for x in fallback_dates]))
        elif len(text.strip()) > 200:
            email_count = 1

    days_to_quote = safe_date_diff_days(first_dt, first_quote_dt)

    # UPDATED THRESHOLDS AS REQUESTED:
    # Late quote = 1 only if quote is more than 4 days after first conversation
    # Negotiation fatigue = 1 only if email count is more than 20
    late_quote = 1 if days_to_quote is not None and days_to_quote > 4 else 0
    negotiation_fatigue = 1 if email_count > 20 else 0

    return {
        "first_conversation_dt": first_dt,
        "first_quote_dt": first_quote_dt,
        "email_count": email_count,
        "days_to_quote": days_to_quote,
        "late_quote": late_quote,
        "negotiation_fatigue": negotiation_fatigue,

        "messages_detected": [
            {
                "sender": e.get("sender"),
                "sender_email": e.get("sender_email"),
                "date": e["dt"].strftime("%Y-%m-%d %H:%M"),
                "source": e.get("source"),
                "is_convex": 1 if "@convexin.com" in (e.get("sender_email") or "").lower() else 0,
                "is_convex_quote": 1 if "@convexin.com" in (e.get("sender_email") or "").lower() and has_convex_quote_language(e.get("body") or "") else 0
            }
            for e in events
        ],

        "all_dates_detected": [
            e["dt"].strftime("%Y-%m-%d %H:%M")
            for e in events
        ],

        "quote_candidates": [
            {
                "sender": e.get("sender"),
                "sender_email": e.get("sender_email"),
                "date": e["dt"].strftime("%Y-%m-%d %H:%M"),
                "source": e.get("source")
            }
            for e in quote_candidates
        ]
    }


def derive_supporting_rule_flags(combined_text):
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
        "captive_expansion_securitization": 0,
        "composite_multi_class_bundling": 0
    }

    if any(x in text for x in [
        "undercut", "cheaper", "lower premium", "lower rate", "more competitive",
        "competing market", "alternative market", "another market",
        "market pricing", "double the market pricing", "too expensive",
        "way too expensive", "not going to get near", "cannot get near"
    ]):
        flags["competitor_undercut_significantly_on_price"] = 1

    if any(x in text for x in [
        "too expensive", "way too expensive", "technical price", "technical pricing",
        "target pricing", "target price", "pricing which is likely to bind",
        "likely to bind", "premium too high", "rate too high", "not competitive"
    ]):
        flags["pricing_inelasticity"] = 1

    if any(x in text for x in [
        "quota share", "layered structure", "layered", "primary or excess",
        "primary", "excess", "attachment", "attach", " xs ", " x/s ",
        "layer", "layers further up", "vertical", "structure", "layer 2"
    ]):
        flags["layer_structure_mismatch"] = 1

    if any(x in text for x in [
        "sub-limit", "sublimit", "sub limits", "sub-limits",
        "flood sublimit", "wind sublimit", "eq sublimit", "named windstorm",
        "coverage restriction", "restricted cover"
    ]):
        flags["restrictive_sub_limits"] = 1

    if any(x in text for x in [
        "deductible", "retention", "sir", "self insured retention",
        "self-insured retention", "nws deductible", "nat cat deductible", "nat.cat"
    ]):
        flags["deductible_mismatch"] = 1

    if any(x in text for x in [
        "capacity", "line size", "line %", "participation", "order",
        "full order", "stretch", "quota share stretch", "available capacity",
        "smaller line", "increase to help fill", "5% line", "7.5% line"
    ]):
        flags["order_size_participation_deficit"] = 1

    if any(x in text for x in [
        "new broker", "broker changed", "different broker", "switch broker",
        "local office", "continue your contact through us", "not actively engaged"
    ]):
        flags["broker_switch_displacement"] = 1

    if any(x in text for x in [
        "incumbent", "lead market", "led by", "beazley", "axa xl", "fm",
        "existing market", "current lead", "current market", "panel",
        "preferred market", "already been placed"
    ]):
        flags["preferred_market_partnerships"] = 1

    if any(x in text for x in [
        "facility", "line slip", "lineslip", "binder", "delegated",
        "pre-agreed", "pre negotiated", "facility placement"
    ]):
        flags["facility_line_slip_displacement"] = 1

    if any(x in text for x in [
        "captive", "self insure", "self-insure", "self insurance",
        "retained more risk", "risk financing", "securitization", "capital market"
    ]):
        flags["captive_expansion_securitization"] = 1

    if any(x in text for x in [
        "multi-class", "multiclass", "composite", "package", "bundled",
        "combined placement", "property and casualty", "property and liability"
    ]):
        flags["composite_multi_class_bundling"] = 1

    return flags


def build_prompt(account_folder_name, combined_text, metadata, rule_flags):
    first_date = metadata["first_conversation_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_conversation_dt"] else None
    quote_date = metadata["first_quote_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_quote_dt"] else None

    return f"""
You are an expert Convex property insurance underwriting and placement analyst.

BUSINESS CONTEXT:
Every account folder provided is already a confirmed NTU / not-taken-up / not-bound / not-written case.
Your task is not to decide whether it is NTU.
Your task is to infer the most likely commercial reason or reasons why Convex did not win / bind / write the placement.

EMAIL CHAIN CONTEXT:
Insurance email chains often read bottom-to-top.
The oldest email is often at the bottom.
The latest reply is often at the top.
A PDF print/export date at the top of the PDF is NOT necessarily a broker/Convex email date.
The key quote date is the date Convex first sent actual quotation terms, such as:
- "we can offer..."
- "we would be looking for..."
- "% line on..."
- quoted premium / rate / less commission
- terms such as NCG, SNDILR, open until inception, risk warranty, premium annual

SYSTEM-EXTRACTED METADATA:
FIRST_CONVERSATION_STARTED: {first_date}
FIRST_CONVEX_QUOTE_SENT: {quote_date}
EMAIL_COUNT_DETECTED: {metadata["email_count"]}
DAYS_TO_FIRST_QUOTE: {metadata["days_to_quote"]}
SYSTEM_LATE_QUOTE_RULE: {metadata["late_quote"]}
SYSTEM_NEGOTIATION_FATIGUE_RULE: {metadata["negotiation_fatigue"]}

Important:
- LATE_QUOTE is calculated by system: 1 only when DAYS_TO_FIRST_QUOTE > 4.
- NEGOTIATION_FATIGUE is calculated by system: 1 only when EMAIL_COUNT_DETECTED > 20.
- Do not mark late quote or negotiation fatigue manually. The system will override those two fields.

Supporting text signals:
COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE_HINT: {rule_flags["competitor_undercut_significantly_on_price"]}
PRICING_INELASTICITY_HINT: {rule_flags["pricing_inelasticity"]}
LAYER_STRUCTURE_MISMATCH_HINT: {rule_flags["layer_structure_mismatch"]}
RESTRICTIVE_SUB_LIMITS_HINT: {rule_flags["restrictive_sub_limits"]}
DEDUCTIBLE_MISMATCH_HINT: {rule_flags["deductible_mismatch"]}
ORDER_SIZE_PARTICIPATION_DEFICIT_HINT: {rule_flags["order_size_participation_deficit"]}
BROKER_SWITCH_DISPLACEMENT_HINT: {rule_flags["broker_switch_displacement"]}
PREFERRED_MARKET_PARTNERSHIPS_HINT: {rule_flags["preferred_market_partnerships"]}
FACILITY_LINE_SLIP_DISPLACEMENT_HINT: {rule_flags["facility_line_slip_displacement"]}
CAPTIVE_EXPANSION_SECURITIZATION_HINT: {rule_flags["captive_expansion_securitization"]}
COMPOSITE_MULTI_CLASS_BUNDLING_HINT: {rule_flags["composite_multi_class_bundling"]}

SUBCATEGORY DEFINITIONS IN INSURANCE TERMS:

1. COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE:
Mark 1 only when the chain indicates a competing insurer / market / lead offered materially better pricing, a lower premium, better rate, or the broker/client was comparing Convex unfavourably against market pricing.

2. PRICING_INELASTICITY:
Mark 1 when Convex appears unable or unwilling to meet target pricing due to technical rating or pricing discipline.

3. LAYER_STRUCTURE_MISMATCH:
Mark 1 when the issue is structure: quota share vs excess, primary vs excess, attachment point, vertical placement, layer size, or broker wanting one layer while Convex proposes another.

4. RESTRICTIVE_SUB_LIMITS:
Mark 1 when Convex terms have restrictive sublimits or cover restrictions on key perils such as Flood, Wind, Earthquake, NatCat, BI, CBI, NWS, or similar.

5. DEDUCTIBLE_MISMATCH:
Mark 1 when deductible/SIR/retention is higher or different than broker/client target or less attractive than the lead/competing market.

6. ORDER_SIZE_PARTICIPATION_DEFICIT:
Mark 1 when the broker/client required a specific line size, order size, capacity, share, or participation, but Convex could not give enough or only offered a smaller line.

7. BROKER_SWITCH_DISPLACEMENT:
Mark 1 when a different broker, local office, communication route, or broker strategy displaced Convex.

8. PREFERRED_MARKET_PARTNERSHIPS:
Mark 1 when the broker/client appears to favour incumbent markets, existing lead, preferred markets, strategic carriers, or named lead markets such as AXA XL, Beazley, FM etc.

9. FACILITY_LINE_SLIP_DISPLACEMENT:
Mark 1 when placement appears to be going through a facility, line slip, binder, delegated placement, pre-negotiated facility, or operational route.

10. NEGOTIATION_FATIGUE:
System-calculated only. The procedure will set 1 only when email count > 20.

11. LATE_QUOTE:
System-calculated only. The procedure will set 1 only when the first Convex quote was sent more than 4 days after the first broker/account conversation date.

12. CAPTIVE_EXPANSION_SECURITIZATION:
Mark 1 when client retains risk, uses captive, self-insurance, securitization, risk financing, or capital market alternatives.

13. COMPOSITE_MULTI_CLASS_BUNDLING:
Mark 1 when property risk was bundled into a multi-class/composite package that Convex could not participate in due to product/class mismatch.

DECISION RULES:
- Multiple categories can be 1.
- Do not mark everything.
- Mark only categories supported by actual commercial evidence in the chain.
- At least one of the non-system commercial categories should usually be 1 because this is a confirmed NTU population.
- Do not use "no NTU evidence" or "successful placement" language.

Return output in EXACTLY this format.
Do not return JSON.
Do not return markdown.
Do not add extra keys.
For LATE_QUOTE and NEGOTIATION_FATIGUE, return 0; the system will override them.

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
Write a granular explanation.
Explain the likely NTU reason.
Explain why each selected commercial flag was marked 1.
Also mention the system-calculated quote timing and email count.
Do not say this is not an NTU case.
NTU_EXPLANATION_END

Account folder name:
{account_folder_name}

Combined conversation text:
{combined_text[:100000]}
"""


def classify_with_llm(session, account_folder_name, combined_text):
    metadata = extract_conversation_metadata(combined_text)
    rule_flags = derive_supporting_rule_flags(combined_text)

    prompt = build_prompt(account_folder_name, combined_text, metadata, rule_flags)

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

        # system-calculated
        "negotiation_fatigue": metadata["negotiation_fatigue"],
        "late_quote": metadata["late_quote"],

        "captive_expansion_securitization": safe_int(extract_value(raw, "CAPTIVE_EXPANSION_SECURITIZATION")),
        "composite_multi_class_bundling": safe_int(extract_value(raw, "COMPOSITE_MULTI_CLASS_BUNDLING")),

        "date_of_first_conversation_started": metadata["first_conversation_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_conversation_dt"] else None,
        "date_of_last_conversation": metadata["first_quote_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_quote_dt"] else None,
        "date_of_first_convex_quote_sent": metadata["first_quote_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_quote_dt"] else None,
        "no_of_emails_transferred_in_between": metadata["email_count"],
        "days_to_first_quote": metadata["days_to_quote"],
        "ntu_explanation": extract_explanation(raw)
    }

    commercial_flag_keys = [
        "competitor_undercut_significantly_on_price",
        "pricing_inelasticity",
        "layer_structure_mismatch",
        "restrictive_sub_limits",
        "deductible_mismatch",
        "order_size_participation_deficit",
        "broker_switch_displacement",
        "preferred_market_partnerships",
        "facility_line_slip_displacement",
        "captive_expansion_securitization",
        "composite_multi_class_bundling"
    ]

    strong_override_keys = [
        "competitor_undercut_significantly_on_price",
        "layer_structure_mismatch",
        "order_size_participation_deficit",
        "preferred_market_partnerships",
        "facility_line_slip_displacement",
        "captive_expansion_securitization",
        "composite_multi_class_bundling"
    ]

    for k in strong_override_keys:
        if rule_flags.get(k, 0) == 1:
            result[k] = 1

    text_lower = (combined_text or "").lower()

    if rule_flags.get("pricing_inelasticity", 0) == 1 and any(x in text_lower for x in [
        "too expensive", "way too expensive", "not going to get near",
        "cannot get near", "unlikely to bind", "not competitive",
        "target pricing", "double the market pricing"
    ]):
        result["pricing_inelasticity"] = 1

    if rule_flags.get("deductible_mismatch", 0) == 1 and any(x in text_lower for x in [
        "deductible too high", "deductible is too high", "cannot accept deductible",
        "deductible mismatch", "higher deductible"
    ]):
        result["deductible_mismatch"] = 1

    if rule_flags.get("restrictive_sub_limits", 0) == 1 and any(x in text_lower for x in [
        "restrictive sublimit", "sublimit too low", "cannot accept sublimit",
        "more restrictive", "restricted cover"
    ]):
        result["restrictive_sub_limits"] = 1

    if sum([safe_int(result.get(k)) for k in commercial_flag_keys]) == 0:
        if rule_flags.get("competitor_undercut_significantly_on_price", 0) == 1:
            result["competitor_undercut_significantly_on_price"] = 1
        elif rule_flags.get("layer_structure_mismatch", 0) == 1:
            result["layer_structure_mismatch"] = 1
        elif rule_flags.get("order_size_participation_deficit", 0) == 1:
            result["order_size_participation_deficit"] = 1
        elif rule_flags.get("preferred_market_partnerships", 0) == 1:
            result["preferred_market_partnerships"] = 1
        elif rule_flags.get("pricing_inelasticity", 0) == 1:
            result["pricing_inelasticity"] = 1
        else:
            result["preferred_market_partnerships"] = 1

        result["ntu_explanation"] = (
            "This account is part of the confirmed NTU population. "
            "A best-fit commercial category was selected using available placement signals because the model did not strongly select a commercial reason. "
            + (result.get("ntu_explanation") or "")
        )

    system_metadata = {
        "first_conversation_started": result["date_of_first_conversation_started"],
        "first_convex_quote_sent": result["date_of_first_convex_quote_sent"],
        "date_of_last_conversation_business_meaning": "first Convex quote / offer / terms sent date",
        "email_count_detected": metadata["email_count"],
        "days_to_first_quote": metadata["days_to_quote"],
        "late_quote_rule": "1 if days_to_first_quote > 4 else 0",
        "negotiation_fatigue_rule": "1 if email_count_detected > 20 else 0",
        "all_dates_detected": metadata["all_dates_detected"],
        "quote_candidates": metadata["quote_candidates"],
        "messages_detected": metadata["messages_detected"],
        "supporting_rule_flags": rule_flags
    }

    return result, raw, system_metadata


def insert_result(session, account_folder_name, result, files_processed, raw_response, system_metadata):
    raw_json = sql_escape(json.dumps(result))
    metadata_json = sql_escape(json.dumps(system_metadata))

    first_date = result.get('date_of_first_conversation_started')
    quote_date = result.get('date_of_first_convex_quote_sent')
    last_date = result.get('date_of_last_conversation')

    first_date_sql = 'NULL' if first_date is None else "'" + sql_escape(first_date) + "'"
    quote_date_sql = 'NULL' if quote_date is None else "'" + sql_escape(quote_date) + "'"
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
            DATE_OF_FIRST_CONVEX_QUOTE_SENT,
            NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN,
            DAYS_TO_FIRST_QUOTE,

            FILES_PROCESSED,
            RAW_LLM_RESPONSE,
            RAW_SYSTEM_EXTRACTED_METADATA
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
            {quote_date_sql},
            {safe_int(result.get('no_of_emails_transferred_in_between'))},
            { 'NULL' if result.get('days_to_first_quote') is None else safe_int(result.get('days_to_first_quote')) },

            {files_processed},
            PARSE_JSON('{raw_json}'),
            PARSE_JSON('{metadata_json}')
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

            result, raw_response, system_metadata = classify_with_llm(session, account_folder, combined_text)

            insert_result(session, account_folder, result, len(files), raw_response, system_metadata)

            processed += 1
            messages.append(f"{account_folder}: processed {len(files)} files")

        except Exception as e:
            failed += 1
            insert_error(session, account_folder, str(e), raw_response, len(files))
            messages.append(f"{account_folder}: FAILED - {str(e)[:200]}")

    return f"Processed={processed}, Failed={failed}. Details: " + " | ".join(messages)
$$;
