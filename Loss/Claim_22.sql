CREATE OR REPLACE PROCEDURE OPEN_MARKET_LOSS_HISTORY_EXTRACTION_6(
    MAX_ACCOUNTS NUMBER,
    ACCOUNT_NAME_FILTER STRING,
    AS_OF_YEAR NUMBER
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

FILE_SELECTION_TABLE = 'OPEN_MARKET_LOSS_FILE_SELECTION_6'
EXTRACTION_TABLE = 'OPEN_MARKET_LOSS_HISTORY_EXTRACTION_6'
AGGREGATED_TABLE = 'OPEN_MARKET_LOSS_HISTORY_AGGREGATED_6'

SUPPORTED_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml', '.xlsx', '.xlsm'}
EXCEL_EXTENSIONS = {'.xlsx', '.xlsm'}
DIRECT_AI_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml'}

MAX_CANDIDATE_FILES_PER_ACCOUNT = 6
AGGREGATION_START_YEAR_FIXED = 2015

STRONG_LOSS_KEYWORDS = [
    'loss history',
    'loss histories',
    'loss record',
    'loss records',
    'loss run',
    'loss runs',
    'cat loss',
    'cat losses',
    'claim history',
    'claims history',
    'claims experience',
    'large loss',
    'large losses'
]

MEDIUM_LOSS_KEYWORDS = [
    'loss',
    'losses',
    'claim',
    'claims',
    'cat',
    'incurred',
    'paid',
    'outstanding',
    'reinsurer payout',
    'total payable',
    'aggregate erosion',
    'yoa',
    'uw year',
    'policy year'
]

HELPFUL_DOC_KEYWORDS = [
    'submission',
    'slip',
    'quote',
    'mail',
    'email',
    'new business',
    'renewal',
    'convex'
]

NEGATIVE_KEYWORDS = [
    'statement of values',
    'sov',
    'schedule of values',
    'construction',
    'occupancy',
    'building values',
    'tiv',
    'exposure only',
    'engineering',
    'risk survey',
    'modelling report',
    'modeling report',
    'rate adjustment'
]


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


def is_blank_row(values):
    return row_to_text(values).strip().replace('|', '').strip() == ''


def is_total_or_subtotal_text(text):
    if text is None:
        return False

    t = str(text).lower()

    bad_markers = [
        'sub total',
        'subtotal',
        'grand total',
        'total years',
        '10 years',
        'ten years',
        '5 year average',
        'five year average',
        'average',
        'overall total',
        'total available',
        'all years total'
    ]

    return any(x in t for x in bad_markers)


def safe_float(value):
    if value is None:
        return None

    if isinstance(value, (int, float)):
        return float(value)

    text = str(value).strip()

    if text == '':
        return None

    lowered = text.lower()

    if lowered in ('nil', 'none', 'null', 'n/a', 'na', '-', '--', 'no loss', 'no losses'):
        return 0.0

    negative = False

    if text.startswith('(') and text.endswith(')'):
        negative = True
        text = text[1:-1]

    text = text.replace('$', '')
    text = text.replace('£', '')
    text = text.replace('€', '')

    for ccy in ['USD', 'GBP', 'EUR', 'CAD', 'AUD', 'CLF', 'usd', 'gbp', 'eur', 'cad', 'aud', 'clf']:
        text = text.replace(ccy, '')

    text = text.strip()

    m = re.search(r'-?[\d,.]+', text)

    if not m:
        return None

    number_text = m.group(0)

    if ',' in number_text and '.' in number_text:
        last_comma = number_text.rfind(',')
        last_dot = number_text.rfind('.')

        if last_comma > last_dot:
            number_text = number_text.replace('.', '').replace(',', '.')
        else:
            number_text = number_text.replace(',', '')

    elif ',' in number_text:
        parts = number_text.split(',')

        if len(parts) > 1 and len(parts[-1]) == 3:
            number_text = number_text.replace(',', '')
        else:
            number_text = number_text.replace(',', '.')

    elif '.' in number_text:
        parts = number_text.split('.')

        if len(parts) > 2:
            number_text = ''.join(parts[:-1]) + '.' + parts[-1]

    try:
        number = float(number_text)
    except Exception:
        return None

    if negative:
        number = number * -1

    return number


def safe_int(value):
    number = safe_float(value)

    if number is None:
        return None

    return int(round(number))


def extract_year_from_text(text):
    if text is None:
        return None

    t = str(text)

    m_range = re.search(r'\b((?:19|20)\d{2})\s*[-/]\s*(\d{2,4})\b', t)
    if m_range:
        return int(m_range.group(1))

    m = re.search(r'\b(?:19|20)\d{2}\b', t)
    if m:
        return int(m.group(0))

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


def sanitize_claim_count(raw_claim_count, loss_year, source_text, count_header=None):
    if count_header is not None:
        header = str(count_header).lower()

        if 'risk' in header or 'risks' in header:
            return None

        if 'amount' in header or 'incurred' in header or 'paid' in header or 'outstanding' in header:
            return None

        if 'reserve' in header or 'recovery' in header or 'premium' in header:
            return None

    claim_count = safe_int(raw_claim_count)

    if claim_count is None:
        return None

    if claim_count < 0:
        return None

    if loss_year is not None and claim_count == int(loss_year):
        return None

    if 1900 <= claim_count <= 2099:
        return None

    if claim_count > 10000:
        return None

    return claim_count


def looks_like_header(values):
    line = row_to_text(values).lower()

    period_markers = [
        'event',
        'period',
        'yoa',
        'uw year',
        'policy year',
        'loss date',
        'date of loss',
        'claim date',
        'd.o.l',
        'dol'
    ]

    amount_markers = [
        'amount clf',
        'amount usd',
        'amount gbp',
        'amount eur',
        'amount cad',
        'amount aud',
        'gross claim incurred',
        'gross incurred',
        'total incurred',
        'incurred net',
        'total gbp',
        'total usd',
        'total eur',
        'total clf',
        'total cad',
        'total aud',
        'paid gbp',
        'paid usd',
        'outstanding gbp',
        'outstanding usd',
        'amount',
        'claim incurred'
    ]

    has_period = any(x in line for x in period_markers)
    has_amount = any(x in line for x in amount_markers)

    return has_period and has_amount


def find_column_indexes(header_values):
    period_idx = None
    amount_idx = None
    count_idx = None

    lowered = ['' if v is None else str(v).strip().lower() for v in header_values]

    period_priority = [
        'period',
        'date of loss',
        'loss date',
        'd.o.l',
        'dol',
        'event',
        'yoa',
        'uw year',
        'policy year',
        'claim date',
        'date'
    ]

    amount_priority = [
        'amount clf',
        'amount usd',
        'amount gbp',
        'amount eur',
        'amount cad',
        'amount aud',
        'gross claim incurred',
        'gross incurred',
        'total incurred 100',
        'total incurred',
        'total claim incurred',
        'claim incurred',
        'incurred net',
        'total payable by reinsurers',
        'reinsurer payout',
        'total gbp',
        'total usd',
        'total eur',
        'total clf',
        'total cad',
        'total aud',
        'amount',
        'paid gbp',
        'paid usd',
        'paid eur',
        'paid',
        'outstanding gbp',
        'outstanding usd',
        'outstanding'
    ]

    negative_amount_headers = [
        'recovery',
        'recoveries',
        'reserve',
        'reserves',
        'cost reserves',
        'salvage',
        'deductible',
        'premium'
    ]

    for keyword in period_priority:
        for i, value in enumerate(lowered):
            if keyword in value:
                period_idx = i
                break
        if period_idx is not None:
            break

    for keyword in amount_priority:
        for i, value in enumerate(lowered):
            if keyword in value:
                if any(neg in value for neg in negative_amount_headers):
                    continue
                amount_idx = i
                break
        if amount_idx is not None:
            break

    count_priority = [
        '# losses',
        'no. losses',
        'no of losses',
        'number of losses',
        'claim count',
        'number of claims',
        'no. of claims',
        'no of claims',
        'claims count',
        '# claims'
    ]

    for keyword in count_priority:
        for i, value in enumerate(lowered):
            if keyword in value:
                count_idx = i
                break
        if count_idx is not None:
            break

    if count_idx is None and amount_idx is not None:
        previous_idx = amount_idx - 1

        if previous_idx >= 0:
            previous_header = lowered[previous_idx]
            allowed_short_count_headers = ['no', 'no.', '#', '# losses', '# claims', 'count']

            if previous_header in allowed_short_count_headers:
                count_idx = previous_idx

    if count_idx is not None:
        count_header = lowered[count_idx]

        if 'risk' in count_header or 'risks' in count_header:
            count_idx = None

    return period_idx, amount_idx, count_idx


def read_stage_file_bytes(session, relative_path):
    stage_location = f"{STAGE_NAME}/{relative_path}"
    stream = session.file.get_stream(stage_location)
    return stream.read()


def normalize_extracted_rows(rows):
    normalized = []

    for row in rows:
        loss_year = row.get("loss_year")
        loss_amount = row.get("loss_amount")
        source_text = row.get("source_row_text")

        if loss_year is None:
            continue

        if loss_amount is None:
            continue

        try:
            loss_year = int(loss_year)
        except Exception:
            continue

        if loss_year < 1900 or loss_year > 2099:
            continue

        include_in_aggregation = True

        if is_total_or_subtotal_text(source_text):
            include_in_aggregation = False

        claim_count = sanitize_claim_count(
            row.get("claim_count"),
            loss_year,
            source_text,
            None
        )

        if claim_count is None:
            claim_count = 1

        normalized.append({
            "loss_year": loss_year,
            "period_text": row.get("period_text"),
            "loss_date": row.get("loss_date"),
            "claim_count": claim_count,
            "loss_amount": float(loss_amount),
            "currency": row.get("currency") or 'UNKNOWN',
            "amount_type": row.get("amount_type"),
            "source_sheet_name": row.get("source_sheet_name"),
            "source_row_text": source_text,
            "include_in_aggregation": include_in_aggregation,
            "confidence": row.get("confidence"),
            "extraction_reason": row.get("extraction_reason")
        })

    return normalized


def extract_excel_loss_rows(session, file_info):
    data = read_stage_file_bytes(session, file_info["file_path"])
    wb = openpyxl.load_workbook(BytesIO(data), data_only=True, read_only=True)

    extracted = []

    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]

        all_rows = []
        for row in ws.iter_rows(values_only=True):
            all_rows.append(list(row))

        for row_idx, values in enumerate(all_rows):
            if not looks_like_header(values):
                continue

            period_idx, amount_idx, count_idx = find_column_indexes(values)

            if amount_idx is None:
                continue

            amount_header = '' if values[amount_idx] is None else str(values[amount_idx]).strip()
            amount_type = amount_header
            header_currency = detect_currency_from_text(amount_header)

            count_header = None
            if count_idx is not None and count_idx < len(values):
                count_header = '' if values[count_idx] is None else str(values[count_idx]).strip()

            blank_streak = 0

            for data_idx in range(row_idx + 1, min(row_idx + 500, len(all_rows))):
                data_values = all_rows[data_idx]
                source_row_text = row_to_text(data_values)

                if is_blank_row(data_values):
                    blank_streak += 1
                    if blank_streak >= 20:
                        break
                    continue

                blank_streak = 0

                if looks_like_header(data_values):
                    break

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

                loss_amount = safe_float(data_values[amount_idx])

                if loss_amount is None:
                    continue

                row_currency = header_currency

                if row_currency is None:
                    row_currency = detect_currency_from_text(source_row_text)

                if row_currency is None:
                    row_currency = 'UNKNOWN'

                claim_count = None

                if count_idx is not None and count_idx < len(data_values):
                    claim_count = sanitize_claim_count(
                        data_values[count_idx],
                        loss_year,
                        source_row_text,
                        count_header
                    )

                if claim_count is None:
                    claim_count = 1

                extracted.append({
                    "loss_year": loss_year,
                    "period_text": str(period_text),
                    "loss_date": None,
                    "claim_count": claim_count,
                    "loss_amount": loss_amount,
                    "currency": row_currency,
                    "amount_type": amount_type,
                    "source_sheet_name": sheet_name,
                    "source_row_text": source_row_text,
                    "include_in_aggregation": True,
                    "confidence": 1.0,
                    "extraction_reason": "Extracted from Excel loss table. Amount column selected by header. Year-like counts and risk columns are not used as claim count."
                })

    return normalize_extracted_rows(extracted)


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


