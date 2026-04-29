CREATE OR REPLACE PROCEDURE PROCESS_OPEN_MARKET_SUBMISSIONS_XLSX()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'openpyxl')
HANDLER = 'main'
EXECUTE AS OWNER
AS
$$
import re
import json
from io import BytesIO
from decimal import Decimal, InvalidOperation

from snowflake.snowpark.files import SnowflakeFile
from openpyxl import load_workbook


STAGE_NAME = "@EXPERIMENT_TEAM_DB.PUBLIC.DROPBOX_STAGE"
TARGET_TABLE = "EXPERIMENT_TEAM_DB.PUBLIC.INSURED_SUBMISSION_EXTRACTED_VALUES"

VALID_YEARS = {"2024", "2025", "2026"}


def normalize_text(value):
    if value is None:
        return ""

    text = str(value).strip().lower()
    text = re.sub(r"\s+", " ", text)
    return text


def clean_number(value):
    """
    Converts values like:
    $1,580,215,088
    1,580,215,088
    (123,456)
    into Decimal.
    """
    if value is None:
        return None

    if isinstance(value, (int, float, Decimal)):
        try:
            return Decimal(str(value))
        except Exception:
            return None

    text = str(value).strip()

    if not text:
        return None

    if text.lower() in ("none", "null", "nan"):
        return None

    is_negative = False

    if text.startswith("(") and text.endswith(")"):
        is_negative = True

    text = text.replace("$", "")
    text = text.replace(",", "")
    text = text.replace("(", "")
    text = text.replace(")", "")
    text = text.replace("%", "")
    text = text.strip()

    match = re.search(r"-?\d+(\.\d+)?", text)

    if not match:
        return None

    try:
        num = Decimal(match.group(0))
        return -num if is_negative else num
    except InvalidOperation:
        return None


def is_probable_year_folder(folder_name):
    """
    Accepts folders like:
    2024 - a139860
    2025 - a176544
    2026 -
    2026
    """
    if folder_name is None:
        return None

    text = str(folder_name).strip()

    match = re.match(r"^(2024|2025|2026)\b", text)

    if not match:
        return None

    return match.group(1)


def extract_relative_path(list_name):
    """
    Converts Snowflake LIST path into a stage-relative path.

    Example input:
    dropbox_stage/Open Market/1-800-Flowers/2024 - a139860/submission/file.xlsx

    Output:
    Open Market/1-800-Flowers/2024 - a139860/submission/file.xlsx
    """
    text = str(list_name).replace("\\", "/").replace("%20", " ")
    lower_text = text.lower()

    idx = lower_text.find("open market/")

    if idx >= 0:
        return text[idx:]

    return text


def parse_stage_path(relative_path):
    """
    Valid path expected:

    Open Market/<insured_name>/<year_folder>/submission/<file or subfolder/file.xlsx>

    This intentionally excludes paths like:

    Open Market/<insured_name>/<year_folder>/modelling/original/submission/file.xlsx
    """
    path = str(relative_path).replace("\\", "/").replace("%20", " ")

    parts = [p.strip() for p in path.split("/") if p and p.strip()]
    lower_parts = [p.lower() for p in parts]

    if "open market" not in lower_parts:
        return None

    open_market_index = lower_parts.index("open market")

    if len(parts) <= open_market_index + 1:
        return None

    insured_name = parts[open_market_index + 1]

    year_index = None
    submission_year = None

    for i in range(open_market_index + 2, len(parts)):
        year = is_probable_year_folder(parts[i])

        if year in VALID_YEARS:
            year_index = i
            submission_year = year
            break

    if year_index is None:
        return None

    if len(parts) <= year_index + 1:
        return None

    first_folder_after_year = lower_parts[year_index + 1]

    # Only process the main submission folder directly under year folder.
    # This avoids modelling/original/submission paths.
    if "submission" not in first_folder_after_year:
        return None

    return {
        "insured_name": insured_name,
        "submission_year": submission_year,
        "relative_path": relative_path
    }


