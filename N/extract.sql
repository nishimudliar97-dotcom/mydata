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
from snowflake.snowpark.functions import ai_extract, to_file, col
from snowflake.snowpark.files import SnowflakeFile
from email import policy
from email.parser import BytesParser
import json
import re

RESPONSE_FORMAT = {
    "schema": {
        "type": "object",
        "properties": {
            "insured_name": {
                "type": "string",
                "description": "Extract insured name/client/account name/company name. Return only the most likely insured entity."
            },
            "property_addresses": {
                "type": "array",
                "description": "Extract all property/site/risk/premises/location addresses. If no full address, return closest location description."
            },
            "building_real_property_value": {
                "type": "string",
                "description": "Extract building real property value. Do not use deductible, retention, premium, rent, or limit values."
            },
            "business_personal_property_value": {
                "type": "string",
                "description": "Extract business personal property value. Look for contents, BPP, stock, inventory, machinery/contents."
            },
            "business_income_value": {
                "type": "string",
                "description": "Extract business income value. Look for BI, rental income, gross rentals, gross revenue, business interruption."
            },
            "total_insurable_value": {
                "type": "string",
                "description": "Extract Total Insurable Value or TIV. Prefer values near TIV, Total Insured Values, Account Specifications."
            }
        }
    }
}

def clean_html(text):
    if not text:
        return ""
    text = re.sub(r"<br\\s*/?>", "\\n", text, flags=re.I)
    text = re.sub(r"</p>", "\\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\\s+", " ", text)
    return text.strip()

def read_eml_as_text(file_uri):
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
            if content_type in ["text/plain", "text/html"]:
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
    return email_text[:200000]

def safe_json(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except Exception:
            return value
    return value

def join_addresses(addresses):
    if not addresses:
        return None
    if isinstance(addresses, list):
        cleaned = [str(x).strip() for x in addresses if x and str(x).strip()]
        return ", ".join(cleaned) if cleaned else None
    return str(addresses).strip() if str(addresses).strip() else None

def run(session, file_uri, file_name, file_type):
    try:
        if file_type == ".eml":
            email_text = read_eml_as_text(file_uri)

            text_df = session.create_dataframe(
                [[email_text]],
                schema=["EMAIL_TEXT"]
            )

            extracted_output = text_df.select(
                ai_extract(
                    col("EMAIL_TEXT"),
                    RESPONSE_FORMAT
                ).alias("EXTRACTED_OUTPUT")
            ).collect()[0]["EXTRACTED_OUTPUT"]

        else:
            extracted_output = session.range(1).select(
                ai_extract(
                    to_file(file_uri),
                    RESPONSE_FORMAT
                ).alias("EXTRACTED_OUTPUT")
            ).collect()[0]["EXTRACTED_OUTPUT"]

        extracted_output = safe_json(extracted_output)

        if isinstance(extracted_output, dict):
            ai_error = extracted_output.get("error")
            response = extracted_output.get("response") or {}
        else:
            ai_error = None
            response = {}

        if ai_error:
            return {
                "file_name": file_name,
                "file_type": file_type,
                "status": "ERROR",
                "insured_name": None,
                "property_addresses": None,
                "building_real_property_value": None,
                "business_personal_property_value": None,
                "business_income_value": None,
                "total_insurable_value": None,
                "reason": str(ai_error)
            }

        return {
            "file_name": file_name,
            "file_type": file_type,
            "status": "SUCCESS",
            "insured_name": response.get("insured_name"),
            "property_addresses": join_addresses(response.get("property_addresses")),
            "building_real_property_value": response.get("building_real_property_value"),
            "business_personal_property_value": response.get("business_personal_property_value"),
            "business_income_value": response.get("business_income_value"),
            "total_insurable_value": response.get("total_insurable_value"),
            "reason": None
        }

    except Exception as e:
        return {
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
$$;
