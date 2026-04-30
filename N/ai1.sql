CREATE OR REPLACE PROCEDURE PROCESS_OPEN_MARKET_SUBMISSIONS_AI()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS
$$
import re
import json
from decimal import Decimal, InvalidOperation


STAGE_NAME_LITERAL = "'@EXPERIMENT_TEAM_DB.PUBLIC.DROPBOX_STAGE'"
STAGE_NAME_FOR_LIST = "@EXPERIMENT_TEAM_DB.PUBLIC.DROPBOX_STAGE"

TARGET_TABLE = "EXPERIMENT_TEAM_DB.PUBLIC.INSURED_SUBMISSION_EXTRACTED_VALUES_AI"
DEBUG_TABLE = "EXPERIMENT_TEAM_DB.PUBLIC.INSURED_SUBMISSION_FILE_AI_DEBUG"

VALID_YEARS = {"2024", "2025", "2026"}

AI_EXTRACT_SUPPORTED_EXTENSIONS = {
    "pdf", "png", "pptx", "ppt", "eml", "doc", "docx",
    "jpeg", "jpg", "htm", "html", "text", "txt",
    "tif", "tiff", "bmp", "gif", "webp", "md"
}

AI_PARSE_SUPPORTED_EXTENSIONS = {
    "pdf", "docx", "pptx", "png", "jpeg", "jpg", "tif", "tiff"
}


def escape_sql_string(value):
    if value is None:
        return None
    return str(value).replace("'", "''")


def get_extension(path):
    if "." not in path:
        return ""
    return path.rsplit(".", 1)[-1].lower().strip()


def clean_number(value):
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

    if text.lower() in ("none", "null", "n/a", "na", "not found", "not available", "unknown"):
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
        number = Decimal(match.group(0))
        return -number if is_negative else number
    except InvalidOperation:
        return None


def clean_int(value):
    if value is None:
        return None

    text = str(value).strip()

    if not text:
        return None

    if text.lower() in ("none", "null", "n/a", "na", "not found", "not available", "unknown"):
        return None

    match = re.search(r"\d+", text)

    if not match:
        return None

    return int(match.group(0))


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
    Converts:
    dropbox_stage/Open Market/1-800-Flowers/2024 - a139860/submission/file.pdf

    Into:
    Open Market/1-800-Flowers/2024 - a139860/submission/file.pdf
    """
    text = str(list_name).replace("\\", "/").replace("%20", " ")
    lower_text = text.lower()

    idx = lower_text.find("open market/")

    if idx >= 0:
        return text[idx:]

    return text


def parse_stage_path(relative_path):
    """
    Valid path:

    Open Market/<insured_name>/<year_folder>/submission/<file or subfolder/file>

    Excludes:

    Open Market/<insured_name>/<year_folder>/modelling/original/submission/file
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

    if "submission" not in first_folder_after_year:
        return None

    return {
        "insured_name": insured_name,
        "submission_year": submission_year,
        "relative_path": relative_path
    }


def get_response_format_json():
    response_format = {
        "schema": {
            "type": "object",
            "properties": {
                "tiv_based_on_avg_inventory": {
                    "type": "string",
                    "description": (
                        "Extract the grand total Total Insurable Value based on average inventory. "
                        "This may be written as Total TIV based on Avg Inventory, TIV based on average inventory, "
                        "total values based on average inventory, total insurable value including average inventory, "
                        "or similar wording. Prefer the GRAND TOTAL or overall total value, not a location-level value. "
                        "Return only the amount as a string. If not found, return null."
                    )
                },
                "tiv_evidence": {
                    "type": "string",
                    "description": (
                        "Return a short evidence snippet or nearby text showing where the TIV based on average "
                        "inventory value was found. If not found, return null."
                    )
                },
                "total_net_paid_loss": {
                    "type": "string",
                    "description": (
                        "Extract the total net paid loss from the loss summary or loss history. "
                        "This may appear as Net Paid Loss, Total Net Paid Loss, Paid Loss, Total Paid Loss, "
                        "10 Year Total, 14 Year Total, loss total, or similar wording. "
                        "Prefer the overall total row for the full loss-history period, not individual year values. "
                        "Return only the amount as a string. If not found, return null."
                    )
                },
                "loss_years": {
                    "type": "string",
                    "description": (
                        "Extract the number of years covered by the loss summary or loss history. "
                        "For example, return 10 from 10 Year Total and 14 from 14 Year Total. "
                        "Return only the number as a string. If not found, return null."
                    )
                },
                "loss_evidence": {
                    "type": "string",
                    "description": (
                        "Return a short evidence snippet or nearby text showing where the total net paid loss "
                        "and loss years were found. If not found, return null."
                    )
                },
                "document_type": {
                    "type": "string",
                    "description": (
                        "Classify the document type briefly, for example SOV, schedule of values, loss summary, "
                        "submission document, policy form, email, engineering report, or unknown."
                    )
                }
            }
        }
    }

    return json.dumps(response_format)


