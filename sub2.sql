CREATE OR REPLACE PROCEDURE RUN_NTU_REASON_SUBCATEGORY_CLASSIFICATION()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python')
HANDLER = 'main'
AS
$$
import json
from snowflake.snowpark import Session
from snowflake.cortex import Complete


SOURCE_TABLE = "NTU_FOLDER_QUOTE_DISCOVERY_RESULTS_V3"
TARGET_TABLE = "NTU_REASON_SUBCATEGORY_RESULTS_V1"

# Change this only if your Snowflake account uses another supported Cortex model
MODEL_NAME = "llama3.1-70b"


ALLOWED_SUBCATEGORIES = [
    "Price",
    "Size/Capacity",
    "Terms & Conditions",
    "Late Quote",
    "Broker Preferred Channel",
    "Back and Forth / Negotiation Delay",
    "Coverage Appetite",
    "Unknown / Insufficient Evidence"
]


def safe_text(value):
    if value is None:
        return ""
    return str(value).strip()


def build_prompt(ntu_explanation):
    allowed_values = "\n".join([f"- {x}" for x in ALLOWED_SUBCATEGORIES])

    prompt = f"""
You are an insurance underwriting and broker communication analyst.

Your task is to classify the NTU explanation into exactly one business subcategory.

Use ONLY the NTU_EXPLANATION field.

Do NOT use NTU_REASON for deciding the subcategory.
Do NOT assume that the NTU_REASON is always correct.
Do NOT map based on NTU_REASON.
Do NOT use quote progression summary for deciding the subcategory.
Do NOT invent facts.
Do NOT create a new category outside the allowed list.
Do NOT return any explanation outside JSON.

Allowed NTU_REASON_SUB_CATEGORY values:
{allowed_values}

Classification guidance:

1. Price
Use when the explanation clearly indicates pricing, premium, rate, quote being expensive, commercial pricing issue, cheaper quote elsewhere, or another market undercutting on price.

2. Size/Capacity
Use when the explanation clearly indicates layer size, capacity, limit, share percentage, line size, participation percentage, quota share, attachment point, excess layer, or layer structure not matching the broker/client requirement.

3. Terms & Conditions
Use when the explanation clearly indicates coverage terms, policy conditions, exclusions, deductible, wording, subjectivities, endorsements, clauses, restrictions, or any non-price and non-capacity term issue.

4. Late Quote
Use when the explanation clearly indicates the quote came too late, the broker/client had already placed elsewhere, timing was missed, or renewal/bind decision happened before Convex could win.

5. Broker Preferred Channel
Use when the explanation clearly indicates the broker/client preferred another market, incumbent, lead market, specific carrier relationship, preferred placement route, or preferred channel.

6. Back and Forth / Negotiation Delay
Use when the explanation clearly indicates prolonged negotiation, repeated revisions, too much back and forth, delayed agreement, or unresolved discussion cycles.

7. Coverage Appetite
Use when the explanation clearly indicates risk appetite, class of business, exposure concern, underwriting appetite, risk quality, or Convex not wanting to write the risk.

8. Unknown / Insufficient Evidence
Use when the NTU_EXPLANATION does not provide enough evidence to confidently classify into one of the above subcategories.

Important rules:
- The classification must be based only on NTU_EXPLANATION.
- If the explanation does not clearly support a subcategory, return "Unknown / Insufficient Evidence".
- If multiple subcategories are possible, choose the strongest one based on the explanation.
- Return only valid JSON.

Input:

NTU_EXPLANATION:
{ntu_explanation}

Return only valid JSON in this exact format:
{{
  "ntu_reason_sub_category": "one value from allowed list"
}}
"""
    return prompt


def parse_llm_json(response_text):
    if response_text is None:
        return None

    text = str(response_text).strip()

    try:
        return json.loads(text)
    except Exception:
        pass

    try:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            json_text = text[start:end + 1]
            return json.loads(json_text)
    except Exception:
        pass

    return None


