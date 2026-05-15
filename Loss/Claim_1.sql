CREATE OR REPLACE PROCEDURE OPEN_MARKET_LOSS_HISTORY_EXTRACTION_1(
    MAX_ACCOUNTS NUMBER,
    ACCOUNT_NAME_FILTER STRING
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

FILE_SELECTION_TABLE = 'OPEN_MARKET_LOSS_FILE_SELECTION_1'
EXTRACTION_TABLE = 'OPEN_MARKET_LOSS_HISTORY_EXTRACTION_1'
AGGREGATED_TABLE = 'OPEN_MARKET_LOSS_HISTORY_AGGREGATED_1'

SUPPORTED_EXTENSIONS = {
    '.pdf', '.doc', '.docx', '.eml',
    '.xlsx', '.xlsm'
}

EXCEL_EXTENSIONS = {'.xlsx', '.xlsm'}
DIRECT_AI_EXTRACT_EXTENSIONS = {'.pdf', '.doc', '.docx', '.eml'}

LOSS_KEYWORDS = [
    'loss history',
    'loss record',
    'loss run',
    'loss runs',
    'losses',
    'loss',
    'claim history',
    'claims history',
    'claims external',
    'claims',
    'claim',
    'cat loss',
    'cat losses',
    'total incurred',
    'incurred net',
    'gross incurred',
    'paid',
    'outstanding',
    'reinsurer payout',
    'total payable by reinsurers',
    'aggregate erosion',
    'yoa',
    'uw year',
    'policy year',
    'period'
]

NEGATIVE_KEYWORDS = [
    'statement of values',
    'sov',
    'construction',
    'occupancy',
    'schedule of values',
    'building values',
    'tiv',
    'exposure only'
]


def sql_escape(value):
    if value is None:
        return None
    return str(value).replace("'", "''")


def normalize_stage_relative_path(raw_name):
    if raw_name is None:
        return None

    name = str(raw_name).replace('\\', '/')

    marker = '/' + ROOT_PREFIX
    if marker in name:
        return name.split(marker, 1)[1] if False else ROOT_PREFIX + name.split(marker, 1)[1]

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
    base, ext = os.path.splitext(file_name.lower())
    return ext


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


def safe_float(value):
    if value is None:
        return None

    text = str(value).strip()
    if text == '':
        return None

    lowered = text.lower()
    if lowered in ('nil', 'none', 'null', '-', '--', 'n/a', 'na'):
        return 0.0

    neg = False
    if text.startswith('(') and text.endswith(')'):
        neg = True
        text = text[1:-1]

    text = text.replace(',', '')
    text = text.replace('$', '')
    text = text.replace('£', '')
    text = text.replace('€', '')
    text = text.replace('usd', '')
    text = text.replace('gbp', '')
    text = text.replace('eur', '')
    text = text.strip()

    m = re.search(r'-?\d+(\.\d+)?', text)
    if not m:
        return None

    num = float(m.group(0))
    return -num if neg else num


def safe_int(value):
    num = safe_float(value)
    if num is None:
        return None
    return int(round(num))


def normalize_year_from_any(loss_year, period_text, loss_date, claim_date, policy_year_text):
    candidates = [loss_year, policy_year_text, period_text, loss_date, claim_date]

    for candidate in candidates:
        if candidate is None:
            continue

        text = str(candidate).strip()

        m = re.search(r'\b(19|20)\d{2}\b', text)
        if m:
            return int(m.group(0))

        m2 = re.search(r'\b(\d{4})\s*[-/]\s*(\d{2,4})\b', text)
        if m2:
            return int(m2.group(1))

    return None


def detect_currency(text):
    if text is None:
        return None, None

    t = str(text).lower()

    if 'gbp' in t or '£' in t:
        return 'GBP', 'TEXT_OR_SYMBOL'
    if 'usd' in t or '$' in t:
        return 'USD', 'TEXT_OR_SYMBOL'
    if 'eur' in t or '€' in t:
        return 'EUR', 'TEXT_OR_SYMBOL'
    if 'cad' in t:
        return 'CAD', 'TEXT'
    if 'aud' in t:
        return 'AUD', 'TEXT'

    return None, None


def bool_from_text(value):
    if value is None:
        return False
    t = str(value).strip().lower()
    return t in ('true', 'yes', 'y', '1')


def infer_total_or_subtotal(text):
    if text is None:
        return False

    t = str(text).lower()

    markers = [
        'sub total',
        'subtotal',
        'grand total',
        'total years',
        '10 years',
        '5 year average',
        'five year average',
        'average',
        'total available',
        'overall total'
    ]

    return any(m in t for m in markers)


def infer_exclude_from_aggregation(source_row_text, is_total_or_subtotal):
    if is_total_or_subtotal:
        return True

    if source_row_text is None:
        return False

    t = str(source_row_text).lower()

    if 'average' in t:
        return True

    return False


def get_response_format_json():
    schema = {
        "schema": {
            "type": "object",
            "properties": {
                "loss_table": {
                    "description": (
                        "Extract all claim/loss history rows from the document or table. "
                        "Rows may come from tables called Loss History, Loss Record, Loss Runs, Claims External, Cat Losses, "
                        "5 Year Net Losses, Current Deductible Structure Loss Record, or similar. "
                        "Do not invent missing values. Extract row-level values only."
                    ),
                    "type": "object",
                    "column_ordering": [
                        "loss_year",
                        "period_text",
                        "policy_year_text",
                        "loss_date",
                        "claim_date",
                        "claim_count",
                        "loss_amount",
                        "currency",
                        "currency_source",
                        "amount_type",
                        "paid_amount",
                        "outstanding_amount",
                        "incurred_amount",
                        "reinsurer_payout",
                        "total_payable_by_reinsurers",
                        "aggregate_erosion",
                        "row_type",
                        "is_total_or_subtotal_row",
                        "exclude_from_aggregation",
                        "source_sheet_name",
                        "source_page_number",
                        "source_section_name",
                        "source_row_text",
                        "extraction_reason"
                    ],
                    "properties": {
                        "loss_year": {
                            "description": (
                                "The year associated with the loss row. If period is 2015-16 or 2015 - 2016, use 2015. "
                                "If only a loss date or claim date exists, derive the year from that date."
                            ),
                            "type": "array"
                        },
                        "period_text": {
                            "description": "The original period text, for example 2015-16, 2020 - 2021, or 2024.",
                            "type": "array"
                        },
                        "policy_year_text": {
                            "description": "Policy year, YOA, UW Year, or underwriting year text exactly as shown.",
                            "type": "array"
                        },
                        "loss_date": {
                            "description": "Loss date if available.",
                            "type": "array"
                        },
                        "claim_date": {
                            "description": "Claim date or reported date if available.",
                            "type": "array"
                        },
                        "claim_count": {
                            "description": (
                                "Number of claims for the row. If the row is an individual claim row, use 1. "
                                "If the table has a No. column, use the relevant total No. value for that row. "
                                "Do not count subtotal or grand total rows as normal rows."
                            ),
                            "type": "array"
                        },
                        "loss_amount": {
                            "description": (
                                "Main loss amount for aggregation. Prefer Total Incurred, Total Incurred Net, Total GBP, "
                                "Gross Claim Incurred, Reinsurer Payout, Total Payable by Reinsurers, or similar main loss amount. "
                                "Do not use aggregate erosion as the main loss amount unless it is the only loss amount available."
                            ),
                            "type": "array"
                        },
                        "currency": {
                            "description": "Currency code such as USD, GBP, EUR, CAD, AUD. Use UNKNOWN if not found.",
                            "type": "array"
                        },
                        "currency_source": {
                            "description": "Where the currency came from: table header, document header, symbol, filename, or not found.",
                            "type": "array"
                        },
                        "amount_type": {
                            "description": (
                                "Name of the column used as main loss amount, for example Total Incurred Net, Total GBP, "
                                "Reinsurer Payout, Total Payable by Reinsurers, Paid GBP, Outstanding GBP."
                            ),
                            "type": "array"
                        },
                        "paid_amount": {
                            "description": "Paid amount if available.",
                            "type": "array"
                        },
                        "outstanding_amount": {
                            "description": "Outstanding amount if available.",
                            "type": "array"
                        },
                        "incurred_amount": {
                            "description": "Incurred amount if available.",
                            "type": "array"
                        },
                        "reinsurer_payout": {
                            "description": "Reinsurer payout amount if available.",
                            "type": "array"
                        },
                        "total_payable_by_reinsurers": {
                            "description": "Total payable by reinsurers amount if available.",
                            "type": "array"
                        },
                        "aggregate_erosion": {
                            "description": "Aggregate erosion amount if available.",
                            "type": "array"
                        },
                        "row_type": {
                            "description": (
                                "Classify row as INDIVIDUAL_CLAIM_ROW, YEAR_SUMMARY_ROW, SUBTOTAL_ROW, "
                                "GRAND_TOTAL_ROW, AVERAGE_ROW, or UNKNOWN."
                            ),
                            "type": "array"
                        },
                        "is_total_or_subtotal_row": {
                            "description": "true if row is subtotal, grand total, average, 5 year average, 10 years total, or similar.",
                            "type": "array"
                        },
                        "exclude_from_aggregation": {
                            "description": (
                                "true for subtotal, grand total, average rows, or duplicate summary rows. "
                                "false for real individual claim rows or year summary rows that should be aggregated."
                            ),
                            "type": "array"
                        },
                        "source_sheet_name": {
                            "description": "Excel sheet name if source is Excel, otherwise blank.",
                            "type": "array"
                        },
                        "source_page_number": {
                            "description": "Page number if available, otherwise blank.",
                            "type": "array"
                        },
                        "source_section_name": {
                            "description": "Section or table title where the row was found.",
                            "type": "array"
                        },
                        "source_row_text": {
                            "description": "Exact row or nearby text used to extract this loss row.",
                            "type": "array"
                        },
                        "extraction_reason": {
                            "description": "Brief explanation of why this row was extracted and how amount/year/count were chosen.",
                            "type": "array"
                        }
                    }
                }
            }
        }
    }

    return json.dumps(schema)


def list_stage_files(session):
    query = f"LIST {STAGE_NAME}/{ROOT_PREFIX}"
    rows = session.sql(query).collect()

    files = []

    for row in rows:
        raw_name = row[0]
        size = row[1] if len(row) > 1 else None
        last_modified = row[3] if len(row) > 3 else None

        relative_path = normalize_stage_relative_path(raw_name)
        if relative_path is None:
            continue

        file_name = get_file_name(relative_path)
        ext = get_extension(file_name)

        if ext not in SUPPORTED_EXTENSIONS:
            continue

        account_folder = get_account_folder(relative_path)
        if account_folder is None:
            continue

        files.append({
            "account_folder": account_folder,
            "file_name": file_name,
            "file_path": relative_path,
            "extension": ext,
            "size": size,
            "last_modified": str(last_modified) if last_modified is not None else None
        })

    return files


def read_stage_file_bytes(session, relative_path):
    stage_location = f"{STAGE_NAME}/{relative_path}"
    stream = session.file.get_stream(stage_location)
    return stream.read()


def extract_excel_preview(session, relative_path, max_rows_per_sheet=250, max_cols=40):
    data = read_stage_file_bytes(session, relative_path)
    wb = openpyxl.load_workbook(BytesIO(data), data_only=True, read_only=True)

    previews = []
    sheet_names = wb.sheetnames

    for sheet_name in sheet_names:
        ws = wb[sheet_name]

        sheet_score_name = sheet_name.lower()
        sheet_is_relevant = any(k in sheet_score_name for k in [
            'loss', 'claim', 'claims', 'cat', 'external', 'run'
        ])

        rows_text = []
        empty_streak = 0
        row_count = 0

        for row in ws.iter_rows(values_only=True):
            row_count += 1

            if row_count > max_rows_per_sheet and not sheet_is_relevant:
                break

            if row_count > max_rows_per_sheet * 2:
                break

            values = []
            non_empty = 0

            for cell in row[:max_cols]:
                if cell is None:
                    values.append('')
                else:
                    text = str(cell).strip()
                    values.append(text)
                    if text != '':
                        non_empty += 1

            if non_empty == 0:
                empty_streak += 1
                if empty_streak > 30 and not sheet_is_relevant:
                    break
                continue

            empty_streak = 0
            row_line = ' | '.join(values)

            lower_line = row_line.lower()
            useful = (
                sheet_is_relevant
                or any(k in lower_line for k in LOSS_KEYWORDS)
                or bool(re.search(r'\b(19|20)\d{2}\b', lower_line))
            )

            if useful:
                rows_text.append(f"ROW {row_count}: {row_line}")

        if rows_text:
            previews.append({
                "sheet_name": sheet_name,
                "text": f"SHEET: {sheet_name}\n" + "\n".join(rows_text[:500])
            })

    if not previews:
        for sheet_name in sheet_names[:5]:
            ws = wb[sheet_name]
            rows_text = []
            row_count = 0

            for row in ws.iter_rows(values_only=True):
                row_count += 1
                if row_count > 80:
                    break

                values = []
                non_empty = 0

                for cell in row[:max_cols]:
                    if cell is None:
                        values.append('')
                    else:
                        text = str(cell).strip()
                        values.append(text)
                        if text != '':
                            non_empty += 1

                if non_empty > 0:
                    rows_text.append(f"ROW {row_count}: {' | '.join(values)}")

            if rows_text:
                previews.append({
                    "sheet_name": sheet_name,
                    "text": f"SHEET: {sheet_name}\n" + "\n".join(rows_text)
                })

    return previews


def extract_eml_preview(session, relative_path, max_chars=12000):
    data = read_stage_file_bytes(session, relative_path)

    try:
        text = data.decode('utf-8', errors='ignore')
    except Exception:
        text = str(data[:max_chars])

    text = re.sub(r'\s+', ' ', text)
    return text[:max_chars]


def score_preview(file_name, extension, preview_text):
    text = f"{file_name}\n{preview_text or ''}".lower()

    score = 0
    has_loss_keyword = False
    has_claim_keyword = False
    has_year_amount_pattern = False
    has_table_structure = False

    if any(k in file_name.lower() for k in ['loss', 'claim', 'claims', 'run']):
        score += 35

    if extension in EXCEL_EXTENSIONS:
        score += 10

    if extension in {'.pdf', '.doc', '.docx'}:
        score += 5

    for keyword in LOSS_KEYWORDS:
        if keyword in text:
            has_loss_keyword = True
            score += 5

    if 'claim' in text or 'claims' in text:
        has_claim_keyword = True
        score += 15

    if re.search(r'\b(19|20)\d{2}\b', text) and re.search(r'[\$£€]?\s?\d{1,3}(,\d{3})+|\b\d{4,}\b', text):
        has_year_amount_pattern = True
        score += 25

    if '|' in text or '\t' in text or 'total incurred' in text or 'paid' in text or 'outstanding' in text:
        has_table_structure = True
        score += 15

    for neg in NEGATIVE_KEYWORDS:
        if neg in text:
            score -= 15

    if 'loss' in text and 'history' in text:
        score += 20

    if 'total incurred' in text:
        score += 20

    if 'reinsurer payout' in text or 'total payable by reinsurers' in text:
        score += 20

    if 'cat losses' in text or 'cat loss' in text:
        score += 20

    return {
        "score": float(score),
        "has_loss_keyword": has_loss_keyword,
        "has_claim_keyword": has_claim_keyword,
        "has_year_amount_pattern": has_year_amount_pattern,
        "has_table_structure": has_table_structure
    }


def insert_file_selection(
    session,
    run_id,
    file_info,
    score_info,
    selected,
    rank,
    reason,
    parse_status,
    error_message
):
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
            HAS_LOSS_KEYWORD,
            HAS_CLAIM_KEYWORD,
            HAS_YEAR_AMOUNT_PATTERN,
            HAS_TABLE_STRUCTURE,
            SELECTED_FOR_EXTRACTION,
            SELECTION_RANK,
            SELECTION_REASON,
            PARSE_STATUS,
            ERROR_MESSAGE
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    session.sql(query, params=[
        run_id,
        file_info.get("account_folder"),
        file_info.get("file_name"),
        file_info.get("file_path"),
        file_info.get("extension"),
        file_info.get("size"),
        file_info.get("last_modified"),
        score_info.get("score"),
        score_info.get("has_loss_keyword"),
        score_info.get("has_claim_keyword"),
        score_info.get("has_year_amount_pattern"),
        score_info.get("has_table_structure"),
        selected,
        rank,
        reason,
        parse_status,
        error_message
    ]).collect()


def call_ai_extract_for_text(session, text):
    response_format = get_response_format_json()

    extraction_text = f"""
You are extracting insurance loss history rows.

Important business rules:
1. Extract only claim/loss history rows.
2. If period is 2015-16, map loss_year to 2015.
3. If individual claim rows and subtotal rows both exist, keep individual rows and mark subtotal rows as exclude_from_aggregation=true.
4. Do not use Grand Total, Sub Total, Average, 5 Year Average, or 10 Years rows as normal yearly rows.
5. If only yearly summary rows are available, use the yearly summary rows.
6. For main loss amount, prefer Total Incurred, Total Incurred Net, Total GBP, Total USD, Gross Claim Incurred, Reinsurer Payout, or Total Payable by Reinsurers.
7. Do not use aggregate erosion as the main loss amount unless it is the only amount available.
8. Do not invent missing values.
9. Return blank values where information is unavailable.

Source text/table:
{text}
"""

    query = """
        SELECT AI_EXTRACT(
            text => ?,
            responseFormat => PARSE_JSON(?),
            scores => TRUE
        )
    """

    result = session.sql(query, params=[extraction_text[:120000], response_format]).collect()[0][0]
    return result


def call_ai_extract_for_file(session, relative_path):
    response_format = get_response_format_json()

    query = """
        SELECT AI_EXTRACT(
            file => TO_FILE(?, ?),
            responseFormat => PARSE_JSON(?),
            scores => TRUE
        )
    """

    result = session.sql(query, params=[STAGE_NAME, relative_path, response_format]).collect()[0][0]
    return result


def parse_ai_extract_result(result):
    if result is None:
        return [], None, "AI_EXTRACT returned NULL"

    if isinstance(result, str):
        try:
            obj = json.loads(result)
        except Exception:
            return [], None, f"Could not parse AI_EXTRACT JSON result: {str(result)[:500]}"
    else:
        obj = result

    if obj.get("error"):
        return [], None, str(obj.get("error"))

    response = obj.get("response", {})
    scoring = obj.get("scoring", {})

    table = response.get("loss_table", {})
    if not table:
        return [], scoring, None

    max_len = 0
    for v in table.values():
        if isinstance(v, list):
            max_len = max(max_len, len(v))

    rows = []

    for i in range(max_len):
        row = {}

        for key, arr in table.items():
            if isinstance(arr, list) and i < len(arr):
                row[key] = arr[i]
            else:
                row[key] = None

        rows.append(row)

    return rows, scoring, None


def insert_loss_row(session, run_id, account_folder, file_info, row, confidence):
    source_row_text = row.get("source_row_text")
    row_type = str(row.get("row_type") or '').upper()

    loss_year = normalize_year_from_any(
        row.get("loss_year"),
        row.get("period_text"),
        row.get("loss_date"),
        row.get("claim_date"),
        row.get("policy_year_text")
    )

    claim_count = safe_int(row.get("claim_count"))
    loss_amount = safe_float(row.get("loss_amount"))

    paid_amount = safe_float(row.get("paid_amount"))
    outstanding_amount = safe_float(row.get("outstanding_amount"))
    incurred_amount = safe_float(row.get("incurred_amount"))
    reinsurer_payout = safe_float(row.get("reinsurer_payout"))
    total_payable_by_reinsurers = safe_float(row.get("total_payable_by_reinsurers"))
    aggregate_erosion = safe_float(row.get("aggregate_erosion"))

    if loss_amount is None:
        for fallback in [
            incurred_amount,
            reinsurer_payout,
            total_payable_by_reinsurers,
            paid_amount
        ]:
            if fallback is not None:
                loss_amount = fallback
                break

    currency = row.get("currency")
    currency_source = row.get("currency_source")

    if currency is None or str(currency).strip() == '' or str(currency).upper() == 'UNKNOWN':
        detected_currency, detected_source = detect_currency(source_row_text)
        if detected_currency:
            currency = detected_currency
            currency_source = detected_source

    if currency is None or str(currency).strip() == '':
        currency = 'UNKNOWN'

    is_total_or_subtotal = bool_from_text(row.get("is_total_or_subtotal_row")) or infer_total_or_subtotal(source_row_text)
    exclude_from_aggregation = bool_from_text(row.get("exclude_from_aggregation")) or infer_exclude_from_aggregation(source_row_text, is_total_or_subtotal)

    is_individual = row_type == 'INDIVIDUAL_CLAIM_ROW'
    is_year_summary = row_type == 'YEAR_SUMMARY_ROW'

    if claim_count is None and is_individual:
        claim_count = 1

    if claim_count is None and not exclude_from_aggregation and loss_year is not None and loss_amount is not None:
        claim_count = 1

    source_page_number = safe_int(row.get("source_page_number"))

    if loss_year is None and loss_amount is None and claim_count is None:
        return False

    query = f"""
        INSERT INTO {EXTRACTION_TABLE} (
            RUN_ID,
            ACCOUNT_FOLDER,
            SOURCE_FILE_NAME,
            SOURCE_FILE_PATH,
            SOURCE_FILE_TYPE,

            LOSS_YEAR,
            PERIOD_TEXT,
            POLICY_YEAR_TEXT,
            LOSS_DATE,
            CLAIM_DATE,

            CLAIM_COUNT,
            LOSS_AMOUNT,
            CURRENCY,
            CURRENCY_SOURCE,
            AMOUNT_TYPE,

            PAID_AMOUNT,
            OUTSTANDING_AMOUNT,
            INCURRED_AMOUNT,
            REINSURER_PAYOUT,
            TOTAL_PAYABLE_BY_REINSURERS,
            AGGREGATE_EROSION,

            IS_INDIVIDUAL_CLAIM_ROW,
            IS_YEAR_SUMMARY_ROW,
            IS_TOTAL_OR_SUBTOTAL_ROW,
            EXCLUDE_FROM_AGGREGATION,

            SOURCE_SHEET_NAME,
            SOURCE_PAGE_NUMBER,
            SOURCE_SECTION_NAME,
            SOURCE_ROW_TEXT,

            CONFIDENCE,
            EXTRACTION_REASON
        )
        VALUES (
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?
        )
    """

    session.sql(query, params=[
        run_id,
        account_folder,
        file_info.get("file_name"),
        file_info.get("file_path"),
        file_info.get("extension"),

        loss_year,
        row.get("period_text"),
        row.get("policy_year_text"),
        row.get("loss_date"),
        row.get("claim_date"),

        claim_count,
        loss_amount,
        currency,
        currency_source,
        row.get("amount_type"),

        paid_amount,
        outstanding_amount,
        incurred_amount,
        reinsurer_payout,
        total_payable_by_reinsurers,
        aggregate_erosion,

        is_individual,
        is_year_summary,
        is_total_or_subtotal,
        exclude_from_aggregation,

        row.get("source_sheet_name"),
        source_page_number,
        row.get("source_section_name"),
        source_row_text,

        confidence,
        row.get("extraction_reason")
    ]).collect()

    return True


def extract_rows_for_selected_file(session, run_id, account_folder, file_info):
    ext = file_info.get("extension")
    inserted = 0

    if ext in EXCEL_EXTENSIONS:
        previews = extract_excel_preview(session, file_info.get("file_path"))

        for preview in previews:
            result = call_ai_extract_for_text(session, preview["text"])
            rows, scoring, error = parse_ai_extract_result(result)

            if error:
                raise Exception(error)

            confidence = None
            try:
                confidence = scoring.get("scores", {}).get("loss_table", {}).get("score")
            except Exception:
                confidence = None

            for row in rows:
                if not row.get("source_sheet_name"):
                    row["source_sheet_name"] = preview["sheet_name"]

                ok = insert_loss_row(session, run_id, account_folder, file_info, row, confidence)
                if ok:
                    inserted += 1

    elif ext in DIRECT_AI_EXTRACT_EXTENSIONS:
        result = call_ai_extract_for_file(session, file_info.get("file_path"))
        rows, scoring, error = parse_ai_extract_result(result)

        if error:
            raise Exception(error)

        confidence = None
        try:
            confidence = scoring.get("scores", {}).get("loss_table", {}).get("score")
        except Exception:
            confidence = None

        for row in rows:
            ok = insert_loss_row(session, run_id, account_folder, file_info, row, confidence)
            if ok:
                inserted += 1

    return inserted


def aggregate_account(session, run_id, account_folder):
    current_year = datetime.now().year
    start_year = current_year - 10

    query = f"""
        SELECT
            MIN(LOSS_YEAR) AS MIN_LOSS_YEAR,
            MAX(LOSS_YEAR) AS MAX_LOSS_YEAR,
            COUNT(DISTINCT LOSS_YEAR) AS AVAILABLE_LOSS_YEAR_COUNT,
            SUM(COALESCE(CLAIM_COUNT, 0)) AS TOTAL_AVAILABLE_CLAIM_COUNT,
            SUM(COALESCE(LOSS_AMOUNT, 0)) AS TOTAL_AVAILABLE_LOSS_AMOUNT,
            SUM(CASE WHEN LOSS_YEAR BETWEEN ? AND ? THEN COALESCE(CLAIM_COUNT, 0) ELSE 0 END) AS LAST_10_YEAR_CLAIM_COUNT,
            SUM(CASE WHEN LOSS_YEAR BETWEEN ? AND ? THEN COALESCE(LOSS_AMOUNT, 0) ELSE 0 END) AS LAST_10_YEAR_LOSS_AMOUNT
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND COALESCE(EXCLUDE_FROM_AGGREGATION, FALSE) = FALSE
          AND LOSS_YEAR IS NOT NULL
    """

    result = session.sql(query, params=[
        start_year,
        current_year,
        start_year,
        current_year,
        run_id,
        account_folder
    ]).collect()[0]

    currency_query = f"""
        SELECT CURRENCY, COUNT(*) AS CNT
        FROM {EXTRACTION_TABLE}
        WHERE RUN_ID = ?
          AND ACCOUNT_FOLDER = ?
          AND COALESCE(EXCLUDE_FROM_AGGREGATION, FALSE) = FALSE
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
        reason = 'No usable non-subtotal loss rows were extracted.'
    elif available_year_count < 5:
        quality = 'LOW_HISTORY_YEARS'
        reason = 'Less than 5 years of usable loss history extracted.'
    elif currency == 'UNKNOWN':
        quality = 'CURRENCY_UNKNOWN'
        reason = 'Loss history extracted but currency could not be confidently identified.'
    else:
        quality = 'OK'
        reason = 'Usable loss history rows extracted and aggregated.'

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


def delete_existing_for_run_scope(session, account_filter):
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


def run(session, max_accounts, account_name_filter):
    run_id = str(uuid.uuid4())

    if max_accounts is None or int(max_accounts) <= 0:
        max_accounts = 10
    else:
        max_accounts = int(max_accounts)

    account_filter = account_name_filter.strip() if account_name_filter else None

    delete_existing_for_run_scope(session, account_filter)

    all_files = list_stage_files(session)

    if account_filter:
        all_files = [
            f for f in all_files
            if account_filter.lower() in f["account_folder"].lower()
        ]

    by_account = {}
    for f in all_files:
        by_account.setdefault(f["account_folder"], []).append(f)

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
                ext = file_info.get("extension")
                preview_text = ''

                if ext in EXCEL_EXTENSIONS:
                    previews = extract_excel_preview(session, file_info.get("file_path"), max_rows_per_sheet=120)
                    preview_text = "\n\n".join([p["text"] for p in previews])[:30000]

                elif ext == '.eml':
                    preview_text = extract_eml_preview(session, file_info.get("file_path"))

                else:
                    preview_text = file_info.get("file_name")

                score_info = score_preview(file_info.get("file_name"), ext, preview_text)

                scored_files.append({
                    "file_info": file_info,
                    "score_info": score_info,
                    "preview_text": preview_text,
                    "error": None
                })

            except Exception as e:
                score_info = {
                    "score": 0.0,
                    "has_loss_keyword": False,
                    "has_claim_keyword": False,
                    "has_year_amount_pattern": False,
                    "has_table_structure": False
                }

                scored_files.append({
                    "file_info": file_info,
                    "score_info": score_info,
                    "preview_text": '',
                    "error": str(e)
                })

        scored_files = sorted(
            scored_files,
            key=lambda x: x["score_info"]["score"],
            reverse=True
        )

        best = scored_files[0] if scored_files else None

        for idx, item in enumerate(scored_files, start=1):
            selected = item is best and item["score_info"]["score"] > 0
            reason = (
                "Selected highest scoring loss-history candidate."
                if selected else
                "Not selected because another file scored higher."
            )

            if item["error"]:
                parse_status = 'SCORING_ERROR'
                error_message = item["error"]
            else:
                parse_status = 'SCORED'
                error_message = None

            insert_file_selection(
                session=session,
                run_id=run_id,
                file_info=item["file_info"],
                score_info=item["score_info"],
                selected=selected,
                rank=idx,
                reason=reason,
                parse_status=parse_status,
                error_message=error_message
            )

        if best is None or best["score_info"]["score"] <= 0:
            errors.append(f"{account_folder}: no suitable loss file found")
            continue

        selected_files_count += 1

        try:
            inserted = extract_rows_for_selected_file(
                session=session,
                run_id=run_id,
                account_folder=account_folder,
                file_info=best["file_info"]
            )

            extracted_rows_count += inserted
            aggregate_account(session, run_id, account_folder)
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
