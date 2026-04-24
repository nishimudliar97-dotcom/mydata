from snowflake.snowpark.functions import ai_extract, ai_parse_document, to_file
import json

# =========================================================
# CONFIG
# =========================================================
STAGE_NAME = "TEST_STAGE"

SUPPORTED_EXTENSIONS = {".pdf", ".doc", ".docx", ".eml"}

RESPONSE_FORMAT = {
    "schema": {
        "type": "object",
        "properties": {
            "insured_name": {
                "type": "string",
                "description": (
                    "Extract the insured name for this insurance submission. "
                    "Look for synonyms such as insured name, account name, named insured, client name, account overview name, insured. "
                    "For email files, infer the insured/client/company name from subject, body, or forwarded message content. "
                    "Return only the most likely insured entity name."
                )
            },
            "property_addresses": {
                "type": "array",
                "description": (
                    "Extract all property or site addresses relevant to the insured locations. "
                    "Look for synonyms such as site, premises, property address, risk location, insured address, location, producing office. "
                    "For emails, infer any location or address mentioned in the email body. "
                    "If multiple locations are present, return all as separate items. "
                    "If no exact address is available, return the closest available location description."
                )
            },
            "building_real_property_value": {
                "type": "string",
                "description": (
                    "Extract the building real property value. "
                    "Look for synonyms such as building value, building real property value, real property value, building amount, "
                    "property damage building amount, PD building component. "
                    "Return only the most relevant numeric value as written."
                )
            },
            "business_personal_property_value": {
                "type": "string",
                "description": (
                    "Extract the business personal property value. "
                    "Look for synonyms such as contents, contents value, business personal property, BPP, stock, inventory, machinery/contents. "
                    "Return only the most relevant numeric value as written."
                )
            },
            "business_income_value": {
                "type": "string",
                "description": (
                    "Extract the business income or rental/business income value. "
                    "Look for synonyms such as business income, BI, rental income, gross rentals, gross revenue, business interruption value. "
                    "For emails, BI may be written as BI, business income, gross revenue, or rental income. "
                    "Return only the most relevant numeric value as written."
                )
            },
            "total_insurable_value": {
                "type": "string",
                "description": (
                    "Extract the total insurable value / total insured value / TIV. "
                    "Look for synonyms such as TIV, total insured values, total insurable value, total values. "
                    "For emails, TIV may be written as TIV, total value, total insured value, or total insurable value. "
                    "Return only the most relevant numeric value as written."
                )
            }
        }
    }
}


# =========================================================
# HELPERS
# =========================================================
def normalize_relative_path(stage_name: str, full_path: str) -> str:
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


def is_blank(value):
    if value is None:
        return True

    if isinstance(value, str) and value.strip().lower() in {
        "",
        "null",
        "none",
        "not found",
        "n/a",
        "na",
        "not available"
    }:
        return True

    if isinstance(value, list) and len(value) == 0:
        return True

    if isinstance(value, dict) and len(value) == 0:
        return True

    return False


def empty_result(file_name, file_ext, status, reason):
    return {
        "FILE_NAME": file_name,
        "FILE_TYPE": file_ext,
        "STATUS": status,
        "INSURED_NAME": None,
        "PROPERTY_ADDRESSES": None,
        "BUILDING_REAL_PROPERTY_VALUE": None,
        "BUSINESS_PERSONAL_PROPERTY_VALUE": None,
        "BUSINESS_INCOME_VALUE": None,
        "TOTAL_INSURABLE_VALUE": None,
        "REASON": reason
    }


# =========================================================
# MAIN HANDLER FOR SNOWFLAKE PYTHON WORKSHEET
# =========================================================
def main(session):
    stage_rows = session.sql(f"LIST @{STAGE_NAME}").collect()

    if not stage_rows:
        return session.create_dataframe([
            empty_result(
                file_name=None,
                file_ext=None,
                status="INFO",
                reason="No files found in stage"
            )
        ])

    results = []

    for row in stage_rows:
        full_path = row[0]
        relative_path = normalize_relative_path(STAGE_NAME, full_path)
        file_name = relative_path.split("/")[-1]
        file_ext = get_extension(file_name)
        file_uri = f"@{STAGE_NAME}/{relative_path}"

        if file_ext not in SUPPORTED_EXTENSIONS:
            results.append(
                empty_result(
                    file_name=file_name,
                    file_ext=file_ext,
                    status="SKIPPED",
                    reason=f"Unsupported file type for this POC: {file_ext}"
                )
            )
            continue

        try:
            # -------------------------------------------------
            # Step 1: Parse only document-style files.
            # For .eml, skip parsing and directly use AI_EXTRACT.
            # -------------------------------------------------
            if file_ext in {".pdf", ".doc", ".docx"}:
                parse_df = session.range(1).select(
                    ai_parse_document(
                        to_file(file_uri),
                        mode="LAYOUT",
                        page_split=True
                    ).alias("PARSED_OUTPUT")
                )
                _ = parse_df.collect()[0]["PARSED_OUTPUT"]

            # -------------------------------------------------
            # Step 2: Extract required values
            # -------------------------------------------------
            extract_df = session.range(1).select(
                ai_extract(
                    to_file(file_uri),
                    RESPONSE_FORMAT
                ).alias("EXTRACTED_OUTPUT")
            )

            extracted_output = extract_df.collect()[0]["EXTRACTED_OUTPUT"]
            extracted_output = safe_json(extracted_output)

            # -------------------------------------------------
            # Step 3: Safely handle Snowflake response
            # Important for .eml where response can be null
            # -------------------------------------------------
            if isinstance(extracted_output, dict):
                ai_error = extracted_output.get("error")
                response = extracted_output.get("response") or {}
            else:
                ai_error = None
                response = {}

            if ai_error:
                results.append(
                    empty_result(
                        file_name=file_name,
                        file_ext=file_ext,
                        status="ERROR",
                        reason=str(ai_error)
                    )
                )
                continue

            insured_name = response.get("insured_name")
            property_addresses = join_addresses(response.get("property_addresses"))
            building_real_property_value = response.get("building_real_property_value")
            business_personal_property_value = response.get("business_personal_property_value")
            business_income_value = response.get("business_income_value")
            total_insurable_value = response.get("total_insurable_value")

            all_missing = all([
                is_blank(insured_name),
                is_blank(property_addresses),
                is_blank(building_real_property_value),
                is_blank(business_personal_property_value),
                is_blank(business_income_value),
                is_blank(total_insurable_value),
            ])

            if all_missing:
                results.append(
                    empty_result(
                        file_name=file_name,
                        file_ext=file_ext,
                        status="SKIPPED",
                        reason="No target values found"
                    )
                )
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
            results.append(
                empty_result(
                    file_name=file_name,
                    file_ext=file_ext,
                    status="ERROR",
                    reason=str(e)
                )
            )

    return session.create_dataframe(results)
