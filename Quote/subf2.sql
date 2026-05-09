CREATE OR REPLACE PROCEDURE RUN_OPEN_MARKET_NTU_CLASSIFICATION_V4(LIMIT_N_FOLDERS NUMBER)
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
import uuid
from datetime import datetime

STAGE_NAME = '@OPEN_MARKET_QUOTE'
ROOT_PATH = 'Open_Market/'
MODEL_NAME = 'claude-sonnet-4-5'

SUPPORTED_EXTENSIONS = (
    '.pdf', '.docx', '.pptx',
    '.png', '.jpg', '.jpeg', '.tif', '.tiff',
    '.txt', '.html'
)

OUTPUT_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_V4_OUTPUT'
ERROR_TABLE = 'OPEN_MARKET_NTU_CLASSIFICATION_V4_ERROR_LOG'


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
    return ""


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

        value = parsed_obj.get('value') if isinstance(parsed_obj, dict) else parsed_obj

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
    text = normalize_email_text(text)
    raw_events = []

    for m in re.finditer(r"(?im)^\s*From:\s*(.+)$", text):
        pos = m.start()
        sender_line = m.group(1).strip()
        window = text[pos:pos + 1800]

        date_match = re.search(r"(?im)^\s*(?:Sent|Date):\s*(.+)$", window)
        dt = None

        if date_match:
            dt = parse_date_candidate(date_match.group(1).strip())

        if dt is None:
            dt = find_first_date_in_text(window)

        sender_email = get_email_from_text(sender_line)

        if dt:
            raw_events.append({
                "pos": pos,
                "dt": dt,
                "sender": sender_line,
                "sender_email": sender_email,
                "source": "from_header"
            })

    wrote_patterns = [
        r"(?is)\bOn\s+([A-Za-z]{3,9},\s+\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?),\s*(.{0,350}?)\s+wrote:",
        r"(?is)\bOn\s+([A-Za-z]{3,9},\s+[A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}(?:\s*(?:AM|PM))?),\s*(.{0,350}?)\s+wrote:"
    ]

    for wrote_pattern in wrote_patterns:
        for m in re.finditer(wrote_pattern, text):
            pos = m.start()
            raw_date = m.group(1).strip()
            sender_part = m.group(2).strip()

            dt = parse_date_candidate(raw_date)
            sender_email = get_email_from_text(sender_part)

            if dt:
                raw_events.append({
                    "pos": pos,
                    "dt": dt,
                    "sender": sender_part,
                    "sender_email": sender_email,
                    "source": "on_wrote"
                })

    for m in re.finditer(r"(?m)^.*<[^>]+@[^>]+>.*$", text):
        line = m.group(0).strip()
        lower_line = line.lower()

        if lower_line.startswith(("to:", "cc:", "bcc:", "from:", "subject:", "e:", "m:", "w:", "in:")):
            continue

        pos = m.start()
        window = text[max(0, pos - 500):pos + 1800]

        looks_like_header = (
            re.search(r"(?im)^\s*To:\s*", window)
            or re.search(r"(?im)^\s*Subject:\s*", window)
            or re.search(r"(?im)^\s*Cc:\s*", window)
            or re.search(r"(?i)\b\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}", window)
        )

        if not looks_like_header:
            continue

        dt = find_first_date_in_text(window)
        sender_email = get_email_from_text(line)

        if dt and sender_email:
            raw_events.append({
                "pos": pos,
                "dt": dt,
                "sender": line,
                "sender_email": sender_email,
                "source": "rendered_header"
            })

    dedup = {}

    for e in raw_events:
        key = (
            (e.get("sender_email") or "").lower(),
            e["dt"].strftime("%Y-%m-%d %H:%M")
        )

        if key not in dedup:
            dedup[key] = e
        else:
            rank = {
                "from_header": 3,
                "rendered_header": 2,
                "on_wrote": 1
            }

            existing_rank = rank.get(dedup[key]["source"], 0)
            new_rank = rank.get(e["source"], 0)

            if new_rank > existing_rank:
                dedup[key] = e

    events = list(dedup.values())
    events.sort(key=lambda x: x["pos"])

    for i, e in enumerate(events):
        start = e["pos"]
        end = events[i + 1]["pos"] if i + 1 < len(events) else len(text)

        body = text[start:end]

        cut_patterns = [
            r"(?is)\n\s*On\s+[A-Za-z]{3,9},\s+\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\s+at\s+\d{1,2}:\d{2}.*?\bwrote:",
            r"(?is)\n\s*On\s+[A-Za-z]{3,9},\s+[A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}.*?\bwrote:",
            r"(?im)\n\s*From:\s+.+\n\s*Sent:\s+.+"
        ]

        earliest_cut = None

        for cp in cut_patterns:
            cm = re.search(cp, body)
            if cm and cm.start() > 50:
                if earliest_cut is None or cm.start() < earliest_cut:
                    earliest_cut = cm.start()

        if earliest_cut is not None:
            body = body[:earliest_cut]

        e["body"] = body

    return events


