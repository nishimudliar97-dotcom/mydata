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
    text = re.sub(r"\\s+", " ", text)
    return text


def clean_number(value):
    """
    Converts values like '$1,580,215,088', '(123,456)', or numeric Excel cells
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

    is_negative = False
    if text.startswith("(") and text.endswith(")"):
        is_negative = True

    text = text.replace("$", "")
    text = text.replace(",", "")
    text = text.replace("(", "")
    text = text.replace(")", "")
    text = text.replace("%", "")
    text = text.strip()

    match = re.search(r"-?\\d+(\\.\\d+)?", text)
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
    - 2024 - a139860
    - 2025 - a176544
    - 2026
    """
    m = re.match(r"^(2024|2025|2026)\\b", folder_name.strip())
    if not m:
        return None
    return m.group(1)


def extract_relative_path(list_name):
    """
    LIST output may return something like:
    experiment_team_db.public.dropbox_stage/Open Market/1-800-Flowers/2025 - a176544/submission/file.xlsx

    We only need:
    Open Market/1-800-Flowers/2025 - a176544/submission/file.xlsx
    """
    text = str(list_name)

    idx = text.lower().find("open market/")
    if idx >= 0:
        return text[idx:]

    return text


def parse_stage_path(relative_path):
    """
    Expected structure:
    Open Market/<insured_name>/<year_folder>/submission/<file or subfolder/file.xlsx>

    Returns:
    {
      insured_name,
      submission_year,
      relative_path
    }
    """
    parts = [p for p in relative_path.split("/") if p]

    if len(parts) < 5:
        return None

    if parts[0].lower() != "open market":
        return None

    insured_name = parts[1]

    year_index = None
    submission_year = None

    for i, part in enumerate(parts):
        year = is_probable_year_folder(part)
        if year:
            year_index = i
            submission_year = year
            break

    if year_index is None or submission_year not in VALID_YEARS:
        return None

    # submission must appear after year folder
    lower_parts_after_year = [p.lower().strip() for p in parts[year_index + 1:]]
    if "submission" not in lower_parts_after_year:
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
    Finds TIV based on average inventory.

    High-confidence condition:
    - A column header contains TIV + AVG/AVERAGE + INVENTORY
    - A row contains GRAND TOTAL
    - Value at intersection is numeric
    """
    candidates = []

    if not matrix:
        return candidates

    max_cols = max(len(r) for r in matrix)

    avg_inventory_cols = set()

    # First pass: find likely TIV Avg Inventory columns.
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

    # Second pass: find GRAND TOTAL row and read same column.
    for r_idx, row in enumerate(matrix):
        row_text = " ".join(normalize_text(v) for v in row if v is not None)

        is_grand_total = "grand total" in row_text
        is_total = re.search(r"\\btotal\\b", row_text) is not None

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

    # Fallback: look around cells containing avg inventory phrase.
    # This is less confident, useful when headers/merged cells are odd.
    for r_idx, row in enumerate(matrix):
        for c_idx, val in enumerate(row):
            text = normalize_text(val)
            if "tiv" in text and "inventory" in text and ("avg" in text or "average" in text):
                for rr in range(r_idx, min(r_idx + 15, len(matrix))):
                    nearby_row = matrix[rr]
                    nearby_text = " ".join(normalize_text(v) for v in nearby_row if v is not None)
                    if "grand total" in nearby_text or re.search(r"\\btotal\\b", nearby_text):
                        for cc in range(max(0, c_idx - 2), min(max_cols, c_idx + 4)):
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
    Finds total net paid loss and number of years.

    High-confidence condition:
    - A column header contains Net Paid Loss
    - A row contains 10 Year Total / 14 Year Total / etc.
    - Value at intersection is numeric
    """
    candidates = []

    if not matrix:
        return candidates

    max_cols = max(len(r) for r in matrix)

    net_paid_cols = set()

    # First pass: find likely Net Paid Loss columns.
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

    # Second pass: find "10 Year Total", "14 Year Total", etc.
    for r_idx, row in enumerate(matrix):
        row_text = " ".join(normalize_text(v) for v in row if v is not None)

        year_match = re.search(r"\\b(\\d{1,2})\\s*year\\s*total\\b", row_text)
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

    # Fallback: if no Net Paid Loss column was found, look for year total row
    # and pick the most likely numeric value on that row.
    if not candidates:
        for r_idx, row in enumerate(matrix):
            row_text = " ".join(normalize_text(v) for v in row if v is not None)
            year_match = re.search(r"\\b(\\d{1,2})\\s*year\\s*total\\b", row_text)

            if not year_match:
                continue

            loss_years = int(year_match.group(1))
            numeric_values = []

            for val in row:
                num = clean_number(val)
                if num is not None:
                    numeric_values.append(num)

            if numeric_values:
                # Usually the total paid loss is one of the larger numeric values on the total row.
                # This is a fallback only, so confidence is lower.
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

    # Highest score first. If same score, choose the larger value.
    # This helps when the same sheet has average rows and total rows.
    return sorted(
        candidates,
        key=lambda x: (x.get("score", 0), x.get("value") or Decimal("0")),
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
    # Make rerun idempotent for same insured + year.
    delete_sql = f"""
        DELETE FROM {TARGET_TABLE}
        WHERE INSURED_NAME = ?
          AND SUBMISSION_YEAR = ?
    """
    session.sql(delete_sql, params=[insured_name, submission_year]).collect()

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
            ?,
            ?,
            ?,
            ?,
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
            float(tiv_value) if tiv_value is not None else None,
            tiv_source_file,
            float(total_net_paid_loss) if total_net_paid_loss is not None else None,
            loss_years,
            loss_source_file,
            json.dumps(all_processed_files),
            status,
            error_message
        ]
    ).collect()


def main(session):
    # List only xlsx files. This POC intentionally ignores PDFs for now.
    list_sql = f"""
        LIST {STAGE_NAME}
        PATTERN = '.*[.]xlsx$'
    """

    listed_files = session.sql(list_sql).collect()

    grouped_files = {}

    for row in listed_files:
        list_name = row["name"]
        relative_path = extract_relative_path(list_name)

        if not relative_path.lower().endswith(".xlsx"):
            continue

        parsed = parse_stage_path(relative_path)
        if not parsed:
            continue

        key = (parsed["insured_name"], parsed["submission_year"])
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
                tiv_candidates, loss_candidates = process_xlsx_file(session, relative_path)

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
            error_message_parts.append("Missing fields: " + ", ".join(missing_fields))
        if errors:
            error_message_parts.append("File errors: " + " | ".join(errors))

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

    return f"Completed. Inserted/updated rows: {inserted_count}. Rows with warnings/errors: {error_count}."
$$;





