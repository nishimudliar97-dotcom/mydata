prompt = f"""
You are analyzing insurance quote discussion email chains.

Important context:
- Every document you receive is already confirmed as an NTU case.
- NTU means the quote was not taken up.
- Your task is NOT to decide whether it is NTU.
- Your task is to discover and name the most likely NTU reason category for this case.

Business objective:
We are running this over many NTU cases to discover repeated behavioral patterns.
Therefore, do not classify into a predefined category list.
Instead, create a short, reusable category name based on the actual negotiation signals in this email chain.

Return ONLY valid JSON.
Do not include markdown.
Do not include explanation outside JSON.

Required JSON keys:
{{
  "ntu_reason_category_llm": "",
  "ntu_reason_short_label": "",
  "ntu_confidence": "",
  "ntu_explanation": "",
  "category_discovery_notes": "",
  "primary_evidence_points": [],
  "supporting_factors": [],
  "alternative_possible_categories": [],
  "weak_or_not_supported_reasons": []
}}

Instructions:
1. Treat this document as a confirmed NTU case.
2. Infer why the quote was likely not taken up from the email discussion.
3. The NTU reason may be implicit. It does not need to be explicitly written.
4. Create your own category name. Do not use a fixed taxonomy.
5. The category should be:
   - short
   - business-friendly
   - reusable across similar cases
   - based on the strongest commercial signal in the email chain
6. Do not overuse "Unclear". Use it only if the email chain contains almost no useful commercial, placement, pricing, capacity, timing, broker, market, or coverage signal.
7. If the reason is inferred rather than explicit, still provide the best category and reduce the confidence.
8. Separate the main category from secondary/supporting factors.
9. Do not invent facts. Every evidence point must be grounded in the email text.
10. Prefer category names that explain behavior, not generic labels.

How to think:
- Look for what changed during the discussion.
- Look for what the broker was pushing for.
- Look for whether another market or lead was setting terms.
- Look for whether the quoted line/capacity was useful enough.
- Look for whether the layer, attachment, limit, or structure changed.
- Look for whether terms, deductibles, sublimits, exclusions, wording, or clauses were challenged.
- Look for whether price, commission, rate cut, or premium target pressure is visible.
- Look for whether the quote was tied, conditional, not standalone, or restrictive.
- Look for whether the discussion happened late or after placement had already advanced.
- Look for whether the risk profile, losses, CAT exposure, geography, occupancy, or engineering concerns affected appetite.

Do not convert the above thinking points into fixed categories.
Use them only to reason about the document and then generate your own best category.

Confidence guidance:
- High: strong direct signal in the email chain.
- Medium-High: multiple strong indirect signals.
- Medium: plausible inference from some meaningful signals.
- Low-Medium: weak inference from limited signals.
- Low: very limited evidence, but still best available inference.

Output field guidance:
- "ntu_reason_category_llm": the category you discover for this NTU case.
- "ntu_reason_short_label": 3 to 7 word label.
- "ntu_confidence": High, Medium-High, Medium, Low-Medium, or Low.
- "ntu_explanation": explain why this category fits this NTU case.
- "category_discovery_notes": explain how this category could be grouped later with similar cases.
- "primary_evidence_points": direct evidence points from the email chain.
- "supporting_factors": secondary signals that support the inferred reason.
- "alternative_possible_categories": other plausible category names, but not selected as primary.
- "weak_or_not_supported_reasons": reasons that should not be treated as primary based on this email chain.

Parsed PDF/email-chain text:
{parsed_text_for_prompt}
"""
