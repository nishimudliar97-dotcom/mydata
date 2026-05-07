CREATE OR REPLACE TABLE NTU_REASON_GRANULAR_SUBCATEGORY_RESULTS_V1 (
    NTU_GRANULAR_SUB_CATEGORY STRING,
    NTU_REASON STRING,
    NTU_EXPLANATION STRING,
    NTU_CONFIDENCE STRING,
    ACCOUNT_FOLDER_NAME STRING,
    QUOTE_PROGRESSION_SUMMARY STRING
);

CREATE OR REPLACE PROCEDURE RUN_NTU_REASON_GRANULAR_SUBCATEGORY_CLASSIFICATION()
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
TARGET_TABLE = "NTU_REASON_GRANULAR_SUBCATEGORY_RESULTS_V1"

# Change this model only if your Snowflake account supports a different Cortex model
MODEL_NAME = "llama3.1-70b"


ALLOWED_GRANULAR_SUBCATEGORIES = [
    "Pricing / Premium",
    "Sublimit",
    "Deductible",
    "Coverage Scope",
    "Policy Terms / Conditions",
    "Limit / Capacity / Line Size",
    "Layer Structure",
    "Late Quote / Timing",
    "Broker / Client Preferred Market",
    "Negotiation Delay",
    "Underwriting Appetite",
    "Unknown / Insufficient Evidence"
]


def safe_text(value):
    if value is None:
        return ""
    return str(value).strip()


