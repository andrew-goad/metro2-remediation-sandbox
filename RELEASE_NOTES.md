# Metro 2 Remediation Sandbox

**Credit-reporting strategy simulation and reproducible PostgreSQL study**

A two-month bank issue led to five proposed monthly corrections on account 24064. The customer was late before the error and continued falling behind after it ended. This PostgreSQL study shows how a bank can protect the consumer, preserve accurate history, and decide what requires another month of review.

[Run your own simulation](https://andrew-goad.github.io/metro2-remediation-sandbox/run.html) · [Read the opening case](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#consumer-decision) · [Inspect all 13 months](https://andrew-goad.github.io/metro2-remediation-sandbox/scale/index.html#account=24064) · [Open the reviewer’s handoff](https://andrew-goad.github.io/metro2-remediation-sandbox/manual-review/index.html#account=24064)

## Three decisions to follow

| Decision | What the evidence shows |
| --- | --- |
| **Correct now and keep reviewing.** Account 24064 | Preserve November 2023’s accurate late mark. Correct December through April, including three late months after the issue ended. On the May 1 record, the bank elects current status and clears the active delinquency date. The next review needs May history from the June 1 snapshot. |
| **Close the review after an observed cure.** Account 175 | The bank issue ended in March 2025. April still needed correction. Three original current months from May through July confirm cure effective in May. July’s history becomes visible in the August 1 snapshot. [Follow the cure](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#cure) |
| **Retain a tradeline after a modeled charge-off reversal.** Account 327 | A March charge-off was followed by a return to ordinary delinquency in April. With the reversal, nine affected entries receive cleanup. September supplies just one current month, so monthly review continues. [Compare the severe-event cases](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#dashboard-case) |

For the field-level example, look at account 17899. One issue month makes the distinction between as-of status, prior payment history, and a proposed delinquency-date clear easy to see. [Field 25 guide](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#field-25)

## Study results

| 25,000 synthetic accounts | Result |
| --- | ---: |
| Keep history as reported | 20,506 |
| Correct affected monthly history | 4,028 |
| Propose whole-tradeline deletion | 466 |
| Monthly substitutions across retained accounts | 11,071 |
| Accounts continuing in monthly review | 3,048 |
| Proposed DOFD clears within that review queue | 2,340 |

The first three outcomes partition the population. Monthly substitutions count individual history entries. Of the 4,028 accounts receiving monthly corrections, 3,048 stay in review. Of those, 2,340 have a proposed delinquency-date clear.

[Business requirements](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/BUSINESS_REQUIREMENTS.md) · [Validation results and test evidence](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/VALIDATION.md) · [Changelog](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/CHANGELOG.md)

## Test a strategy before production

Choose the account count and cure threshold in the simulation guide. Copy its PowerShell commands, generate original records in a new PostgreSQL database and open a local explorer containing your accounts. The matched 1,000-account example holds every original month and incident date fixed. Requiring four current months instead of three increases monthly reviews from 133 to 147 and monthly substitutions from 461 to 496. On account 975 the longer window reaches a later unresolved charge-off. Proposed deletions rise from 22 to 23. [Run your own simulation](https://andrew-goad.github.io/metro2-remediation-sandbox/run.html) · [Matched comparison](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Threshold_Comparison_1000.json)

## Release assets

| Asset | What you can do |
| --- | --- |
| [Review workbook](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Manual_Review_25000.xlsx) · [Review CSV](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Manual_Review_25000.csv) | Inspect 3,048 open referrals, their evidence dates, field decisions and next original month. |
| [PowerShell study kit](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_PowerShell_Study.zip) | Generate a fresh population and run independent checks in PostgreSQL. |
| [25,000-account results](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_25000_Results.zip) | Reconcile counts, source versions and native run evidence. |
| [DBeaver export kit](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_DBeaver_Export.zip) | Build an account explorer from an existing synthetic database. |
| [Field 25 source exceptions](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Field25_Source_Exceptions_25000.csv) | Investigate 130 retained accounts whose source data already lacked a date called for by their observed status or rating. |
| [Account-field research CSV](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Account_Field_Review_25000.csv) | Assign 26 missing required payment ratings to servicing. Three status-65 accounts also need a missing required date. Controlled cases demonstrate how to investigate an uncertain onset or closure. |
| [Code change log](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/CHANGELOG.md) · [SQL changes](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_SQL_Changes.patch) | Compare the candidate with the public source and trace the reason for each correction. |

## What changed after independent audit

The independent auditor closed the prior hold and reproduced the 25,000-account reference. Two additional findings concerned what happens after a correct run. An edited full viewer could yield a passing policy comparison, and choosing the stock three-month SQL could overwrite a four-month decision on the same incident.

The updated tools verify the complete export and its run identity before replacing a saved comparison. The engine also checks the saved threshold before changing any incident tables. The 25,000-account reference data and their native run receipt are preserved. The 1,000-account comparison uses fresh exports. [Audit findings and developer retest](https://andrew-goad.github.io/metro2-remediation-sandbox/retest.html) · [Validation documentation](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/VALIDATION.md)

## Reporting scope

The sandbox produces proposed decisions. Its ordinary Field 25 example uses the standard 426-character format. CDIA lists the 2026 CRRG; the detailed field examples were checked against the publicly reviewable 2020 edition and identified corroborating sources. [Field guide and sources](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#reporting-clock) · [CDIA publications](https://www.cdiaonline.org/publications/)