def has_convex_quote_language(body):
    w = (body or "").lower()
    w = re.sub(r"\s+", " ", w).strip()

    non_quote_phrases = [
        "we will take a look",
        "i'll take a look",
        "i will take a look",
        "shouldn't be a problem",
        "shall we catch up",
        "can do a call",
        "i can do a call",
        "yes. that's fine",
        "yes that's fine",
        "thanks for your patience",
        "hope this helps",
        "let me know if you need anything else",
        "do call tomorrow",
        "call tomorrow",
        "are you free",
        "are you available",
        "will take a look for you",
        "i'm so sorry",
        "this week has been a nightmare",
        "we will take a look for you"
    ]

    if any(p in w for p in non_quote_phrases):
        strong_override = any(p in w for p in [
            "we can offer",
            "pleased to say we can offer",
            "we would be looking for",
            "quote subject",
            "premium is annual",
            "as discussed, we can follow"
        ])

        if not strong_override:
            return False

    strong_quote_phrases = [
        "we can offer",
        "can offer a",
        "we are able to offer",
        "pleased to say we can offer",
        "we would be looking for",
        "would be looking for",
        "quote subject",
        "quote subject:",
        "as discussed, we can follow",
        "we can follow axa",
        "we can follow axa xl",
        "we can follow the lead",
        "with our expiring capacity",
        "premium is annual",
        "open until inception",
        "open 30 days",
        "risk warranty",
        "ncg",
        "sndilr",
        "terms are",
        "our terms",
        "our quote",
        "quotation",
        "quote is",
        "offer a 5%",
        "offer a 7.5%",
        "offer a 8%",
        "offer an 8%",
        "offer a 10%",
        "offer a line",
        "quoted a",
        "quoted an",
        "quoted premium",
        "quoted terms"
    ]

    if any(p in w for p in strong_quote_phrases):
        return True

    has_line = re.search(r"\b\d+(\.\d+)?\s*%\s+(line|share)\b", w) is not None

    has_layer_or_price = any(x in w for x in [
        " xs ",
        " x/s ",
        "x/s",
        " xs",
        "@",
        "premium",
        "annual",
        "less 20%",
        "less 15%",
        "less 12.5%",
        "clf",
        "usd",
        "eur",
        "gbp"
    ])

    if has_line and has_layer_or_price:
        return True

    return False


def extract_conversation_metadata(combined_text):
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

    raw_email_count = len(events)
    email_count = max(raw_email_count - 3, 1) if raw_email_count > 0 else 0

    if raw_email_count == 0:
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
            raw_email_count = len(set([x.strftime("%Y-%m-%d %H:%M") for x in fallback_dates]))
            email_count = max(raw_email_count - 3, 1)
        elif len(text.strip()) > 200:
            email_count = 1

    days_to_quote = safe_date_diff_days(first_dt, first_quote_dt)

    late_quote = 1 if days_to_quote is not None and days_to_quote > 4 else 0
    negotiation_fatigue = 1 if email_count > 20 else 0

    messages_detected = []
    for e in events:
        sender_email = (e.get("sender_email") or "").lower()
        is_convex = 1 if "@convexin.com" in sender_email else 0
        is_convex_quote = 1 if is_convex == 1 and has_convex_quote_language(e.get("body") or "") else 0

        messages_detected.append({
            "sender": e.get("sender"),
            "sender_email": e.get("sender_email"),
            "date": e["dt"].strftime("%Y-%m-%d %H:%M"),
            "source": e.get("source"),
            "is_convex": is_convex,
            "is_convex_quote": is_convex_quote
        })

    quote_candidates_debug = []
    for e in quote_candidates:
        quote_candidates_debug.append({
            "sender": e.get("sender"),
            "sender_email": e.get("sender_email"),
            "date": e["dt"].strftime("%Y-%m-%d %H:%M"),
            "source": e.get("source")
        })

    return {
        "first_conversation_dt": first_dt,
        "first_quote_dt": first_quote_dt,
        "raw_email_count_detected_before_adjustment": raw_email_count,
        "email_count_adjustment_applied": "-3 with minimum 1",
        "email_count": email_count,
        "days_to_quote": days_to_quote,
        "late_quote": late_quote,
        "negotiation_fatigue": negotiation_fatigue,
        "messages_detected": messages_detected,
        "all_dates_detected": [
            e["dt"].strftime("%Y-%m-%d %H:%M")
            for e in events
        ],
        "quote_candidates": quote_candidates_debug
    }


