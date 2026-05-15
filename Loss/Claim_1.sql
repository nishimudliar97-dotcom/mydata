CREATE OR REPLACE PROCEDURE OPEN_MARKET_LOSS_HISTORY_EXTRACTION_2(
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

FILE_SELECTION_TABLE = 'OPEN_MARKET_LOSS_FILE_SELECTION_2'
EXTRACTION_TABLE = 'OPEN_MARKET_LOSS_HISTORY_EXTRACTION_2'
AGGREGATED_TABLE = 'OPEN_MARKET_LOSS_HISTORY_AGGREGATED_2'

SUPPORTED_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml', '.xlsx', '.xlsm'}
EXCEL_EXTENSIONS = {'.xlsx', '.xlsm'}
DIRECT_AI_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml'}

LOSS_KEYWORDS = [
    'loss', 'losses', 'loss history', 'loss record', 'loss run', 'loss runs',
    'claim', 'claims', 'claims external', 'claim history', 'cat loss', 'cat losses',
    'total incurred', 'incurred net', 'gross incurred', 'paid', 'outstanding',
    'reinsurer payout', 'total payable by reinsurers', 'aggregate erosion',
    'yoa', 'uw year', 'policy year', 'period', 'amount clf'
]

NEGATIVE_KEYWORDS = [
    'statement of values', 'sov', 'construction', 'occupancy',
    'schedule of values', 'building values', 'tiv', 'exposure only'
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
        '5 year average',
        'five year average',
        'average',
        'overall total'
    ]

    return any(x in t for x in bad_markers)


def safe_float(value):
    if value is None:
        return None

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

    text = text.replace(',', '')
    text = text.replace('$', '')
    text = text.replace('£', '')
    text = text.replace('€', '')
    text = text.replace('USD', '')
    text = text.replace('GBP', '')
    text = text.replace('EUR', '')
    text = text.replace('CLF', '')
    text = text.replace('usd', '')
    text = text.replace('gbp', '')
    text = text.replace('eur', '')
    text = text.replace('clf', '')
    text = text.strip()

    m = re.search(r'-?\d+(\.\d+)?', text)

    if not m:
        return None

    number = float(m.group(0))

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

    # Handles 2015-16, 2015 - 2016, 2020/2021
    m_range = re.search(r'\b((?:19|20)\d{2})\s*[-/]\s*(\d{2,4})\b', t)
    if m_range:
        return int(m_range.group(1))

    # Handles normal years anywhere in the event/period text
    m = re.search(r'\b(19|20)\d{2}\b', t)
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


def row_to_text(values):
    return ' | '.join(['' if v is None else str(v).strip() for v in values])


def looks_like_header(values):
    line = row_to_text(values).lower()

    year_markers = [
        'event', 'period', 'yoa', 'uw year', 'policy year',
        'loss date', 'claim date', 'date'
    ]

    amount_markers = [
        'amount', 'total incurred', 'incurred net', 'gross incurred',
        'total gbp', 'total usd', 'total eur', 'total clf',
        'paid', 'outstanding', 'reinsurer payout', 'total payable'
    ]

    has_year_or_period = any(x in line for x in year_markers)
    has_amount = any(x in line for x in amount_markers)

    return has_year_or_period and has_amount


def find_column_indexes(header_values):
    period_idx = None
    amount_idx = None
    count_idx = None

    amount_priority = [
        'total incurred net',
        'total incurred',
        'gross incurred',
        'total payable by reinsurers',
        'reinsurer payout',
        'total gbp',
        'total usd',
        'total eur',
        'total clf',
        'amount clf',
        'amount',
        'paid',
        'outstanding'
    ]

    period_priority = [
        'event',
        'period',
        'yoa',
        'uw year',
        'policy year',
        'loss date',
        'claim date',
        'date'
    ]

    count_priority = [
        'claim count',
        'number of claims',
        'no. of claims',
        'no of claims',
        'claim no',
        'no.'
    ]

    lowered = ['' if v is None else str(v).strip().lower() for v in header_values]

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
                amount_idx = i
                break
        if amount_idx is not None:
            break

    for keyword in count_priority:
        for i, value in enumerate(lowered):
            if keyword == value or keyword in value:
                count_idx = i
                break
        if count_idx is not None:
            break

    return period_idx, amount_idx, count_idx


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
            values = list(row)
            all_rows.append(values)

        for row_idx, values in enumerate(all_rows):
            if not looks_like_header(values):
                continue

            period_idx, amount_idx, count_idx = find_column_indexes(values)

            if amount_idx is None:
                continue

            amount_header = '' if values[amount_idx] is None else str(values[amount_idx]).strip()
            amount_type = amount_header
            currency = detect_currency_from_text(amount_header)

            blank_streak = 0

            for data_idx in range(row_idx + 1, min(row_idx + 250, len(all_rows))):
                data_values = all_rows[data_idx]
                source_row_text = row_to_text(data_values)

                if source_row_text.strip().replace('|', '').strip() == '':
                    blank_streak += 1
                    if blank_streak >= 15:
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

                loss_amount = safe_float(data_values[amount_idx])

                if loss_amount is None:
                    continue

                if currency is None:
                    currency = detect_currency_from_text(source_row_text)

                if currency is None:
                    currency = 'UNKNOWN'

                claim_count = None

                if count_idx is not None and count_idx < len(data_values):
                    claim_count = safe_int(data_values[count_idx])

                # In event-level cat loss tables, each row is one loss occurrence/event.
                # Do not use "RISKS" as claim count.
                if claim_count is None:
                    claim_count = 1

                extracted.append({
                    "loss_year": loss_year,
                    "period_text": str(period_text),
                    "loss_date": None,
                    "claim_count": claim_count,
                    "loss_amount": loss_amount,
                    "currency": currency,
                    "amount_type": amount_type,
                    "source_sheet_name": sheet_name,
                    "source_row_text": source_row_text,
                    "include_in_aggregation": True,
                    "confidence": 1.0,
                    "extraction_reason": "Extracted deterministically from Excel header and row values."
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


def score_excel_file(session, file_info):
    try:
        rows = extract_excel_loss_rows(session, file_info)

        if len(rows) == 0:
            base_score = 0
        else:
            base_score = 80 + min(len(rows), 20)

        file_name = file_info["file_name"].lower()

        if any(k in file_name for k in ['loss', 'claim', 'claims', 'cat']):
            base_score += 20

        return float(base_score), None

    except Exception as e:
        return 0.0, str(e)


def score_non_excel_file(file_info):
    file_name = file_info["file_name"].lower()
    score = 0

    for keyword in LOSS_KEYWORDS:
        if keyword in file_name:
            score += 10

    for keyword in NEGATIVE_KEYWORDS:
        if keyword in file_name:
            score -= 15

    return float(score)


def get_response_format_json():
    schema = {
        "schema": {
            "type": "object",
            "properties": {
                "loss_table": {
                    "description": "Extract normalized claim/loss history rows only.",
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
                            "description": "Number of claims. If row is one event/claim, use 1.",
                            "type": "array"
                        },
                        "loss_amount": {
                            "description": "Main loss amount for the row.",
                            "type": "array"
                        },
                        "currency": {
                            "description": "Currency code such as USD, GBP, EUR, CLF, CAD, AUD, or UNKNOWN.",
                            "type": "array"
                        },
                        "amount_type": {
                            "description": "Column used as amount, e.g. Total Incurred, Total GBP, Reinsurer Payout.",
                            "type": "array"
                        },
                        "source_row_text": {
                            "description": "Exact row or text used.",
                            "type": "array"
                        },
                        "include_in_aggregation": {
                            "description": "false for subtotal, grand total, average rows. true for actual rows.",
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

    rows = []

    confidence = None

    try:
        confidence = scoring.get("scores", {}).get("loss_table", {}).get("score")
    except Exception:
        confidence = None

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

        include_value = row.get("include_in_aggregation")

        if include_value is None:
            include_in_aggregation = not is_total_or_subtotal_text(source_text)
        else:
            include_in_aggregation = str(include_value).strip().lower() in ('true', 'yes', '1')

        currency = row.get("currency")

        if currency is None or str(currency).strip() == '' or str(currency).upper() == 'UNKNOWN':
            currency = detect_currency_from_text(source_text)

        if currency is None:
            currency = 'UNKNOWN'

        rows.append({
            "loss_year": loss_year,
            "period_text": period_text,
            "loss_date": row.get("loss_date"),
            "claim_count": safe_int(row.get("claim_count")) if row.get("claim_count") is not None else 1,
            "loss_amount": safe_float(row.get("loss_amount")),
            "currency": currency,
            "amount_type": row.get("amount_type"),
            "source_sheet_name": None,
            "source_row_text": source_text,
            "include_in_aggregation": include_in_aggregation,
            "confidence": confidence,
            "extraction_reason": row.get("extraction_reason")
        })

    return rows


def insert_file_selection(session, run_id, file_info, score, selected, rank, reason, status, error):
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
            SELECTED_FOR_EXTRACTION,
            SELECTION_RANK,
            SELECTION_REASON,
            PARSE_STATUS,
            ERROR_MESSAGE
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        selected,
        rank,
        reason,
        status,
        error
    ]).collect()


def insert_loss_row(session, run_id, account_folder, file_info, row):
    if row.get("loss_year") is None:
        return False

    if row.get("loss_amount") is None:
        return False

    if is_total_or_subtotal_text(row.get("source_row_text")):
        row["include_in_aggregation"] = False

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

    return True


def extract_rows_for_file(session, file_info):
    ext = file_info["extension"]

    if ext in EXCEL_EXTENSIONS:
        return extract_excel_loss_rows(session, file_info)

    if ext in DIRECT_AI_EXTENSIONS:
        result = call_ai_extract_for_file(session, file_info["file_path"])
        return parse_ai_result(result)

    return []


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

    min_year = result[0]
    max_year = result[1]
    available_year_count = result[2]
    total_claim_count = result[3]
    total_loss_amount = result[4]
    last_10_claim_count = result[5]
    last_10_loss_amount = result[6]

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

    selected_accounts = sorted(by_account.keys())[:max_accounts]

    processed_accounts = 0
    selected_files_count = 0
    extracted_rows_count = 0
    errors = []

    for account_folder in selected_accounts:
        files = by_account[account_folder]
        scored_files = []

        for file_info in files:
            try:
                if file_info["extension"] in EXCEL_EXTENSIONS:
                    score, error = score_excel_file(session, file_info)
                else:
                    score = score_non_excel_file(file_info)
                    error = None

                scored_files.append({
                    "file_info": file_info,
                    "score": score,
                    "error": error
                })

            except Exception as e:
                scored_files.append({
                    "file_info": file_info,
                    "score": 0.0,
                    "error": str(e)
                })

        scored_files = sorted(scored_files, key=lambda x: x["score"], reverse=True)

        best = scored_files[0] if scored_files else None

        for idx, item in enumerate(scored_files, start=1):
            selected = item is best and item["score"] > 0

            if selected:
                reason = 'Selected highest scoring loss-history file.'
            else:
                reason = 'Not selected because another file scored higher.'

            status = 'SCORED' if item["error"] is None else 'SCORING_ERROR'

            insert_file_selection(
                session,
                run_id,
                item["file_info"],
                item["score"],
                selected,
                idx,
                reason,
                status,
                item["error"]
            )

        if best is None or best["score"] <= 0:
            errors.append(f"{account_folder}: no suitable loss file found")
            continue

        selected_files_count += 1

        try:
            rows = extract_rows_for_file(session, best["file_info"])

            inserted = 0

            for row in rows:
                ok = insert_loss_row(session, run_id, account_folder, best["file_info"], row)

                if ok:
                    inserted += 1

            extracted_rows_count += inserted

            aggregate_account(session, run_id, account_folder, as_of_year)

            processed_accounts += 1

        except Exception as e:
            errors.append(f"{account_folder}: extraction error: {str(e)}")

            session.sql(
                f"""
                UPDATE {FILE_SELECTION_TABLE}
                SET PARSE_STATUS = 'EXTRACTION_ERROR',
                    ERROR_MESSAGE = ?
                WHERE RUN_ID = ?
                  AND ACCOUNT_FOLDER = ?
                  AND SELECTED_FOR_EXTRACTION = TRUE
                """,
                params=[str(e), run_id, account_folder]
            ).collect()

    summary = {
        "run_id": run_id,
        "accounts_seen": len(by_account),
        "accounts_attempted": len(selected_accounts),
        "accounts_processed": processed_accounts,
        "selected_files_count": selected_files_count,
        "extracted_rows_count": extracted_rows_count,
        "error_count": len(errors),
        "errors_sample": errors[:10]
    }

    return json.dumps(summary, indent=2)
$$;