def score_excel_file(session, file_info):
    try:
        rows = extract_excel_loss_rows(session, file_info)
        file_name = file_info["file_name"].lower()

        if len(rows) == 0:
            base_score = 10
        else:
            base_score = 100 + min(len(rows), 50)

        for keyword in STRONG_LOSS_KEYWORDS:
            if keyword in file_name:
                base_score += 35

        for keyword in MEDIUM_LOSS_KEYWORDS:
            if keyword in file_name:
                base_score += 12

        for keyword in NEGATIVE_KEYWORDS:
            if keyword in file_name:
                base_score -= 25

        return float(base_score), None, rows

    except Exception as e:
        return 0.0, str(e), []


def score_non_excel_file(file_info):
    file_name = file_info["file_name"].lower()
    score = 0

    for keyword in STRONG_LOSS_KEYWORDS:
        if keyword in file_name:
            score += 35

    for keyword in MEDIUM_LOSS_KEYWORDS:
        if keyword in file_name:
            score += 12

    for keyword in HELPFUL_DOC_KEYWORDS:
        if keyword in file_name:
            score += 4

    for keyword in NEGATIVE_KEYWORDS:
        if keyword in file_name:
            score -= 25

    if file_info["extension"] in DIRECT_AI_EXTENSIONS:
        score += 5

    return float(score)


