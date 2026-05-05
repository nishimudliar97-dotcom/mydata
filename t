Below is the same structured analysis for the **Sunpork 2025 Renewal** NTU case.

---

# Sunpork — Excel-ready extraction table

| Category          | Variable / Field to Extract | Value Found in Email / Submission                                      | Why This Matters for NTU                                                    | Possible NTU Reason Signal              | Confidence  |
| ----------------- | --------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------- | ----------- |
| Account Info      | Insured Name                | Sunpork                                                                | Identifies the account                                                      | Identifier only                         | High        |
| Broker            | Broker Name                 | McGill and Partners                                                    | Helps track broker/channel behavior                                         | Broker / channel analysis               | High        |
| Market            | Quoting Market              | Convex                                                                 | Market whose quote became NTU                                               | Market-level NTU tracking               | High        |
| Submission Type   | Renewal Type                | 2025 Renewal                                                           | Confirms renewal placement                                                  | Renewal analysis                        | High        |
| Submission Timing | Initial Submission Timing   | Broker sent Huddle link and asked for terms while awaiting final SOV   | Submission was not fully final at first                                     | Timing / incomplete information signal  | Medium      |
| Data Completeness | Final SOV Status            | Awaiting copy of final SOV                                             | Values may not have been final when terms requested                         | Incomplete submission / timing pressure | Medium      |
| Broker Request    | Basis of Terms              | Expiring values due to timing                                          | Broker wanted quote quickly before final values                             | Timing pressure                         | Medium-High |
| Broker Process    | Lead Terms Status           | Broker said lead terms were now in and wanted to discuss layer options | Broker likely already had lead market terms                                 | Broker / lead market influence          | High        |
| Broker Process    | Layer Options Discussion    | Broker wanted to discuss layer options with Convex                     | Placement structure was still being explored                                | Layer / structure negotiation           | High        |
| Relationship      | Meeting / Discussion        | Broker and Convex arranged an in-person discussion / call              | Active negotiation                                                          | Not NTU reason by itself                | Medium      |
| Convex Quote      | Quote Option 1              | 5% line on AUD 65M xs AUD 10M @ AUD 2.75M net                          | Convex quoted one layer option                                              | Price / capacity / layer structure      | High        |
| Convex Quote      | Quote Option 2              | 5% of AUD 70M xs AUD 5M @ AUD 3.45M net                                | Convex quoted alternative layer option                                      | Price / capacity / layer structure      | High        |
| Convex Line Size  | Line Offered                | 5%                                                                     | Small participation                                                         | Limited capacity relevance              | High        |
| Layer Structure   | Layer 1                     | AUD 65M xs AUD 10M                                                     | Excess layer above AUD 10M attachment                                       | Structure option                        | High        |
| Layer Structure   | Layer 2                     | AUD 70M xs AUD 5M                                                      | Lower attachment alternative                                                | Structure option                        | High        |
| Pricing           | Premium Option 1            | AUD 2.75M net                                                          | Price of first option                                                       | Price competitiveness                   | High        |
| Pricing           | Premium Option 2            | AUD 3.45M net                                                          | Price of second option                                                      | Price competitiveness                   | High        |
| Quote Condition   | Line to Stand               | Yes                                                                    | Convex wants its offered line to remain as quoted                           | Quote certainty / signing condition     | Medium      |
| Quote Condition   | NCG                         | Yes                                                                    | Normal quote condition                                                      | Not main NTU reason                     | Medium      |
| Quote Condition   | SNDILR                      | Yes                                                                    | Subject to no deterioration in loss record                                  | Standard subjectivity                   | Medium      |
| Quote Validity    | Open Period                 | Open 14 days                                                           | Quote not indefinite                                                        | Timing / quote validity                 | Medium      |
| Deductible / Term | XS OPDs                     | Mentioned                                                              | Operational deductible / excess condition                                   | Terms condition                         | Medium      |
| Terms             | Other Terms                 | All else as expiry                                                     | Indicates no major terms change from Convex side                            | Not primary NTU reason                  | Medium      |
| Final Outcome     | Bound Confirmation          | Not visible in provided chain                                          | No evidence quote was accepted                                              | Supports known NTU status, not reason   | Medium      |
| Derived Reason    | Primary NTU Reason          | Layer / structure uncertainty or broker-led placement                  | Broker had lead terms and was discussing layer options before Convex quoted | Main NTU candidate                      | Medium      |
| Derived Reason    | Secondary NTU Reason 1      | Limited Convex capacity                                                | Convex only offered 5% line                                                 | Capacity / relevance issue              | Medium-High |
| Derived Reason    | Secondary NTU Reason 2      | Timing / incomplete data                                               | Terms requested on expiring values while final SOV awaited                  | Timing / data uncertainty               | Medium      |
| Derived Reason    | Secondary NTU Reason 3      | Price competitiveness                                                  | Premiums of AUD 2.75M and AUD 3.45M net; no direct broker pushback visible  | Possible but not clearly proven         | Low-Medium  |

