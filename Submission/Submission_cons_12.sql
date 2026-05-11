CREATE OR REPLACE PROCEDURE RUN_OPEN_MARKET_CONSTRUCTION_CODE_EXTRACTION(
    STAGE_ROOT STRING,
    MAX_FOLDERS NUMBER
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
import io
from collections import Counter, defaultdict

from openpyxl import load_workbook
from snowflake.snowpark.files import SnowflakeFile


# ============================================================
# 1. STANDARD CONSTRUCTION NORMALIZATION MAP
# ============================================================
# This map is used only AFTER a value has already been found
# in a valid construction context.
#
# It does NOT decide whether a value is construction-related.
# That decision happens earlier:
#   - XLSX: only under construction-related columns
#   - PDF/DOC/DOCX/EML: only if AI_EXTRACT finds explicit
#     construction context
# ============================================================

EXACT_NORMALIZATION_MAP = {
    "UNKNOWN": "Unknown",

    "FRAME": "Frame",
    "WOOD FRAME": "Frame",
    "5 STORY WRAP": "Frame",

    "JM": "Joisted Masonry",
    "JOISTED MASONRY": "Joisted Masonry",

    "NON COMBUSTIBLE": "Non-Combustible",
    "NON-COMBUSTIBLE": "Non-Combustible",
    "NC": "Non-Combustible",
    "PEMB": "Non-Combustible",
    "METAL": "Non-Combustible",

    "MNC": "Masonry Non-Combustible",
    "MASONRY NON COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY NON-COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY": "Masonry Non-Combustible",
    "BRICK WITH MASONRY": "Masonry Non-Combustible",
    "BRICK/BLOCK": "Masonry Non-Combustible",
    "BRICK ON BLOCK": "Masonry Non-Combustible",
    "CMU": "Masonry Non-Combustible",
    "CMU BLOCK": "Masonry Non-Combustible",
    "CMU/BRICK ON BLOCK": "Masonry Non-Combustible",
    "CMU BLOCK WITH STUCCO FACADE": "Masonry Non-Combustible",
    "CMU BLOCK W/ STUCCO FACADE": "Masonry Non-Combustible",
    "CONCRETE BLOCK STUCCO": "Masonry Non-Combustible",
    "MASONRY WITH STUCCO": "Masonry Non-Combustible",
    "BRICK": "Masonry Non-Combustible",

    "CONCRETE": "Modified Fire Resistive",
    "REINFORCED CONCRETE/PODIUM": "Modified Fire Resistive",
    "CONCRETE PODIUM WITH BRICK": "Modified Fire Resistive",
    "STEEL FRAME/CONCRETE": "Modified Fire Resistive",

    "MODIFIED FIRE RESISTIVE": "Modified Fire Resistive",
    "FIRE RESISTIVE": "Fire Resistive",
    "HEAVY TIMBER JOISTED MASONRY": "Heavy Timber Joisted Masonry",
    "SUPERIOR NON-COMBUSTIBLE": "Superior Non-Combustible",
    "SUPERIOR NON COMBUSTIBLE": "Superior Non-Combustible",
    "SUPERIOR MASONRY NON-COMBUSTIBLE": "Superior Masonry Non-Combustible",
    "SUPERIOR MASONRY NON COMBUSTIBLE": "Superior Masonry Non-Combustible"
}


# ============================================================
# 2. BASIC HELPERS
# ============================================================

def clean_text(value):
    if value is None:
        return None

    value = str(value).strip()

    if not value:
        return None

    value = re.sub(r'\s+', ' ', value)
    return value


def canonical_key(value):
    """
    Creates a cleaned uppercase key used only for matching.
    """
    value = clean_text(value)

    if not value:
        return None

    value = value.upper()
    value = value.replace("–", "-").replace("—", "-")
    value = value.replace("&", " AND ")
    value = value.replace("FAÇADE", "FACADE")
    value = re.sub(r'\s+', ' ', value).strip()

    return value


def normalize_construction_type(raw_value):
    """
    Normalizes an already-valid raw construction value into
    the approved construction code categories.
    """
    key = canonical_key(raw_value)

    if not key:
        return "Unknown"

    if key in EXACT_NORMALIZATION_MAP:
        return EXACT_NORMALIZATION_MAP[key]

    # Rule-based fallback for new but clear raw values
    if "WOOD" in key and "FRAME" in key:
        return "Frame"

    if key == "FRAME":
        return "Frame"

    if "JOISTED MASONRY" in key:
        return "Joisted Masonry"

    if "HEAVY TIMBER" in key:
        return "Heavy Timber Joisted Masonry"

    if "FIRE RESISTIVE" in key and "MODIFIED" in key:
        return "Modified Fire Resistive"

    if "FIRE RESISTIVE" in key:
        return "Fire Resistive"

    if "SUPERIOR" in key and "MASONRY" in key and "NON" in key and "COMBUST" in key:
        return "Superior Masonry Non-Combustible"

    if "SUPERIOR" in key and "NON" in key and "COMBUST" in key:
        return "Superior Non-Combustible"

    if "NON" in key and "COMBUST" in key and "MASONRY" in key:
        return "Masonry Non-Combustible"

    if "NON" in key and "COMBUST" in key:
        return "Non-Combustible"

    if any(token in key for token in [
        "CMU",
        "MASONRY",
        "BRICK",
        "BLOCK",
        "TILT WALL",
        "TILT-WALL",
        "TILT UP",
        "TILT-UP",
        "CONCRETE TILT",
        "CB-TILT",
        "CB TILT"
    ]):
        return "Masonry Non-Combustible"

    if "CONCRETE" in key or "STEEL FRAME" in key:
        return "Modified Fire Resistive"

    if "METAL" in key:
        return "Non-Combustible"

    return "Unknown"


def likely_construction_header(value):
    """
    Detects real construction-related spreadsheet headers.
    This is intentionally stricter than before.
    """
    if value is None:
        return False

    h = str(value).strip().lower()
    h = re.sub(r'\s+', ' ', h)

    exact_or_strong_headers = {
        "construction",
        "construction description",
        "construction type",
        "construction code",
        "iso construction",
        "building construction",
        "construction class",
        "const",
        "const.",
        "const type",
        "const. type"
    }

    if h in exact_or_strong_headers:
        return True

    # Allow clear compound variants
    if "construction" in h and any(x in h for x in ["description", "type", "code", "class"]):
        return True

    return False


def is_probably_invalid_raw_value(value):
    """
    Filters blanks and obvious non-values.
    Does NOT filter real raw construction text.
    """
    value = clean_text(value)

    if not value:
        return True

    upper_value = value.upper()

    invalid_values = {
        "N/A",
        "NA",
        "NULL",
        "NONE",
        "-",
        "--",
        "TBD",
        "UNKNOWN VALUE"
    }

    if upper_value in invalid_values:
        return True

    return False


def add_raw_value(
    raw_value,
    raw_counter,
    normalized_counter,
    raw_to_normalized_mapping,
    evidence_rows,
    source_file,
    evidence_text
):
    raw_value = clean_text(raw_value)

    if is_probably_invalid_raw_value(raw_value):
        return

    normalized = normalize_construction_type(raw_value)

    raw_counter[raw_value] += 1
    normalized_counter[normalized] += 1
    raw_to_normalized_mapping[raw_value] = normalized

    evidence_rows.append({
        "source_file": source_file,
        "raw_value": raw_value,
        "normalized_code": normalized,
        "evidence": evidence_text
    })


def escape_sql_string(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")


def split_stage_root(stage_root):
    """
    Example:
      @OPEN_MARKET_SUBMISSION/Open_Market

    Returns:
      stage_name = @OPEN_MARKET_SUBMISSION
      relative_root = Open_Market
    """
    stage_root = stage_root.rstrip("/")

    if "/" not in stage_root:
        return stage_root, ""

    first_slash = stage_root.find("/")
    stage_name = stage_root[:first_slash]
    relative_root = stage_root[first_slash + 1:].strip("/")

    return stage_name, relative_root


def get_relative_path_from_list_name(list_name, stage_name):
    """
    Converts LIST output into a relative path under the stage.
    """
    name = list_name.replace("\\", "/")

    stage_without_at = stage_name.replace("@", "")
    stage_without_at = stage_without_at.split(".")[-1]

    possible_prefixes = [
        stage_without_at + "/",
        stage_without_at.lower() + "/",
        stage_without_at.upper() + "/"
    ]

    for prefix in possible_prefixes:
        if name.startswith(prefix):
            return name[len(prefix):]

    return name


def get_folder_name(relative_path, relative_root):
    """
    relative_path:
      Open_Market/A133101_Volvo_Cars_AB/file.xlsx

    relative_root:
      Open_Market

    returns:
      A133101_Volvo_Cars_AB
    """
    path = relative_path.replace("\\", "/").strip("/")

    if relative_root:
        root_prefix = relative_root.strip("/") + "/"

        if path.startswith(root_prefix):
            path = path[len(root_prefix):]

    parts = path.split("/")

    if len(parts) < 2:
        return None

    return parts[0]


def get_file_name(relative_path):
    return relative_path.replace("\\", "/").split("/")[-1]


def get_extension(file_name):
    file_name = file_name.lower()

    if "." not in file_name:
        return ""

    return "." + file_name.split(".")[-1]


# ============================================================
# 3. XLSX EXTRACTION
# ============================================================
# XLSX is treated as the most reliable source because we only
# count values under actual construction-related columns.
# ============================================================

def extract_from_xlsx(scoped_file_url):
    """
    Reads XLSX using openpyxl and returns every value found under
    explicit construction-related columns.
    """
    found_values = []

    with SnowflakeFile.open(scoped_file_url, "rb") as f:
        data = f.read()

    wb = load_workbook(
        io.BytesIO(data),
        read_only=True,
        data_only=True
    )

    for ws in wb.worksheets:
        header_row_number = None
        construction_columns = {}

        # Search first 50 rows for a valid header row
        for row_number, row in enumerate(ws.iter_rows(values_only=True), start=1):
            if row_number > 50:
                break

            current_construction_columns = {}

            for col_idx, cell_value in enumerate(row):
                if likely_construction_header(cell_value):
                    current_construction_columns[col_idx] = clean_text(cell_value)

            if current_construction_columns:
                header_row_number = row_number
                construction_columns = current_construction_columns
                break

        if header_row_number is None:
            continue

        # Read all data rows under detected construction columns
        for row_number, row in enumerate(ws.iter_rows(values_only=True), start=1):
            if row_number <= header_row_number:
                continue

            for col_idx, header_name in construction_columns.items():
                if col_idx >= len(row):
                    continue

                value = clean_text(row[col_idx])

                if is_probably_invalid_raw_value(value):
                    continue

                found_values.append({
                    "raw_value": value,
                    "sheet_name": ws.title,
                    "row_number": row_number,
                    "header_name": header_name,
                    "evidence": (
                        f"XLSX sheet '{ws.title}', row {row_number}, "
                        f"column '{header_name}' = '{value}'"
                    )
                })

    return found_values


# ============================================================
# 4. STRICT AI_EXTRACT FOR PDF / DOC / DOCX / EML
# ============================================================
# IMPORTANT:
# This replaces the old loose logic.
#
# The previous version:
#   - parsed text
#   - searched every occurrence of Frame / Metal / Concrete / etc.
#   - counted them even when they were not construction types
#
# This version:
#   - asks AI_EXTRACT only for explicit construction-type records
#   - returns nothing if the value is not tied to a construction label,
#     field, table column, or explicit building-construction statement
# ============================================================

def ai_extract_strict_construction_records(session, stage_name, relative_path):
    relative_path_sql = escape_sql_string(relative_path)
    stage_name_sql = escape_sql_string(stage_name)

    response_format = """
    {
      'schema': {
        'type': 'object',
        'properties': {
          'construction_records': {
            'description': 'Return ONLY actual construction-type values for the insured property/building. A value is valid only when it is explicitly tied to a construction-related field, label, column, or statement, such as Construction, Construction Description, Construction Type, Construction Code, ISO Construction, Building Construction, or an equivalent explicit construction context. Examples of valid raw values may include MNC, JM, Frame, Wood Frame, Non-Combustible, Concrete Tilt Wall, CMU, etc., but only return them if the document itself clearly uses them as construction-type values. DO NOT return general mentions of words such as frame, concrete, steel, metal, masonry, brick, wall, or non-combustible when they occur in ordinary narrative text and are not clearly a construction-type field. DO NOT return percentages, currency amounts, company names, dates, ratios, generic building materials, or unrelated text. If no explicit construction-type information exists, return an empty array.',
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'raw_value': {
                  'description': 'The exact raw construction-type value as written in the document.',
                  'type': 'string'
                },
                'evidence': {
                  'description': 'A short quote or nearby text proving that the raw value is explicitly used as a construction-type value, ideally including the construction label, field name, column name, or table context.',
                  'type': 'string'
                }
              }
            }
          }
        }
      }
    }
    """

    sql = f"""
        SELECT AI_EXTRACT(
            file => TO_FILE('{stage_name_sql}', '{relative_path_sql}'),
            responseFormat => {response_format},
            scores => TRUE
        ) AS R
    """

    result = session.sql(sql).collect()[0]["R"]

    if isinstance(result, str):
        result = json.loads(result)

    response = result.get("response", {}) if result else {}
    scoring = result.get("scoring", {}) if result else {}
    error = result.get("error") if result else None

    records = response.get("construction_records", []) or []

    score = None

    try:
        score = scoring.get("scores", {}).get("construction_records", {}).get("score")
    except Exception:
        score = None

    return records, score, error


def evidence_looks_contextual(evidence_text):
    """
    Extra guardrail on top of the AI prompt.
    We only accept AI extracted records if the evidence itself
    contains construction-related context.
    """
    if not evidence_text:
        return False

    e = evidence_text.lower()

    construction_context_markers = [
        "construction",
        "construction description",
        "construction type",
        "construction code",
        "iso construction",
        "building construction",
        "construction class"
    ]

    return any(marker in e for marker in construction_context_markers)


# ============================================================
# 5. MAIN PROCEDURE
# ============================================================

def run(session, STAGE_ROOT, MAX_FOLDERS):

    stage_name, relative_root = split_stage_root(STAGE_ROOT)

    # --------------------------------------------------------
    # Step 1: List all files under the root path
    # --------------------------------------------------------
    list_sql = f"LIST {STAGE_ROOT}"
    list_rows = session.sql(list_sql).collect()

    all_files = []

    for row in list_rows:
        list_name = row[0]
        relative_path = get_relative_path_from_list_name(list_name, stage_name)
        folder_name = get_folder_name(relative_path, relative_root)

        if not folder_name:
            continue

        file_name = get_file_name(relative_path)
        extension = get_extension(file_name)

        all_files.append({
            "folder_name": folder_name,
            "relative_path": relative_path,
            "file_name": file_name,
            "extension": extension
        })

    files_by_folder = defaultdict(list)

    for f in all_files:
        files_by_folder[f["folder_name"]].append(f)

    folder_names = sorted(files_by_folder.keys())

    if MAX_FOLDERS is not None and int(MAX_FOLDERS) > 0:
        folder_names = folder_names[:int(MAX_FOLDERS)]

    processed_folder_count = 0
    total_files_processed = 0

    supported_ai_extract_extensions = {".pdf", ".doc", ".docx", ".eml"}
    xlsx_extensions = {".xlsx"}

    # --------------------------------------------------------
    # Step 2: Process one account folder at a time
    # --------------------------------------------------------
    for folder_name in folder_names:

        folder_files = files_by_folder[folder_name]

        raw_counter = Counter()
        normalized_counter = Counter()
        raw_to_normalized_mapping = {}
        evidence_rows = []
        source_files = set()
        skipped_files = []
        confidence_scores = []
        error_messages = []

        files_found = len(folder_files)
        files_processed = 0

        for file_info in folder_files:
            relative_path = file_info["relative_path"]
            file_name = file_info["file_name"]
            extension = file_info["extension"]

            try:
                # ====================================================
                # XLSX PATH
                # ====================================================
                if extension in xlsx_extensions:
                    scoped_url_sql = f"""
                        SELECT BUILD_SCOPED_FILE_URL(
                            {stage_name},
                            '{escape_sql_string(relative_path)}'
                        ) AS FILE_URL
                    """

                    scoped_file_url = session.sql(scoped_url_sql).collect()[0]["FILE_URL"]

                    xlsx_values = extract_from_xlsx(scoped_file_url)

                    for item in xlsx_values:
                        add_raw_value(
                            raw_value=item["raw_value"],
                            raw_counter=raw_counter,
                            normalized_counter=normalized_counter,
                            raw_to_normalized_mapping=raw_to_normalized_mapping,
                            evidence_rows=evidence_rows,
                            source_file=file_name,
                            evidence_text=item["evidence"]
                        )

                    files_processed += 1
                    source_files.add(file_name)

                # ====================================================
                # PDF / DOC / DOCX / EML PATH
                # ====================================================
                elif extension in supported_ai_extract_extensions:
                    records, score, ai_error = ai_extract_strict_construction_records(
                        session=session,
                        stage_name=stage_name,
                        relative_path=relative_path
                    )

                    if ai_error:
                        error_messages.append(
                            f"{file_name}: AI_EXTRACT error: {ai_error}"
                        )

                    accepted_record_count = 0

                    for record in records:
                        raw_value = clean_text(record.get("raw_value"))
                        evidence_text = clean_text(record.get("evidence"))

                        # Very important second-level safeguard:
                        # evidence must itself show construction context.
                        if not evidence_looks_contextual(evidence_text):
                            continue

                        add_raw_value(
                            raw_value=raw_value,
                            raw_counter=raw_counter,
                            normalized_counter=normalized_counter,
                            raw_to_normalized_mapping=raw_to_normalized_mapping,
                            evidence_rows=evidence_rows,
                            source_file=file_name,
                            evidence_text=evidence_text
                        )

                        accepted_record_count += 1

                    if score is not None and accepted_record_count > 0:
                        confidence_scores.append(float(score))

                    files_processed += 1
                    source_files.add(file_name)

                # ====================================================
                # UNSUPPORTED FILE TYPES
                # ====================================================
                else:
                    skipped_files.append({
                        "file_name": file_name,
                        "reason": f"Unsupported extension: {extension if extension else 'no extension'}"
                    })

            except Exception as e:
                skipped_files.append({
                    "file_name": file_name,
                    "reason": str(e)
                })

                error_messages.append(
                    f"{file_name}: {str(e)}"
                )

        avg_confidence = None

        if confidence_scores:
            avg_confidence = sum(confidence_scores) / len(confidence_scores)

        # --------------------------------------------------------
        # Step 3: Save one consolidated row per account folder
        # --------------------------------------------------------
        insert_sql = f"""
            INSERT INTO OPEN_MARKET_CONSTRUCTION_CODE_EXTRACTION (
                ACCOUNT_FOLDER_NAME,
                CONSTRUCTION_CODE,
                RAW_CONSTRUCTION_TYPES,
                RAW_TO_NORMALIZED_MAPPING,
                EVIDENCE,
                SOURCE_FILES,
                FILES_FOUND,
                FILES_PROCESSED,
                FILES_SKIPPED,
                CONFIDENCE,
                PROCESSED_AT,
                ERROR_MESSAGE
            )
            SELECT
                '{escape_sql_string(folder_name)}',
                PARSE_JSON('{escape_sql_string(json.dumps(dict(normalized_counter)))}'),
                PARSE_JSON('{escape_sql_string(json.dumps(dict(raw_counter)))}'),
                PARSE_JSON('{escape_sql_string(json.dumps(raw_to_normalized_mapping))}'),
                PARSE_JSON('{escape_sql_string(json.dumps(evidence_rows))}'),
                PARSE_JSON('{escape_sql_string(json.dumps(sorted(list(source_files))))}'),
                {files_found},
                {files_processed},
                PARSE_JSON('{escape_sql_string(json.dumps(skipped_files))}'),
                {"NULL" if avg_confidence is None else avg_confidence},
                CURRENT_TIMESTAMP(),
                {"NULL" if not error_messages else "'" + escape_sql_string(" | ".join(error_messages)) + "'"}
        """

        session.sql(insert_sql).collect()

        processed_folder_count += 1
        total_files_processed += files_processed

    return (
        f"Completed strict construction code extraction. "
        f"Folders processed: {processed_folder_count}. "
        f"Files processed: {total_files_processed}."
    )
$$;