def derive_supporting_rule_flags(combined_text):
    text = (combined_text or "").lower()
    compact = re.sub(r"\s+", " ", text)

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

    competitor_price_terms = [
        "undercut", "cheaper", "lower premium", "lower rate", "lower price",
        "better price", "better pricing", "more competitive", "competing market",
        "alternative market", "another market", "market pricing",
        "double the market pricing", "too expensive", "way too expensive",
        "not going to get near", "cannot get near", "can't get near",
        "pricing gap", "material pricing gap", "premium gap", "rate gap",
        "target price", "target pricing", "rate reduction target",
        "reduction target", "best pricing", "best price", "price sensitive",
        "pricing pressure", "competitive quote", "quoted lower", "quoted less",
        "bound elsewhere", "went with another market", "placed with another market"
    ]

    if any(x in compact for x in competitor_price_terms):
        flags["competitor_undercut_significantly_on_price"] = 1

    pricing_inelasticity_terms = [
        "technical price", "technical pricing", "technical rate",
        "target pricing", "target price", "best pricing", "best price",
        "pricing which is likely to bind", "likely to bind", "price to bind",
        "premium too high", "rate too high", "not competitive",
        "too expensive", "way too expensive", "material pricing gap",
        "pricing gap", "premium gap", "broker explicitly communicated the target",
        "asked convex to provide best pricing", "asked convex to improve pricing",
        "asked convex for best terms", "unable to meet target",
        "unable to match target", "could not meet target", "could not match target",
        "premium exceeded", "premium was above", "quoted premium",
        "quoted price was above", "price difference", "rate reduction"
    ]

    if any(x in compact for x in pricing_inelasticity_terms):
        flags["pricing_inelasticity"] = 1

    layer_terms_present = any(x in compact for x in [
        "layer", "layers", "layered", "primary", "excess", "attachment",
        "attach", "attaches", " xs ", " x/s ", "x/s", "quota share",
        "vertical placement", "tower", "placement tower", "programme structure",
        "program structure", "layer 1", "layer 2", "layer 3",
        "line on layer", "line on the layer", "primary layer", "excess layer",
        "requested layer structure", "alternative layer options", "layer options",
        "lower layer", "higher layer", "lower attachment", "higher attachment",
        "attachment point", "limit excess", "excess of"
    ])

    layer_mismatch_terms = any(x in compact for x in [
        "declined to participate on the broker's requested layer structure",
        "declined to participate on the requested layer structure",
        "requested layer structure", "alternative layer options",
        "could not support the requested layer", "could not support the layer",
        "unable to support the requested layer", "unable to support the layer",
        "not able to support the requested layer", "not able to support the layer",
        "below attachment is too low", "attachment is too low", "attachment too low",
        "attachment too high", "not able to offer on that layer",
        "cannot offer on that layer", "can't offer on that layer",
        "cannot write this layer", "can't write this layer",
        "not aligned with the broker's requested structure",
        "not aligned with the requested structure",
        "did not align with the evolving placement structure",
        "structure did not align", "different layer structure",
        "counter-offered with a different layer structure",
        "convex declined to participate", "convex did not quote",
        "no convex quote was issued", "only interested in the excess",
        "only interested in excess", "broker wanted primary",
        "broker required primary", "convex only wanted excess",
        "convex was only interested in excess", "primary but convex",
        "excess but broker", "lower layer was too low", "below attachment",
        "placement structure", "overall tower structure", "structure mismatch",
        "layer structure mismatch", "vertical structure mismatch"
    ])

    layer_conditional_offer_terms = any(x in compact for x in [
        "condition to sign", "condition to bind", "subject to sign",
        "subject to bind", "subject to order", "subject to minimum",
        "minimum signed", "sign no less", "signing no less", "no less than",
        "minimum line", "minimum participation", "conditional line",
        "conditional offer", "line to stand", "lts", "line on layer 1",
        "line on layer 2", "line on layer 3", "line on the primary",
        "line on the excess", "offered a line on", "offered a 5% line",
        "offered a 7.5% line", "offered an 8% line", "offered a 8% line",
        "offered a 10% line", "quoted a 5% line", "quoted a 7.5% line",
        "quoted an 8% line", "quoted a 8% line", "quoted a 10% line"
    ])

    layer_specific_capacity_present = (
        re.search(r"\b\d+(\.\d+)?\s*%\s+(line|share|capacity|participation)\b", compact) is not None
        and any(x in compact for x in [
            "layer", "xs", "x/s", "excess", "primary", "attachment", "tower", "quota share"
        ])
    )

    if layer_terms_present and (
        layer_mismatch_terms
        or layer_conditional_offer_terms
        or layer_specific_capacity_present
    ):
        flags["layer_structure_mismatch"] = 1

    sublimit_terms = [
        "sub-limit", "sub limit", "sublimit", "sub-limits", "sub limits",
        "restrictive sublimit", "restrictive sub limit", "restrictive sub-limits",
        "reduced sublimit", "reduced sub limit", "lower sublimit", "lower sub limit",
        "capped at", "cap on", "coverage restriction", "restricted cover",
        "narrower cover", "less favourable cover", "less favorable cover",
        "more restrictive", "nat cat sublimit", "natural catastrophe sublimit",
        "flood sublimit", "wind sublimit", "named windstorm sublimit",
        "nws sublimit", "earthquake sublimit", "eq sublimit", "bi sublimit",
        "business interruption sublimit", "storm/hail", "storm / hail",
        "snow pressure", "avalanche", "volcanic eruption", "high-hazard peril",
        "key natural catastrophe perils", "key nat cat perils"
    ]

    if any(x in compact for x in sublimit_terms):
        flags["restrictive_sub_limits"] = 1

    deductible_terms = [
        "deductible", "deductibles", "retention", "sir",
        "self insured retention", "self-insured retention", "minimum deductible",
        "deductible change", "deductible adjustment", "deductible increase",
        "increased deductible", "higher deductible", "reduced deductible",
        "alternative deductible", "deductible option", "deductible structure",
        "deductible mismatch", "named windstorm deductible", "nws deductible",
        "nat cat deductible", "natural catastrophe deductible", "5% min",
        "5% minimum", "minimum threshold", "retention appetite",
        "deductible alignment", "more favourable deductible", "more favorable deductible"
    ]

    if any(x in compact for x in deductible_terms):
        flags["deductible_mismatch"] = 1

    order_size_terms = [
        "capacity", "line size", "line %", "participation", "order",
        "full order", "increase your share", "increase our line", "increase the line",
        "smaller line", "reduced share", "reduced line", "bound convex to",
        "required a smaller participation", "smaller participation",
        "available participation", "available capacity", "capacity to fill",
        "fill the order", "fill the placement", "oversubscribed", "over-subscribed",
        "program was oversubscribed", "programme was oversubscribed",
        "not enough capacity", "limited capacity", "participation deficit",
        "line reduced", "share reduced", "10% line", "8% line", "7.5% line",
        "5.5%", "5% line"
    ]

    if any(x in compact for x in order_size_terms):
        flags["order_size_participation_deficit"] = 1

    broker_switch_terms = [
        "new broker", "broker changed", "different broker", "switch broker",
        "broker switch", "local office", "continue your contact through us",
        "not actively engaged", "another broker", "different placement team"
    ]

    if any(x in compact for x in broker_switch_terms):
        flags["broker_switch_displacement"] = 1

    preferred_market_strict_terms = [
        "preferred market", "preferred markets", "preferred panel", "panel market",
        "strategic partner", "strategic partnership", "incumbent market was selected",
        "incumbent market was preferred", "lead market was selected",
        "lead market was preferred", "bound with the lead", "bound with another market",
        "placed with another market", "placed with the incumbent", "placed with the lead",
        "went with another market", "went with the incumbent", "went with the lead",
        "already placed with", "already been placed with", "lead market preference",
        "market preference", "broker preference for another market",
        "client preference for another market", "axa xl has already been placed",
        "beazley has already been placed", "fm has already been placed",
        "liberty seguros", "everest insurance", "qbe", "sompo", "fidelis"
    ]

    false_preferred_patterns = [
        "broker ultimately bound convex",
        "bound convex to",
        "convex receiving a reduced share",
        "convex was bound to",
        "convex bound to"
    ]

    if any(x in compact for x in preferred_market_strict_terms):
        if not any(x in compact for x in false_preferred_patterns):
            flags["preferred_market_partnerships"] = 1

    facility_terms = [
        "facility", "line slip", "lineslip", "binder", "delegated",
        "pre-agreed", "pre negotiated", "pre-negotiated",
        "facility placement", "broker facility", "slip facility"
    ]

    if any(x in compact for x in facility_terms):
        flags["facility_line_slip_displacement"] = 1

    captive_terms = [
        "captive", "protected cell captive", "pcc", "self insure",
        "self-insure", "self insurance", "self-insurance", "retained more risk",
        "risk financing", "risk retention", "risk retention pool", "pooled risk",
        "securitization", "securitisation", "capital market", "retention strategy",
        "captive-like", "self-retention"
    ]

    if any(x in compact for x in captive_terms):
        flags["captive_expansion_securitization"] = 1

    composite_terms = [
        "multi-class", "multiclass", "multi class", "composite", "package",
        "bundled", "combined placement", "property and casualty",
        "property and liability", "combined programme", "combined program",
        "multi-line", "multiline"
    ]

    if any(x in compact for x in composite_terms):
        flags["composite_multi_class_bundling"] = 1

    return flags


