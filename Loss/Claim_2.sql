CREATE OR REPLACE PROCEDURE OPEN_MARKET_LOSS_HISTORY_EXTRACTION_4(
    MAX_ACCOUNTS NUMBER,
    ACCOUNT_NAME_FILTER STRING,
    AS_OF_YEAR NUMBER,
    FORCE_REPROCESS BOOLEAN
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'openpyxl')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import re
import os
import uuid
from io import BytesIO
from datetime import datetime

import openpyxl


STAGE_NAME = '@OPEN_MARKET_SUBMISSION'
ROOT_PREFIX = 'Open_Market/'

FILE_SELECTION_TABLE = 'OPEN_MARKET_LOSS_FILE_SELECTION_4'
EXTRACTION_TABLE = 'OPEN_MARKET_LOSS_HISTORY_EXTRACTION_4'
AGGREGATED_TABLE = 'OPEN_MARKET_LOSS_HISTORY_AGGREGATED_4'
PROCESSED_TABLE = 'OPEN_MARKET_LOSS_PROCESSED_ACCOUNTS_4'

SUPPORTED_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml', '.xlsx', '.xlsm'}
EXCEL_EXTENSIONS = {'.xlsx', '.xlsm'}
DIRECT_AI_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml'}

LOSS_KEYWORDS = [
    'loss history', 'loss record', 'loss run', 'loss runs', 'losses', 'loss',
    'claim history', 'claims history', 'claims external', 'claim', 'claims',
    'cat loss', 'cat losses', 'cat loss record',
    'total incurred', 'incurred net', 'gross claim incurred', 'gross incurred',
    'paid', 'outstanding', 'reinsurer payout', 'total payable by reinsurers',
    'aggregate erosion', 'yoa', 'uw year', 'policy year', 'period',
    'amount clf', 'amount gbp', 'amount usd', 'amount eur', '# losses'
]

SOFT_FILE_KEYWORDS = [
    'submission', 'slip', 'quote', 'mail', 'new business', 'renewal',
    'summary', 'bordereau', 'bor', 'convex'
]

NEGATIVE_KEYWORDS = [
    'statement of values', 'sov', 'construction', 'occupancy',
    'schedule of values', 'building values', 'tiv', 'exposure only'
]

MONTH_MAP = {
    'jan': 1, 'january': 1, 'ene': 1, 'enero': 1,
    'feb': 2, 'february': 2, 'febrero': 2,
    'mar': 3, 'march': 3, 'marzo': 3,
    'apr': 4, 'april': 4, 'abr': 4, 'abril': 4,
    'may': 5, 'mayo': 5,
    'jun': 6, 'june': 6, 'junio': 6,
    'jul': 7, 'july': 7, 'julio': 7,
    'aug': 8, 'august': 8, 'ago': 8, 'agosto': 8,
    'sep': 9, 'sept': 9, 'september': 9, 'septiembre': 9,
    'oct': 10, 'october': 10, 'octubre': 10,
    'nov': 11, 'november': 11, 'noviembre': 11,
    'dec': 12, 'december': 12, 'dic': 12, 'diciembre': 12
}


def clean_number(value):
    if value is None:
        return None
    text = str(value).strip()
    if text == '' or text.lower() in ('none', 'null', 'nan'):
        return None
    try:
        return float(text)
    except Exception:
        return None


def clean_int(value):
    number = clean_number(value)
    if number is None:
        return None
    return int(round(number))


def normalize_stage_relative_path(raw_name):
    if raw_name is None:
        return None

    name = str(raw_name).replace('\\', '/')

    if ROOT_PREFIX in name:
        return ROOT_PREFIX + name.split(ROOT_PREFIX, 1)[1]

    if name.startswith('@'):
        parts = name.split('/', 1)
        if len(parts) == 2:
            return parts[1]

    return name.lstrip('/')


def get_file_name(relative_path):
    return relative_path.split('/')[-1]


def get_extension(file_name):
    return os.path.splitext(file_name.lower())[1]


def get_account_folder(relative_path):
    rel = relative_path.replace('\\', '/')

    if rel.startswith(ROOT_PREFIX):
        remaining = rel[len(ROOT_PREFIX):]
    else:
        remaining = rel

    parts = remaining.split('/')

    if len(parts) >= 2:
        return parts[0]

    return None