---

# Compact Excel-ready version

| Factor                               | Extracted Evidence                                                            | NTU Impact                                                                      | Reason Category                 | Confidence  |
| ------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------- | ----------- |
| Lead terms already in market         | Broker said “we’ve got lead terms in now” and wanted to discuss layer options | Placement may have been led by another market before Convex quote was finalized | Broker / lead market preference | High        |
| Layer options still under discussion | Broker wanted to discuss layer options with Convex                            | Final placement structure may not have matched Convex’s offered layers          | Layer / structure uncertainty   | High        |
| Convex quote option 1                | 5% line on AUD 65M xs AUD 10M @ AUD 2.75M net                                 | Convex offered a small line on one excess structure                             | Limited line / capacity         | High        |
| Convex quote option 2                | 5% of AUD 70M xs AUD 5M @ AUD 3.45M net                                       | Alternative structure had higher premium and different attachment               | Layer / price option            | High        |
| Small Convex participation           | Both quote options were only 5% lines                                         | Broker may have placed capacity elsewhere or needed larger/clearer capacity     | Capacity / line size            | Medium-High |
| Submission timing issue              | Broker asked for terms on expiring values while awaiting final SOV            | Quote may have been produced before final values were available                 | Timing / incomplete data        | Medium      |
| Quote validity                       | Quote open 14 days                                                            | Quote had limited validity                                                      | Timing / no bind yet            | Medium      |
| Terms as expiry                      | All else as expiry                                                            | No clear coverage disagreement visible                                          | Not NTU reason                  | Medium      |
| No explicit price pushback           | No visible email saying premium too high                                      | Price may be a factor, but not clearly evidenced                                | Price competitiveness           | Low-Medium  |
| No explicit rejection                | No visible email saying declined / not taken up                               | Reason must be inferred from placement signals                                  | Outcome uncertainty             | Medium      |

---

# Final NTU JSON output

```json
{
  "ntu_reason": "Broker / lead market preference and layer structure uncertainty",
  "ntu_reason_confidence": "Medium",
  "ntu_reason_explanation": "The strongest visible signal is that the broker already had lead terms in the market and wanted to discuss layer options with Convex before Convex provided its quote. Convex then offered two alternative structures: a 5% line on AUD 65M xs AUD 10M at AUD 2.75M net, or 5% of AUD 70M xs AUD 5M at AUD 3.45M net. Because the placement was already being shaped around lead terms and layer options, Convex's offered structure may not have aligned with the final placement requirement. The small 5% line also suggests limited capacity relevance. There is not enough visible evidence to state price as the primary NTU reason, although pricing could be a secondary factor.",
  "secondary_factors": [
    "Limited Convex line size: only 5% offered on both layer options",
    "Layer structure negotiation: broker wanted to discuss options after receiving lead terms",
    "Timing / data uncertainty: broker requested terms on expiring values while awaiting final SOV",
    "Quote validity: quote was open for only 14 days",
    "Price may have contributed, but no direct broker pushback on premium is visible"
  ],
  "do_not_use_as_primary_reason": [
    "Poor loss history",
    "Material risk deterioration",
    "Coverage mismatch",
    "Deductible issue",
    "Price competitiveness as a primary reason unless further evidence shows premium pushback"
  ]
}
```

# Final quoted reason for Excel

> **Broker / lead market preference and layer structure uncertainty — the broker already had lead terms and was still discussing layer options, while Convex offered only a 5% line on two alternative structures. This suggests Convex’s quote may not have aligned with the final placement structure or may have been less relevant once the lead placement had developed.**