def build_prompt(account_folder_name, combined_text, metadata, rule_flags):
    first_date = metadata["first_conversation_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_conversation_dt"] else None
    quote_date = metadata["first_quote_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_quote_dt"] else None

    return f"""
You are an expert London Market property insurance underwriting and placement analyst working for Convex.

BUSINESS CONTEXT:
Every account folder provided is already a confirmed NTU / not-taken-up / not-bound / not-written case.
Your task is not to decide whether it is NTU.
Your task is to infer the most likely commercial reason or reasons why Convex did not win / bind / write the placement.

VERY IMPORTANT EXPLANATION RULE:
The NTU_EXPLANATION must explain ONLY the selected commercial subcategories from this list:
- COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE
- PRICING_INELASTICITY
- LAYER_STRUCTURE_MISMATCH
- RESTRICTIVE_SUB_LIMITS
- DEDUCTIBLE_MISMATCH
- ORDER_SIZE_PARTICIPATION_DEFICIT
- BROKER_SWITCH_DISPLACEMENT
- PREFERRED_MARKET_PARTNERSHIPS
- FACILITY_LINE_SLIP_DISPLACEMENT
- CAPTIVE_EXPANSION_SECURITIZATION
- COMPOSITE_MULTI_CLASS_BUNDLING

Do NOT explain:
- LATE_QUOTE
- NEGOTIATION_FATIGUE
- first conversation date
- first Convex quote date
- days to quote
- quote timing
- email count
- conversation duration
- delay or late response

If only LATE_QUOTE and/or NEGOTIATION_FATIGUE are selected and no commercial subcategory is selected, return a blank NTU_EXPLANATION between the markers.

SYSTEM-EXTRACTED METADATA FOR CALCULATION ONLY:
FIRST_CONVERSATION_STARTED: {first_date}
FIRST_CONVEX_QUOTE_SENT: {quote_date}
RAW_EMAIL_COUNT_DETECTED_BEFORE_ADJUSTMENT: {metadata["raw_email_count_detected_before_adjustment"]}
EMAIL_COUNT_ADJUSTMENT: {metadata["email_count_adjustment_applied"]}
EMAIL_COUNT_DETECTED_AFTER_ADJUSTMENT: {metadata["email_count"]}
DAYS_TO_FIRST_QUOTE: {metadata["days_to_quote"]}
SYSTEM_LATE_QUOTE_RULE: {metadata["late_quote"]}
SYSTEM_NEGOTIATION_FATIGUE_RULE: {metadata["negotiation_fatigue"]}

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

SUBCATEGORY DEFINITIONS:

1. COMPETITOR_UNDERCUT_SIGNIFICANTLY_ON_PRICE:
Mark 1 when the email chain suggests that Convex lost or was disadvantaged because another insurer, lead, market, or alternative placement offered better economics.
This includes lower premium, lower rate, better price, more competitive terms, material pricing gap, target pricing gap, broker/client saying Convex was too expensive, or broker moving toward another quote because it was commercially better.
Also mark 1 if the chain says the broker/client asked Convex for best pricing because another market or target price was more competitive.

2. PRICING_INELASTICITY:
Mark 1 when Convex appears unable or unwilling to meet the broker/client's pricing expectation.
This includes technical pricing discipline, target price not being met, premium above target, material pricing gap, broker asking for best price, broker saying pricing is too expensive, or Convex not being able to reduce premium enough to bind.
If the explanation says quoted premium exceeded target, material pricing gap, best pricing, target of an amount, or pricing pressure, this should usually be 1.

3. LAYER_STRUCTURE_MISMATCH:
Act as a London Market property insurance placement expert.
Mark 1 when the issue relates to the placement layer, primary/excess position, quota share, attachment point, limit excess, tower structure, layer options, vertical placement, line-to-stand condition, signed line, written line, or conditional participation.

This must be marked 1 when:
- the broker requested one layer structure but Convex declined, countered, or could only support another structure;
- Convex declined to participate on the broker's requested layer structure;
- the broker presented alternative layer options and Convex could not support them;
- Convex offered a line on a specific layer but only with conditions such as LTS, line-to-stand, minimum signing, no less than X%, subject to order, or subject to minimum participation;
- Convex offered a smaller/different layer, attachment, or participation than requested;
- there is disagreement around primary vs excess, lower layer vs higher layer, attachment point, or quota share placement;
- the explanation says requested layer structure, alternative layer options, attachment mismatch, below attachment, counter-offered with a different layer structure, line on Layer 2, line to stand, or conditional line.

Do not require the exact word mismatch. If the broker's requested layer/tower/attachment/participation structure and Convex's offered structure do not naturally align, mark this as 1.

4. RESTRICTIVE_SUB_LIMITS:
Mark 1 when Convex's terms include restrictive, reduced, capped, narrower, or less favourable sublimits or coverage restrictions.
This includes NatCat, Flood, Earthquake, Wind, Named Windstorm, Storm/Hail, Snow Pressure, Avalanche, Volcanic Eruption, BI, CBI, or other key peril sublimits.
If the explanation says restrictive sublimits, sublimits on key natural catastrophe perils, capped at, reduced sublimit, narrower cover, or less attractive coverage, this should be 1.

5. DEDUCTIBLE_MISMATCH:
Mark 1 when deductible, retention, SIR, self-insured retention, minimum deductible, named windstorm deductible, NatCat deductible, or deductible change creates a placement issue.
This includes broker/client requesting a different deductible, deductible being higher than target, deductible change during negotiation, deductible adjustment from original terms, or deductible terms being less favourable than competing/lead terms.
If the explanation says deductible change, deductible adjustment, minimum deductible, named windstorm deductible, or retention appetite, this should be 1.

6. ORDER_SIZE_PARTICIPATION_DEFICIT:
Mark 1 when the issue relates to Convex's share, line size, order size, available capacity, participation percentage, signed line, written line, oversubscription, reduced share, or broker requiring a different/smaller/larger participation.
Examples:
- broker required 15% capacity but Convex offered less;
- Convex quoted 8% but broker bound 5.5%;
- program was oversubscribed;
- broker required smaller participation;
- Convex's line was not enough or was reduced;
- broker asked Convex to increase share or capacity.

7. BROKER_SWITCH_DISPLACEMENT:
Mark 1 only when there is evidence of broker change, local office displacement, another broker controlling the placement, or Convex being displaced because of a broker strategy or communication route.

8. PREFERRED_MARKET_PARTNERSHIPS:
Mark 1 only when another market/insurer/lead is explicitly selected, preferred, already placed, followed, or strategically favoured.
Do NOT mark this just because Convex was bound at a smaller share.
Do NOT mark this just because a broker negotiated Convex down.
Only mark when the text clearly says another market was preferred, selected, placed, followed, or had preferred/incumbent/lead status.
Examples:
- broker placed with AXA XL / Beazley / FM / QBE / Sompo / Liberty / Everest instead of Convex;
- another lead was already placed;
- broker/client preferred incumbent or panel market;
- placement followed a lead market and Convex did not win the preferred position.

9. FACILITY_LINE_SLIP_DISPLACEMENT:
Mark 1 when the risk was placed or likely placed through a facility, line slip, binder, delegated authority, pre-negotiated broker facility, or similar operational placement route.

10. NEGOTIATION_FATIGUE:
System-calculated only. Do not explain this in NTU_EXPLANATION.

11. LATE_QUOTE:
System-calculated only. Do not explain this in NTU_EXPLANATION.

12. CAPTIVE_EXPANSION_SECURITIZATION:
Mark 1 when the client retained risk through captive, protected cell captive, risk retention pool, self-insurance, capital markets, securitization/securitisation, or other alternative risk financing.
If the text says protected cell captive, PCC, risk retention pool, self-retention, captive-like structure, or client retained more risk, mark this as 1.

13. COMPOSITE_MULTI_CLASS_BUNDLING:
Mark 1 when property was bundled into a multi-class, composite, package, combined programme, or multi-line placement where Convex did not have suitable product/class participation.

DECISION RULES:
- Multiple categories can be 1.
- Do not mark everything.
- Mark only categories supported by actual commercial evidence in the chain.
- Do not use "no NTU evidence" or "successful placement" language.
- Do not explain LATE_QUOTE.
- Do not explain NEGOTIATION_FATIGUE.
- Do not mention dates, timing, email count, delays, or conversation duration inside NTU_EXPLANATION.
- Be careful with PREFERRED_MARKET_PARTNERSHIPS: do not mark unless another market/insurer/lead/preferred panel is clearly involved.

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
        "negotiation_fatigue": metadata["negotiation_fatigue"],
        "late_quote": metadata["late_quote"],
        "captive_expansion_securitization": safe_int(extract_value(raw, "CAPTIVE_EXPANSION_SECURITIZATION")),
        "composite_multi_class_bundling": safe_int(extract_value(raw, "COMPOSITE_MULTI_CLASS_BUNDLING")),
        "date_of_first_conversation_started": metadata["first_conversation_dt"].strftime("%Y-%m-%d %H:%M") if metadata["first_conversation_dt"] else None,
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
        "pricing_inelasticity",
        "layer_structure_mismatch",
        "restrictive_sub_limits",
        "deductible_mismatch",
        "order_size_participation_deficit",
        "facility_line_slip_displacement",
        "captive_expansion_securitization",
        "composite_multi_class_bundling"
    ]

    for k in strong_override_keys:
        if rule_flags.get(k, 0) == 1:
            result[k] = 1

    text_lower = (combined_text or "").lower()

    preferred_false_text = [
        "broker ultimately bound convex",
        "bound convex to",
        "convex receiving a reduced share",
        "convex was bound to",
        "convex bound to",
        "broker required a smaller participation",
        "smaller participation"
    ]

    preferred_true_text = [
        "preferred market",
        "preferred panel",
        "strategic partner",
        "incumbent market was selected",
        "incumbent market was preferred",
        "lead market was selected",
        "lead market was preferred",
        "bound with another market",
        "placed with another market",
        "placed with the incumbent",
        "placed with the lead",
        "went with another market",
        "went with the incumbent",
        "went with the lead",
        "already placed with",
        "broker preference for another market",
        "client preference for another market",
        "liberty seguros",
        "everest insurance",
        "axa xl has already been placed",
        "beazley has already been placed",
        "qbe",
        "sompo",
        "fidelis"
    ]

    if any(x in text_lower for x in preferred_false_text) and not any(x in text_lower for x in preferred_true_text):
        result["preferred_market_partnerships"] = 0

    if rule_flags.get("preferred_market_partnerships", 0) == 1:
        result["preferred_market_partnerships"] = 1

    if sum([safe_int(result.get(k)) for k in commercial_flag_keys]) == 0:
        if rule_flags.get("competitor_undercut_significantly_on_price", 0) == 1:
            result["competitor_undercut_significantly_on_price"] = 1
        elif rule_flags.get("pricing_inelasticity", 0) == 1:
            result["pricing_inelasticity"] = 1
        elif rule_flags.get("layer_structure_mismatch", 0) == 1:
            result["layer_structure_mismatch"] = 1
        elif rule_flags.get("restrictive_sub_limits", 0) == 1:
            result["restrictive_sub_limits"] = 1
        elif rule_flags.get("deductible_mismatch", 0) == 1:
            result["deductible_mismatch"] = 1
        elif rule_flags.get("order_size_participation_deficit", 0) == 1:
            result["order_size_participation_deficit"] = 1
        elif rule_flags.get("preferred_market_partnerships", 0) == 1:
            result["preferred_market_partnerships"] = 1
        else:
            result["pricing_inelasticity"] = 1

    explanation = result.get("ntu_explanation") or ""

    banned_patterns = [
        r"(?i).*late quote.*",
        r"(?i).*negotiation fatigue.*",
        r"(?i).*days to quote.*",
        r"(?i).*first conversation.*",
        r"(?i).*first convex quote.*",
        r"(?i).*quote timing.*",
        r"(?i).*conversation started.*",
        r"(?i).*quote was sent.*",
        r"(?i).*sent on \d{4}-\d{2}-\d{2}.*",
        r"(?i).*email count.*",
        r"(?i).*emails transferred.*",
        r"(?i).*number of emails.*",
        r"(?i).*conversation duration.*",
        r"(?i).*delay.*",
        r"(?i).*delayed.*",
        r"(?i).*response time.*",
        r"(?i).*days after.*"
    ]

    cleaned_lines = []
    for line in explanation.splitlines():
        line_strip = line.strip()
        if not line_strip:
            continue

        should_drop = False
        for bp in banned_patterns:
            if re.match(bp, line_strip):
                should_drop = True
                break

        if not should_drop:
            cleaned_lines.append(line)

    result["ntu_explanation"] = "\n".join(cleaned_lines).strip()

    system_metadata = {
        "first_conversation_started": result["date_of_first_conversation_started"],
        "first_convex_quote_sent": result["date_of_first_convex_quote_sent"],
        "raw_email_count_detected_before_adjustment": metadata["raw_email_count_detected_before_adjustment"],
        "email_count_adjustment_applied": metadata["email_count_adjustment_applied"],
        "email_count_detected_after_adjustment": metadata["email_count"],
        "days_to_first_quote": metadata["days_to_quote"],
        "late_quote_rule": "1 if days_to_first_quote > 4 else 0",
        "negotiation_fatigue_rule": "1 if adjusted email_count_detected > 20 else 0",
        "all_dates_detected": metadata["all_dates_detected"],
        "quote_candidates": metadata["quote_candidates"],
        "messages_detected": metadata["messages_detected"],
        "supporting_rule_flags": rule_flags
    }

    return result, raw, system_metadata


def insert_result(session, account_folder_name, result, files_processed, raw_response, system_metadata, run_id):
    raw_json_text = sql_escape(json.dumps(result, ensure_ascii=False))
    metadata_json_text = sql_escape(json.dumps(system_metadata, ensure_ascii=False))

    first_date = result.get('date_of_first_conversation_started')
    quote_date = result.get('date_of_first_convex_quote_sent')

    first_date_sql = 'NULL' if first_date is None else "'" + sql_escape(first_date) + "'"
    quote_date_sql = 'NULL' if quote_date is None else "'" + sql_escape(quote_date) + "'"

    days_value = result.get('days_to_first_quote')
    days_sql = 'NULL' if days_value is None else str(safe_int(days_value))

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
            DATE_OF_FIRST_CONVEX_QUOTE_SENT,
            NO_OF_EMAILS_TRANSFERRED_IN_BETWEEN,
            DAYS_TO_FIRST_QUOTE,
            FILES_PROCESSED,
            RAW_LLM_RESPONSE,
            RAW_SYSTEM_EXTRACTED_METADATA,
            PROCESSING_STATUS,
            ERROR_MESSAGE,
            RUN_ID,
            PROCESSED_AT,
            UPDATED_AT
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
            {quote_date_sql},
            {safe_int(result.get('no_of_emails_transferred_in_between'))},
            {days_sql},
            {files_processed},
            TO_VARIANT('{raw_json_text}'),
            TO_VARIANT('{metadata_json_text}'),
            'SUCCESS',
            NULL,
            '{sql_escape(run_id)}',
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP()
    """

    session.sql(q).collect()