def row_to_text(values):
    return ' | '.join(['' if v is None else str(v).strip() for v in values])


def is_total_or_subtotal_text(text):
    if text is None:
        return False

    t = str(text).lower()

    bad_markers = [
        'sub total',
        'subtotal',
        'grand total',
        '10 years',
        '10 year',
        '5 year average',
        'five year average',
        'average',
        'overall total',
        'total available'
    ]

    return any(x in t for x in bad_markers)


def parse_number(value):
    if value is None:
        return None

    if isinstance(value, int) or isinstance(value, float):
        return float(value)

    text = str(value).strip()

    if text == '':
        return None

    lowered = text.lower()

    if lowered in ('nil', 'none', 'null', 'n/a', 'na', '-', '--'):
        return 0.0

    negative = False

    if text.startswith('(') and text.endswith(')'):
        negative = True
        text = text[1:-1]

    text = text.replace('€', '').replace('$', '').replace('£', '')
    text = re.sub(r'\b(usd|gbp|eur|clf|cad|aud)\b', '', text, flags=re.I)
    text = text.strip()

    m = re.search(r'-?[\d.,]+', text)

    if not m:
        return None

    num = m.group(0)

    if ',' in num and '.' in num:
        last_comma = num.rfind(',')
        last_dot = num.rfind('.')

        if last_dot > last_comma:
            num = num.replace(',', '')
        else:
            num = num.replace('.', '').replace(',', '.')

    elif ',' in num:
        parts = num.split(',')

        if len(parts) > 2:
            num = ''.join(parts)
        else:
            left, right = parts[0], parts[1]
            if len(right) == 3 and len(left) >= 1:
                num = left + right
            else:
                num = left + '.' + right

    elif '.' in num:
        parts = num.split('.')

        if len(parts) > 2:
            num = ''.join(parts)
        else:
            left, right = parts[0], parts[1]
            if len(right) == 3 and len(left) >= 4:
                num = left + right

    try:
        parsed = float(num)
    except Exception:
        return None

    if negative:
        parsed = parsed * -1

    return parsed


def parse_int(value):
    num = parse_number(value)
    if num is None:
        return None
    return int(round(num))


def extract_year_from_text(text):
    if text is None:
        return None

    t = str(text).strip()

    m_range = re.search(r'\b((?:19|20)\d{2})\s*[-/]\s*(\d{2,4})\b', t)
    if m_range:
        return int(m_range.group(1))

    m_date = re.search(r'\b\d{1,2}[-/]\d{1,2}[-/]((?:19|20)\d{2})\b', t)
    if m_date:
        return int(m_date.group(1))

    m_year = re.search(r'\b((?:19|20)\d{2})\b', t)
    if m_year:
        return int(m_year.group(1))

    m_short = re.search(r'\b([a-zA-Z]{3,9})[-\s]?(\d{2})\b', t)
    if m_short:
        month = m_short.group(1).lower()
        yy = int(m_short.group(2))

        if month in MONTH_MAP:
            return 2000 + yy if yy < 50 else 1900 + yy

    return None


def detect_currency_from_text(text):
    if text is None:
        return None

    t = str(text).lower()

    if 'clf' in t:
        return 'CLF'
    if 'gbp' in t or '£' in t:
        return 'GBP'
    if 'usd' in t or '$' in t:
        return 'USD'
    if 'eur' in t or '€' in t:
        return 'EUR'
    if 'cad' in t:
        return 'CAD'
    if 'aud' in t:
        return 'AUD'

    return None


def is_bad_count_header(header_text):
    h = str(header_text or '').lower()

    bad = [
        'year', 'date', 'period', 'amount', 'incurred', 'paid',
        'outstanding', 'recovery', 'reserve', 'currency', 'policy'
    ]

    return any(x in h for x in bad)


def looks_like_header(values):
    line = row_to_text(values).lower()

    year_markers = [
        'event', 'period', 'yoa', 'uw year', 'policy year',
        'loss date', 'claim date', 'date', 'd.o.l', 'dol'
    ]

    amount_markers = [
        'amount', 'total incurred', 'incurred net', 'gross claim incurred',
        'gross incurred', 'total gbp', 'total usd', 'total eur', 'total clf',
        'amount clf', 'paid', 'outstanding', 'reinsurer payout',
        'total payable'
    ]

    count_markers = [
        '# losses', 'no. losses', 'number of losses', 'loss count',
        'claim count', 'number of claims'
    ]

    has_period = any(x in line for x in year_markers)
    has_amount = any(x in line for x in amount_markers)
    has_count = any(x in line for x in count_markers)

    return has_period and (has_amount or has_count)