def normalize_subcategory(value):
    value = safe_text(value)

    if value in ALLOWED_SUBCATEGORIES:
        return value

    lower_value = value.lower()

    mapping = {
        "price": "Price",
        "pricing": "Price",
        "premium": "Price",
        "rate": "Price",
        "cheaper": "Price",
        "undercut": "Price",
        "commercial": "Price",

        "size": "Size/Capacity",
        "capacity": "Size/Capacity",
        "layer": "Size/Capacity",
        "limit": "Size/Capacity",
        "share": "Size/Capacity",
        "quota": "Size/Capacity",
        "attachment": "Size/Capacity",
        "excess": "Size/Capacity",

        "terms": "Terms & Conditions",
        "conditions": "Terms & Conditions",
        "wording": "Terms & Conditions",
        "deductible": "Terms & Conditions",
        "exclusion": "Terms & Conditions",
        "subjectivity": "Terms & Conditions",
        "endorsement": "Terms & Conditions",
        "clause": "Terms & Conditions",

        "late": "Late Quote",
        "timing": "Late Quote",
        "already placed": "Late Quote",
        "bound elsewhere": "Late Quote",

        "broker preferred": "Broker Preferred Channel",
        "preferred market": "Broker Preferred Channel",
        "preferred channel": "Broker Preferred Channel",
        "incumbent": "Broker Preferred Channel",
        "lead market": "Broker Preferred Channel",
        "relationship": "Broker Preferred Channel",

        "back and forth": "Back and Forth / Negotiation Delay",
        "negotiation": "Back and Forth / Negotiation Delay",
        "delay": "Back and Forth / Negotiation Delay",
        "revisions": "Back and Forth / Negotiation Delay",

        "appetite": "Coverage Appetite",
        "risk appetite": "Coverage Appetite",
        "exposure": "Coverage Appetite",
        "risk quality": "Coverage Appetite",
        "not willing to write": "Coverage Appetite"
    }

    for key, mapped_value in mapping.items():
        if key in lower_value:
            return mapped_value

    return "Unknown / Insufficient Evidence"


def classify_subcategory(session, ntu_explanation):
    ntu_explanation = safe_text(ntu_explanation)

    if not ntu_explanation:
        return "Unknown / Insufficient Evidence"

    prompt = build_prompt(ntu_explanation)

    try:
        response = Complete(
            MODEL_NAME,
            prompt,
            session=session
        )

        parsed = parse_llm_json(response)

        if parsed is None:
            return "Unknown / Insufficient Evidence"

        subcategory = parsed.get("ntu_reason_sub_category")
        return normalize_subcategory(subcategory)

    except Exception:
        return "Unknown / Insufficient Evidence"


def main(session: Session) -> str:
    session.sql(f"TRUNCATE TABLE {TARGET_TABLE}").collect()

    source_sql = f"""
        SELECT
            ACCOUNT_FOLDER_NAME,
            NTU_REASON,
            NTU_CONFIDENCE,
            NTU_EXPLANATION,
            QUOTE_PROGRESSION_SUMMARY
        FROM {SOURCE_TABLE}
        WHERE NTU_EXPLANATION IS NOT NULL
        ORDER BY ACCOUNT_FOLDER_NAME
    """

    rows = session.sql(source_sql).collect()

    output_rows = []
    processed_count = 0
    unknown_count = 0

    for row in rows:
        account_folder_name = row["ACCOUNT_FOLDER_NAME"]
        ntu_reason = row["NTU_REASON"]
        ntu_confidence = row["NTU_CONFIDENCE"]
        ntu_explanation = row["NTU_EXPLANATION"]
        quote_progression_summary = row["QUOTE_PROGRESSION_SUMMARY"]

        ntu_reason_sub_category = classify_subcategory(
            session=session,
            ntu_explanation=ntu_explanation
        )

        if ntu_reason_sub_category == "Unknown / Insufficient Evidence":
            unknown_count += 1

        output_rows.append([
            safe_text(ntu_reason_sub_category),
            safe_text(ntu_reason),
            safe_text(ntu_explanation),
            safe_text(ntu_confidence),
            safe_text(account_folder_name),
            safe_text(quote_progression_summary)
        ])

        processed_count += 1

    if output_rows:
        output_df = session.create_dataframe(
            output_rows,
            schema=[
                "NTU_REASON_SUB_CATEGORY",
                "NTU_REASON",
                "NTU_EXPLANATION",
                "NTU_CONFIDENCE",
                "ACCOUNT_FOLDER_NAME",
                "QUOTE_PROGRESSION_SUMMARY"
            ]
        )

        output_df.write.mode("append").save_as_table(TARGET_TABLE)

    return (
        f"NTU subcategory classification completed. "
        f"Rows processed: {processed_count}. "
        f"Unknown/insufficient evidence rows: {unknown_count}."
    )
$$;
