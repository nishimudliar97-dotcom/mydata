from snowflake.snowpark.functions import ai_extract, ai_parse_document, to_file
import json

STAGE_NAME = "TEST_STAGE"

SUPPORTED_EXTENSIONS = {".pdf", ".doc", ".docx"}

# Structured schema-style extraction request
RESPONSE_FORMAT = {
    "schema": {
        "type": "object",
        "properties": {
            "insured_name": {
                "type": "string",
                "description": (
                    "Extract the insured name for this insurance submission. "
                    "Look for synonyms such as insured name, account name, named insured, client name, or account overview name. "
                    "Return only the most likely insured entity name."
                )
            },
            "property_addresses": {
                "type": "array",
                "description": (
                    "Extract all property/site/risk addresses relevant to the insured locations. "
                    "Look for synonyms such as site, premises, property address, risk location, producing office, locations, insured address. "
                    "If multiple site addresses are present, return all of them as separate items. "
                    "If no direct full address is available, return the closest location description available."
                )
            },
            "building_real_property_value": {
                "type": "string",
                "description": (
                    "Extract the building real property value. "
                    "Look for synonyms such as building value, building real property value, real property, building amount, building TIV component. "
                    "Return the most relevant numeric value as written in the document."
                )
            },
            "business_personal_property_value": {
                "type": "string",
                "description": (
                    "Extract the business personal property value. "
                    "Look for synonyms such as contents, contents value, business personal property, BPP, stock, inventory, machinery/contents where relevant. "
                    "Return the most relevant numeric value as written in the document."
                )
            },
            "business_income_value": {
                "type": "string",
                "description": (
                    "Extract the rental or business income value. "
                    "Look for synonyms such as business income, BI, rental income, gross rentals, gross revenue, business interruption amount where relevant. "
                    "Return the most relevant numeric value as written in the document."
                )
            },
            "total_insurable_value": {
                "type": "string",
                "description": (
                    "Extract the total insurable value / total insured value / TIV. "
                    "Look for synonyms such as TIV, total insured values, total insurable value, total values. "
                    "Return the most relevant numeric value as written in the document."
                )
            }
        }
    }
}

def normalize_relative_path(stage_name: str, full_path: str) -> str:
    path = full_path.strip()

    if path.startswith("@"):
        path = path[1:]

    stage_prefix = f"{stage_name}/"
    if path.startswith(stage_prefix):
        path = path[len(stage_prefix):]

    lower_stage_prefix = f"{stage_name.lower()}/"
    if path.lower().startswith(lower_stage_prefix):
        path = path[len(lower_stage_prefix):]

    return path

