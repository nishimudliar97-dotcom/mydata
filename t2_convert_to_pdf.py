from snowflake.snowpark.functions import ai_extract, ai_parse_document, to_file, col
from snowflake.snowpark.files import SnowflakeFile
from email import policy
from email.parser import BytesParser
import json
import re

# =========================================================
# CONFIG
# =========================================================
STAGE_NAME = "TEST_A"

SUPPORTED_EXTENSIONS = {".pdf", ".doc", ".docx", ".eml"}

RESPONSE_FORMAT = {
    "schema": {
        "type": "object",
        "properties": {
            "insured_name": {
                "type": "string",
                "description": (
                    "Extract the insured name/client/account name for this insurance submission. "
                    "Look for insured name, account name, named insured, client name, company name, or subject/body context. "
                    "Return only the most likely insured entity name."
                )
            },
            "property_addresses": {
                "type": "array",
                "description": (
                    "Extract all property, site, premises, risk location, insured address, or location descriptions. "
                    "If multiple locations are present, return all separately. "
                    "If no exact address exists, return the closest available location description."
                )
            },
            "building_real_property_value": {
                "type": "string",
                "description": (
                    "Extract building real property value. "
                    "Look for building value, real property value, building amount, property damage building amount, or PD building component. "
                    "Do not use deductible, retention, premium, limit, or rent range values."
                )
            },
            "business_personal_property_value": {
                "type": "string",
                "description": (
                    "Extract business personal property value. "
                    "Look for contents, business personal property, BPP, stock, inventory, machinery, or contents value. "
                    "Do not use deductible, retention, premium, limit, or rent range values."
                )
            },
            "business_income_value": {
                "type": "string",
                "description": (
                    "Extract business income value. "
                    "Look for BI, business income, rental income, gross rentals, gross revenue, or business interruption value. "
                    "Do not use deductible, retention, premium, limit, or rent range values."
                )
            },
            "total_insurable_value": {
                "type": "string",
                "description": (
                    "Extract Total Insurable Value or TIV. "
                    "Prefer values explicitly written near labels like TIV, Total Insured Values, Total Insurable Value, "
                    "Account Specifications, or split across locations. "
                    "Do not use retention, deductible, rent range, premium, payroll, or limit values."
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


def clean_html(text: str) -> str:
    if not text:
        return ""
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"</p>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def read_eml_as_text(file_uri: str) -> str:
    with SnowflakeFile.open(file_uri, "rb", require_scoped_url=False) as f:
        msg = BytesParser(policy=policy.default).parse(f)

    subject = msg.get("subject", "")
    sender = msg.get("from", "")
    to = msg.get("to", "")
    cc = msg.get("cc", "")
    date = msg.get("date", "")

    body_parts = []

    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()

            if content_type in {"text/plain", "text/html"}:
                try:
                    content = part.get_content()
                    if content_type == "text/html":
                        content = clean_html(content)
                    body_parts.append(content)
                except Exception:
                    pass
    else:
        try:
            content = msg.get_content()
            if msg.get_content_type() == "text/html":
                content = clean_html(content)
            body_parts.append(content)
        except Exception:
            pass

    email_text = f"""
EMAIL METADATA
Subject: {subject}
From: {sender}
To: {to}
Cc: {cc}
Date: {date}

EMAIL BODY
{" ".join(body_parts)}
"""

    # avoid sending very large email threads
    return email_text[:200000]


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


def extract_from_text(session, text_value):
    text_df = session.create_dataframe(
        [[text_value]],
        schema=["EMAIL_TEXT"]
    )

    return text_df.select(
        ai_extract(
            col("EMAIL_TEXT"),
            RESPONSE_FORMAT
        ).alias("EXTRACTED_OUTPUT")
    ).collect()[0]["EXTRACTED_OUTPUT"]


def extract_from_file(session, file_uri):
    extract_df = session.range(1).select(
        ai_extract(
            to_file(file_uri),
            RESPONSE_FORMAT
        ).alias("EXTRACTED_OUTPUT")
    )

    return extract_df.collect()[0]["EXTRACTED_OUTPUT"]


# =========================================================
# MAIN HANDLER
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
            # PDF / DOC / DOCX: parse first, then extract from file
            if file_ext in {".pdf", ".doc", ".docx"}:
                parse_df = session.range(1).select(
                    ai_parse_document(
                        to_file(file_uri),
                        mode="LAYOUT",
                        page_split=True
                    ).alias("PARSED_OUTPUT")
                )
                _ = parse_df.collect()[0]["PARSED_OUTPUT"]

                extracted_output = extract_from_file(session, file_uri)

            # EML: read email as clean text, then extract from text
            elif file_ext == ".eml":
                email_text = read_eml_as_text(file_uri)
                extracted_output = extract_from_text(session, email_text)

            extracted_output = safe_json(extracted_output)

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