def get_scoped_file_url(session, relative_path):
    escaped_path = relative_path.replace("'", "''")

    sql = f"""
        SELECT BUILD_SCOPED_FILE_URL({STAGE_NAME}, '{escaped_path}') AS FILE_URL
    """

    return session.sql(sql).collect()[0]["FILE_URL"]


def sheet_to_matrix(ws):
    matrix = []

    for row in ws.iter_rows(values_only=True):
        matrix.append(list(row))

    return matrix


def find_tiv_candidates(matrix, source_file, sheet_name):
    """
    Finds:
    TOTAL TIV based on Avg Inventory

    Priority:
    1. GRAND TOTAL row + TIV Avg Inventory column
    2. TOTAL row + TIV Avg Inventory column
    3. nearby fallback around TIV Avg Inventory text
    """
    candidates = []

    if not matrix:
        return candidates

    max_cols = max(len(r) for r in matrix)

    avg_inventory_cols = set()

    # Find likely TIV based on average inventory columns.
    for r_idx, row in enumerate(matrix):
        for c_idx in range(max_cols):
            val = row[c_idx] if c_idx < len(row) else None
            text = normalize_text(val)

            if not text:
                continue

            has_tiv = "tiv" in text
            has_inventory = "inventory" in text
            has_avg = "avg" in text or "average" in text

            if has_tiv and has_inventory and has_avg:
                avg_inventory_cols.add(c_idx)

    # Find total rows and read value from TIV Avg Inventory column.
    for r_idx, row in enumerate(matrix):
        row_text = " ".join(normalize_text(v) for v in row if v is not None)

        is_grand_total = "grand total" in row_text
        is_total = re.search(r"\btotal\b", row_text) is not None

        for c_idx in avg_inventory_cols:
            val = row[c_idx] if c_idx < len(row) else None
            num = clean_number(val)

            if num is not None:
                if is_grand_total:
                    score = 100
                elif is_total:
                    score = 75
                else:
                    score = 40

                candidates.append({
                    "value": num,
                    "score": score,
                    "source_file": source_file,
                    "sheet_name": sheet_name,
                    "reason": "TIV based on Avg Inventory column with total row"
                })

    # Fallback for merged/odd headers.
    for r_idx, row in enumerate(matrix):
        for c_idx, val in enumerate(row):
            text = normalize_text(val)

            if "tiv" in text and "inventory" in text and ("avg" in text or "average" in text):
                for rr in range(r_idx, min(r_idx + 15, len(matrix))):
                    nearby_row = matrix[rr]
                    nearby_text = " ".join(normalize_text(v) for v in nearby_row if v is not None)

                    if "grand total" in nearby_text or re.search(r"\btotal\b", nearby_text):
                        for cc in range(max(0, c_idx - 2), min(max_cols, c_idx + 6)):
                            nearby_val = nearby_row[cc] if cc < len(nearby_row) else None
                            num = clean_number(nearby_val)

                            if num is not None:
                                candidates.append({
                                    "value": num,
                                    "score": 60,
                                    "source_file": source_file,
                                    "sheet_name": sheet_name,
                                    "reason": "Nearby fallback around TIV Avg Inventory text"
                                })

    return candidates