def get_response_format_json():
    schema = {
        "schema": {
            "type": "object",
            "properties": {
                "loss_table": {
                    "description": "Extract actual yearly/event claim or loss history rows only. Use rows from loss history, CAT loss record, claim history, loss runs, paid/outstanding/total incurred tables.",
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
                            "description": "Year of the loss row. For period 2015-16, use 2015.",
                            "type": "array"
                        },
                        "period_text": {
                            "description": "Original period/event/year text.",
                            "type": "array"
                        },
                        "loss_date": {
                            "description": "Loss date if available.",
                            "type": "array"
                        },
                        "claim_count": {
                            "description": "Number of claims/losses only if explicitly available. Never use year, period, amount, risk count, exposure count, or amount as claim count. If not available, return null.",
                            "type": "array"
                        },
                        "loss_amount": {
                            "description": "Main loss amount. Prefer Gross Claim Incurred, Total Incurred, Total GBP/USD/EUR/CLF/CAD/AUD, Amount CLF/USD/GBP/EUR. Do not use recovery, reserve, risk count, or exposure columns as amount.",
                            "type": "array"
                        },
                        "currency": {
                            "description": "Currency code such as USD, GBP, EUR, CLF, CAD, AUD, or UNKNOWN.",
                            "type": "array"
                        },
                        "amount_type": {
                            "description": "Column or label used as amount.",
                            "type": "array"
                        },
                        "source_row_text": {
                            "description": "Exact row or text used as evidence.",
                            "type": "array"
                        },
                        "include_in_aggregation": {
                            "description": "false only for subtotal, grand total, average, 10 years total, or summary rows. true for actual yearly/event rows.",
                            "type": "array"
                        },
                        "extraction_reason": {
                            "description": "Brief reason for extraction.",
                            "type": "array"
                        }
                    }
                }
            }
        }
    }

    return json.dumps(schema)


