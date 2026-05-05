prompt = f"""
You are analyzing insurance quote discussion email chains for known NTU cases.

Important context:
- NTU means the quote was not taken up.
- The case is already known to be NTU.
- Your task is to infer the most likely reason from the email chain without using any predefined category list.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason_category_llm": "",
  "ntu_reason_short_label": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "evidence_points": [],
  "secondary_factors": [],
  "uncertainties": [],
  "not_supported_reasons": []
}}

Rules:
1. The case is already known to be NTU. Do not decide whether it is NTU.
2. Do not use any predefined category taxonomy.
3. Create the reason category yourself based only on the email-chain evidence.
4. Keep "ntu_reason_category_llm" short, business-friendly, and reusable across similar cases.
5. Keep "ntu_reason_short_label" even shorter, like a 3 to 7 word label.
6. The category should be derived from the commercial discussion, not copied blindly from one phrase.
7. Do not force a reason if the evidence is weak. Use "Unclear / insufficient evidence" if needed.
8. ntu_confidence must be one of:
   - High
   - Medium-High
   - Medium
   - Low-Medium
   - Low
9. ntu_explanation must explain why this category was chosen.
10. evidence_points must be an array of short evidence statements directly supported by the email chain.
11. secondary_factors must be an array of other possible contributing factors, if any.
12. uncertainties must list anything that is not clear from the email chain.
13. not_supported_reasons must list reasons that should NOT be treated as the main NTU reason because the email does not support them.
14. Avoid generic labels like "Other", "Business decision", or "General underwriting issue" unless the email evidence is truly insufficient.
15. Do not invent missing facts. If no clear reason can be inferred, say so.

Parsed PDF/email-chain text:
{parsed_text_for_prompt}
"""
