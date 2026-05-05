Below is the **Excel-ready pipe-delimited structure** for this KKR / Convex use case.

You can paste this into Excel and then use **Data → Text to Columns → Delimited → Other → `|`**.

```text
Field Category | Field Name | Extracted Value | Evidence / Notes | NTU Relevance | Confidence
Account | Named Insured | KKR & Co. Inc. | Shown as Named Insured in submission summary | Identifies the insured/account | High
Account | Mailing Address | 30 Hudson Yards Suite 7500, New York, NY 10001 | Visible in submission summary | Account/location identification | High
Account | Operations | Real Estate | Submission summary states Operations: Real Estate | Occupancy / risk profile | High
Account | Broker | Marsh | Emails from Marsh contacts and Bcc / broker context | Broker/channel analysis | High
Account | Market / Carrier | Convex | Convex Insurance Mail / property.insurance@convexin.com | Quoting market | High
Submission | Submission Type | Renewal | Subject line states RENEWAL: KKR & Co. Inc. August 22 2025 Submission | Renewal submission | High
Submission | Policy Period | 12 months, August 22, 2025 – August 22, 2026 | Visible in submission summary | Coverage period | High
Submission | Quote Due Date | July 8th | Submission notes state Quote Due Date: July 8th | Timeline / urgency | Medium
Exposure | TIV | USD 17,928,702,731 | Submission summary shows TIV: $17,928,702,731 | Large exposed values; capacity relevance | High
Exposure | 2024 Ingoing TIV | USD 17,818,010,556 | Broker email references 2024 Ingoing TIV | Prior year exposure benchmark | Medium
Coverage | Perils Insured | All Risk including Named Storm, Flood, Earthquake and Equipment Breakdown | Submission summary states perils insured | Catastrophe exposure context | High
Program Limits | Overall Loss Limit | USD 600,000,000 | Main Program Limits show Loss Limit: $600,000,000 | Maximum program capacity | High
Program Limits | Earthquake Limit | USD 275,000,000 | Main Program Limits show Earthquake: $275,000,000 | Cat limit / requested increase | High
Program Limits | Flood Limit | USD 100,000,000 annual aggregate | Main Program Limits show Flood: $100,000,000 annual aggregate | Cat limit | High
Program Limits | Named Storm Limit | USD 600,000,000 | Main Program Limits show Named Storm: $600,000,000 | Named Storm exposure | High
Program Limits | Wind Areas Zone 1 Limit | USD 300,000,000 for locations in Wind Areas Zone 1 | Main Program Limits / CAT table show $300M for Wind Areas Zone 1 | Cat sublimit increase; capacity pressure | High
Program Limits | California Earthquake Sublimit | USD 200,000,000 annual aggregate in California, except listed Appendix A locations | Renewal table shows increase from USD 125M to USD 200M | Increased cat sublimit | High
Program Limits | Pacific Northwest / New Madrid EQ Sublimit | USD 200,000,000 annual aggregate in Pacific Northwest Zone & New Madrid Zone, except Appendix A locations | Renewal table shows increase from USD 125M to USD 200M | Increased cat sublimit | High
Program Limits | High Hazard Flood Sublimit | USD 30,000,000 in respect to locations within High Flood Hazard Area as defined in Appendix B | Renewal table shows increase from USD 20M to USD 30M | Increased flood sublimit | High
Deductibles | AOP Deductible | USD 100,000 per occurrence | Main Program Deductibles show AOP: $100,000 per occurrence | Deductible structure | High
Deductibles | Certain Water Deductible | USD 250,000 per occurrence | Main Program Deductibles show Certain Water: $250,000 per occurrence | Deductible structure | High
Deductibles | Named Storm Zone 1 Deductible | 5% per Unit of Insurance, minimum USD 250,000 per occurrence | Deductible section mentions locations in defined Zone 1 | Cat deductible burden | High
Deductibles | Earthquake High Hazard Deductible | 5% per Unit of Insurance, minimum USD 250,000 per occurrence | Deductible section states High Hazard except PNW / New Madrid | Cat deductible burden | High
Deductibles | Earthquake Pacific Northwest / New Madrid Deductible | 3% per Unit of Insurance, minimum USD 250,000 per occurrence | Deductible section states Pacific Northwest / New Madrid | Cat deductible burden | High
Deductibles | Flood High Hazard Deductible | USD 500,000 per building, USD 500,000 contents, USD 100,000 time element per occurrence | Deductible section under Flood | Flood risk quality / pricing relevance | High
Deductibles | Convective Storm Texas and Colorado Deductible | 2% per Unit of Insurance, minimum USD 250,000 per occurrence | Deductible section states Convective Storm Texas and Colorado | Severe convective storm exposure | High
Layering | Requested / Discussed Layering Options | Primary 100M; Primary 125M; 75M x 125M; Primary 150M; 50M x 150M; Primary 200M; 100M x 200M; 100M x 300M; 200M x 400M | Submission email lists possible layering options | Structure / attachment flexibility | High
Layering | Earlier Layering List | Primary 50M; 50 x 50; 50 x 100; 50 x 150; 100 x 200; 100 x 300; 100 x 400; 100 x 500 | Broker email lists target pricing / layering discussion | Layering alternatives | Medium
Pricing | Expiring Layer | USD 200M xs USD 50M | Broker email says expiring layer is $200M xs $50M | Prior structure benchmark | High
Pricing | Expiring Premium | USD 7,928,412 less 7.5% | Broker email states expiring layer premium | Pricing benchmark | High
Pricing | Expiring Share | 5% share | Broker email states 5% share | Capacity/share participation | High
Pricing | Broker Requested Target | Possibly USD 300M if possible / Q/S USD 300M target | Broker asks whether P$300M possible; Convex says Q/S $300M target puts them out of running | Key reason for non-competitive outcome | High
Convex Quote | Quote Option 1 | USD 200M xs USD 50M @ USD 7.75M less 7.5%; Line 5% to stand | Convex email: “Can quote; 200m xs 50m @ 7.75m (less 7.5%). Line 5% to stand.” | Quote offered, but not target $300M | High
Convex Quote | Quote Option 2 / Alternative | USD 250M xs USD 50M @ USD 8.25M less 7.5%; Line 4% stand | Convex email lists alternative quote | Alternative lower participation / structure | High
Convex Quote | Quote Option 3 | USD 200M xs USD 100M @ USD 4.125M less 7.5%; Line 5% to stand | Convex later email offers alternative to quotes below | Alternative higher attachment option | High
Convex Quote | Quote Conditions | Quote subject to slip and wording tag; sub-limit CAT increases as requested; NCG/Open 14 days | Convex quote email lists conditions | Conditional quote / underwriting terms | High
Convex Position | Comment on Target | Target for Q/S USD 300M puts Convex well out of the running and would require well north of USD 25M for a line | Convex email explicitly states this | Strong NTU / non-competitive reason | High
Convex Position | Premium Concern | Greater than USD 25M premium would be more than the USD 600M loss limit can pay | Broker email says premium needed is more than the $600M L/L can pay | Price not commercially viable | High
Commission | Commission | 7.5% Bowring UK / Marsh SF Net | Submission summary shows commission | Net pricing calculation | Medium
Loss Info | 10 Year Loss Summary | See loss run for detail | Submission summary references loss run | Loss experience considered but not visible in images | Medium
Attachments | Submission Documents | Statement of Values; Loss Run; Policy Form redlined for changes | Submission email lists attached documents | Source docs for underwriting | High
Updates | CAT Sublimit Updates | Earth Movement limit updated $275M; CA and WA Earth Movement $200M; Flood $30M; Named Wind Tier 1 $300M; Appendix A/B updated; Rate Matrix to be updated at binding | Submission notes list changes | Increased CAT exposure / structure changes | High
```