def find_amount_col(headers):
    amount_priority = [
        'gross claim incurred',
        'total incurred 100%',
        'total incurred',
        'incurred net',
        'gross incurred',
        'total payable by reinsurers',
        'reinsurer payout',
        'total gbp',
        'total usd',
        'total eur',
        'total clf',
        'amount clf',
        'amount gbp',
        'amount usd',
        'amount eur',
        'amount',
        'paid',
        'outstanding'
    ]

    lowered = ['' if v is None else str(v).strip().lower() for v in headers]

    for keyword in amount_priority:
        for i, value in enumerate(lowered):
            if keyword in value:
                return i, str(headers[i]).strip()

    return None, None


def find_period_col(headers):
    period_priority = [
        'event',
        'period',
        'd.o.l',
        'dol',
        'date of loss',
        'loss date',
        'claim date',
        'notification date',
        'yoa',
        'uw year',
        'policy year',
        'date'
    ]

    lowered = ['' if v is None else str(v).strip().lower() for v in headers]

    for keyword in period_priority:
        for i, value in enumerate(lowered):
            if keyword in value:
                return i

    return None


def find_count_col(headers, amount_idx):
    lowered = ['' if v is None else str(v).strip().lower() for v in headers]

    explicit_keywords = [
        '# losses',
        'no. losses',
        'number of losses',
        'loss count',
        'claim count',
        'number of claims',
        'no of claims',
        '# claims'
    ]

    for keyword in explicit_keywords:
        for i, value in enumerate(lowered):
            if keyword in value and not is_bad_count_header(value):
                return i

    if amount_idx is not None:
        for i in range(amount_idx - 1, -1, -1):
            value = lowered[i].strip()
            if value in ('no.', 'no', '#') and not is_bad_count_header(value):
                return i

    return None


def is_event_level_row(period_text, source_row_text):
    text = f"{period_text or ''} {source_row_text or ''}".lower()

    event_markers = [
        'flood', 'fire', 'eq', 'earthquake', 'storm', 'hail',
        'wind', 'srcc', 'riot', 'rain', 'tornado', 'copiapo',
        'valparaiso', 'sismo', 'terremoto', 'inundacion',
        'loss', 'claim'
    ]

    return any(x in text for x in event_markers)


def read_stage_file_bytes(session, relative_path):
    stage_location = f"{STAGE_NAME}/{relative_path}"
    stream = session.file.get_stream(stage_location)
    return stream.read()


def extract_excel_loss_rows(session, file_info):
    data = read_stage_file_bytes(session, file_info["file_path"])
    wb = openpyxl.load_workbook(BytesIO(data), data_only=True, read_only=True)

    extracted = []

    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]

        all_rows = []
        for row in ws.iter_rows(values_only=True):
            all_rows.append(list(row))

        for row_idx, header_values in enumerate(all_rows):
            if not looks_like_header(header_values):
                continue

            period_idx = find_period_col(header_values)
            amount_idx, amount_type = find_amount_col(header_values)

            if amount_idx is None:
                continue

            count_idx = find_count_col(header_values, amount_idx)

            header_text = row_to_text(header_values)
            currency = detect_currency_from_text(header_text) or detect_currency_from_text(sheet_name)

            blank_streak = 0

            for data_idx in range(row_idx + 1, len(all_rows)):
                data_values = all_rows[data_idx]
                source_row_text = row_to_text(data_values)

                cleaned = source_row_text.strip().replace('|', '').strip()

                if cleaned == '':
                    blank_streak += 1
                    if blank_streak >= 20:
                        break
                    continue

                blank_streak = 0

                if is_total_or_subtotal_text(source_row_text):
                    continue

                period_text = None

                if period_idx is not None and period_idx < len(data_values):
                    period_text = data_values[period_idx]

                if period_text is None or str(period_text).strip() == '':
                    period_text = source_row_text

                loss_year = extract_year_from_text(period_text)

                if loss_year is None:
                    loss_year = extract_year_from_text(source_row_text)

                if loss_year is None:
                    continue

                if amount_idx >= len(data_values):
                    continue

                loss_amount = parse_number(data_values[amount_idx])

                if loss_amount is None:
                    continue

                row_currency = currency or detect_currency_from_text(source_row_text) or 'UNKNOWN'

                claim_count = None

                if count_idx is not None and count_idx < len(data_values):
                    count_header = header_values[count_idx]
                    if not is_bad_count_header(count_header):
                        claim_count = parse_int(data_values[count_idx])

                if claim_count is None:
                    if is_event_level_row(period_text, source_row_text):
                        claim_count = 1
                    else:
                        claim_count = None

                extracted.append({
                    "loss_year": loss_year,
                    "period_text": str(period_text),
                    "loss_date": str(period_text) if re.search(r'\d{1,2}[-/]\d{1,2}[-/]\d{2,4}', str(period_text)) else None,
                    "claim_count": claim_count,
                    "loss_amount": loss_amount,
                    "currency": row_currency,
                    "amount_type": amount_type,
                    "source_sheet_name": sheet_name,
                    "source_row_text": source_row_text,
                    "include_in_aggregation": True,
                    "confidence": 1.0,
                    "extraction_reason": "Extracted deterministically from Excel table header and row values."
                })

    return extracted