def safe_json(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except Exception:
            return value
    return value

def get_extension(file_name: str) -> str:
    file_name = file_name.lower()
    if "." not in file_name:
        return ""
    return "." + file_name.split(".")[-1]

def join_addresses(addresses):
    if not addresses:
        return None
    if isinstance(addresses, list):
        cleaned = [str(x).strip() for x in addresses if x and str(x).strip()]
        return ", ".join(cleaned) if cleaned else None
    return str(addresses).strip() if str(addresses).strip() else None

def main(session):
    stage_rows = session.sql(f"LIST @{STAGE_NAME}").collect()

    if not stage_rows:
        return session.create_dataframe([{
            "FILE_NAME": None,
            "FILE_TYPE": None,
            "STATUS": "INFO",
            "INSURED_NAME": None,
            "PROPERTY_ADDRESSES": None,
            "BUILDING_REAL_PROPERTY_VALUE": None,
            "BUSINESS_PERSONAL_PROPERTY_VALUE": None,
            "BUSINESS_INCOME_VALUE": None,
            "TOTAL_INSURABLE_VALUE": None,
            "REASON": "No files found in stage"
        }])

    results = []

    for row in stage_rows:
        full_path = row[0]
        relative_path = normalize_relative_path(STAGE_NAME, full_path)
        file_name = relative_path.split("/")[-1]
        file_ext = get_extension(file_name)
        file_uri = f"@{STAGE_NAME}/{relative_path}"

        if file_ext not in SUPPORTED_EXTENSIONS:
            results.append({
                "FILE_NAME": file_name,
                "FILE_TYPE": file_ext,
                "STATUS": "SKIPPED",
                "INSURED_NAME": None,
                "PROPERTY_ADDRESSES": None,
                "BUILDING_REAL_PROPERTY_VALUE": None,
                "BUSINESS_PERSONAL_PROPERTY_VALUE": None,
                "BUSINESS_INCOME_VALUE": None,
                "TOTAL_INSURABLE_VALUE": None,
                "REASON": f"Unsupported file type for this POC: {file_ext}"
            })
            continue

        try:
            # Optional parse first for OCR/layout understanding
            parse_df = session.range(1).select(
                ai_parse_document(
                    to_file(file_uri),
                    {
                        "mode": "LAYOUT",
                        "page_split": True
                    },
                    True
                ).alias("PARSED_OUTPUT")
            )
            _parsed_output = parse_df.collect()[0]["PARSED_OUTPUT"]

            # Actual structured extraction
            extract_df = session.range(1).select(
                ai_extract(
                    to_file(file_uri),
                    RESPONSE_FORMAT
                ).alias("EXTRACTED_OUTPUT")
            )

            extracted_output = safe_json(extract_df.collect()[0]["EXTRACTED_OUTPUT"])

            if isinstance(extracted_output, dict):
                response = extracted_output.get("response", extracted_output)
            else:
                response = {}

            insured_name = response.get("insured_name")
            property_addresses = join_addresses(response.get("property_addresses"))
            building_real_property_value = response.get("building_real_property_value")
            business_personal_property_value = response.get("business_personal_property_value")
            business_income_value = response.get("business_income_value")
            total_insurable_value = response.get("total_insurable_value")

            # Skip if nothing meaningful found
            all_missing = all(
                x in [None, "", [], {}]
                for x in [
                    insured_name,
                    property_addresses,
                    building_real_property_value,
                    business_personal_property_value,
                    business_income_value,
                    total_insurable_value
                ]
            )

            if all_missing:
                results.append({
                    "FILE_NAME": file_name,
                    "FILE_TYPE": file_ext,
                    "STATUS": "SKIPPED",
                    "INSURED_NAME": None,
                    "PROPERTY_ADDRESSES": None,
                    "BUILDING_REAL_PROPERTY_VALUE": None,
                    "BUSINESS_PERSONAL_PROPERTY_VALUE": None,
                    "BUSINESS_INCOME_VALUE": None,
                    "TOTAL_INSURABLE_VALUE": None,
                    "REASON": "No target values found"
                })
                continue

            results.append({
                "FILE_NAME": file_name,
                "FILE_TYPE": file_ext,
                "STATUS": "SUCCESS",
                "INSURED_NAME": insured_name,
                "PROPERTY_ADDRESSES": property_addresses,
                "BUILDING_REAL_PROPERTY_VALUE": building_real_property_value,
                "BUSINESS_PERSONAL_PROPERTY_VALUE": business_personal_property_value,
                "BUSINESS_INCOME_VALUE": business_income_value,
                "TOTAL_INSURABLE_VALUE": total_insurable_value,
                "REASON": None
            })

        except Exception as e:
            results.append({
                "FILE_NAME": file_name,
                "FILE_TYPE": file_ext,
                "STATUS": "ERROR",
                "INSURED_NAME": None,
                "PROPERTY_ADDRESSES": None,
                "BUILDING_REAL_PROPERTY_VALUE": None,
                "BUSINESS_PERSONAL_PROPERTY_VALUE": None,
                "BUSINESS_INCOME_VALUE": None,
                "TOTAL_INSURABLE_VALUE": None,
                "REASON": str(e)
            })

    return session.create_dataframe(results)