def run_ai_extract(session, relative_path):
    escaped_path = escape_sql_string(relative_path)
    response_format = escape_sql_string(get_response_format_json())

    sql = f"""
        SELECT AI_EXTRACT(
            file => TO_FILE({STAGE_NAME_LITERAL}, '{escaped_path}'),
            responseFormat => PARSE_JSON('{response_format}'),
            config => {{'scale_factor': 2.0}},
            scores => TRUE
        )::STRING AS AI_RESULT
    """

    rows = session.sql(sql).collect()

    if not rows:
        return None

    raw = rows[0]["AI_RESULT"]

    if raw is None:
        return None

    return json.loads(raw)


def run_ai_parse_document(session, relative_path, extension):
    if extension not in AI_PARSE_SUPPORTED_EXTENSIONS:
        return None

    escaped_path = escape_sql_string(relative_path)

    sql = f"""
        SELECT AI_PARSE_DOCUMENT(
            TO_FILE({STAGE_NAME_LITERAL}, '{escaped_path}'),
            {{'mode': 'LAYOUT'}},
            TRUE
        )::STRING AS PARSE_RESULT
    """

    rows = session.sql(sql).collect()

    if not rows:
        return None

    raw = rows[0]["PARSE_RESULT"]

    if raw is None:
        return None

    return json.loads(raw)


def insert_file_debug(
    session,
    insured_name,
    submission_year,
    file_path,
    file_extension,
    ai_extract_result,
    ai_parse_result,
    status,
    error_message
):
    sql = f"""
        INSERT INTO {DEBUG_TABLE} (
            INSURED_NAME,
            SUBMISSION_YEAR,
            FILE_PATH,
            FILE_EXTENSION,
            AI_EXTRACT_RESULT,
            AI_PARSE_RESULT,
            EXTRACTION_STATUS,
            ERROR_MESSAGE,
            PROCESSED_AT
        )
        SELECT
            ?,
            ?,
            ?,
            ?,
            PARSE_JSON(?),
            PARSE_JSON(?),
            ?,
            ?,
            CURRENT_TIMESTAMP()
    """

    session.sql(
        sql,
        params=[
            insured_name,
            submission_year,
            file_path,
            file_extension,
            json.dumps(ai_extract_result) if ai_extract_result is not None else "null",
            json.dumps(ai_parse_result) if ai_parse_result is not None else "null",
            status,
            error_message
        ]
    ).collect()


def extract_fields_from_ai_result(ai_result):
    if not ai_result:
        return {}

    response = ai_result.get("response", {})

    if response is None:
        response = {}

    return {
        "tiv_based_on_avg_inventory": response.get("tiv_based_on_avg_inventory"),
        "tiv_evidence": response.get("tiv_evidence"),
        "total_net_paid_loss": response.get("total_net_paid_loss"),
        "loss_years": response.get("loss_years"),
        "loss_evidence": response.get("loss_evidence"),
        "document_type": response.get("document_type")
    }


def score_candidate(value, evidence, source_file):
    if value is None:
        return -1

    score = 50

    if evidence:
        score += 20

    lower_file = source_file.lower()

    if "sov" in lower_file or "schedule" in lower_file or "values" in lower_file:
        score += 10

    if "loss" in lower_file or "summary" in lower_file:
        score += 10

    return score


def choose_best_tiv(candidates):
    valid = []

    for c in candidates:
        value = clean_number(c.get("value"))

        if value is None:
            continue

        c["clean_value"] = value
        c["rank_score"] = score_candidate(
            value=value,
            evidence=c.get("evidence"),
            source_file=c.get("source_file", "")
        )

        valid.append(c)

    if not valid:
        return None

    return sorted(
        valid,
        key=lambda x: (x.get("rank_score", 0), x.get("clean_value") or Decimal("0")),
        reverse=True
    )[0]