def list_stage_files(session):
    rows = session.sql(f"LIST {STAGE_NAME}/{ROOT_PREFIX}").collect()

    files = []

    for row in rows:
        raw_name = row[0]
        size = row[1] if len(row) > 1 else None
        last_modified = row[3] if len(row) > 3 else None

        relative_path = normalize_stage_relative_path(raw_name)

        if relative_path is None:
            continue

        file_name = get_file_name(relative_path)
        extension = get_extension(file_name)

        if extension not in SUPPORTED_EXTENSIONS:
            continue

        account_folder = get_account_folder(relative_path)

        if account_folder is None:
            continue

        files.append({
            "account_folder": account_folder,
            "file_name": file_name,
            "file_path": relative_path,
            "extension": extension,
            "size": size,
            "last_modified": str(last_modified) if last_modified is not None else None
        })

    return files


def get_ai_response_format_json():
    schema = {
        "schema": {
            "type": "object",
            "properties": {
                "loss_table": {
                    "description": (
                        "Extract claim/loss history rows only. Look for sections/tables called Loss History, "
                        "Loss Record, CAT Loss Record, Claims External, Loss Runs, 5 Year Net Losses, or similar."
                    ),
                    "type": "object",
                    "column_ordering": [
                        "loss_year",
                        "period_text",
                        "loss_date",
                        "claim_count",
                        "loss_amount",
                        "currency",
                        "amount_type",
                        "source_row_text",
                        "include_in_aggregation",
                        "extraction_reason"
                    ],
                    "properties": {
                        "loss_year": {
                            "description": "Year of loss. For 2015-16 use 2015. For 24-03-2015 use 2015. For jul-17 or ago-19 use 2017 or 2019.",
                            "type": "array"
                        },
                        "period_text": {
                            "description": "Original period, event, D.O.L, policy year, or date text.",
                            "type": "array"
                        },
                        "loss_date": {
                            "description": "Loss date if available.",
                            "type": "array"
                        },
                        "claim_count": {
                            "description": "Use explicit # Losses, No. of claims, or count column if present. Never use year, policy year, UW year, period, or date as claim_count. If each row is a single event/claim and no count is present, use 1. If only amount by year is present and no count exists, leave blank.",
                            "type": "array"
                        },
                        "loss_amount": {
                            "description": "Main loss amount. Prefer Total/Gross/Net Incurred, Total GBP/USD/EUR/CLF, Amount CLF, Reinsurer Payout, or Total Payable by Reinsurers.",
                            "type": "array"
                        },
                        "currency": {
                            "description": "Currency code such as USD, GBP, EUR, CLF, CAD, AUD, or UNKNOWN.",
                            "type": "array"
                        },
                        "amount_type": {
                            "description": "The exact amount column used.",
                            "type": "array"
                        },
                        "source_row_text": {
                            "description": "Exact source row/table text.",
                            "type": "array"
                        },
                        "include_in_aggregation": {
                            "description": "False for subtotal, grand total, average, 5 year average, or 10 years total rows.",
                            "type": "array"
                        },
                        "extraction_reason": {
                            "description": "Brief explanation of the extraction.",
                            "type": "array"
                        }
                    }
                }
            }
        }
    }

    return json.dumps(schema)


