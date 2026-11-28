# Metro 2 Remediation Sandbox

A bank error can affect a customer’s credit reporting after the underlying issue ends. This PostgreSQL project follows each synthetic account from the first affected month through a proposed correction, a documented cure, or the next monthly review. The account explorer pairs each proposed decision with the original account fields and dated payment history.

[Open the teaching exhibit](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html) · [Run your own simulation](https://andrew-goad.github.io/metro2-remediation-sandbox/run.html) · [Explore 25,000 accounts](https://andrew-goad.github.io/metro2-remediation-sandbox/scale/index.html) · [Open the monthly review queue](https://andrew-goad.github.io/metro2-remediation-sandbox/manual-review/index.html)

## Start with account 24064

The customer was already 30–59 days late in November 2023. The bank issue began in December, ended in January, and the account continued to fall further behind. The history cannot tell us whether the customer would have caught up without the bank’s error. The bank bears that uncertainty in this exercise. It preserves the pre-issue delinquency and corrects the affected months while waiting for evidence of recovery.

| History month | Original reporting | Sandbox decision |
| --- | --- | --- |
| November 2023, before the issue | `1` | Keep November’s accurate delinquency. |
| December 2023 and January 2024, during the issue | `2`, `3` | Change each to `D`, meaning no payment history reported for that month. |
| February through April 2024, after the issue | `4`, `5`, `6` | Extend the credit-impact window and change all three to `D`. The original months show continuing delinquency. |
| May 1, 2024 reporting snapshot | April is the latest history month. None of the three post-issue months is current. | Cure start and confirmation are unknown. Keep the account open for review. May’s original history will appear in the June 1 snapshot. |

On May 1 the bank elects current status `11` and proposes clearing the active date of first delinquency. Its internal modeled payment rating changes from `6` to `0`. Standard Field 17B is blank at both status `84` and `11` under the historical guide. The reviewer can inspect all five proposed changes alongside the original observations. [Inspect account 24064 in the 25,000-account study](https://andrew-goad.github.io/metro2-remediation-sandbox/scale/index.html#account=24064)

## Follow the evidence to the next decision

- **Account 175 shows an observed cure.** Its bank issue ran from April 2024 through March 2025. February, March and April 2025 showed `1`, `2`, `1`. The bank corrects all three. Original May, June and July each showed `0`. May starts the cure and July confirms it. The correction window ends in April and monthly review closes. [Account 175 in the 1,000-account replay](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#account=175)
- **Account 327 separates reversal from cure.** The issue ran from December 2024 through January 2025. A March charge-off occurred during continuing credit impact. April’s original `5` is the model’s proxy for reversal and still denotes delinquency. On the October 1 snapshot, the bank retains the tradeline, corrects nine months and has just one current observation toward cure. October is the next history month to request. [Account 327 in the 1,000-account replay](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#account=327)
- **Account 17899 explains the date of first delinquency (Field 25).** December 2024’s original `1` stays. The January 1 reconstruction shows status `71` and a December 1 delinquency date. The bank issue covers January alone. On February 1 the retained source still shows `71`. The bank changes January’s `1` to `D`, elects current status `11` and clears the active date. The internal rating moves from `1` to `0`. The historical standard leaves Field 17B blank at both statuses. February’s history first appears March 1. Cure has yet to be established. [Account 17899 in the 25,000-account study](https://andrew-goad.github.io/metro2-remediation-sandbox/scale/index.html#account=17899) · [Standard Field 25 format](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#field-25)

Account status (17A) describes the condition on the Date of Account Information. The first Payment History Profile (PHP) byte describes the previous reporting month. Only original current months count toward cure. An original `D` means that month’s payment history is unavailable. It supplies no evidence that an earlier delinquency ended. An unrelated later status or delinquency onset can remain accurate when an older month needs correction.

Read the [business requirements](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/BUSINESS_REQUIREMENTS.md) for the rules behind these cases and the [validation report](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/VALIDATION.md) for the observed results.

## Run your own simulation

Use the same tool to test a pre-production credit-reporting strategy. In two runs of the same 1,000 accounts, moving the cure threshold from three to four original current months changed confirmed cures from 555 to 494 and open monthly reviews from 133 to 147. Account 57 shows which month the reviewer needs next. Account 975 explains why one more tradeline receives a deletion proposal. Three current months establish a cure before the later charge-off. A four-month requirement keeps the charge-off inside the credit-impact window. [Compare the two decisions](https://andrew-goad.github.io/metro2-remediation-sandbox/run.html#case-975)

1. Download and extract the PowerShell study kit. Open PowerShell in the folder containing `src`, `tools` and `explorer-template`. Use a local PostgreSQL server and a login that can create a study database.
2. Run `./tools/Run-Metro2Study.ps1 -AccountCount 1000 -CureMonths 3`. Change the threshold to `4` for a second run. Each run creates a fresh database and writes a new result folder.
3. Use the guide’s commands to open your own account explorer and compare the dated evidence in the two runs. Keep the run receipts, configured SQL, reviewer handoff and comparison together.

[Configure your PowerShell commands](https://andrew-goad.github.io/metro2-remediation-sandbox/run.html) · [Download the self-contained kit](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_PowerShell_Study.zip) · [Inspect the measured comparison](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Threshold_Comparison_1000.json)

## Two SQL modules

| Module | What you can inspect or reuse |
| --- | --- |
| [Synthetic portfolio generator](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/src/module_01_metro2_synthetic_portfolio_generator.sql) | Account blueprints, one original observation per account-month, 24-position history snapshots and account-level outputs. The generator can be run independently to test reporting logic with synthetic data. |
| [Remediation engine](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/src/module_02_metro2_remediation_engine.sql) | Incident dates, credit-impact windows, cure evidence, treatment decisions and original versus proposed fields. The engine preserves accurate pre-issue months and can reevaluate the same incident as new history arrives. |

The 25,000-account study contains **873,193 original account-months**. It proposes **11,071 monthly corrections** across 4,028 accounts and **466 whole-tradeline deletions**. It flags **3,048 accounts** for the next cure review. Account 987 shows the deletion route when the latest in-window charge-off has no modeled reversal. [Account 987 in the 1,000-account replay](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#account=987)

Of the 2,340 proposed date clears, 329 preserve an earlier delinquent month that predates the bank issue. A separate source check identifies 130 retained accounts already missing a date called for by the historical field rules, including 129 at paid derogatory statuses 61–65. A separate servicing handoff identifies 26 missing required ratings. Three status-65 accounts are on both field worklists. The cure queue and the date investigation answer different questions. [Field 25 findings](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/CODE_AUDIT.md#manual-review-and-delinquency-date-audit) · [Forensic scorecard on the three meanings of a blank date](https://github.com/andrew-goad/forensic-data-integrity/blob/main/examples/portfolio/metro2/README.md)

## Explore or reproduce the study

- Open `docs/index.html` from an extracted copy for the offline exhibit. The [original dashboard](https://andrew-goad.github.io/metro2-remediation-sandbox/executive_dashboard_preview.png) illustrates a separate 500-account study scaled by 10,000.
- [Run the study on Windows](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/tools/RUN_STUDY.md) or [export retained DBeaver results](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/tools/README.md) from `metro2_lab`, schemas `module1` and `module2`.
- Inspect the [review workbook](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Manual_Review_25000.xlsx), [Field 25 source exceptions](https://andrew-goad.github.io/metro2-remediation-sandbox/downloads/Metro2_Field25_Source_Exceptions_25000.csv), [code audit](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/CODE_AUDIT.md), [changelog](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/CHANGELOG.md) and [regression tests](https://github.com/andrew-goad/metro2-remediation-sandbox/blob/main/tests/README.md).

The independent audit reproduced the four featured cases, both study sizes and the three- versus four-month experiment. It closed the earlier hold and identified two operator errors that could still change a result. The current kit checks the identity and contents of a saved comparison input. It also checks the saved cure threshold before rerunning a bank incident. The 25,000-account reference keeps the original run receipt and the SQL that produced it. [Release corrections and evidence](https://andrew-goad.github.io/metro2-remediation-sandbox/retest.html)

## Reporting guidance

CDIA maintains the Metro 2® format and lists the 2026 Credit Reporting Resource Guide®. Approved users can access the current field rules. The detailed field examples use the publicly reviewable 2020 definitions. CDIA retired status 05 in April 2022. The three-current-month cure threshold, severe-event reversal proxy and choice of favorable as-of status for an affected account are sandbox policy choices. [Current CDIA guide and access](https://www.cdiaonline.org/resources/furnishers-of-data-overview/metro2-information/) · [CDIA publications](https://www.cdiaonline.org/publications/) · [Field 17B, 2020 guide](https://autodealerplus.com/dealerzone/metro2.pdf#page=64) · [CDIA retirement of status 05](https://www.cdiaonline.org/ondemand-retirement-of-account-status-05-transferred/) · [Field 25 teaching notes](https://andrew-goad.github.io/metro2-remediation-sandbox/index.html#field-25)