def find_loss_candidates(matrix, source_file, sheet_name):
    """
    Finds:
    total net paid loss
    loss years

    Priority:
    1. 10/14/etc Year Total row + Net Paid Loss column
    2. fallback from Year Total row
    """
    candidates = []

    if not matrix:
        return candidates

    max_cols = max(len(r) for r in matrix)

    net_paid_cols = set()

    # Find likely Net Paid Loss columns.
    for r_idx, row in enumerate(matrix):
        for c_idx in range(max_cols):
            val = row[c_idx] if c_idx < len(row) else None
            text = normalize_text(val)

            if not text:
                continue

            if "net paid loss" in text:
                net_paid_cols.add(c_idx)
            elif "paid loss" in text and "net" in text:
                net_paid_cols.add(c_idx)

    # Find rows like 10 Year Total / 14 Year Total.
    for r_idx, row in enumerate(matrix):
        row_text = " ".join(normalize_text(v) for v in row if v is not None)

        year_match = re.search(r"\b(\d{1,2})\s*year\s*total\b", row_text)

        if not year_match:
            continue

        loss_years = int(year_match.group(1))

        for c_idx in net_paid_cols:
            val = row[c_idx] if c_idx < len(row) else None
            num = clean_number(val)

            if num is not None:
                candidates.append({
                    "value": num,
                    "loss_years": loss_years,
                    "score": 100,
                    "source_file": source_file,
                    "sheet_name": sheet_name,
                    "reason": "Year Total row with Net Paid Loss column"
                })

    # Fallback if Net Paid Loss column was not detected.
    if not candidates:
        for r_idx, row in enumerate(matrix):
            row_text = " ".join(normalize_text(v) for v in row if v is not None)

            year_match = re.search(r"\b(\d{1,2})\s*year\s*total\b", row_text)

            if not year_match:
                continue

            loss_years = int(year_match.group(1))

            numeric_values = []

            for val in row:
                num = clean_number(val)

                if num is not None:
                    numeric_values.append(num)

            if numeric_values:
                selected = max(numeric_values)

                candidates.append({
                    "value": selected,
                    "loss_years": loss_years,
                    "score": 60,
                    "source_file": source_file,
                    "sheet_name": sheet_name,
                    "reason": "Fallback from Year Total row"
                })

    return candidates


def process_xlsx_file(session, relative_path):
    scoped_url = get_scoped_file_url(session, relative_path)

    tiv_candidates = []
    loss_candidates = []

    with SnowflakeFile.open(scoped_url, "rb") as f:
        file_bytes = f.read()

    workbook = load_workbook(
        filename=BytesIO(file_bytes),
        data_only=True,
        read_only=True
    )

    for ws in workbook.worksheets:
        matrix = sheet_to_matrix(ws)

        tiv_candidates.extend(
            find_tiv_candidates(
                matrix=matrix,
                source_file=relative_path,
                sheet_name=ws.title
            )
        )

        loss_candidates.extend(
            find_loss_candidates(
                matrix=matrix,
                source_file=relative_path,
                sheet_name=ws.title
            )
        )

    return tiv_candidates, loss_candidates


def choose_best_candidate(candidates):
    if not candidates:
        return None

    return sorted(
        candidates,
        key=lambda x: (
            x.get("score", 0),
            x.get("value") or Decimal("0")
        ),
        reverse=True
    )[0]


def insert_result(
    session,
    insured_name,
    submission_year,
    tiv_value,
    tiv_source_file,
    total_net_paid_loss,
    loss_years,
    loss_source_file,
    all_processed_files,
    status,
    error_message
):
    """
    This insert uses TRY_TO_DECIMAL and TRY_TO_NUMBER so that missing values
    are stored as NULL instead of failing with:
    Numeric value 'None' is not recognized.
    """

    delete_sql = f"""
        DELETE FROM {TARGET_TABLE}
        WHERE INSURED_NAME = ?
          AND SUBMISSION_YEAR = ?
    """

    session.sql(
        delete_sql,
        params=[insured_name, submission_year]
    ).collect()

    def decimal_param(value):
        if value is None:
            return None
        return str(value)

    def int_param(value):
        if value is None:
            return None
        return str(value)

    insert_sql = f"""
        INSERT INTO {TARGET_TABLE} (
            INSURED_NAME,
            SUBMISSION_YEAR,
            TIV_BASED_ON_AVG_INVENTORY,
            TIV_SOURCE_FILE,
            TOTAL_NET_PAID_LOSS,
            LOSS_YEARS,
            LOSS_SOURCE_FILE,
            ALL_PROCESSED_FILES,
            EXTRACTION_STATUS,
            ERROR_MESSAGE,
            PROCESSED_AT
        )
        SELECT
            ?,
            ?,
            TRY_TO_DECIMAL(?, 38, 2),
            ?,
            TRY_TO_DECIMAL(?, 38, 2),
            TRY_TO_NUMBER(?),
            ?,
            PARSE_JSON(?),
            ?,
            ?,
            CURRENT_TIMESTAMP()
    """

    session.sql(
        insert_sql,
        params=[
            insured_name,
            submission_year,
            decimal_param(tiv_value),
            tiv_source_file,
            decimal_param(total_net_paid_loss),
            int_param(loss_years),
            loss_source_file,
            json.dumps(all_processed_files),
            status,
            error_message
        ]
    ).collect()