def choose_best_loss(candidates):
    valid = []

    for c in candidates:
        value = clean_number(c.get("value"))
        years = clean_int(c.get("loss_years"))

        if value is None:
            continue

        c["clean_value"] = value
        c["clean_years"] = years
        c["rank_score"] = score_candidate(
            value=value,
            evidence=c.get("evidence"),
            source_file=c.get("source_file", "")
        )

        valid.append(c)

    if not valid:
        return None

    return sorted(
        valid,
        key=lambda x: (x.get("rank_score", 0), x.get("clean_value") or Decimal("0")),
        reverse=True
    )[0]


def insert_final_result(
    session,
    insured_name,
    submission_year,
    tiv_value,
    tiv_source_file,
    tiv_evidence,
    total_net_paid_loss,
    loss_years,
    loss_source_file,
    loss_evidence,
    all_processed_files,
    all_skipped_files,
    extraction_method,
    status,
    error_message
):
    delete_sql = f"""
        DELETE FROM {TARGET_TABLE}
        WHERE INSURED_NAME = ?
          AND SUBMISSION_YEAR = ?
    """

    session.sql(
        delete_sql,
        params=[insured_name, submission_year]
    ).collect()

    insert_sql = f"""
        INSERT INTO {TARGET_TABLE} (
            INSURED_NAME,
            SUBMISSION_YEAR,
            TIV_BASED_ON_AVG_INVENTORY,
            TIV_SOURCE_FILE,
            TIV_EVIDENCE,
            TOTAL_NET_PAID_LOSS,
            LOSS_YEARS,
            LOSS_SOURCE_FILE,
            LOSS_EVIDENCE,
            ALL_PROCESSED_FILES,
            ALL_SKIPPED_FILES,
            EXTRACTION_METHOD,
            EXTRACTION_STATUS,
            ERROR_MESSAGE,
            PROCESSED_AT
        )
        SELECT
            ?,
            ?,
            TRY_TO_DECIMAL(?, 38, 2),
            ?,
            ?,
            TRY_TO_DECIMAL(?, 38, 2),
            TRY_TO_NUMBER(?),
            ?,
            ?,
            PARSE_JSON(?),
            PARSE_JSON(?),
            ?,
            ?,
            ?,
            CURRENT_TIMESTAMP()
    """

    session.sql(
        insert_sql,
        params=[
            insured_name,
            submission_year,
            str(tiv_value) if tiv_value is not None else None,
            tiv_source_file,
            tiv_evidence,
            str(total_net_paid_loss) if total_net_paid_loss is not None else None,
            str(loss_years) if loss_years is not None else None,
            loss_source_file,
            loss_evidence,
            json.dumps(all_processed_files),
            json.dumps(all_skipped_files),
            extraction_method,
            status,
            error_message
        ]
    ).collect()


