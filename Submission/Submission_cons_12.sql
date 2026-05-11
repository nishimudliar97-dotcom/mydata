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


VARIABLE_CONFIGS = {
    "CONSTRUCTION_CODE": {
        "display_name": "Construction Code",
        "xlsx_headers_exact": {
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
        },
        "ai_table_description": "Extract ONLY actual construction-type values for the insured property/building. A row is valid only when the value is explicitly tied to a construction-related field, label, table column, or statement, such as Construction, Construction Description, Construction Type, Construction Code, ISO Construction, Building Construction, or Construction Class. Valid examples may include raw values such as MNC, JM, Frame, Wood, Wood Frame, Non-Combustible, Concrete Tilt Wall, CMU, Masonry, Reinforced Masonry, Confined Masonry, Adobe, Steel, Reinforced Concrete, PEMB, CB-TILT, etc. Do NOT return general narrative mentions of words such as frame, concrete, steel, metal, masonry, brick, wall, or non-combustible unless the document clearly uses them as a construction-type value. Do NOT return percentages, currency amounts, dates, company names, insured names, limits, deductibles, or unrelated text. If the document does not contain explicit construction-type information, return no rows.",
        "evidence_context_markers": [
            "construction",
            "construction description",
            "construction type",
            "construction code",
            "iso construction",
            "building construction",
            "construction class"
        ]
    }
}