def call_ai_extract_for_file(session, relative_path):
    response_format = get_ai_response_format_json()

    query = """
        SELECT AI_EXTRACT(
            file => TO_FILE(?, ?),
            responseFormat => PARSE_JSON(?),
            scores => TRUE
        )
    """

    return session.sql(query, params=[STAGE_NAME, relative_path, response_format]).collect()[0][0]


def parse_ai_result(result):
    if result is None:
        return []

    if isinstance(result, str):
        try:
            obj = json.loads(result)
        except Exception:
            return []
    else:
        obj = result

    response = obj.get("response", {})
    scoring = obj.get("scoring", {})

    table = response.get("loss_table", {})

    if not table:
        return []

    max_len = 0

    for value in table.values():
        if isinstance(value, list):
            max_len = max(max_len, len(value))

    confidence = None

    try:
        confidence = scoring.get("scores", {}).get("loss_table", {}).get("score")
    except Exception:
        confidence = None

    rows = []

    for i in range(max_len):
        raw = {}

        for key, arr in table.items():
            if isinstance(arr, list) and i < len(arr):
                raw[key] = arr[i]
            else:
                raw[key] = None

        source_text = raw.get("source_row_text")
        period_text = raw.get("period_text")
        loss_year = extract_year_from_text(period_text) or extract_year_from_text(source_text) or parse_int(raw.get("loss_year"))
        loss_amount = parse_number(raw.get("loss_amount"))

        if loss_year is None or loss_amount is None:
            continue

        include_raw = raw.get("include_in_aggregation")

        if include_raw is None:
            include = not is_total_or_subtotal_text(source_text)
        else:
            include = str(include_raw).strip().lower() in ('true', 'yes', '1')

        if is_total_or_subtotal_text(source_text):
            include = False

        currency = raw.get("currency") or detect_currency_from_text(source_text) or 'UNKNOWN'

        claim_count = parse_int(raw.get("claim_count"))

        if claim_count is not None:
            if claim_count == loss_year or claim_count > 10000:
                claim_count = None

        if claim_count is None and is_event_level_row(period_text, source_text):
            claim_count = 1

        rows.append({
            "loss_year": loss_year,
            "period_text": period_text,
            "loss_date": raw.get("loss_date"),
            "claim_count": claim_count,
            "loss_amount": loss_amount,
            "currency": currency,
            "amount_type": raw.get("amount_type"),
            "source_sheet_name": None,
            "source_row_text": source_text,
            "include_in_aggregation": include,
            "confidence": confidence,
            "extraction_reason": raw.get("extraction_reason")
        })

    return rows


def score_excel_file(session, file_info):
    try:
        rows = extract_excel_loss_rows(session, file_info)

        if len(rows) == 0:
            return 0.0, False, None

        file_name = file_info["file_name"].lower()
        score = 90 + min(len(rows), 30)

        if any(k in file_name for k in ['loss', 'claim', 'claims', 'cat']):
            score += 30

        return float(score), True, None

    except Exception as e:
        return 0.0, False, str(e)


def score_non_excel_file_base(file_info):
    file_name = file_info["file_name"].lower()
    score = 0

    for keyword in LOSS_KEYWORDS:
        if keyword in file_name:
            score += 15

    for keyword in SOFT_FILE_KEYWORDS:
        if keyword in file_name:
            score += 8

    for keyword in NEGATIVE_KEYWORDS:
        if keyword in file_name:
            score -= 20

    if file_info["extension"] in {'.pdf', '.docx', '.doc'}:
        score += 8

    if file_info["extension"] == '.eml':
        score += 5

    return float(score)


def score_non_excel_file_content(session, file_info, base_score):
    try:
        rows = parse_ai_result(call_ai_extract_for_file(session, file_info["file_path"]))

        if len(rows) > 0:
            return base_score + 120 + min(len(rows), 30), True, None, rows

        return base_score, False, None, []

    except Exception as e:
        return base_score, False, str(e), []