def main(session):
    session.sql(f"TRUNCATE TABLE {DEBUG_TABLE}").collect()

    list_sql = f"""
        LIST {STAGE_NAME_FOR_LIST}
        PATTERN = '.*'
    """

    listed_files = session.sql(list_sql).collect()

    total_listed = 0
    total_open_market_files = 0
    total_year_files = 0
    total_submission_files = 0
    total_supported_files = 0
    total_skipped_unsupported_files = 0

    grouped_files = {}

    for row in listed_files:
        total_listed += 1

        list_name = row["name"]
        relative_path = extract_relative_path(list_name)
        lower_path = relative_path.lower()

        if "open market/" in lower_path:
            total_open_market_files += 1

        if "2024" in lower_path or "2025" in lower_path or "2026" in lower_path:
            total_year_files += 1

        parsed = parse_stage_path(relative_path)

        if not parsed:
            continue

        total_submission_files += 1

        extension = get_extension(relative_path)

        key = (
            parsed["insured_name"],
            parsed["submission_year"]
        )

        grouped_files.setdefault(
            key,
            {
                "supported": [],
                "skipped": []
            }
        )

        if extension in AI_EXTRACT_SUPPORTED_EXTENSIONS:
            grouped_files[key]["supported"].append(relative_path)
            total_supported_files += 1
        else:
            grouped_files[key]["skipped"].append(relative_path)
            total_skipped_unsupported_files += 1

    inserted_count = 0
    warning_count = 0

    for (insured_name, submission_year), file_bucket in grouped_files.items():
        supported_files = file_bucket["supported"]
        skipped_files = file_bucket["skipped"]

        tiv_candidates = []
        loss_candidates = []
        processed_files = []
        file_errors = []

        for relative_path in supported_files:
            extension = get_extension(relative_path)

            try:
                ai_extract_result = run_ai_extract(
                    session=session,
                    relative_path=relative_path
                )

                ai_parse_result = None

                try:
                    ai_parse_result = run_ai_parse_document(
                        session=session,
                        relative_path=relative_path,
                        extension=extension
                    )
                except Exception as parse_error:
                    ai_parse_result = {
                        "parse_error": str(parse_error)
                    }

                insert_file_debug(
                    session=session,
                    insured_name=insured_name,
                    submission_year=submission_year,
                    file_path=relative_path,
                    file_extension=extension,
                    ai_extract_result=ai_extract_result,
                    ai_parse_result=ai_parse_result,
                    status="SUCCESS",
                    error_message=None
                )

                fields = extract_fields_from_ai_result(ai_extract_result)

                tiv_candidates.append({
                    "value": fields.get("tiv_based_on_avg_inventory"),
                    "evidence": fields.get("tiv_evidence"),
                    "source_file": relative_path,
                    "document_type": fields.get("document_type")
                })

                loss_candidates.append({
                    "value": fields.get("total_net_paid_loss"),
                    "loss_years": fields.get("loss_years"),
                    "evidence": fields.get("loss_evidence"),
                    "source_file": relative_path,
                    "document_type": fields.get("document_type")
                })

                processed_files.append(relative_path)

            except Exception as e:
                error_message = str(e)

                file_errors.append(f"{relative_path}: {error_message}")

                insert_file_debug(
                    session=session,
                    insured_name=insured_name,
                    submission_year=submission_year,
                    file_path=relative_path,
                    file_extension=extension,
                    ai_extract_result=None,
                    ai_parse_result=None,
                    status="FAILED",
                    error_message=error_message
                )

        best_tiv = choose_best_tiv(tiv_candidates)
        best_loss = choose_best_loss(loss_candidates)

        tiv_value = best_tiv.get("clean_value") if best_tiv else None
        tiv_source_file = best_tiv.get("source_file") if best_tiv else None
        tiv_evidence = best_tiv.get("evidence") if best_tiv else None

        total_net_paid_loss = best_loss.get("clean_value") if best_loss else None
        loss_years = best_loss.get("clean_years") if best_loss else None
        loss_source_file = best_loss.get("source_file") if best_loss else None
        loss_evidence = best_loss.get("evidence") if best_loss else None

        missing_fields = []

        if tiv_value is None:
            missing_fields.append("TIV_BASED_ON_AVG_INVENTORY")

        if total_net_paid_loss is None:
            missing_fields.append("TOTAL_NET_PAID_LOSS")

        if loss_years is None:
            missing_fields.append("LOSS_YEARS")

        error_parts = []

        if missing_fields:
            error_parts.append("Missing fields: " + ", ".join(missing_fields))

        if skipped_files:
            error_parts.append(
                "Skipped unsupported files: "
                + ", ".join(skipped_files[:10])
            )

        if file_errors:
            error_parts.append("File errors: " + " | ".join(file_errors[:10]))

        if not supported_files and skipped_files:
            status = "SKIPPED_UNSUPPORTED_ONLY"
        elif not missing_fields and not file_errors:
            status = "SUCCESS"
        elif processed_files:
            status = "PARTIAL"
        else:
            status = "FAILED"

        if status != "SUCCESS":
            warning_count += 1

        error_message = " || ".join(error_parts) if error_parts else None

        insert_final_result(
            session=session,
            insured_name=insured_name,
            submission_year=submission_year,
            tiv_value=tiv_value,
            tiv_source_file=tiv_source_file,
            tiv_evidence=tiv_evidence,
            total_net_paid_loss=total_net_paid_loss,
            loss_years=loss_years,
            loss_source_file=loss_source_file,
            loss_evidence=loss_evidence,
            all_processed_files=processed_files,
            all_skipped_files=skipped_files,
            extraction_method="AI_EXTRACT_WITH_AI_PARSE_DOCUMENT_DEBUG",
            status=status,
            error_message=error_message
        )

        inserted_count += 1

    return (
        f"Completed AI extraction. "
        f"Total listed files: {total_listed}. "
        f"Open Market files: {total_open_market_files}. "
        f"Files containing 2024/2025/2026: {total_year_files}. "
        f"Matched top-level submission files for 2024/2025/2026: {total_submission_files}. "
        f"AI_EXTRACT supported files: {total_supported_files}. "
        f"Skipped unsupported files: {total_skipped_unsupported_files}. "
        f"Insured-year groups: {len(grouped_files)}. "
        f"Inserted/updated rows: {inserted_count}. "
        f"Rows with warnings/errors: {warning_count}."
    )
$$;