def build_prompt(ntu_explanation):
    allowed_values = "\n".join([f"- {x}" for x in ALLOWED_GRANULAR_SUBCATEGORIES])

    prompt = f"""
You are an insurance underwriting and broker communication analyst.

Your task is to classify the NTU explanation into exactly one granular business subcategory.

Use ONLY the NTU_EXPLANATION field.

Do NOT use NTU_REASON for deciding the granular subcategory.
Do NOT use QUOTE_PROGRESSION_SUMMARY for deciding the granular subcategory.
Do NOT assume that NTU_REASON is correct.
Do NOT invent facts.
Do NOT create a new category outside the allowed list.
Do NOT return any explanation outside JSON.

Allowed NTU_GRANULAR_SUB_CATEGORY values:
{allowed_values}

Granular classification guidance:

1. Pricing / Premium
Use when the explanation clearly indicates premium, pricing, rate, quote being too expensive, another market being cheaper, commercial pricing issue, price competitiveness, or premium differential.

2. Sublimit
Use when the explanation clearly indicates a sublimit issue, sublimited coverage, insufficient sublimit, reduced sublimit, or broker/client requiring a better sublimit.

Examples of signals:
- sublimit
- sub-limited
- inner limit
- capped coverage for a specific peril or coverage section
- lower sublimit than required

3. Deductible
Use when the explanation clearly indicates deductible, retention, excess, attachment deductible, self-insured retention, or broker/client not accepting the deductible level.

Examples of signals:
- deductible too high
- retention too high
- excess not acceptable
- SIR issue
- deductible comparison with another market

4. Coverage Scope
Use when the explanation clearly indicates the issue was about what is covered or not covered, breadth of cover, missing coverage, coverage restriction, coverage gap, or coverage not matching client requirements.

Examples of signals:
- coverage not broad enough
- missing coverage
- coverage excluded
- cover not matching requirement
- narrower coverage than competitor
- coverage gap

5. Policy Terms / Conditions
Use when the explanation clearly indicates non-price terms and conditions such as wording, clauses, endorsements, exclusions, subjectivities, warranties, policy conditions, or contract language.

Examples of signals:
- wording
- terms and conditions
- exclusion
- endorsement
- clause
- subjectivity
- warranty
- condition precedent

6. Limit / Capacity / Line Size
Use when the explanation clearly indicates total limit, capacity, line size, participation amount, written line, share percentage, or inability to provide the required capacity.

Examples of signals:
- capacity
- line size
- limit
- share percentage
- participation
- unable to provide required line
- not enough capacity

7. Layer Structure
Use when the explanation clearly indicates layer structure, attachment point, excess layer, primary/excess positioning, layer participation, or structure mismatch.

Examples of signals:
- layer
- excess layer
- attachment point
- primary layer
- quota share structure
- different layer structure
- structure not aligned

8. Late Quote / Timing
Use when the explanation clearly indicates the quote came too late, timing was missed, broker/client had already placed elsewhere, decision was already made, or Convex responded after the opportunity had moved on.

Examples of signals:
- too late
- already placed
- already bound
- timing issue
- missed deadline
- quote received after placement

9. Broker / Client Preferred Market
Use when the explanation clearly indicates the broker or client preferred another insurer, incumbent, lead market, existing relationship, preferred placement route, or another market was favoured for reasons not clearly limited to price, coverage, deductible, sublimit, capacity, or timing.

Examples of signals:
- preferred incumbent
- preferred another market
- relationship with another carrier
- lead market preference
- broker preference
- client preference

10. Negotiation Delay
Use when the explanation clearly indicates prolonged negotiation, repeated back-and-forth, unresolved revisions, discussion cycles, or delay caused by negotiation rather than late initial quote.

Examples of signals:
- back and forth
- repeated revisions
- negotiation did not conclude
- prolonged discussion
- unresolved negotiation
- multiple rounds

11. Underwriting Appetite
Use when the explanation clearly indicates risk appetite, exposure concern, class of business concern, risk quality, underwriting concern, or Convex did not want to write the risk.

Examples of signals:
- outside appetite
- risk quality concern
- exposure concern
- underwriting concern
- class not preferred
- not willing to write
- declined due to appetite

12. Unknown / Insufficient Evidence
Use when the NTU_EXPLANATION does not provide enough clear evidence to classify into one of the granular categories above.

Important decision rules:
- Classify based only on NTU_EXPLANATION.
- If the explanation mentions a specific technical issue like sublimit, deductible, coverage, limit, or layer, prefer the more specific granular category over a broad category.
- For example, if the issue is "deductible too high", return "Deductible", not "Policy Terms / Conditions".
- If the issue is "sublimit too low", return "Sublimit", not "Coverage Scope".
- If the issue is "coverage not broad enough", return "Coverage Scope", not "Policy Terms / Conditions".
- If the issue is "limit or capacity not enough", return "Limit / Capacity / Line Size".
- If the issue is about attachment point or layer arrangement, return "Layer Structure".
- If multiple categories are possible, choose the strongest and most specific category supported by the explanation.
- If the explanation does not clearly support any category, return "Unknown / Insufficient Evidence".
- Return only valid JSON.

Input:

NTU_EXPLANATION:
{ntu_explanation}

Return only valid JSON in this exact format:
{{
  "ntu_granular_sub_category": "one value from allowed list"
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


def normalize_granular_subcategory(value):
    value = safe_text(value)

    if value in ALLOWED_GRANULAR_SUBCATEGORIES:
        return value

    lower_value = value.lower()

    mapping = {
        "pricing": "Pricing / Premium",
        "price": "Pricing / Premium",
        "premium": "Pricing / Premium",
        "rate": "Pricing / Premium",
        "cheaper": "Pricing / Premium",
        "undercut": "Pricing / Premium",
        "commercial": "Pricing / Premium",

        "sublimit": "Sublimit",
        "sub limit": "Sublimit",
        "sub-limit": "Sublimit",
        "inner limit": "Sublimit",
        "capped coverage": "Sublimit",

        "deductible": "Deductible",
        "retention": "Deductible",
        "sir": "Deductible",
        "self-insured retention": "Deductible",
        "excess": "Deductible",

        "coverage scope": "Coverage Scope",
        "coverage": "Coverage Scope",
        "cover": "Coverage Scope",
        "missing coverage": "Coverage Scope",
        "coverage gap": "Coverage Scope",
        "not covered": "Coverage Scope",
        "narrower coverage": "Coverage Scope",

        "policy terms": "Policy Terms / Conditions",
        "terms": "Policy Terms / Conditions",
        "conditions": "Policy Terms / Conditions",
        "wording": "Policy Terms / Conditions",
        "exclusion": "Policy Terms / Conditions",
        "endorsement": "Policy Terms / Conditions",
        "clause": "Policy Terms / Conditions",
        "subjectivity": "Policy Terms / Conditions",
        "warranty": "Policy Terms / Conditions",

        "limit": "Limit / Capacity / Line Size",
        "capacity": "Limit / Capacity / Line Size",
        "line size": "Limit / Capacity / Line Size",
        "share": "Limit / Capacity / Line Size",
        "participation": "Limit / Capacity / Line Size",
        "written line": "Limit / Capacity / Line Size",

        "layer structure": "Layer Structure",
        "layer": "Layer Structure",
        "attachment point": "Layer Structure",
        "primary layer": "Layer Structure",
        "excess layer": "Layer Structure",
        "quota share": "Layer Structure",

        "late": "Late Quote / Timing",
        "timing": "Late Quote / Timing",
        "already placed": "Late Quote / Timing",
        "already bound": "Late Quote / Timing",
        "missed deadline": "Late Quote / Timing",

        "preferred market": "Broker / Client Preferred Market",
        "preferred carrier": "Broker / Client Preferred Market",
        "incumbent": "Broker / Client Preferred Market",
        "broker preference": "Broker / Client Preferred Market",
        "client preference": "Broker / Client Preferred Market",
        "relationship": "Broker / Client Preferred Market",
        "lead market": "Broker / Client Preferred Market",

        "negotiation": "Negotiation Delay",
        "back and forth": "Negotiation Delay",
        "revisions": "Negotiation Delay",
        "prolonged discussion": "Negotiation Delay",
        "discussion cycles": "Negotiation Delay",

        "appetite": "Underwriting Appetite",
        "underwriting appetite": "Underwriting Appetite",
        "risk appetite": "Underwriting Appetite",
        "exposure concern": "Underwriting Appetite",
        "risk quality": "Underwriting Appetite",
        "not willing to write": "Underwriting Appetite",
        "outside appetite": "Underwriting Appetite"
    }

    for key, mapped_value in mapping.items():
        if key in lower_value:
            return mapped_value

    return "Unknown / Insufficient Evidence"


def classify_granular_subcategory(session, ntu_explanation):
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

        granular_subcategory = parsed.get("ntu_granular_sub_category")
        return normalize_granular_subcategory(granular_subcategory)

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

        ntu_granular_sub_category = classify_granular_subcategory(
            session=session,
            ntu_explanation=ntu_explanation
        )

        if ntu_granular_sub_category == "Unknown / Insufficient Evidence":
            unknown_count += 1

        output_rows.append([
            safe_text(ntu_granular_sub_category),
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
                "NTU_GRANULAR_SUB_CATEGORY",
                "NTU_REASON",
                "NTU_EXPLANATION",
                "NTU_CONFIDENCE",
                "ACCOUNT_FOLDER_NAME",
                "QUOTE_PROGRESSION_SUMMARY"
            ]
        )

        output_df.write.mode("append").save_as_table(TARGET_TABLE)

    return (
        f"Granular NTU subcategory classification completed. "
        f"Rows processed: {processed_count}. "
        f"Unknown/insufficient evidence rows: {unknown_count}."
    )
$$;



CALL RUN_NTU_REASON_GRANULAR_SUBCATEGORY_CLASSIFICATION();

SELECT
    g.ACCOUNT_FOLDER_NAME,
    b.NTU_REASON_SUB_CATEGORY AS BROAD_SUB_CATEGORY,
    g.NTU_GRANULAR_SUB_CATEGORY,
    g.NTU_REASON,
    g.NTU_EXPLANATION
FROM NTU_REASON_GRANULAR_SUBCATEGORY_RESULTS_V1 g
LEFT JOIN NTU_REASON_SUBCATEGORY_RESULTS_V1 b
    ON g.ACCOUNT_FOLDER_NAME = b.ACCOUNT_FOLDER_NAME
   AND g.NTU_REASON = b.NTU_REASON
   AND g.NTU_EXPLANATION = b.NTU_EXPLANATION
ORDER BY g.ACCOUNT_FOLDER_NAME;