def insert_file_selection(session, run_id, file_info, score, content_found, selected, attempted, row_count, rank, reason, status, error):
    query = f"""
        INSERT INTO {FILE_SELECTION_TABLE} (
            RUN_ID,
            ACCOUNT_FOLDER,
            FILE_NAME,
            FILE_PATH,
            FILE_EXTENSION,
            FILE_SIZE,
            LAST_MODIFIED,
            LOSS_RELEVANCE_SCORE,
            CONTENT_LOSS_FOUND,
            SELECTED_FOR_EXTRACTION,
            ATTEMPTED_EXTRACTION,
            EXTRACTION_ROW_COUNT,
            SELECTION_RANK,
            SELECTION_REASON,
            PARSE_STATUS,
            ERROR_MESSAGE
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    session.sql(query, params=[
        run_id,
        file_info["account_folder"],
        file_info["file_name"],
        file_info["file_path"],
        file_info["extension"],
        file_info["size"],
        file_info["last_modified"],
        score,
        content_found,
        selected,
        attempted,
        row_count,
        rank,
        reason,
        status,
        error
    ]).collect()


def insert_loss_row(session, run_id, account_folder, file_info, row):
    loss_year = clean_int(row.get("loss_year"))
    claim_count = clean_number(row.get("claim_count"))
    loss_amount = clean_number(row.get("loss_amount"))

    if loss_year is None:
        return False

    if loss_amount is None:
        return False

    include_value = row.get("include_in_aggregation")

    if include_value is None:
        include_value = True

    if is_total_or_subtotal_text(row.get("source_row_text")):
        include_value = False

    query = f"""
        INSERT INTO {EXTRACTION_TABLE} (
            RUN_ID,
            ACCOUNT_FOLDER,
            SOURCE_FILE_NAME,
            SOURCE_FILE_PATH,
            SOURCE_FILE_TYPE,
            LOSS_YEAR,
            PERIOD_TEXT,
            LOSS_DATE,
            CLAIM_COUNT,
            LOSS_AMOUNT,
            CURRENCY,
            AMOUNT_TYPE,
            SOURCE_SHEET_NAME,
            SOURCE_ROW_TEXT,
            INCLUDE_IN_AGGREGATION,
            CONFIDENCE,
            EXTRACTION_REASON
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    session.sql(query, params=[
        run_id,
        account_folder,
        file_info["file_name"],
        file_info["file_path"],
        file_info["extension"],
        loss_year,
        row.get("period_text"),
        row.get("loss_date"),
        claim_count,
        loss_amount,
        row.get("currency") or 'UNKNOWN',
        row.get("amount_type"),
        row.get("source_sheet_name"),
        row.get("source_row_text"),
        include_value,
        row.get("confidence"),
        row.get("extraction_reason")
    ]).collect()

    return True


def aggregate_account(session, run_id, account_folder, as_of_year):
    if as_of_year is None or int(as_of_year) <= 0:
        as_of_year = datetime.now().year
    else:
        as_of_year = int(as_of_year)

    start_year = as_of_year - 10

    query = f"""
        SELECT
            MIN(LOSS_YEAR),
            MAX(LOSS_YEAR),
            COUNT(DISTINCT LOSS_YEAR),
            SUM(COALESCE(CLAIM_COUNT, 0)),
            SUM(COALESCE(LOSS_AMOUNT, 0)),
            SUM(CASE WHEN LOSS_YEAR BETWEEN ? AND ? THEN COALESCE(CLAIM_COUNT, 0) ELSE 0 END),
            SUM(CASE WHEN LOSS_YEAR BETWEEN ? AND ? THEN COALESCE(LOSS_AMOUNT, 0) ELSE 0 END)
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND INCLUDE_IN_AGGREGATION = TRUE
          AND LOSS_YEAR IS NOT NULL
    """

    result = session.sql(query, params=[
        start_year,
        as_of_year,
        start_year,
        as_of_year,
        run_id,
        account_folder
    ]).collect()[0]

    currency_query = f"""
        SELECT CURRENCY, COUNT(*) AS CNT
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND INCLUDE_IN_AGGREGATION = TRUE
          AND CURRENCY IS NOT NULL
          AND CURRENCY <> 'UNKNOWN'
        GROUP BY CURRENCY
        ORDER BY CNT DESC
        LIMIT 1
    """

    currency_rows = session.sql(currency_query, params=[run_id, account_folder]).collect()
    currency = currency_rows[0][0] if currency_rows else 'UNKNOWN'

    min_year = clean_int(result[0])
    max_year = clean_int(result[1])
    available_year_count = clean_int(result[2])
    total_claim_count = clean_number(result[3])
    total_loss_amount = clean_number(result[4])
    last_10_claim_count = clean_number(result[5])
    last_10_loss_amount = clean_number(result[6])

    if available_year_count is None or available_year_count == 0:
        quality = 'NO_USABLE_LOSS_ROWS'
        reason = 'No usable loss rows were extracted.'
    elif currency == 'UNKNOWN':
        quality = 'CURRENCY_UNKNOWN'
        reason = 'Loss rows extracted, but currency could not be identified.'
    else:
        quality = 'OK'
        reason = 'Loss rows extracted and aggregated successfully.'

    insert_query = f"""
        INSERT INTO {AGGREGATED_TABLE} (
            RUN_ID,
            ACCOUNT_FOLDER,
            MIN_LOSS_YEAR,
            MAX_LOSS_YEAR,
            AVAILABLE_LOSS_YEAR_COUNT,
            TOTAL_AVAILABLE_CLAIM_COUNT,
            TOTAL_AVAILABLE_LOSS_AMOUNT,
            LAST_10_YEAR_CLAIM_COUNT,
            LAST_10_YEAR_LOSS_AMOUNT,
            CURRENCY,
            DATA_QUALITY_FLAG,
            AGGREGATION_REASON
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    session.sql(insert_query, params=[
        run_id,
        account_folder,
        min_year,
        max_year,
        available_year_count,
        total_claim_count,
        total_loss_amount,
        last_10_claim_count,
        last_10_loss_amount,
        currency,
        quality,
        reason
    ]).collect()


def mark_processed(session, account_folder, run_id, status, error_message):
    session.sql(
        f"DELETE FROM {PROCESSED_TABLE} WHERE ACCOUNT_FOLDER = ?",
        params=[account_folder]
    ).collect()

    session.sql(
        f"""
        INSERT INTO {PROCESSED_TABLE} (
            ACCOUNT_FOLDER,
            LAST_RUN_ID,
            STATUS,
            ERROR_MESSAGE
        )
        VALUES (?, ?, ?, ?)
        """,
        params=[account_folder, run_id, status, error_message]
    ).collect()


def delete_existing_for_account(session, account_folder):
    session.sql(
        f"DELETE FROM {EXTRACTION_TABLE} WHERE ACCOUNT_FOLDER = ?",
        params=[account_folder]
    ).collect()

    session.sql(
        f"DELETE FROM {AGGREGATED_TABLE} WHERE ACCOUNT_FOLDER = ?",
        params=[account_folder]
    ).collect()


def get_successfully_processed_accounts(session):
    rows = session.sql(
        f"SELECT ACCOUNT_FOLDER FROM {PROCESSED_TABLE} WHERE STATUS = 'SUCCESS'"
    ).collect()

    return set([r[0] for r in rows])


def run(session, max_accounts, account_name_filter, as_of_year, force_reprocess):
    run_id = str(uuid.uuid4())

    if max_accounts is None or int(max_accounts) <= 0:
        max_accounts = 1
    else:
        max_accounts = int(max_accounts)

    account_filter = account_name_filter.strip() if account_name_filter else None
    force_reprocess = bool(force_reprocess)

    all_files = list_stage_files(session)

    if account_filter:
        all_files = [
            f for f in all_files
            if account_filter.lower() in f["account_folder"].lower()
        ]

    by_account = {}

    for file_info in all_files:
        by_account.setdefault(file_info["account_folder"], []).append(file_info)

    processed_success = set()

    if not force_reprocess and not account_filter:
        processed_success = get_successfully_processed_accounts(session)

    candidate_accounts = [
        acc for acc in sorted(by_account.keys())
        if force_reprocess or account_filter or acc not in processed_success
    ]

    selected_accounts = candidate_accounts[:max_accounts]

    processed_accounts = 0
    selected_files_count = 0
    extracted_rows_count = 0
    errors = []

    for account_folder in selected_accounts:
        delete_existing_for_account(session, account_folder)

        files = by_account[account_folder]
        scored_files = []
        precomputed_rows_by_file = {}

        for file_info in files:
            try:
                if file_info["extension"] in EXCEL_EXTENSIONS:
                    score, content_found, error = score_excel_file(session, file_info)

                else:
                    base_score = score_non_excel_file_base(file_info)

                    should_probe = (
                        base_score > 0
                        or file_info["extension"] in {'.docx', '.doc', '.pdf', '.eml'}
                    )

                    if should_probe:
                        score, content_found, error, rows = score_non_excel_file_content(session, file_info, base_score)
                        if rows:
                            precomputed_rows_by_file[file_info["file_path"]] = rows
                    else:
                        score = base_score
                        content_found = False
                        error = None

                scored_files.append({
                    "file_info": file_info,
                    "score": score,
                    "content_found": content_found,
                    "error": error
                })

            except Exception as e:
                scored_files.append({
                    "file_info": file_info,
                    "score": 0.0,
                    "content_found": False,
                    "error": str(e)
                })

        scored_files = sorted(scored_files, key=lambda x: x["score"], reverse=True)

        inserted_for_account = 0
        selected_file_path = None

        for idx, item in enumerate(scored_files[:10], start=1):
            file_info = item["file_info"]

            if item["score"] <= 0:
                continue

            row_count = 0

            try:
                if file_info["file_path"] in precomputed_rows_by_file:
                    rows = precomputed_rows_by_file[file_info["file_path"]]
                elif file_info["extension"] in EXCEL_EXTENSIONS:
                    rows = extract_excel_loss_rows(session, file_info)
                else:
                    rows = parse_ai_result(call_ai_extract_for_file(session, file_info["file_path"]))

                for row in rows:
                    if insert_loss_row(session, run_id, account_folder, file_info, row):
                        row_count += 1

                if row_count > 0:
                    inserted_for_account = row_count
                    selected_file_path = file_info["file_path"]
                    break

            except Exception as e:
                item["error"] = str(e)

        for idx, item in enumerate(scored_files, start=1):
            file_info = item["file_info"]
            selected = selected_file_path == file_info["file_path"]
            attempted = idx <= 10 and item["score"] > 0
            row_count = inserted_for_account if selected else 0

            if selected:
                reason = 'Selected because it produced usable loss-history rows.'
                status = 'SELECTED_SUCCESS'
            elif attempted:
                reason = 'Attempted as fallback candidate but did not produce usable rows.'
                status = 'ATTEMPTED_NO_ROWS' if item["error"] is None else 'ATTEMPT_ERROR'
            else:
                reason = 'Not attempted because higher-scoring candidates were tried first.'
                status = 'SCORED'

            insert_file_selection(
                session=session,
                run_id=run_id,
                file_info=file_info,
                score=item["score"],
                content_found=item["content_found"],
                selected=selected,
                attempted=attempted,
                row_count=row_count,
                rank=idx,
                reason=reason,
                status=status,
                error=item["error"]
            )

        if inserted_for_account > 0:
            try:
                aggregate_account(session, run_id, account_folder, as_of_year)
                mark_processed(session, account_folder, run_id, 'SUCCESS', None)

                processed_accounts += 1
                selected_files_count += 1
                extracted_rows_count += inserted_for_account

            except Exception as e:
                error_message = f"Aggregation error: {str(e)}"
                mark_processed(session, account_folder, run_id, 'ERROR', error_message)
                errors.append(f"{account_folder}: {error_message}")

        else:
            error_message = 'No candidate file produced usable loss-history rows.'
            mark_processed(session, account_folder, run_id, 'ERROR', error_message)
            errors.append(f"{account_folder}: {error_message}")

    summary = {
        "run_id": run_id,
        "accounts_seen": len(by_account),
        "accounts_skipped_success_previous_runs": len(processed_success),
        "accounts_attempted": len(selected_accounts),
        "accounts_processed": processed_accounts,
        "selected_files_count": selected_files_count,
        "extracted_rows_count": extracted_rows_count,
        "error_count": len(errors),
        "errors_sample": errors[:10]
    }

    return json.dumps(summary, indent=2)
$$;
