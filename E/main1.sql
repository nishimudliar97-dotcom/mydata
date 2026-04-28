CREATE OR REPLACE PROCEDURE EXPERIMENT_TEAM_DB.PUBLIC.RUN_DOCUMENT_EXTRACTION_PIPELINE()
RETURNS TABLE (
    FILE_NAME STRING,
    FILE_TYPE STRING,
    STATUS STRING,
    INSURED_NAME STRING,
    PROPERTY_ADDRESSES STRING,
    BUILDING_REAL_PROPERTY_VALUE STRING,
    BUSINESS_PERSONAL_PROPERTY_VALUE STRING,
    BUSINESS_INCOME_VALUE STRING,
    TOTAL_INSURABLE_VALUE STRING,
    REASON STRING
)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

STAGE_NAME = "TEST_A"
TARGET_TABLE = "EXPERIMENT_TEAM_DB.PUBLIC.EXTRACTED_INSURANCE_SUBMISSIONS"

SUPPORTED_EXTENSIONS = [".pdf", ".doc", ".docx", ".eml"]

PARSE_PROC = "EXPERIMENT_TEAM_DB.PUBLIC.PARSE_FILE_IF_NEEDED"
EXTRACT_PROC = "EXPERIMENT_TEAM_DB.PUBLIC.EXTRACT_FILE_FIELDS"


def normalize_relative_path(stage_name, full_path):
    path = str(full_path).strip()

    if path.startswith("@"):
        path = path[1:]

    stage_prefix = f"{stage_name}/"
    if path.startswith(stage_prefix):
        path = path[len(stage_prefix):]

    lower_stage_prefix = f"{stage_name.lower()}/"
    if path.lower().startswith(lower_stage_prefix):
        path = path[len(lower_stage_prefix):]

    return path


def get_extension(file_name):
    file_name = file_name.lower()
    if "." not in file_name:
        return ""
    return "." + file_name.split(".")[-1]


def clean_value(value):
    if value is None:
        return None
    return str(value)


def run(session):
    stage_rows = session.sql(f"LIST @{STAGE_NAME}").collect()

    existing_rows = session.sql(f"""
        SELECT FILE_NAME
        FROM {TARGET_TABLE}
    """).collect()

    existing_files = set()
    for row in existing_rows:
        if row["FILE_NAME"]:
            existing_files.add(row["FILE_NAME"])

    output_rows = []

    for row in stage_rows:
        full_path = row[0]
        relative_path = normalize_relative_path(STAGE_NAME, full_path)
        file_name = relative_path.split("/")[-1]
        file_type = get_extension(file_name)
        file_uri = f"@{STAGE_NAME}/{relative_path}"

        if file_name in existing_files:
            continue

        if file_type not in SUPPORTED_EXTENSIONS:
            result = {
                "file_name": file_name,
                "file_type": file_type,
                "status": "SKIPPED",
                "insured_name": None,
                "property_addresses": None,
                "building_real_property_value": None,
                "business_personal_property_value": None,
                "business_income_value": None,
                "total_insurable_value": None,
                "reason": "Unsupported file type"
            }
        else:
            try:
                session.sql(f"""
                    CALL {PARSE_PROC}('{file_uri}', '{file_type}')
                """).collect()

                result_variant = session.sql(f"""
                    CALL {EXTRACT_PROC}('{file_uri}', '{file_name}', '{file_type}')
                """).collect()[0][0]

                if isinstance(result_variant, str):
                    result = json.loads(result_variant)
                else:
                    result = result_variant

            except Exception as e:
                result = {
                    "file_name": file_name,
                    "file_type": file_type,
                    "status": "ERROR",
                    "insured_name": None,
                    "property_addresses": None,
                    "building_real_property_value": None,
                    "business_personal_property_value": None,
                    "business_income_value": None,
                    "total_insurable_value": None,
                    "reason": str(e)
                }

        file_name_v = clean_value(result.get("file_name"))
        file_type_v = clean_value(result.get("file_type"))
        status_v = clean_value(result.get("status"))
        insured_name_v = clean_value(result.get("insured_name"))
        property_addresses_v = clean_value(result.get("property_addresses"))
        building_v = clean_value(result.get("building_real_property_value"))
        bpp_v = clean_value(result.get("business_personal_property_value"))
        bi_v = clean_value(result.get("business_income_value"))
        tiv_v = clean_value(result.get("total_insurable_value"))
        reason_v = clean_value(result.get("reason"))

        temp_df = session.create_dataframe(
            [[
                file_name_v,
                file_type_v,
                status_v,
                insured_name_v,
                property_addresses_v,
                building_v,
                bpp_v,
                bi_v,
                tiv_v,
                reason_v
            ]],
            schema=[
                "FILE_NAME",
                "FILE_TYPE",
                "STATUS",
                "INSURED_NAME",
                "PROPERTY_ADDRESSES",
                "BUILDING_REAL_PROPERTY_VALUE",
                "BUSINESS_PERSONAL_PROPERTY_VALUE",
                "BUSINESS_INCOME_VALUE",
                "TOTAL_INSURABLE_VALUE",
                "REASON"
            ]
        )

        temp_view_name = "TEMP_EXTRACTION_RESULT"
        temp_df.create_or_replace_temp_view(temp_view_name)

        session.sql(f"""
            INSERT INTO {TARGET_TABLE} (
                FILE_NAME,
                FILE_TYPE,
                STATUS,
                INSURED_NAME,
                PROPERTY_ADDRESSES,
                BUILDING_REAL_PROPERTY_VALUE,
                BUSINESS_PERSONAL_PROPERTY_VALUE,
                BUSINESS_INCOME_VALUE,
                TOTAL_INSURABLE_VALUE,
                REASON,
                EXTRACTED_AT
            )
            SELECT
                FILE_NAME,
                FILE_TYPE,
                STATUS,
                INSURED_NAME,
                PROPERTY_ADDRESSES,
                BUILDING_REAL_PROPERTY_VALUE,
                BUSINESS_PERSONAL_PROPERTY_VALUE,
                BUSINESS_INCOME_VALUE,
                TOTAL_INSURABLE_VALUE,
                REASON,
                CURRENT_TIMESTAMP()
            FROM {temp_view_name}
        """).collect()

        output_rows.append((
            file_name_v,
            file_type_v,
            status_v,
            insured_name_v,
            property_addresses_v,
            building_v,
            bpp_v,
            bi_v,
            tiv_v,
            reason_v
        ))

    if not output_rows:
        output_rows.append((
            None,
            None,
            "INFO",
            None,
            None,
            None,
            None,
            None,
            None,
            "No new files to process"
        ))

    return session.create_dataframe(
        output_rows,
        schema=[
            "FILE_NAME",
            "FILE_TYPE",
            "STATUS",
            "INSURED_NAME",
            "PROPERTY_ADDRESSES",
            "BUILDING_REAL_PROPERTY_VALUE",
            "BUSINESS_PERSONAL_PROPERTY_VALUE",
            "BUSINESS_INCOME_VALUE",
            "TOTAL_INSURABLE_VALUE",
            "REASON"
        ]
    )
$$;
