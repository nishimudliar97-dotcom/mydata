CREATE OR REPLACE PROCEDURE EXPERIMENT_TEAM_DB.PUBLIC.EXTRACT_FILE_FIELDS(
    FILE_URI STRING,
    FILE_NAME STRING,
    FILE_TYPE STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
def run(session, file_uri, file_name, file_type):
    return {
        "file_name": file_name,
        "file_type": file_type,
        "status": "SUCCESS_TEST",
        "insured_name": "test",
        "property_addresses": "test",
        "building_real_property_value": "test",
        "business_personal_property_value": "test",
        "business_income_value": "test",
        "total_insurable_value": "test",
        "reason": None
    }
$$;