def main(session):
    list_sql = f"""
        LIST {STAGE_NAME}
        PATTERN = '.*'
    """

    listed_files = session.sql(list_sql).collect()

    total_listed = 0
    total_xlsx = 0
    total_top_level_submission_xlsx = 0
    total_matched = 0

    grouped_files = {}

    for row in listed_files:
        total_listed += 1

        list_name = row["name"]
        relative_path = extract_relative_path(list_name)
        lower_path = relative_path.lower()

        if not lower_path.endswith(".xlsx"):
            continue

        total_xlsx += 1

        parsed = parse_stage_path(relative_path)

        if not parsed:
            continue

        total_top_level_submission_xlsx += 1
        total_matched += 1

        key = (
            parsed["insured_name"],
            parsed["submission_year"]
        )

        grouped_files.setdefault(key, []).append(relative_path)

    inserted_count = 0
    error_count = 0

    for (insured_name, submission_year), files in grouped_files.items():
        all_tiv_candidates = []
        all_loss_candidates = []
        processed_files = []
        errors = []

        for relative_path in files:
            try:
                tiv_candidates, loss_candidates = process_xlsx_file(
                    session=session,
                    relative_path=relative_path
                )

                all_tiv_candidates.extend(tiv_candidates)
                all_loss_candidates.extend(loss_candidates)
                processed_files.append(relative_path)

            except Exception as e:
                errors.append(f"{relative_path}: {str(e)}")

        best_tiv = choose_best_candidate(all_tiv_candidates)
        best_loss = choose_best_candidate(all_loss_candidates)

        tiv_value = best_tiv["value"] if best_tiv else None
        tiv_source_file = best_tiv["source_file"] if best_tiv else None

        total_net_paid_loss = best_loss["value"] if best_loss else None
        loss_years = best_loss["loss_years"] if best_loss else None
        loss_source_file = best_loss["source_file"] if best_loss else None

        missing_fields = []

        if tiv_value is None:
            missing_fields.append("TIV_BASED_ON_AVG_INVENTORY")

        if total_net_paid_loss is None:
            missing_fields.append("TOTAL_NET_PAID_LOSS")

        if loss_years is None:
            missing_fields.append("LOSS_YEARS")

        if not missing_fields and not errors:
            status = "SUCCESS"
        elif not missing_fields and errors:
            status = "SUCCESS_WITH_FILE_ERRORS"
        elif processed_files:
            status = "PARTIAL"
        else:
            status = "FAILED"

        error_message_parts = []

        if missing_fields:
            error_message_parts.append(
                "Missing fields: " + ", ".join(missing_fields)
            )

        if errors:
            error_message_parts.append(
                "File errors: " + " | ".join(errors)
            )

        error_message = " || ".join(error_message_parts) if error_message_parts else None

        insert_result(
            session=session,
            insured_name=insured_name,
            submission_year=submission_year,
            tiv_value=tiv_value,
            tiv_source_file=tiv_source_file,
            total_net_paid_loss=total_net_paid_loss,
            loss_years=loss_years,
            loss_source_file=loss_source_file,
            all_processed_files=processed_files,
            status=status,
            error_message=error_message
        )

        inserted_count += 1

        if status in ("FAILED", "PARTIAL", "SUCCESS_WITH_FILE_ERRORS"):
            error_count += 1

    return (
        f"Completed. "
        f"Total listed files: {total_listed}. "
        f"Total xlsx files: {total_xlsx}. "
        f"Top-level submission xlsx files: {total_top_level_submission_xlsx}. "
        f"Matched valid 2024/2025/2026 files: {total_matched}. "
        f"Insured-year groups: {len(grouped_files)}. "
        f"Inserted/updated rows: {inserted_count}. "
        f"Rows with warnings/errors: {error_count}."
    )
$$;
