CREATE OR REPLACE PROCEDURE PARSE_FILE_IF_NEEDED(FILE_URI STRING, FILE_TYPE STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.functions import ai_parse_document, to_file

def run(session, file_uri, file_type):
    if file_type in [".pdf", ".doc", ".docx"]:
        df = session.range(1).select(
            ai_parse_document(
                to_file(file_uri),
                mode="LAYOUT",
                page_split=True
            ).alias("PARSED_OUTPUT")
        )
        _ = df.collect()[0]["PARSED_OUTPUT"]
        return "PARSED"

    if file_type == ".eml":
        return "SKIPPED_PARSE_FOR_EML"

    return "UNSUPPORTED_FILE_TYPE"
$$;