def call_ai_extract_for_file(session, relative_path):
    response_format = get_response_format_json()

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

    for v in table.values():
        if isinstance(v, list):
            max_len = max(max_len, len(v))

    confidence = None

    try:
        confidence = scoring.get("scores", {}).get("loss_table", {}).get("score")
    except Exception:
        confidence = None

    rows = []

    for i in range(max_len):
        row = {}

        for key, arr in table.items():
            if isinstance(arr, list) and i < len(arr):
                row[key] = arr[i]
            else:
                row[key] = None

        source_text = row.get("source_row_text")
        period_text = row.get("period_text")

        loss_year = extract_year_from_text(period_text)

        if loss_year is None:
            loss_year = extract_year_from_text(source_text)

        if loss_year is None:
            loss_year = safe_int(row.get("loss_year"))

        loss_amount = safe_float(row.get("loss_amount"))

        if loss_year is None or loss_amount is None:
            continue

        currency = row.get("currency")

        if currency is None or str(currency).strip() == '' or str(currency).upper() == 'UNKNOWN':
            currency = detect_currency_from_text(source_text)

        if currency is None:
            currency = 'UNKNOWN'

        claim_count = sanitize_claim_count(
            row.get("claim_count"),
            loss_year,
            source_text,
            None
        )

        if claim_count is None:
            claim_count = 1

        include_in_aggregation = True

        if is_total_or_subtotal_text(source_text):
            include_in_aggregation = False

        rows.append({
            "loss_year": loss_year,
            "period_text": period_text,
            "loss_date": row.get("loss_date"),
            "claim_count": claim_count,
            "loss_amount": loss_amount,
            "currency": currency,
            "amount_type": row.get("amount_type"),
            "source_sheet_name": None,
            "source_row_text": source_text,
            "include_in_aggregation": include_in_aggregation,
            "confidence": confidence,
            "extraction_reason": row.get("extraction_reason")
        })

    return normalize_extracted_rows(rows)