def insert_failed_result(session, account_folder_name, error_message, files_processed, raw_response, run_id):
    q = f"""
        INSERT INTO {OUTPUT_TABLE} (
            ACCOUNT_FOLDER_NAME,
            FILES_PROCESSED,
            RAW_LLM_RESPONSE,
            PROCESSING_STATUS,
            ERROR_MESSAGE,
            RUN_ID,
            PROCESSED_AT,
            UPDATED_AT
        )
        SELECT
            '{sql_escape(account_folder_name)}',
            {files_processed},
            TO_VARIANT('{sql_escape(str(raw_response)[:10000])}'),
            'FAILED',
            '{sql_escape(error_message)}',
            '{sql_escape(run_id)}',
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP()
    """

    session.sql(q).collect()


def insert_error(session, account_folder_name, error_message, raw_response, files_processed, run_id):
    q = f"""
        INSERT INTO {ERROR_TABLE} (
            ACCOUNT_FOLDER_NAME,
            ERROR_MESSAGE,
            RAW_LLM_RESPONSE,
            FILES_PROCESSED,
            RUN_ID,
            ERROR_CREATED_AT
        )
        SELECT
            '{sql_escape(account_folder_name)}',
            '{sql_escape(error_message)}',
            '{sql_escape(str(raw_response)[:10000])}',
            {files_processed},
            '{sql_escape(run_id)}',
            CURRENT_TIMESTAMP()
    """

    session.sql(q).collect()