### NTU / Decline Analysis JSON

```json
{
  "ntu_status": "Partial NTU / Not competitive for requested target structure",
  "ntu_reason": "Convex did not appear willing to support the broker's requested USD 300M target structure at a commercially viable price. Convex indicated that the Q/S USD 300M target would put them well out of the running and would require well north of USD 25M for a line. Instead, Convex offered alternative lower or different attachment structures.",
  "ntu_confidence": "High",
  "ntu_reason_category": [
    "Price / premium competitiveness",
    "Capacity / line size limitation",
    "Layer structure mismatch",
    "Large CAT-exposed real estate schedule",
    "Increased catastrophe sublimits"
  ],
  "ntu_reason_explanation": "The account has a very large TIV of approximately USD 17.93B and includes catastrophe exposures such as earthquake, flood, named storm and convective storm. The renewal also requested increased CAT sublimits, including earthquake movement to USD 275M, California / Pacific Northwest / New Madrid earthquake sublimits to USD 200M, High Hazard Flood to USD 30M, and Wind Areas Zone 1 to USD 300M. Convex’s response shows they could quote certain alternatives, such as USD 200M xs USD 50M, USD 250M xs USD 50M, and USD 200M xs USD 100M, but the requested USD 300M target was considered not commercially viable because the required premium would be well north of USD 25M.",
  "primary_driver": "The requested USD 300M participation / structure was too expensive and outside Convex's competitive appetite.",
  "supporting_evidence": [
    "Convex stated that the target for Q/S USD 300M puts them well out of the running.",
    "Convex stated it would require well north of USD 25M for a line.",
    "Broker noted that the greater-than-USD 25M premium would be more than the USD 600M loss limit can pay.",
    "Convex offered alternatives rather than the requested USD 300M target structure.",
    "The submission involved large TIV and increased CAT sublimits."
  ],
  "recommended_excel_ntu_label": "Price / capacity / layer structure not competitive",
  "final_decision_interpretation": "Not a clean full decline, because Convex did quote alternative options. However, it is a strong NTU / non-competitive signal for the broker's desired USD 300M target structure."
}
```

In short: **Convex was not fully declining the account**, but they were effectively **not competitive / not willing for the requested USD 300M target structure**. They shifted to alternative structures with lower or different capacity.