def insert_file_selection(session, run_id, file_info, score, attempted, selected_final, rank, reason, status, error):
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
            ATTEMPTED_FOR_EXTRACTION,
            SELECTED_FOR_FINAL_EXTRACTION,
            SELECTION_RANK,
            SELECTION_REASON,
            PARSE_STATUS,
            ERROR_MESSAGE
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        attempted,
        selected_final,
        rank,
        reason,
        status,
        error
    ]).collect()


def update_file_selection_status(session, run_id, account_folder, file_path, status, error=None, selected_final=False):
    query = f"""
        UPDATE {FILE_SELECTION_TABLE}
        SET PARSE_STATUS = ?,
            ERROR_MESSAGE = ?,
            SELECTED_FOR_FINAL_EXTRACTION = ?
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND FILE_PATH = ?
    """

    session.sql(query, params=[
        status,
        error,
        selected_final,
        run_id,
        account_folder,
        file_path
    ]).collect()


def insert_loss_row(session, run_id, account_folder, file_info, row):
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
        row.get("loss_year"),
        row.get("period_text"),
        row.get("loss_date"),
        row.get("claim_count"),
        row.get("loss_amount"),
        row.get("currency") or 'UNKNOWN',
        row.get("amount_type"),
        row.get("source_sheet_name"),
        row.get("source_row_text"),
        row.get("include_in_aggregation"),
        row.get("confidence"),
        row.get("extraction_reason")
    ]).collect()


def extract_rows_for_file(session, file_info, pre_extracted_rows=None):
    if pre_extracted_rows is not None:
        return normalize_extracted_rows(pre_extracted_rows)

    ext = file_info["extension"]

    if ext in EXCEL_EXTENSIONS:
        return extract_excel_loss_rows(session, file_info)

    if ext in DIRECT_AI_EXTENSIONS:
        result = call_ai_extract_for_file(session, file_info["file_path"])
        return parse_ai_result(result)

    return []


