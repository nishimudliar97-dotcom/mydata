USE DATABASE EXPERIMENT_TEAM_DB;
USE SCHEMA PUBLIC;

CREATE OR REPLACE TABLE OPEN_MARKET_CONSTRUCTION_VARIABLE_EXTRACTION_V6 (
    ACCOUNT_FOLDER_NAME STRING,

    CONSTRUCTION_CODE VARIANT,
    RAW_CONSTRUCTION_TYPES VARIANT,
    RAW_TO_NORMALIZED_MAPPING VARIANT,

    YEAR_BUILT VARIANT,
    YEAR_OF_LAST_MAJOR_RENOVATION VARIANT,
    SQUARE_FOOTAGE VARIANT,
    NUMBER_OF_STORIES VARIANT,
    NUMBER_OF_BASEMENTS VARIANT,
    NUMBER_OF_BUILDINGS_AT_LOCATION VARIANT,

    WALL_MATERIAL_EXTERNAL_CLADDING VARIANT,
    RAW_WALL_MATERIAL_EXTERNAL_CLADDING VARIANT,

    ROOF_MATERIAL_COVERING VARIANT,
    RAW_ROOF_MATERIAL_COVERING VARIANT,

    FOUNDATION_TYPE VARIANT,
    RAW_FOUNDATION_TYPE VARIANT,

    ROOF_ANCHOR VARIANT,
    RAW_ROOF_ANCHOR VARIANT,

    ROOF_GEOMETRY VARIANT,
    RAW_ROOF_GEOMETRY VARIANT,

    SOURCE_FILES VARIANT,
    FILES_FOUND NUMBER,
    FILES_PROCESSED NUMBER,
    FILES_SKIPPED VARIANT,
    PROCESSED_AT TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE RUN_OPEN_MARKET_CONSTRUCTION_VARIABLE_EXTRACTION_V6(
    STAGE_ROOT STRING,
    MAX_FOLDERS NUMBER,
    TARGET_FOLDER_KEYWORD STRING
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
from datetime import datetime
from collections import Counter, defaultdict

from openpyxl import load_workbook
from snowflake.snowpark.files import SnowflakeFile


CURRENT_YEAR = datetime.utcnow().year


VARIABLES = {
    "CONSTRUCTION_CODE": {
        "output_column": "CONSTRUCTION_CODE",
        "table_name": "construction_table",
        "headers": {
            "construction": 4,
            "construction code": 1,
            "const code": 1,
            "const. code": 1,
            "iso construction code": 1,
            "iso construction": 1,
            "construction class": 1,
            "class code": 1,
            "specific construction class": 2,
            "general construction": 2,
            "construction type definition": 3,
            "construction definition": 3,
            "construction description": 3,
            "construction type": 3,
            "building construction": 3
        },
        "context_markers": [
            "construction",
            "construction code",
            "construction type",
            "construction description",
            "construction class",
            "iso construction",
            "specific construction",
            "general construction"
        ],
        "ai_description": "Extract only construction type or construction code values for the insured property/building. Valid values may include Frame, Brick Veneer, Joisted Masonry, Masonry, Non-Combustible, MNC, Concrete, Fire Resistive, Steel, CMU, ISO construction code, construction class, or construction type."
    },
    "YEAR_BUILT": {
        "output_column": "YEAR_BUILT",
        "table_name": "year_built_table",
        "headers": {
            "year built": 1,
            "year built original": 1,
            "year built originally": 1,
            "original year built": 1,
            "built year": 1,
            "year of construction": 1,
            "construction year": 1,
            "yr built": 1,
            "built": 2,
            "year": 5
        },
        "context_markers": [
            "year built",
            "original year built",
            "built year",
            "year of construction",
            "construction year",
            "yr built"
        ],
        "ai_description": "Extract only the original year built of the insured property/building. Do not return policy years, renewal years, report years, email dates, inspection dates, or loss years."
    },
    "YEAR_OF_LAST_MAJOR_RENOVATION": {
        "output_column": "YEAR_OF_LAST_MAJOR_RENOVATION",
        "table_name": "renovation_year_table",
        "headers": {
            "year of last major renovation": 1,
            "last major renovation": 1,
            "year renovated": 1,
            "renovation year": 1,
            "year of renovation": 1,
            "major renovation year": 1,
            "year of major structural upgrade": 1,
            "major structural upgrade": 1
        },
        "context_markers": [
            "renovation",
            "renovated",
            "major renovation",
            "last major renovation",
            "structural upgrade",
            "major structural upgrade"
        ],
        "ai_description": "Extract only the year of last major renovation or year of major structural upgrade for the insured property/building."
    },
    "SQUARE_FOOTAGE": {
        "output_column": "SQUARE_FOOTAGE",
        "table_name": "square_footage_table",
        "headers": {
            "building sq. ft.": 1,
            "building sq ft": 1,
            "building sqft": 1,
            "bldg sq. ft.": 1,
            "bldg sq ft": 1,
            "bldg sqft": 1,
            "square footage": 1,
            "square feet": 1,
            "sq ft": 1,
            "sq. ft.": 1,
            "sqft": 1,
            "total sq ft": 1,
            "total sq. ft.": 1,
            "total square feet": 1,
            "floor area": 1,
            "floor area sq": 1,
            "floor area sqft": 1,
            "floor area sq ft": 1,
            "building area": 2,
            "gross floor area": 1,
            "area": 5
        },
        "context_markers": [
            "square footage",
            "square feet",
            "sq ft",
            "sqft",
            "floor area",
            "building area",
            "gross floor area",
            "building sq"
        ],
        "ai_description": "Extract only square footage, square feet, floor area, building area, building sq ft, or gross floor area. Do not return TIV, values, limits, deductibles, or currency amounts."
    },
    "NUMBER_OF_STORIES": {
        "output_column": "NUMBER_OF_STORIES",
        "table_name": "stories_table",
        "headers": {
            "# stories": 1,
            "# of stories": 1,
            "number of stories": 1,
            "no of stories": 1,
            "no. of stories": 1,
            "stories": 1,
            "story": 1,
            "number of storeys": 1,
            "# storeys": 1,
            "# of storeys": 1,
            "storeys": 1,
            "number of stories - above grade": 1,
            "number of stories above grade": 1,
            "stories above grade": 1
        },
        "context_markers": [
            "stories",
            "storeys",
            "# stories",
            "# of stories",
            "number of stories",
            "above grade"
        ],
        "ai_description": "Extract only number of stories or storeys for the insured property/building. Values may be 1, 2, 3, or 2 & 3."
    },
    "NUMBER_OF_BASEMENTS": {
        "output_column": "NUMBER_OF_BASEMENTS",
        "table_name": "basements_table",
        "headers": {
            "no of basements": 1,
            "no. of basements": 1,
            "number of basements": 1,
            "number of basement": 1,
            "basements": 1,
            "basement": 1,
            "basement levels": 1,
            "number of basement levels": 1,
            "no of basement levels": 1,
            "no. of basement levels": 1
        },
        "context_markers": [
            "basement",
            "basements",
            "basement levels",
            "number of basement"
        ],
        "ai_description": "Extract only the number of basements or basement levels for the insured property/building."
    },
    "NUMBER_OF_BUILDINGS_AT_LOCATION": {
        "output_column": "NUMBER_OF_BUILDINGS_AT_LOCATION",
        "table_name": "buildings_table",
        "headers": {
            "# of buildings": 1,
            "# buildings": 1,
            "number of buildings at location": 1,
            "number of buildings": 1,
            "no of buildings": 1,
            "no. of buildings": 1,
            "number of building": 1,
            "number of building at location": 1,
            "number of buildings at loc": 1,
            "# buildings at location": 1,
            "building count": 1,
            "total buildings": 1
        },
        "context_markers": [
            "number of buildings",
            "number of building",
            "# buildings",
            "# of buildings",
            "building count",
            "buildings at location",
            "total buildings"
        ],
        "ai_description": "Extract only the number of buildings at the insured location. Values may be numeric or text such as 78 Apts, 1 Office, 16 Laundry."
    },
    "WALL_MATERIAL_EXTERNAL_CLADDING": {
        "output_column": "WALL_MATERIAL_EXTERNAL_CLADDING",
        "raw_output_column": "RAW_WALL_MATERIAL_EXTERNAL_CLADDING",
        "table_name": "wall_material_external_cladding_table",
        "headers": {
            "construction": 3,
            "wall material / external cladding": 1,
            "wall material/external cladding": 1,
            "wall material external cladding": 1,
            "wall material": 1,
            "external cladding": 1,
            "exterior cladding": 1,
            "cladding type": 1,
            "cladding": 2,
            "external wall material": 1,
            "exterior wall material": 1,
            "wall cladding": 1,
            "wall type": 2,
            "wall construction": 3
        },
        "context_markers": [
            "wall material",
            "external cladding",
            "exterior cladding",
            "cladding type",
            "cladding",
            "wall cladding",
            "external wall",
            "exterior wall",
            "construction"
        ],
        "ai_description": "Extract only wall material or external cladding. Construction columns containing values like Brick Veneer may also indicate wall material or external cladding."
    },
    "ROOF_MATERIAL_COVERING": {
        "output_column": "ROOF_MATERIAL_COVERING",
        "raw_output_column": "RAW_ROOF_MATERIAL_COVERING",
        "table_name": "roof_material_covering_table",
        "headers": {
            "roof": 1,
            "roof material / covering": 1,
            "roof material/covering": 1,
            "roof material covering": 1,
            "roof material": 1,
            "roof covering": 1,
            "roof system covering": 1,
            "roof system": 2,
            "roof cover": 1,
            "roof type": 2
        },
        "context_markers": [
            "roof material",
            "roof covering",
            "roof system covering",
            "roof cover",
            "roof type",
            "roof"
        ],
        "ai_description": "Extract only roof material or roof covering values for the insured property/building."
    },
    "FOUNDATION_TYPE": {
        "output_column": "FOUNDATION_TYPE",
        "raw_output_column": "RAW_FOUNDATION_TYPE",
        "table_name": "foundation_type_table",
        "headers": {
            "foundation type": 1,
            "foundation type engineered slab pier": 1,
            "foundation type (engineered/slab/pier)": 1,
            "foundation type engineered/slab/pier": 1,
            "engineered/slab/pier": 1,
            "foundation": 2,
            "foundation system": 1,
            "foundation construction": 2,
            "foundation description": 2
        },
        "context_markers": [
            "foundation",
            "foundation type",
            "foundation system",
            "engineered",
            "slab",
            "pier",
            "basement"
        ],
        "ai_description": "Extract only foundation type values for the insured property/building."
    },
    "ROOF_ANCHOR": {
        "output_column": "ROOF_ANCHOR",
        "raw_output_column": "RAW_ROOF_ANCHOR",
        "table_name": "roof_anchor_table",
        "headers": {
            "roof anchor": 1,
            "roof anchorage": 1,
            "roof anchoring": 1,
            "roof anchor type": 1,
            "roof attachment": 2,
            "roof connection": 2,
            "roof connected": 2
        },
        "context_markers": [
            "roof anchor",
            "roof anchorage",
            "roof anchoring",
            "roof attachment",
            "roof connection",
            "clips",
            "hurricane ties",
            "anchor bolts"
        ],
        "ai_description": "Extract only roof anchor or roof anchorage values for the insured property/building."
    },
    "ROOF_GEOMETRY": {
        "output_column": "ROOF_GEOMETRY",
        "raw_output_column": "RAW_ROOF_GEOMETRY",
        "table_name": "roof_geometry_table",
        "headers": {
            "roof geometry": 1,
            "roof shape": 1,
            "roof form": 1,
            "roof profile": 1,
            "roof configuration": 2
        },
        "context_markers": [
            "roof geometry",
            "roof shape",
            "roof form",
            "roof profile",
            "gable",
            "hip",
            "flat",
            "mansard",
            "stepped"
        ],
        "ai_description": "Extract only roof geometry or roof shape values for the insured property/building."
    }
}


RAW_TRACKED_VARIABLES = {
    "WALL_MATERIAL_EXTERNAL_CLADDING",
    "ROOF_MATERIAL_COVERING",
    "FOUNDATION_TYPE",
    "ROOF_ANCHOR",
    "ROOF_GEOMETRY"
}


CONSTRUCTION_EXACT_NORMALIZATION_MAP = {
    "0": "Unknown",
    "CLASS 0": "Unknown",
    "UNKNOWN": "Unknown",
    "UNKNOWN/DEFAULT": "Unknown",

    "1": "Frame",
    "CLASS 1": "Frame",
    "FRAME": "Frame",
    "WOOD": "Frame",
    "WOOD FRAME": "Frame",
    "5 STORY WRAP": "Frame",

    "2": "Joisted Masonry",
    "CLASS 2": "Joisted Masonry",
    "JM": "Joisted Masonry",
    "JOISTED MASONRY": "Joisted Masonry",
    "MASONRY/JOISTED": "Joisted Masonry",
    "MASONRY / JOISTED": "Joisted Masonry",

    "3": "Non-Combustible",
    "CLASS 3": "Non-Combustible",
    "NON COMBUSTIBLE": "Non-Combustible",
    "NON-COMBUSTIBLE": "Non-Combustible",
    "NC": "Non-Combustible",
    "PEMB": "Non-Combustible",
    "METAL": "Non-Combustible",
    "STEEL": "Non-Combustible",
    "PRE-ENGINEERED": "Non-Combustible",
    "PRE ENGINEERED": "Non-Combustible",
    "PROTECTED STEEL": "Non-Combustible",

    "4": "Masonry Non-Combustible",
    "CLASS 4": "Masonry Non-Combustible",
    "MNC": "Masonry Non-Combustible",
    "MASONRY NON COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY NON-COMBUSTIBLE": "Masonry Non-Combustible",
    "MASONRY": "Masonry Non-Combustible",
    "REINFORCED MASONRY": "Masonry Non-Combustible",
    "BRICK VENEER": "Masonry Non-Combustible",
    "BRICK": "Masonry Non-Combustible",
    "BLOCK": "Masonry Non-Combustible",
    "CMU": "Masonry Non-Combustible",

    "5": "Modified Fire Resistive",
    "CLASS 5": "Modified Fire Resistive",
    "CONCRETE": "Modified Fire Resistive",
    "REINFORCED CONCRETE": "Modified Fire Resistive",
    "MODIFIED FIRE RESISTIVE": "Modified Fire Resistive",

    "6": "Fire Resistive",
    "CLASS 6": "Fire Resistive",
    "FIRE RESISTIVE": "Fire Resistive",
    "REINFORCED CONC": "Fire Resistive",
    "REINFORCED CONC.": "Fire Resistive",

    "7": "Heavy Timber Joisted Masonry",
    "CLASS 7": "Heavy Timber Joisted Masonry",
    "HEAVY TIMBER JOISTED MASONRY": "Heavy Timber Joisted Masonry",

    "8": "Superior Non-Combustible",
    "CLASS 8": "Superior Non-Combustible",
    "SUPERIOR NON-COMBUSTIBLE": "Superior Non-Combustible",
    "SUPERIOR NON COMBUSTIBLE": "Superior Non-Combustible",

    "9": "Superior Masonry Non-Combustible",
    "CLASS 9": "Superior Masonry Non-Combustible",
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
    value = value.replace("_", " ")
    value = re.sub(r'\s+', ' ', value).strip()
    return value


def normalize_header(value):
    value = clean_text(value)
    if not value:
        return ""
    value = value.lower()
    value = value.replace("\n", " ")
    value = value.replace("_", " ")
    value = value.replace("#", "# ")
    value = value.replace("&", " and ")
    value = re.sub(r'[\(\)]', ' ', value)
    value = re.sub(r'\s+', ' ', value).strip()
    return value


def strip_code_prefix(value):
    value = clean_text(value)
    if not value:
        return None
    value = re.sub(r'^\s*\d+\s*[-:\.)]\s*', '', value).strip()
    value = re.sub(r'\s+', ' ', value)
    return value if value else None


def escape_sql_string(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")


def make_json_safe(value):
    if isinstance(value, dict):
        return {str(k): make_json_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [make_json_safe(v) for v in value]
    if isinstance(value, tuple):
        return [make_json_safe(v) for v in value]
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return value

    value = str(value)
    value = value.replace("\\", "/")
    value = value.replace("\r", " ")
    value = value.replace("\n", " ")
    value = value.replace("\t", " ")
    value = re.sub(r"\s+", " ", value).strip()

    if len(value) > 1000:
        value = value[:1000]

    return value


def json_sql_expr(value):
    safe_value = make_json_safe(value)
    safe_json = json.dumps(safe_value, ensure_ascii=False)
    safe_json = safe_json.replace(chr(36) + chr(36), "$ $")
    dollar_quote = chr(36) + chr(36)
    return "PARSE_JSON(" + dollar_quote + safe_json + dollar_quote + ")"


def counter_json_expr(counter_obj):
    return json_sql_expr(dict(counter_obj))


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


def is_reference_sheet(sheet_name):
    name = clean_text(sheet_name)
    if not name:
        return False

    name = name.upper()

    bad_keywords = [
        "REFERENCE",
        "GUIDE",
        "LOOKUP",
        "MAPPING",
        "DEFINITION",
        "INSTRUCTION",
        "README"
    ]

    return any(keyword in name for keyword in bad_keywords)


def is_sov_sheet(sheet_name):
    name = clean_text(sheet_name)
    if not name:
        return False

    name = name.upper()

    good_keywords = [
        "SOV",
        "STATEMENT OF VALUES",
        "COPE",
        "PROPERTY",
        "LOCATIONS",
        "LOCATION"
    ]

    return any(keyword in name for keyword in good_keywords)


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
        FROM OPEN_MARKET_CONSTRUCTION_VARIABLE_EXTRACTION_V6
    """).collect()

    return {row["ACCOUNT_FOLDER_NAME"] for row in rows}


def classify_header(value, variable_key):
    h = normalize_header(value)
    if not h:
        return None

    headers = VARIABLES[variable_key]["headers"]

    if h in headers:
        return headers[h]

    h_compact = h.replace(".", "").replace("/", " ").replace("-", " ")
    h_compact = re.sub(r'\s+', ' ', h_compact).strip()

    if variable_key == "CONSTRUCTION_CODE":
        if h == "construction":
            return 4
        if "construction" in h and "code" in h:
            return 1
        if "iso construction" in h:
            return 1
        if "specific construction" in h:
            return 2
        if "general construction" in h:
            return 2
        if "construction" in h and any(x in h for x in ["definition", "description", "type", "class"]):
            return 3

    if variable_key == "YEAR_BUILT":
        if "year" in h and "built" in h:
            return 1
        if "year" in h and "construction" in h:
            return 1
        if h in ["yr built", "built"]:
            return 1

    if variable_key == "YEAR_OF_LAST_MAJOR_RENOVATION":
        if "renovation" in h and "year" in h:
            return 1
        if "renovated" in h and "year" in h:
            return 1
        if "structural upgrade" in h:
            return 1

    if variable_key == "SQUARE_FOOTAGE":
        if "building sq" in h and "ft" in h:
            return 1
        if "bldg sq" in h and "ft" in h:
            return 1
        if "building sqft" in h_compact:
            return 1
        if "building sq ft" in h_compact:
            return 1
        if "sq ft" in h or "sq. ft" in h or "sqft" in h:
            return 1
        if "square" in h and ("feet" in h or "footage" in h):
            return 1
        if "floor area" in h:
            return 1
        if "building area" in h:
            return 2

    if variable_key == "NUMBER_OF_STORIES":
        if h in ["# stories", "# of stories", "no of stories", "no. of stories", "stories"]:
            return 1
        if "# stories" in h:
            return 1
        if "# of stories" in h:
            return 1
        if "number of stories" in h:
            return 1
        if "stor" in h:
            return 1

    if variable_key == "NUMBER_OF_BASEMENTS":
        if "basement" in h:
            return 1

    if variable_key == "NUMBER_OF_BUILDINGS_AT_LOCATION":
        if h in ["# of buildings", "# buildings", "number of buildings", "no of buildings", "no. of buildings"]:
            return 1
        if "# of buildings" in h:
            return 1
        if "# buildings" in h:
            return 1
        if "number of buildings" in h:
            return 1
        if "building count" in h:
            return 1
        if "total buildings" in h:
            return 1
        if "building" in h and any(x in h for x in ["number", "#", "count", "total"]):
            return 1

    if variable_key == "WALL_MATERIAL_EXTERNAL_CLADDING":
        if h == "construction":
            return 3
        if "cladding type" in h:
            return 1
        if "wall" in h and "material" in h:
            return 1
        if "external" in h and "cladding" in h:
            return 1
        if "exterior" in h and "cladding" in h:
            return 1
        if "wall" in h and "cladding" in h:
            return 1
        if h == "cladding":
            return 2

    if variable_key == "ROOF_MATERIAL_COVERING":
        if h == "roof":
            return 1
        if "roof system covering" in h:
            return 1
        if "roof" in h and "covering" in h:
            return 1
        if "roof" in h and "material" in h:
            return 1
        if "roof cover" in h:
            return 1
        if "roof type" in h:
            return 2

    if variable_key == "FOUNDATION_TYPE":
        if "foundation type" in h:
            return 1
        if "foundation" in h and any(x in h for x in ["engineered", "slab", "pier"]):
            return 1
        if h == "foundation":
            return 2
        if "foundation system" in h:
            return 1

    if variable_key == "ROOF_ANCHOR":
        if "roof anchor" in h:
            return 1
        if "roof anchorage" in h:
            return 1
        if "roof anchoring" in h:
            return 1
        if "roof attachment" in h:
            return 2
        if "roof connection" in h:
            return 2

    if variable_key == "ROOF_GEOMETRY":
        if "roof geometry" in h:
            return 1
        if "roof shape" in h:
            return 1
        if "roof form" in h:
            return 1
        if "roof profile" in h:
            return 1

    return None


def normalize_construction_type(raw_value):
    raw_value = clean_text(raw_value)
    if not raw_value:
        return "Unknown"

    key = canonical_key(raw_value)

    if key in CONSTRUCTION_EXACT_NORMALIZATION_MAP:
        return CONSTRUCTION_EXACT_NORMALIZATION_MAP[key]

    stripped = strip_code_prefix(raw_value)
    stripped_key = canonical_key(stripped)

    if stripped_key in CONSTRUCTION_EXACT_NORMALIZATION_MAP:
        return CONSTRUCTION_EXACT_NORMALIZATION_MAP[stripped_key]

    class_match = re.search(r'\bCLASS\s*([0-9])\b', key)
    if class_match:
        class_key = class_match.group(1)
        if class_key in CONSTRUCTION_EXACT_NORMALIZATION_MAP:
            return CONSTRUCTION_EXACT_NORMALIZATION_MAP[class_key]

    if re.fullmatch(r'[0-9]', key):
        return CONSTRUCTION_EXACT_NORMALIZATION_MAP.get(key, "Unknown")

    if "BRICK VENEER" in key:
        return "Masonry Non-Combustible"

    if "MASONRY/JOISTED" in key or "JOISTED/MASONRY" in key:
        return "Joisted Masonry"

    if "WOOD" in key and "FRAME" in key:
        return "Frame"

    if key == "WOOD" or key == "FRAME":
        return "Frame"

    if "JOISTED MASONRY" in key:
        return "Joisted Masonry"

    if "HEAVY TIMBER" in key:
        return "Heavy Timber Joisted Masonry"

    if "FIRE RESISTIVE" in key and "MODIFIED" in key:
        return "Modified Fire Resistive"

    if "FIRE RESISTIVE" in key:
        return "Fire Resistive"

    if "REINFORCED CONC" in key:
        return "Fire Resistive"

    if "SUPERIOR" in key and "MASONRY" in key and "NON" in key and "COMBUST" in key:
        return "Superior Masonry Non-Combustible"

    if "SUPERIOR" in key and "NON" in key and "COMBUST" in key:
        return "Superior Non-Combustible"

    if "NON" in key and "COMBUST" in key and "MASONRY" in key:
        return "Masonry Non-Combustible"

    if "NON" in key and "COMBUST" in key:
        return "Non-Combustible"

    if "PRE-ENGINEERED" in key or "PRE ENGINEERED" in key:
        return "Non-Combustible"

    if "PROTECTED STEEL" in key:
        return "Non-Combustible"

    if "REINFORCED CONCRETE" in key:
        return "Modified Fire Resistive"

    if any(token in key for token in ["CMU", "MASONRY", "BRICK", "BLOCK"]):
        return "Masonry Non-Combustible"

    if "CONCRETE" in key or "STEEL FRAME" in key:
        return "Modified Fire Resistive"

    if "METAL" in key or key == "STEEL":
        return "Non-Combustible"

    return "Unknown"


def normalize_wall_material_external_cladding(raw_value):
    key = canonical_key(strip_code_prefix(raw_value) or raw_value)
    if not key:
        return None

    if key in ["UNKNOWN", "UNKNOWN/DEFAULT", "DEFAULT", "UNK"]:
        return "Unknown/default"

    if "BRICK VENEER" in key:
        return "Brick/unreinforced masonry"

    if "BRICK" in key and "REINFORCED" not in key:
        return "Brick/unreinforced masonry"

    if "UNREINFORCED MASONRY" in key:
        return "Brick/unreinforced masonry"

    if "REINFORCED MASONRY" in key:
        return "Reinforced masonry"

    if "PLYWOOD" in key:
        return "Plywood"

    if "WOOD PLANK" in key:
        return "Wood planks"

    if "PARTICLE" in key or "OSB" in key:
        return "Particle board/OSB"

    if "METAL PANEL" in key or key == "METAL":
        return "Metal panels"

    if "PRE-CAST" in key or "PRECAST" in key:
        return "Pre-cast concrete elements"

    if "CAST-IN-PLACE" in key or "CAST IN PLACE" in key:
        return "Cast-in-place concrete"

    if "GYPSUM" in key:
        return "Gypsum board"

    return None


def normalize_roof_material_covering(raw_value):
    key = canonical_key(strip_code_prefix(raw_value) or raw_value)
    if not key:
        return None

    if key in ["UNKNOWN", "UNKNOWN/DEFAULT", "DEFAULT", "UNK"]:
        return "Unknown/default"

    if key in ["COMP", "COMPOSITION"] or "COMPOSITION" in key:
        return "Asphalt shingles"

    if "ASPHALT" in key and "SHINGLE" in key:
        return "Asphalt shingles"

    if key == "SHINGLE" or key == "SHINGLES":
        return "Asphalt shingles"

    if "WOOD" in key and "SHINGLE" in key:
        return "Wooden shingles"

    if "WOOD FIBER" in key and "SHINGLE" in key:
        return "Wooden shingles"

    if "WOOD SHAKE" in key:
        return "Wooden shingles"

    if "CLAY" in key and ("CONCRETE" in key or "TILE" in key):
        return "Clay/concrete tiles"

    if "CONCRETE" in key and "TILE" in key:
        return "Clay/concrete tiles"

    if "CLAY TILE" in key:
        return "Clay/concrete tiles"

    if "LIGHT METAL" in key or "METAL PANEL" in key:
        return "Light metal panels"

    if "SLATE" in key:
        return "Slate"

    if "TPO" in key:
        return "Single ply membrane"

    if "SINGLE PLY" in key or "SINGLE-PLY" in key:
        if "BALLAST" in key:
            return "Single ply membrane ballasted"
        return "Single ply membrane"

    if "MEMBRANE" in key:
        if "BALLAST" in key:
            return "Single ply membrane ballasted"
        return "Single ply membrane"

    if "BUILT-UP" in key or "BUILT UP" in key or "TAR AND GRAVEL" in key or "TAR & GRAVEL" in key:
        if "WITHOUT" in key or "NO GRAVEL" in key:
            return "Built-up roof without gravel"
        if "GRAVEL" in key:
            return "Built-up roof with gravel"
        return "Built-up roof with gravel"

    if key == "GRAVEL" or "GRAVEL" in key:
        return "Built-up roof with gravel"

    if "HURRICANE" in key and "ROOF" in key:
        return "Hurricane Wind-Rated Roof Coverings"

    return None


def normalize_foundation_type(raw_value):
    key = canonical_key(strip_code_prefix(raw_value) or raw_value)
    if not key:
        return None

    if key in ["UNKNOWN", "UNKNOWN/DEFAULT", "DEFAULT", "UNK"]:
        return "Unknown/default"

    if "NO BASEMENT" in key:
        return "No basement"

    if "ENGINEERING FOUNDATION" in key or "ENGINEERED FOUNDATION" in key:
        return "Engineering foundation"

    if "CONCRETE BASEMENT" in key:
        return "Concrete basement"

    if "MAT" in key and "SLAB" in key:
        return "Mat / slab"

    if key == "SLAB" or "SLAB" in key:
        return "Mat / slab"

    if "FOOTING" in key:
        return "Footing"

    if "POST" in key and "PIER" in key:
        return "Post & pier"

    if key == "PIER":
        return "Post & pier"

    if "PILE" in key:
        return "Pile"

    if "MASONRY BASEMENT" in key:
        return "Masonry basement"

    return None


def normalize_roof_anchor(raw_value):
    key = canonical_key(strip_code_prefix(raw_value) or raw_value)
    if not key:
        return None

    if key in ["UNKNOWN", "UNKNOWN/DEFAULT", "DEFAULT", "UNK"]:
        return "Unknown/default"

    if "STRUCTURALLY CONNECTED" in key or key == "STRUCTURAL" or "STRUCTURAL" in key:
        return "Structurally Connected"

    if "NAIL" in key or "SCREW" in key:
        return "Nails/Screws"

    if "HURRICANE TIE" in key:
        return "Hurricane Ties"

    if "GRAVITY" in key or "FRICTION" in key:
        return "Gravity/friction"

    if "CLIP" in key:
        return "Clips"

    if "ANCHOR BOLT" in key:
        return "Anchor bolts"

    if "ADHESIVE" in key or "EPOXY" in key:
        return "Adhesive epoxy"

    return None


def normalize_roof_geometry(raw_value):
    key = canonical_key(strip_code_prefix(raw_value) or raw_value)
    if not key:
        return None

    if key in ["UNKNOWN", "UNKNOWN/DEFAULT", "DEFAULT", "UNK"]:
        return "Unknown/default"

    if key == "FLAT" or "FLAT ROOF" in key:
        return "Flat"

    if "WITHOUT BRACING" in key:
        return "Gable end without bracing"

    if "WITH BRACING" in key:
        return "Gable end with bracing"

    if "GABLE" in key:
        return "Gable end with bracing"

    if key == "HIP" or "HIP ROOF" in key:
        return "Hip"

    if key == "SHED" or "SHED ROOF" in key:
        return "Shed"

    if "BUTTERFLY" in key:
        return "Butterfly"

    if "MANSARD" in key:
        return "Mansard"

    if "STEPPED" in key:
        return "Stepped"

    return None


def normalize_number_string(value):
    value = clean_text(value)
    if not value:
        return None

    value = value.replace(",", "")
    value = value.replace("$", "")
    value = value.strip()

    match = re.search(r'-?\d+(\.\d+)?', value)
    if not match:
        return None

    number_text = match.group(0)

    try:
        number_value = float(number_text)
        if number_value.is_integer():
            return str(int(number_value))
        return str(number_value)
    except Exception:
        return None


def normalize_year(value):
    value = clean_text(value)
    if not value:
        return None

    match = re.search(r'\b(1[0-9]{3}|20[0-9]{2})\b', value)
    if match:
        year = int(match.group(1))
        if 1000 <= year <= CURRENT_YEAR:
            return str(year)

    number_text = normalize_number_string(value)
    if not number_text:
        return None

    try:
        year = int(float(number_text))
        if 1000 <= year <= CURRENT_YEAR:
            return str(year)
    except Exception:
        return None

    return None


def normalize_positive_integer(value, allow_zero=False, max_value=None):
    number_text = normalize_number_string(value)
    if not number_text:
        return None

    try:
        number_value = float(number_text)
        if not number_value.is_integer():
            return None

        number_value = int(number_value)

        if allow_zero:
            if number_value < 0:
                return None
        else:
            if number_value <= 0:
                return None

        if max_value is not None and number_value > max_value:
            return None

        return str(number_value)
    except Exception:
        return None


def normalize_stories(value):
    value = clean_text(value)
    if not value:
        return None

    value = value.replace(",", "")
    numbers = re.findall(r'\b\d+\b', value)

    if not numbers:
        return None

    numbers_int = [int(x) for x in numbers if 0 < int(x) <= 200]

    if not numbers_int:
        return None

    if len(numbers_int) == 1:
        return str(numbers_int[0])

    return " & ".join(str(x) for x in sorted(set(numbers_int)))


def normalize_building_count(value):
    value = clean_text(value)
    if not value:
        return None

    value_upper = value.upper()

    if any(x in value_upper for x in [
        "APT",
        "APTS",
        "APARTMENT",
        "APARTMENTS",
        "OFFICE",
        "LAUNDRY",
        "BUILDING",
        "BUILDINGS",
        "BLDG",
        "BLDGS",
        "UNIT",
        "UNITS"
    ]):
        numbers = re.findall(r'\b\d+\b', value_upper)
        if numbers:
            total = sum(int(x) for x in numbers)
            if total > 0:
                return str(total)

    return normalize_positive_integer(value, allow_zero=False, max_value=100000)


def normalize_square_footage(value):
    number_text = normalize_number_string(value)
    if not number_text:
        return None

    try:
        number_value = float(number_text)
        if number_value <= 0:
            return None
        if number_value.is_integer():
            return str(int(number_value))
        return str(number_value)
    except Exception:
        return None


def normalize_value_for_variable(variable_key, raw_value):
    if variable_key == "CONSTRUCTION_CODE":
        return normalize_construction_type(raw_value)

    if variable_key == "YEAR_BUILT":
        return normalize_year(raw_value)

    if variable_key == "YEAR_OF_LAST_MAJOR_RENOVATION":
        return normalize_year(raw_value)

    if variable_key == "SQUARE_FOOTAGE":
        return normalize_square_footage(raw_value)

    if variable_key == "NUMBER_OF_STORIES":
        return normalize_stories(raw_value)

    if variable_key == "NUMBER_OF_BASEMENTS":
        return normalize_positive_integer(raw_value, allow_zero=True, max_value=20)

    if variable_key == "NUMBER_OF_BUILDINGS_AT_LOCATION":
        return normalize_building_count(raw_value)

    if variable_key == "WALL_MATERIAL_EXTERNAL_CLADDING":
        return normalize_wall_material_external_cladding(raw_value)

    if variable_key == "ROOF_MATERIAL_COVERING":
        return normalize_roof_material_covering(raw_value)

    if variable_key == "FOUNDATION_TYPE":
        return normalize_foundation_type(raw_value)

    if variable_key == "ROOF_ANCHOR":
        return normalize_roof_anchor(raw_value)

    if variable_key == "ROOF_GEOMETRY":
        return normalize_roof_geometry(raw_value)

    return clean_text(raw_value)


def add_value(variable_key, raw_value, counters, raw_counters, raw_construction_counter, raw_to_normalized_mapping, count_value=1):
    raw_value = clean_text(raw_value)

    if is_probably_invalid_value(raw_value):
        return False

    normalized_value = normalize_value_for_variable(variable_key, raw_value)

    if normalized_value is None:
        return False

    counters[variable_key][normalized_value] += count_value

    if variable_key == "CONSTRUCTION_CODE":
        raw_construction_counter[raw_value] += count_value
        raw_to_normalized_mapping[raw_value] = normalized_value

    if variable_key in RAW_TRACKED_VARIABLES:
        raw_counters[variable_key][raw_value] += count_value

    return True


def extract_variables_from_xlsx(scoped_file_url):
    extracted = {variable_key: [] for variable_key in VARIABLES.keys()}

    with SnowflakeFile.open(scoped_file_url, "rb") as f:
        data = f.read()

    wb = load_workbook(
        io.BytesIO(data),
        read_only=True,
        data_only=True,
        keep_vba=False
    )

    for variable_key in VARIABLES.keys():
        if variable_key == "ROOF_MATERIAL_COVERING":
            worksheets = [
                ws for ws in wb.worksheets
                if not is_reference_sheet(ws.title)
            ]

            worksheets = sorted(
                worksheets,
                key=lambda ws: 0 if is_sov_sheet(ws.title) else 1
            )
        else:
            worksheets = wb.worksheets

        for ws in worksheets:
            rows = list(ws.iter_rows(values_only=True))
            candidate_columns = []

            for row_number, row in enumerate(rows, start=1):
                if row_number > 120:
                    break

                for col_idx, cell_value in enumerate(row):
                    priority = classify_header(cell_value, variable_key)

                    if priority is not None:
                        candidate_columns.append({
                            "header_row_number": row_number,
                            "col_idx": col_idx,
                            "header_name": clean_text(cell_value),
                            "priority": priority,
                            "sheet_name": ws.title,
                            "sheet_priority": 0 if is_sov_sheet(ws.title) else 1
                        })

            if not candidate_columns:
                continue

            scored_candidates = []

            for candidate in candidate_columns:
                header_row_number = candidate["header_row_number"]
                col_idx = candidate["col_idx"]
                header_name = candidate["header_name"]
                priority = candidate["priority"]
                sheet_priority = candidate["sheet_priority"]

                raw_counter = Counter()

                for row_number, row in enumerate(rows, start=1):
                    if row_number <= header_row_number:
                        continue

                    if col_idx >= len(row):
                        continue

                    raw_value = clean_text(row[col_idx])

                    if is_probably_invalid_value(raw_value):
                        continue

                    normalized_value = normalize_value_for_variable(variable_key, raw_value)

                    if normalized_value is None:
                        continue

                    raw_counter[raw_value] += 1

                valid_count = sum(raw_counter.values())

                if valid_count > 0:
                    scored_candidates.append({
                        "header_row_number": header_row_number,
                        "col_idx": col_idx,
                        "header_name": header_name,
                        "priority": priority,
                        "sheet_priority": sheet_priority,
                        "valid_count": valid_count,
                        "raw_counter": raw_counter,
                        "sheet_name": candidate["sheet_name"]
                    })

            if not scored_candidates:
                continue

            if variable_key == "ROOF_MATERIAL_COVERING":
                scored_candidates = sorted(
                    scored_candidates,
                    key=lambda x: (
                        x["sheet_priority"],
                        x["priority"],
                        -x["valid_count"],
                        x["header_row_number"],
                        x["col_idx"]
                    )
                )
            else:
                scored_candidates = sorted(
                    scored_candidates,
                    key=lambda x: (
                        x["priority"],
                        -x["valid_count"],
                        x["header_row_number"],
                        x["col_idx"]
                    )
                )

            best_candidate = scored_candidates[0]

            for raw_value, count_value in best_candidate["raw_counter"].items():
                extracted[variable_key].append({
                    "raw_value": raw_value,
                    "count": count_value,
                    "sheet_name": best_candidate["sheet_name"],
                    "header_name": best_candidate["header_name"]
                })

            if variable_key == "ROOF_MATERIAL_COVERING" and is_sov_sheet(best_candidate["sheet_name"]):
                break

    return extracted


def build_ai_response_format(variable_keys):
    properties_text = []

    for variable_key in variable_keys:
        config = VARIABLES[variable_key]
        table_name = config["table_name"]
        description = escape_sql_string(config["ai_description"])

        properties_text.append(f"""
          '{table_name}': {{
            'description': '{description}',
            'type': 'object',
            'column_ordering': ['raw_value', 'evidence'],
            'properties': {{
              'raw_value': {{
                'description': 'The exact raw value as written in the document.',
                'type': 'array'
              }},
              'evidence': {{
                'description': 'Short supporting text proving the value is explicitly used for this field.',
                'type': 'array'
              }}
            }}
          }}
        """)

    joined_properties = ",".join(properties_text)

    response_format = f"""
    {{
      'schema': {{
        'type': 'object',
        'properties': {{
          {joined_properties}
        }}
      }}
    }}
    """

    return response_format


def evidence_has_required_context(variable_key, evidence_text):
    if not evidence_text:
        return False

    evidence_lower = evidence_text.lower()
    markers = VARIABLES[variable_key]["context_markers"]

    return any(marker in evidence_lower for marker in markers)


def batch_list(values, batch_size):
    for i in range(0, len(values), batch_size):
        yield values[i:i + batch_size]


def ai_extract_variables_from_file(session, stage_name, relative_path, variable_keys_needed):
    relative_path_sql = escape_sql_string(relative_path)
    stage_name_sql = escape_sql_string(stage_name)

    extracted = {variable_key: [] for variable_key in VARIABLES.keys()}
    ai_errors = []

    variable_keys_needed = [
        key for key in variable_keys_needed
        if key in VARIABLES
    ]

    if not variable_keys_needed:
        return extracted, None

    for variable_keys in batch_list(variable_keys_needed, 5):
        response_format = build_ai_response_format(variable_keys)

        sql = f"""
            SELECT AI_EXTRACT(
                file => TO_FILE('{stage_name_sql}', '{relative_path_sql}'),
                responseFormat => {response_format},
                scores => TRUE
            ) AS R
        """

        try:
            result = session.sql(sql).collect()[0]["R"]

            if isinstance(result, str):
                result = json.loads(result)

            result = result or {}
            response = result.get("response") or {}
            ai_error = result.get("error")

            if ai_error:
                ai_errors.append(str(ai_error))

            for variable_key in variable_keys:
                config = VARIABLES[variable_key]
                table_name = config["table_name"]
                table_data = response.get(table_name) or {}

                raw_values = table_data.get("raw_value") or []
                evidence_values = table_data.get("evidence") or []

                max_len = max(len(raw_values), len(evidence_values))

                for i in range(max_len):
                    raw_value = raw_values[i] if i < len(raw_values) else None
                    evidence = evidence_values[i] if i < len(evidence_values) else None

                    raw_value = clean_text(raw_value)
                    evidence = clean_text(evidence)

                    if not raw_value:
                        continue

                    if not evidence_has_required_context(variable_key, evidence):
                        continue

                    normalized_value = normalize_value_for_variable(variable_key, raw_value)

                    if normalized_value is None:
                        continue

                    extracted[variable_key].append({
                        "raw_value": raw_value,
                        "count": 1,
                        "evidence": evidence
                    })

        except Exception as e:
            ai_errors.append(str(e))

    if ai_errors:
        return extracted, " | ".join(ai_errors)

    return extracted, None


def build_target_keywords(target_folder_keyword):
    value = clean_text(target_folder_keyword)

    if not value:
        return []

    parts = re.split(r'[,|;]', value)
    keywords = []

    for part in parts:
        part = clean_text(part)

        if part:
            keywords.append(part.upper())

    return keywords


def folder_matches_target(folder_name, target_keywords):
    if not target_keywords:
        return True

    folder_upper = folder_name.upper()

    folder_normalized = folder_upper.replace("_", " ").replace("-", " ")
    folder_normalized = re.sub(r"\s+", " ", folder_normalized).strip()

    for keyword in target_keywords:
        keyword_upper = keyword.upper()
        keyword_normalized = keyword_upper.replace("_", " ").replace("-", " ")
        keyword_normalized = re.sub(r"\s+", " ", keyword_normalized).strip()

        if keyword_upper in folder_upper:
            return True

        if keyword_normalized in folder_normalized:
            return True

    return False


def run(session, STAGE_ROOT, MAX_FOLDERS, TARGET_FOLDER_KEYWORD):
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
    target_keywords = build_target_keywords(TARGET_FOLDER_KEYWORD)

    candidate_folder_names = sorted([
        folder_name
        for folder_name in files_by_folder.keys()
        if folder_name not in already_processed_folders
        and folder_matches_target(folder_name, target_keywords)
    ])

    if MAX_FOLDERS is not None and int(MAX_FOLDERS) > 0:
        folder_names_to_process = candidate_folder_names[:int(MAX_FOLDERS)]
    else:
        folder_names_to_process = candidate_folder_names

    ai_extract_extensions = {
        ".pdf",
        ".doc",
        ".docx",
        ".eml"
    }

    excel_extensions = {
        ".xlsx",
        ".xlsm"
    }

    processed_folder_count = 0
    total_files_processed = 0

    for folder_name in folder_names_to_process:
        folder_files = files_by_folder[folder_name]

        counters = {variable_key: Counter() for variable_key in VARIABLES.keys()}
        raw_counters = {variable_key: Counter() for variable_key in RAW_TRACKED_VARIABLES}

        raw_construction_counter = Counter()
        raw_to_normalized_mapping = {}

        roof_material_found_from_excel = False

        source_files = set()
        skipped_files = []

        files_found = len(folder_files)
        files_processed = 0

        excel_files = [
            file_info for file_info in folder_files
            if file_info["extension"] in excel_extensions
        ]

        other_files = [
            file_info for file_info in folder_files
            if file_info["extension"] not in excel_extensions
        ]

        for file_info in excel_files:
            relative_path = file_info["relative_path"]
            file_name = file_info["file_name"]

            try:
                scoped_url_sql = f"""
                    SELECT BUILD_SCOPED_FILE_URL(
                        {stage_name},
                        '{escape_sql_string(relative_path)}'
                    ) AS FILE_URL
                """

                scoped_file_url = session.sql(scoped_url_sql).collect()[0]["FILE_URL"]
                extracted = extract_variables_from_xlsx(scoped_file_url)

                for variable_key, values in extracted.items():
                    for item in values:
                        added = add_value(
                            variable_key=variable_key,
                            raw_value=item["raw_value"],
                            counters=counters,
                            raw_counters=raw_counters,
                            raw_construction_counter=raw_construction_counter,
                            raw_to_normalized_mapping=raw_to_normalized_mapping,
                            count_value=item["count"]
                        )

                        if added and variable_key == "ROOF_MATERIAL_COVERING":
                            roof_material_found_from_excel = True

                files_processed += 1
                source_files.add(file_name)

            except Exception as e:
                skipped_files.append({
                    "file_name": file_name,
                    "reason": str(e)
                })

        all_variable_keys_for_ai = list(VARIABLES.keys())

        if roof_material_found_from_excel:
            variable_keys_for_ai = [
                variable_key
                for variable_key in all_variable_keys_for_ai
                if variable_key != "ROOF_MATERIAL_COVERING"
            ]
        else:
            variable_keys_for_ai = all_variable_keys_for_ai

        for file_info in other_files:
            relative_path = file_info["relative_path"]
            file_name = file_info["file_name"]
            extension = file_info["extension"]

            try:
                if extension in ai_extract_extensions:
                    extracted, ai_error = ai_extract_variables_from_file(
                        session=session,
                        stage_name=stage_name,
                        relative_path=relative_path,
                        variable_keys_needed=variable_keys_for_ai
                    )

                    if ai_error:
                        skipped_files.append({
                            "file_name": file_name,
                            "reason": f"AI_EXTRACT error: {ai_error}"
                        })

                    for variable_key, values in extracted.items():
                        if variable_key == "ROOF_MATERIAL_COVERING" and roof_material_found_from_excel:
                            continue

                        for item in values:
                            add_value(
                                variable_key=variable_key,
                                raw_value=item["raw_value"],
                                counters=counters,
                                raw_counters=raw_counters,
                                raw_construction_counter=raw_construction_counter,
                                raw_to_normalized_mapping=raw_to_normalized_mapping,
                                count_value=item["count"]
                            )

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

        insert_sql = f"""
            INSERT INTO OPEN_MARKET_CONSTRUCTION_VARIABLE_EXTRACTION_V6 (
                ACCOUNT_FOLDER_NAME,

                CONSTRUCTION_CODE,
                RAW_CONSTRUCTION_TYPES,
                RAW_TO_NORMALIZED_MAPPING,

                YEAR_BUILT,
                YEAR_OF_LAST_MAJOR_RENOVATION,
                SQUARE_FOOTAGE,
                NUMBER_OF_STORIES,
                NUMBER_OF_BASEMENTS,
                NUMBER_OF_BUILDINGS_AT_LOCATION,

                WALL_MATERIAL_EXTERNAL_CLADDING,
                RAW_WALL_MATERIAL_EXTERNAL_CLADDING,

                ROOF_MATERIAL_COVERING,
                RAW_ROOF_MATERIAL_COVERING,

                FOUNDATION_TYPE,
                RAW_FOUNDATION_TYPE,

                ROOF_ANCHOR,
                RAW_ROOF_ANCHOR,

                ROOF_GEOMETRY,
                RAW_ROOF_GEOMETRY,

                SOURCE_FILES,
                FILES_FOUND,
                FILES_PROCESSED,
                FILES_SKIPPED,
                PROCESSED_AT
            )
            SELECT
                '{escape_sql_string(folder_name)}',

                {counter_json_expr(counters["CONSTRUCTION_CODE"])},
                {json_sql_expr(dict(raw_construction_counter))},
                {json_sql_expr(raw_to_normalized_mapping)},

                {counter_json_expr(counters["YEAR_BUILT"])},
                {counter_json_expr(counters["YEAR_OF_LAST_MAJOR_RENOVATION"])},
                {counter_json_expr(counters["SQUARE_FOOTAGE"])},
                {counter_json_expr(counters["NUMBER_OF_STORIES"])},
                {counter_json_expr(counters["NUMBER_OF_BASEMENTS"])},
                {counter_json_expr(counters["NUMBER_OF_BUILDINGS_AT_LOCATION"])},

                {counter_json_expr(counters["WALL_MATERIAL_EXTERNAL_CLADDING"])},
                {counter_json_expr(raw_counters["WALL_MATERIAL_EXTERNAL_CLADDING"])},

                {counter_json_expr(counters["ROOF_MATERIAL_COVERING"])},
                {counter_json_expr(raw_counters["ROOF_MATERIAL_COVERING"])},

                {counter_json_expr(counters["FOUNDATION_TYPE"])},
                {counter_json_expr(raw_counters["FOUNDATION_TYPE"])},

                {counter_json_expr(counters["ROOF_ANCHOR"])},
                {counter_json_expr(raw_counters["ROOF_ANCHOR"])},

                {counter_json_expr(counters["ROOF_GEOMETRY"])},
                {counter_json_expr(raw_counters["ROOF_GEOMETRY"])},

                {json_sql_expr(sorted(list(source_files)))},
                {files_found},
                {files_processed},
                {json_sql_expr(skipped_files)},
                CURRENT_TIMESTAMP()
        """

        session.sql(insert_sql).collect()

        processed_folder_count += 1
        total_files_processed += files_processed

    return (
        f"Completed construction/property variable extraction V6. "
        f"Target folder keyword: {TARGET_FOLDER_KEYWORD}. "
        f"Matched unprocessed folders available before limit: {len(candidate_folder_names)}. "
        f"New folders processed in this run: {processed_folder_count}. "
        f"Files processed in this run: {total_files_processed}. "
        f"Folders already present in V6 output table and skipped: {len(already_processed_folders)}. "
        f"SOV/Excel priority applied only for ROOF_MATERIAL_COVERING: True. "
        f"Other variables remain unchanged and can still use Excel plus PDF/DOC/EML extraction. "
        f"Unprocessed matched folders remaining after this run: "
        f"{max(0, len(candidate_folder_names) - processed_folder_count)}."
    )
$$;