CONSTRUCTION_EXACT_NORMALIZATION_MAP = {
    "UNKNOWN": "Unknown",

    "FRAME": "Frame",
    "WOOD": "Frame",
    "WOOD FRAME": "Frame",
    "5 STORY WRAP": "Frame",

    "JM": "Joisted Masonry",
    "JOISTED MASONRY": "Joisted Masonry",

    "NON COMBUSTIBLE": "Non-Combustible",
    "NON-COMBUSTIBLE": "Non-Combustible",
    "NC": "Non-Combustible",
    "PEMB": "Non-Combustible",
    "METAL": "Non-Combustible",
    "STEEL": "Non-Combustible",

    "MNC": "Masonry Non-Combustible",
    "MASONRY NON COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY NON-COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY": "Masonry Non-Combustible",
    "REINFORCED MASONRY": "Masonry Non-Combustible",
    "ADOBE": "Masonry Non-Combustible",
    "CONFINED MASONRY": "Masonry Non-Combustible",
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
    "REINFORCED CONCRETE": "Modified Fire Resistive",
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


def clean_text(value):
    if value is None:
        return None
    value = str(value).strip()
    if not value:
        return None
    value = re.sub(r'\s+', ' ', value)
    return value


def canonical_key(value):
    value = clean_text(value)
    if not value:
        return None
    value = value.upper()
    value = value.replace("–", "-").replace("—", "-")
    value = value.replace("&", " AND ")
    value = value.replace("FAÇADE", "FACADE")
    value = re.sub(r'\s+', ' ', value).strip()
    return value


def escape_sql_string(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")


def is_probably_invalid_value(value):
    value = clean_text(value)
    if not value:
        return True
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
    return value.upper() in invalid_values


def split_stage_root(stage_root):
    stage_root = stage_root.rstrip("/")
    if "/" not in stage_root:
        return stage_root, ""
    first_slash = stage_root.find("/")
    stage_name = stage_root[:first_slash]
    relative_root = stage_root[first_slash + 1:].strip("/")
    return stage_name, relative_root


def get_relative_path_from_list_name(list_name, stage_name):
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


def get_already_processed_folders(session):
    rows = session.sql("""
        SELECT DISTINCT ACCOUNT_FOLDER_NAME
        FROM OPEN_MARKET_CONSTRUCTION_CODE_EXTRACTION
    """).collect()
    return {row["ACCOUNT_FOLDER_NAME"] for row in rows}


def normalize_construction_type(raw_value):
    key = canonical_key(raw_value)
    if not key:
        return "Unknown"

    if key in CONSTRUCTION_EXACT_NORMALIZATION_MAP:
        return CONSTRUCTION_EXACT_NORMALIZATION_MAP[key]

    if key == "WOOD":
        return "Frame"

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

    if "REINFORCED CONCRETE" in key:
        return "Modified Fire Resistive"

    if any(token in key for token in [
        "CMU",
        "MASONRY",
        "BRICK",
        "BLOCK",
        "ADOBE",
        "CONFINED MASONRY",
        "REINFORCED MASONRY",
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

    if "METAL" in key or key == "STEEL":
        return "Non-Combustible"

    return "Unknown"


def add_construction_value(
    raw_value,
    raw_counter,
    normalized_counter,
    raw_to_normalized_mapping,
    evidence_rows,
    source_file,
    evidence_text
):
    raw_value = clean_text(raw_value)
    if is_probably_invalid_value(raw_value):
        return
    normalized_value = normalize_construction_type(raw_value)
    raw_counter[raw_value] += 1
    normalized_counter[normalized_value] += 1
    raw_to_normalized_mapping[raw_value] = normalized_value
    evidence_rows.append({
        "source_file": source_file,
        "raw_value": raw_value,
        "normalized_code": normalized_value,
        "evidence": evidence_text
    })


def is_matching_xlsx_header(value, variable_key):
    if value is None:
        return False
    config = VARIABLE_CONFIGS[variable_key]
    header = str(value).strip().lower()
    header = re.sub(r'\s+', ' ', header)
    if header in config["xlsx_headers_exact"]:
        return True
    if variable_key == "CONSTRUCTION_CODE":
        if "construction" in header and any(
            token in header for token in ["description", "type", "code", "class"]
        ):
            return True
    return False


def extract_construction_from_xlsx(scoped_file_url):
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

        for row_number, row in enumerate(ws.iter_rows(values_only=True), start=1):
            if row_number > 50:
                break

            current_columns = {}

            for col_idx, cell_value in enumerate(row):
                if is_matching_xlsx_header(cell_value, "CONSTRUCTION_CODE"):
                    current_columns[col_idx] = clean_text(cell_value)

            if current_columns:
                header_row_number = row_number
                construction_columns = current_columns
                break

        if header_row_number is None:
            continue

        for row_number, row in enumerate(ws.iter_rows(values_only=True), start=1):
            if row_number <= header_row_number:
                continue

            for col_idx, header_name in construction_columns.items():
                if col_idx >= len(row):
                    continue

                value = clean_text(row[col_idx])

                if is_probably_invalid_value(value):
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


def build_construction_ai_response_format():
    config = VARIABLE_CONFIGS["CONSTRUCTION_CODE"]
    response_format = f"""
    {{
      'schema': {{
        'type': 'object',
        'properties': {{
          'construction_table': {{
            'description': '{escape_sql_string(config["ai_table_description"])}',
            'type': 'object',
            'column_ordering': ['raw_value', 'evidence'],
            'properties': {{
              'raw_value': {{
                'description': 'The exact raw construction-type value as written in the document.',
                'type': 'array'
              }},
              'evidence': {{
                'description': 'Short supporting text proving the value is explicitly used as a construction field or construction table value.',
                'type': 'array'
              }}
            }}
          }}
        }}
      }}
    }}
    """
    return response_format


def evidence_has_required_context(evidence_text, variable_key):
    if not evidence_text:
        return False
    evidence_lower = evidence_text.lower()
    markers = VARIABLE_CONFIGS[variable_key]["evidence_context_markers"]
    return any(marker in evidence_lower for marker in markers)


def ai_extract_construction_from_file(session, stage_name, relative_path):
    relative_path_sql = escape_sql_string(relative_path)
    stage_name_sql = escape_sql_string(stage_name)
    response_format = build_construction_ai_response_format()

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

    result = result or {}
    response = result.get("response") or {}
    scoring = result.get("scoring") or {}
    ai_error = result.get("error")

    construction_table = response.get("construction_table") or {}

    raw_values = construction_table.get("raw_value") or []
    evidence_values = construction_table.get("evidence") or []

    rows = []
    max_len = max(len(raw_values), len(evidence_values))

    for i in range(max_len):
        raw_value = raw_values[i] if i < len(raw_values) else None
        evidence = evidence_values[i] if i < len(evidence_values) else None

        raw_value = clean_text(raw_value)
        evidence = clean_text(evidence)

        if not raw_value:
            continue

        if not evidence_has_required_context(evidence, "CONSTRUCTION_CODE"):
            continue

        rows.append({
            "raw_value": raw_value,
            "evidence": evidence
        })

    score = None

    try:
        score = (
            scoring.get("scores", {})
            .get("construction_table", {})
            .get("score")
        )
    except Exception:
        score = None

    return rows, score, ai_error


def run(session, STAGE_ROOT, MAX_FOLDERS):
    stage_name, relative_root = split_stage_root(STAGE_ROOT)

    list_rows = session.sql(f"LIST {STAGE_ROOT}").collect()

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

    for file_info in all_files:
        files_by_folder[file_info["folder_name"]].append(file_info)

    already_processed_folders = get_already_processed_folders(session)

    candidate_folder_names = sorted([
        folder_name
        for folder_name in files_by_folder.keys()
        if folder_name not in already_processed_folders
    ])

    if MAX_FOLDERS is not None and int(MAX_FOLDERS) > 0:
        folder_names_to_process = candidate_folder_names[:int(MAX_FOLDERS)]
    else:
        folder_names_to_process = candidate_folder_names

    processed_folder_count = 0
    total_files_processed = 0
    total_folders_skipped_as_already_processed = len(already_processed_folders)

    supported_ai_extract_extensions = {
        ".pdf",
        ".doc",
        ".docx",
        ".eml"
    }

    xlsx_extensions = {
        ".xlsx"
    }

    for folder_name in folder_names_to_process:
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
                if extension in xlsx_extensions:
                    scoped_url_sql = f"""
                        SELECT BUILD_SCOPED_FILE_URL(
                            {stage_name},
                            '{escape_sql_string(relative_path)}'
                        ) AS FILE_URL
                    """

                    scoped_file_url = session.sql(scoped_url_sql).collect()[0]["FILE_URL"]
                    xlsx_values = extract_construction_from_xlsx(scoped_file_url)

                    for item in xlsx_values:
                        add_construction_value(
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

                elif extension in supported_ai_extract_extensions:
                    rows, score, ai_error = ai_extract_construction_from_file(
                        session=session,
                        stage_name=stage_name,
                        relative_path=relative_path
                    )

                    if ai_error:
                        error_messages.append(
                            f"{file_name}: AI_EXTRACT error: {ai_error}"
                        )

                    for row in rows:
                        add_construction_value(
                            raw_value=row["raw_value"],
                            raw_counter=raw_counter,
                            normalized_counter=normalized_counter,
                            raw_to_normalized_mapping=raw_to_normalized_mapping,
                            evidence_rows=evidence_rows,
                            source_file=file_name,
                            evidence_text=row["evidence"]
                        )

                    if score is not None and rows:
                        confidence_scores.append(float(score))

                    files_processed += 1
                    source_files.add(file_name)

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
        f"Completed construction code extraction. "
        f"New folders processed in this run: {processed_folder_count}. "
        f"Files processed in this run: {total_files_processed}. "
        f"Folders already present in output table and skipped: {total_folders_skipped_as_already_processed}. "
        f"Unprocessed folders remaining after this run: "
        f"{max(0, len(candidate_folder_names) - processed_folder_count)}."
    )
$$;