def main(session, LIMIT_N_FOLDERS):
    run_id = str(uuid.uuid4())

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

    all_account_folders = sorted(account_to_files.keys())

    selected_account_folders = []
    skipped_success = 0

    for account_folder in all_account_folders:
        success_count = session.sql(f"""
            SELECT COUNT(*) AS CNT
            FROM {OUTPUT_TABLE}
            WHERE ACCOUNT_FOLDER_NAME = '{sql_escape(account_folder)}'
              AND PROCESSING_STATUS = 'SUCCESS'
        """).collect()[0]['CNT']

        if success_count > 0:
            skipped_success += 1
            continue

        selected_account_folders.append(account_folder)

        if len(selected_account_folders) >= int(LIMIT_N_FOLDERS):
            break

    processed = 0
    failed = 0
    messages = []

    for account_folder in selected_account_folders:
        raw_response = ''
        files = account_to_files.get(account_folder, [])

        try:
            session.sql(f"""
                DELETE FROM {OUTPUT_TABLE}
                WHERE ACCOUNT_FOLDER_NAME = '{sql_escape(account_folder)}'
                  AND COALESCE(PROCESSING_STATUS, '') IN ('FAILED', 'IN_PROGRESS', '')
            """).collect()

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
                error_message = "No parsed text found"

                insert_failed_result(
                    session,
                    account_folder,
                    error_message,
                    len(files),
                    raw_response,
                    run_id
                )

                insert_error(
                    session,
                    account_folder,
                    error_message,
                    raw_response,
                    len(files),
                    run_id
                )

                messages.append(f"{account_folder}: FAILED - no parsed text")
                continue

            result, raw_response, system_metadata = classify_with_llm(
                session,
                account_folder,
                combined_text
            )

            session.sql(f"""
                DELETE FROM {OUTPUT_TABLE}
                WHERE ACCOUNT_FOLDER_NAME = '{sql_escape(account_folder)}'
                  AND COALESCE(PROCESSING_STATUS, '') <> 'SUCCESS'
            """).collect()

            insert_result(
                session,
                account_folder,
                result,
                len(files),
                raw_response,
                system_metadata,
                run_id
            )

            processed += 1
            messages.append(f"{account_folder}: SUCCESS - processed {len(files)} files")

        except Exception as e:
            failed += 1
            error_message = str(e)[:5000]

            session.sql(f"""
                DELETE FROM {OUTPUT_TABLE}
                WHERE ACCOUNT_FOLDER_NAME = '{sql_escape(account_folder)}'
                  AND COALESCE(PROCESSING_STATUS, '') IN ('FAILED', 'IN_PROGRESS', '')
            """).collect()

            insert_failed_result(
                session,
                account_folder,
                error_message,
                len(files),
                raw_response,
                run_id
            )

            insert_error(
                session,
                account_folder,
                error_message,
                raw_response,
                len(files),
                run_id
            )

            messages.append(f"{account_folder}: FAILED - {error_message[:250]}")

    return (
        f"Run ID: {run_id}; "
        f"Processed={processed}; "
        f"Failed={failed}; "
        f"Skipped already successful={skipped_success}; "
        f"Selected for this run={len(selected_account_folders)}. "
        f"Details: " + " | ".join(messages)
    )
$$;