def aggregate_account(session, run_id, account_folder, as_of_year, final_file_info):
    if as_of_year is None or int(as_of_year) <= 0:
        as_of_year = datetime.now().year
    else:
        as_of_year = int(as_of_year)

    start_year = AGGREGATION_START_YEAR_FIXED
    end_year = as_of_year

    usable_count_query = f"""
        SELECT COUNT(*)
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND LOSS_YEAR BETWEEN ? AND ?
          AND LOSS_AMOUNT IS NOT NULL
          AND INCLUDE_IN_AGGREGATION = TRUE
    """

    usable_count = session.sql(
        usable_count_query,
        params=[run_id, account_folder, start_year, end_year]
    ).collect()[0][0]

    if usable_count is None or int(usable_count) == 0:
        insert_no_rows_query = f"""
            INSERT INTO {AGGREGATED_TABLE} (
                RUN_ID,
                ACCOUNT_FOLDER,
                MIN_LOSS_YEAR,
                MAX_LOSS_YEAR,
                AVAILABLE_LOSS_YEAR_COUNT,
                TOTAL_AVAILABLE_CLAIM_COUNT,
                TOTAL_AVAILABLE_LOSS_AMOUNT,
                AGGREGATION_START_YEAR,
                AGGREGATION_END_YEAR,
                AGGREGATED_CLAIM_COUNT,
                AGGREGATED_LOSS_AMOUNT,
                CURRENCY,
                DATA_QUALITY_FLAG,
                AGGREGATION_REASON,
                FINAL_SOURCE_FILE_NAME,
                FINAL_SOURCE_FILE_PATH
            )
            SELECT
                ?,
                ?,
                NULL,
                NULL,
                0,
                0,
                0,
                ?,
                ?,
                0,
                0,
                'UNKNOWN',
                'NO_USABLE_LOSS_ROWS',
                'No rows were available between aggregation year range after excluding total/subtotal rows.',
                ?,
                ?
        """

        session.sql(insert_no_rows_query, params=[
            run_id,
            account_folder,
            start_year,
            end_year,
            final_file_info["file_name"] if final_file_info else None,
            final_file_info["file_path"] if final_file_info else None
        ]).collect()

        return

    currency_query = f"""
        SELECT CURRENCY, COUNT(*) AS CNT
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND LOSS_YEAR BETWEEN ? AND ?
          AND INCLUDE_IN_AGGREGATION = TRUE
          AND CURRENCY IS NOT NULL
          AND CURRENCY <> 'UNKNOWN'
        GROUP BY CURRENCY
        ORDER BY CNT DESC
        LIMIT 1
    """

    currency_rows = session.sql(
        currency_query,
        params=[run_id, account_folder, start_year, end_year]
    ).collect()

    currency = currency_rows[0][0] if currency_rows else 'UNKNOWN'

    insert_query = f"""
        INSERT INTO {AGGREGATED_TABLE} (
            RUN_ID,
            ACCOUNT_FOLDER,
            MIN_LOSS_YEAR,
            MAX_LOSS_YEAR,
            AVAILABLE_LOSS_YEAR_COUNT,
            TOTAL_AVAILABLE_CLAIM_COUNT,
            TOTAL_AVAILABLE_LOSS_AMOUNT,
            AGGREGATION_START_YEAR,
            AGGREGATION_END_YEAR,
            AGGREGATED_CLAIM_COUNT,
            AGGREGATED_LOSS_AMOUNT,
            CURRENCY,
            DATA_QUALITY_FLAG,
            AGGREGATION_REASON,
            FINAL_SOURCE_FILE_NAME,
            FINAL_SOURCE_FILE_PATH
        )
        SELECT
            ? AS RUN_ID,
            ? AS ACCOUNT_FOLDER,
            MIN(LOSS_YEAR) AS MIN_LOSS_YEAR,
            MAX(LOSS_YEAR) AS MAX_LOSS_YEAR,
            COUNT(DISTINCT LOSS_YEAR) AS AVAILABLE_LOSS_YEAR_COUNT,
            SUM(COALESCE(CLAIM_COUNT, 0)) AS TOTAL_AVAILABLE_CLAIM_COUNT,
            SUM(COALESCE(LOSS_AMOUNT, 0)) AS TOTAL_AVAILABLE_LOSS_AMOUNT,
            ? AS AGGREGATION_START_YEAR,
            ? AS AGGREGATION_END_YEAR,
            SUM(COALESCE(CLAIM_COUNT, 0)) AS AGGREGATED_CLAIM_COUNT,
            SUM(COALESCE(LOSS_AMOUNT, 0)) AS AGGREGATED_LOSS_AMOUNT,
            ? AS CURRENCY,
            CASE
                WHEN ? = 'UNKNOWN' THEN 'CURRENCY_UNKNOWN'
                ELSE 'OK'
            END AS DATA_QUALITY_FLAG,
            CASE
                WHEN ? = 'UNKNOWN' THEN 'Rows were aggregated from 2015 to as-of year, but currency was unknown.'
                ELSE 'Rows were aggregated from 2015 to as-of year. Amounts are summed as source currency values without FX conversion.'
            END AS AGGREGATION_REASON,
            ? AS FINAL_SOURCE_FILE_NAME,
            ? AS FINAL_SOURCE_FILE_PATH
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND LOSS_YEAR BETWEEN ? AND ?
          AND LOSS_AMOUNT IS NOT NULL
          AND INCLUDE_IN_AGGREGATION = TRUE
    """

    session.sql(insert_query, params=[
        run_id,
        account_folder,
        start_year,
        end_year,
        currency,
        currency,
        currency,
        final_file_info["file_name"] if final_file_info else None,
        final_file_info["file_path"] if final_file_info else None,
        run_id,
        account_folder,
        start_year,
        end_year
    ]).collect()


def delete_existing_for_scope(session, account_filter):
    if account_filter and account_filter.strip():
        pattern = f"%{account_filter.strip()}%"

        session.sql(
            f"DELETE FROM {FILE_SELECTION_TABLE} WHERE ACCOUNT_FOLDER ILIKE ?",
            params=[pattern]
        ).collect()

        session.sql(
            f"DELETE FROM {EXTRACTION_TABLE} WHERE ACCOUNT_FOLDER ILIKE ?",
            params=[pattern]
        ).collect()

        session.sql(
            f"DELETE FROM {AGGREGATED_TABLE} WHERE ACCOUNT_FOLDER ILIKE ?",
            params=[pattern]
        ).collect()


def run(session, max_accounts, account_name_filter, as_of_year):
    run_id = str(uuid.uuid4())

    if max_accounts is None or int(max_accounts) <= 0:
        max_accounts = 1
    else:
        max_accounts = int(max_accounts)

    account_filter = account_name_filter.strip() if account_name_filter else None

    delete_existing_for_scope(session, account_filter)

    all_files = list_stage_files(session)

    if account_filter:
        all_files = [
            f for f in all_files
            if account_filter.lower() in f["account_folder"].lower()
        ]

    by_account = {}

    for file_info in all_files:
        by_account.setdefault(file_info["account_folder"], []).append(file_info)

    if account_filter:
        selected_accounts = sorted(by_account.keys())[:max_accounts]
    else:
        already_processed_rows = session.sql(f"""
            SELECT DISTINCT ACCOUNT_FOLDER
            FROM {AGGREGATED_TABLE}
        """).collect()

        already_processed_accounts = set([r[0] for r in already_processed_rows])

        remaining_accounts = [
            account
            for account in sorted(by_account.keys())
            if account not in already_processed_accounts
        ]

        selected_accounts = remaining_accounts[:max_accounts]

    processed_accounts = 0
    attempted_accounts = 0
    attempted_files_count = 0
    final_selected_files_count = 0
    extracted_rows_count = 0
    errors = []

    for account_folder in selected_accounts:
        attempted_accounts += 1

        files = by_account[account_folder]
        scored_files = []

        for file_info in files:
            try:
                if file_info["extension"] in EXCEL_EXTENSIONS:
                    score, error, pre_rows = score_excel_file(session, file_info)
                else:
                    score = score_non_excel_file(file_info)
                    error = None
                    pre_rows = None

                scored_files.append({
                    "file_info": file_info,
                    "score": score,
                    "error": error,
                    "pre_rows": pre_rows
                })

            except Exception as e:
                scored_files.append({
                    "file_info": file_info,
                    "score": 0.0,
                    "error": str(e),
                    "pre_rows": None
                })

        scored_files = sorted(scored_files, key=lambda x: x["score"], reverse=True)

        candidate_files = scored_files[:MAX_CANDIDATE_FILES_PER_ACCOUNT]
        candidate_paths = set([x["file_info"]["file_path"] for x in candidate_files])

        for idx, item in enumerate(scored_files, start=1):
            attempted = item["file_info"]["file_path"] in candidate_paths

            if attempted:
                reason = 'Candidate for extraction. If this candidate gives zero valid rows, next ranked candidate will be tried.'
                status = 'CANDIDATE'
            else:
                reason = 'Not attempted because it ranked below candidate limit.'
                status = 'NOT_ATTEMPTED'

            if item["error"] is not None:
                status = 'SCORING_ERROR'

            insert_file_selection(
                session,
                run_id,
                item["file_info"],
                item["score"],
                attempted,
                False,
                idx,
                reason,
                status,
                item["error"]
            )

        if len(candidate_files) == 0:
            errors.append(f"{account_folder}: no supported files found")
            continue

        account_inserted = 0
        final_file_info = None
        candidate_errors = []

        for candidate in candidate_files:
            file_info = candidate["file_info"]
            attempted_files_count += 1

            try:
                rows = extract_rows_for_file(
                    session,
                    file_info,
                    candidate.get("pre_rows")
                )

                rows = normalize_extracted_rows(rows)

                if len(rows) == 0:
                    update_file_selection_status(
                        session,
                        run_id,
                        account_folder,
                        file_info["file_path"],
                        'ATTEMPTED_ZERO_VALID_ROWS',
                        'Candidate was attempted but produced zero valid loss rows.',
                        False
                    )
                    continue

                inserted = 0

                for row in rows:
                    insert_loss_row(session, run_id, account_folder, file_info, row)
                    inserted += 1

                update_file_selection_status(
                    session,
                    run_id,
                    account_folder,
                    file_info["file_path"],
                    'FINAL_SELECTED_ROWS_EXTRACTED',
                    None,
                    True
                )

                account_inserted = inserted
                final_file_info = file_info
                final_selected_files_count += 1
                extracted_rows_count += inserted
                break

            except Exception as e:
                candidate_errors.append(f"{file_info['file_name']}: {str(e)}")

                update_file_selection_status(
                    session,
                    run_id,
                    account_folder,
                    file_info["file_path"],
                    'EXTRACTION_ERROR',
                    str(e),
                    False
                )

        if account_inserted > 0:
            try:
                aggregate_account(session, run_id, account_folder, as_of_year, final_file_info)
                processed_accounts += 1
            except Exception as e:
                errors.append(f"{account_folder}: aggregation error: {str(e)}")
        else:
            errors.append(
                f"{account_folder}: no candidate produced valid rows. Candidate errors: {candidate_errors[:3]}"
            )

    summary = {
        "run_id": run_id,
        "accounts_seen": len(by_account),
        "accounts_selected_this_run": len(selected_accounts),
        "accounts_attempted": attempted_accounts,
        "accounts_processed": processed_accounts,
        "attempted_files_count": attempted_files_count,
        "final_selected_files_count": final_selected_files_count,
        "extracted_rows_count": extracted_rows_count,
        "error_count": len(errors),
        "errors_sample": errors[:10],
        "candidate_limit_per_account": MAX_CANDIDATE_FILES_PER_ACCOUNT,
        "aggregation_start_year": AGGREGATION_START_YEAR_FIXED,
        "aggregation_end_year": int(as_of_year) if as_of_year is not None and int(as_of_year) > 0 else datetime.now().year,
        "account_filter_used": account_filter,
        "next_set_mode": True if not account_filter else False
    }

    return json.dumps(summary, indent=2)
$$;
