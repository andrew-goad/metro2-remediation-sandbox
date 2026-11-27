# Business requirements

A customer was already late when the bank made an error. Two months later the error ended, but the customer was still falling behind. What should the bank correct today, and what would justify closing the review? This project gives the bank responsibility for the uncertainty its error introduced. It preserves accurate earlier history, proposes corrections for affected months, and returns to the original evidence to decide whether the impact has ended.

**Account 24064 is the starting point.** November’s late mark stays. The December–January bank issue and three later delinquent months produce five proposed changes. The May 1 snapshot still gives the reviewer zero original current months toward cure. Account 175 shows what closes review. Account 327 shows how a charge-off reversal changes the decision. Account 17899 explains what the field-level correction looks like on a dated record. [Opening case](docs/index.html#consumer-decision) · [Validation results](VALIDATION.md) · [Code changes and reasons](CHANGELOG.md) · [Technical audit](CODE_AUDIT.md)

## Establish what was observable

<a id="br-01"></a>

**BR-01 · Keep the source evidence.** The portfolio generator must support standalone testing and produce a synthetic account ID, original dated performance and a dated reporting snapshot. The engine must retain the received account fields and each original monthly code beside its proposed value. A reviewer must be able to reconstruct a decision without reading corrected history as observed customer behavior.

*Acceptance.* Account 24064 has 13 original monthly observations. The May 1, 2024 proposal retains November’s `1` and shows the original `2,3,4,5,6` beside the five proposed `D` entries. [Generator, snapshot_rows](src/module_01_metro2_synthetic_portfolio_generator.sql#L1018) · [Engine, monthly evidence table](src/module_02_metro2_remediation_engine.sql#L1049) · [Account 24064](docs/scale/index.html#account=24064)

<a id="br-02"></a>

**BR-02 · Use the reporting clock.** In this simulation the Date of Account Information is the first of the month following the latest original history month. Account Status (17A) describes the account as of that date. The first position in the Payment History Profile (Field 18) describes the previous month. Require one summary per account and one observation per consecutive month, with matching endpoints and newest-first history. Accept original codes `0`–`6`, `D`, `G/H/J/K/L` and `B` only at the oldest end. A source `D` is an unknown month.

*Acceptance.* On April 1 only February and March can count toward a post-January cure. Supplying April’s history in that snapshot, an interior `B`, or an unsupported `X` must reject the run and preserve the prior decision tables. [Engine, source clock and monthly validation](src/module_02_metro2_remediation_engine.sql#L430) · [Invalid-input and cutoff tests](tests/audit_counterexamples.py)

<a id="br-03"></a>

**BR-03 · Fix the bank-issue dates.** Each account has an inclusive first and last month of bank impact. Module 2 generates them for a fresh synthetic study. Reassessing the same incident must preserve both months while allowing new original performance to change the credit-impact end, cure and treatment. Identifying the real root cause and affected population belongs to the bank.

*Acceptance.* Follow-up fixture 1201 retains January 2024 as both issue dates across successive snapshots. The input, window and final tables must contain the same incident dates for each member of the fixed cohort. A changed December start in one copy of 17899’s January incident must reject the refresh before it suppresses December’s accurate late mark. A source account can advance or submit a correction at the same reporting cutoff. An older cutoff for even one account must leave the prior results in place. Preserve the cure threshold already saved for this incident. If the continuing study previously required four months, selecting the stock three-month SQL must fail before any of the four result tables change. An unchanged cutoff or an advancing cutoff with the same four-month policy can proceed. Reconstruct a different cutoff or policy in a separate study. [Engine, reuse of original bank dates](src/module_02_metro2_remediation_engine.sql#L471) · [Fixed-incident replay](tests/rolling_review_controls.py) · [Conflict and stale-cutoff tests](tests/followup_controls.py)

## Decide what to correct

<a id="br-04"></a>

**BR-04 · Target the affected months.** The modeled credit-impact window starts in the first bank-issue month. When harm continues, evaluate later months until the first qualifying cure or the latest available evidence. Inside the window, substitute `D` (no history reported for that month) for eligible adverse codes on a retained tradeline. Preserve current, unavailable and out-of-window history. Keep history as supplied when there are no adverse entries in the window.

*Acceptance.* For 24064, the bank issue ends January 2024. February, March and April still show delinquency, so cleanup continues through April. November’s accurate pre-issue delinquency survives. [Engine, preliminary_eval](src/module_02_metro2_remediation_engine.sql#L871) · [Original and proposed entries](docs/index.html#consumer-decision)

<a id="br-05"></a>

**BR-05 · Date cure from original performance.** Use the first uninterrupted run of original current months (`0`) strictly after the bank issue ends. The default threshold is three. Cure starts with the first month in that run, becomes confirmed in the month that completes it, and becomes knowable on the following reporting snapshot. Credit impact ends the month before cure starts. Pending cases show the latest observed impact month, any current streak and its progress.

*Acceptance.* On account 175, April 2025 still requires correction. May starts the cure, July confirms it, and the August 1 snapshot is the first that can establish it. A late, unknown or suppressed month supplies no observed current month. The controls also exercise thresholds of two and four. [Engine, original months used for cure](src/module_02_metro2_remediation_engine.sql#L758) · [Account 175](docs/index.html#cure)

<a id="br-06"></a>

**BR-06 · Reassess the latest severe event.** If the latest in-window collection, foreclosure, surrender, repossession or charge-off (`G/H/J/K/L`) is unresolved at the cutoff, propose whole-tradeline deletion (`DA`) with zero monthly substitutions. A later original `0`–`6` is the synthetic reversal proxy. Consider evidence only through the reporting cutoff or cure confirmation when established. Once reversed, retain the tradeline and correct eligible months. A new severe event during continuing impact reopens the deletion decision. Servicing owns confirmation of an actual reversal.

*Acceptance.* On 327, March’s charge-off and April’s `5` support nine monthly corrections. September provides one current observation and October is the next month to review. In rolling fixture 1201 a second severe event in May produces a new deletion proposal, and June’s `4` returns the case to cleanup. [Engine, in-window severe events and treatment](src/module_02_metro2_remediation_engine.sql#L936) · [Account 327 and deletion comparator](docs/index.html#dashboard-case) · [Recurrence test](tests/rolling_review_controls.py)

## Reconcile account fields

<a id="br-07"></a>

**BR-07 · Connect each changed field to its evidence.** Correcting old history can leave today’s account status, rating and delinquency date intact. On an eligible open account, suppressing its latest adverse mark can support the bank’s favorable current-status election when the supplied as-of status agrees and the other fields support that basis. Closed status 13 requires evidence about its rating at closure. Paid derogatory statuses 61–65 require evidence that the corresponding severe basis was removed and no surviving or later basis contradicts the change. A proposed open/current election with a supplied closure date, or a proposed closed-account election with original adverse performance in or after the closure month, requires servicing to reconcile the timing. Preserve the supplied account fields while applying supported monthly corrections.

*Acceptance.* In fixture 130090 the earlier incident cured. Its unrelated August charge-off cannot turn a supplied September status `11` into `97`. In the separate closed-account controls, an unaffected status 13 retains its adverse internal rating `2`, and six cases with supported May dates retain them. [Engine, field_basis and field_decision](src/module_02_metro2_remediation_engine.sql#L1142) · [Closed-account and later-event tests](tests/audit_counterexamples.py)

<a id="br-08"></a>

**BR-08 · Make date intent explicit and interpret the rating correctly.** Preserve a supported date of first delinquency (DOFD). When a justified election removes its basis, flag the proposed clear explicitly. Under `EVIDENCE_SCOPED_FIELDS_V2`, a populated source date can support this election when its month contains original numeric delinquency and each original month through the affected basis is adverse. The source date can precede the bank issue. A known current month separates episodes. An unknown or unrepresented month leaves the connection unverified. Keep the date, status and rating in either case and refer them to servicing. Preserve the independently supported PHP corrections. A missing date supplies no new onset. Interpret an exported internal modeled payment rating using the status and applicable standard before preparing any furnishing instruction.

*Acceptance.* The February 1, 2025 snapshot for 17899 shows source status `71` and a January history byte of `1`. The bank proposes status `11` and moves the **internal modeled rating from `1` to `0`**. January becomes `D`, December stays `1`, and the bank explicitly clears the documented December onset. Under the inspected 2020 character layout, standard Field 17B is blank for both statuses. Ordinary Field 25 uses `00000000` when no date applies. Certain bankruptcy or receivership indicators can require a date at status 11.

In the controlled variation, the supplied onset is May 2024. Six observed current months separate it from the December–January delinquency. The proposal corrects January’s history and keeps the supplied May date, as-of status `71` and internal rating `1` pending servicing research. [Engine, date and field actions](src/module_02_metro2_remediation_engine.sql#L1211) · [Account 17899 and sources](docs/index.html#field-25)

## Hand the next decision to its owner

<a id="br-09"></a>

**BR-09 · Give monthly reviewers an actionable row.** For each open, uncured cleanup case, provide the account and cutoff, original and proposed history and fields, bank and credit-impact dates, reason for review, progress toward cure and next original month to request. Use separate reasons for too few months to test cure and sufficient history without cure. Whole-tradeline deletion, clean-window history, established cure and source-closed accounts leave this monthly queue.

*Acceptance.* The 25,000-account handoff contains 3,048 unique accounts. Of these, 2,058 have insufficient post-issue history and 990 have sufficient history without cure. For 24064 the reviewer requests May’s original performance from the June 1 snapshot. [Handoff export, queue and progress](tools/export_manual_review.sql) · [Workbook](tools/Write-ManualReviewWorkbook.ps1) · [Reviewer’s case](docs/manual-review/index.html#account=24064)

<a id="br-10"></a>

**BR-10 · Route unresolved field evidence separately.** The export contract has three distinct decisions.

| Worklist | Who acts and what resolves it | 25,000-account acceptance |
| --- | --- | ---: |
| Monthly cure handoff | Remediation reviews the next original month and revises the incident decision. | 3,048 referrals |
| Account-field evidence review | Servicing obtains a missing historically required rating or reconciles an uncertain as-of status, closure, paid derogatory basis or onset. Retain disputed fields while investigating. | 26 missing required ratings. Three at 65, nine at 94 and fourteen at 95. |
| Field 25 source exceptions | Furnishing and servicing research a missing required date on a retained record using the represented status/rating conditions. | 130 exceptions. All lacked dates at source. |

Three status-65 accounts appear on both field worklists because their status independently requires a date and their rating is missing. The other 23 rating referrals already have source dates. Neither field worklist overlaps the 3,048 monthly referrals in this study. All 2,340 proposed date clears are in the monthly queue. For a controlled status 13 with both rating and date missing, research the rating first. Its date requirement depends on the rating. For imported records, validate each nonblank rating against the applicable source specification before using the worklists. A status-13 input with a nonblank unsupported rating such as `X` or `D` and no onset falls outside the automated missing-rating and required-date checks. Send it to servicing to establish the rating before assessing the date. The independent reviewer found zero nonblank unsupported ratings at the historically required statuses in the 1,000- and 25,000-account reference studies. The workbook gives the monthly reviewer space to record the next decision. [Account-field query](tools/export_account_field_review.sql) · [Field 25 exception query](tools/export_field25_exceptions.sql) · [Export dictionary](tools/RUN_STUDY.md)

## Repeat the decision and verify the result

<a id="br-11"></a>

**BR-11 · Reconcile and retain each run.** The operator must be able to launch a fresh study, retain its receipt and rerun the same incident with the next month’s original evidence. Before a follow-up, archive the prior snapshot and reviewer decisions. The verifier compares the generated source, monthly edits, account fields, dates and queue memberships. Invalid input or a failed transaction must leave the previous result intact. For a continued incident, compare both saved decision cutoffs against each other and the incoming snapshot for that account. Every saved threshold in the window and final results must agree with the threshold selected for the continuing run before the engine can replace a decision. An external archive enables recovery or comparison if every local copy is altered together.

*Acceptance.* The successor reproduces the 25,000 preexisting account outcomes and 873,193 original/proposed monthly records from the matched study. All 48 original audit assertions and 55 additional follow-up assertions pass. The latter cover frozen incident dates, stale snapshots, onset continuity, closure timing, missing ratings, and the work each finding creates. [PowerShell study entry point](tools/Run-Metro2Study.ps1) · [Independent SQL verifier](tools/verify_study.sql) · [Validation report](VALIDATION.md)

<a id="br-12"></a>

**BR-12 · Keep cohort and case identity visible.** Exact-ID lookup, a shared address, reload and browser history must identify the same account in the same dataset. Keep the loaded DBeaver export identifiable separately from the packaged 25,000 study. A historical export with missing clear flags or a superseded policy must show its provenance and uncertainty. Before replacing an explorer file, both CSV import and direct read-only database export must check the recorded field policy, treatment, source-supported field actions, change summary and servicing reason. When comparing two cure thresholds, verify each complete saved viewer against its export-time digest, declared account and month counts, recorded threshold and configured SQL identity. The studies must use the same original records and bank-issue dates. A changed decision, relabeled threshold or equally truncated pair must fail before replacing the last valid comparison. Older unbound viewers remain available for account inspection.

*Acceptance.* A retained export with 187 accounts opens its own account 187. The packaged link opens the 25,000-account example. After searching the handoff from 24064 to 17899, the copied address reopens 17899. Refuse an invented onset on 327, a fabricated deletion on clean account 1, or removal of 17899’s supported clear before installing the replacement. [Export guide](tools/README.md) · [Handoff address, writeAddress and openLocation](docs/manual-review/queue.js) · [Developer retest](docs/retest.html)

<a id="br-13"></a>

**BR-13 · Separate a model decision from a completed consumer correction.** The remediation owner selects the incident policy and cure threshold. Servicing establishes actual payments, account adjustments, closure, reversal and delinquency dates. Furnishing confirms the applicable current specifications and status-dependent fields, identifies each affected recipient, records delivery and reconciles acknowledgments, exceptions and downstream reflection. A regular furnisher that determines it supplied incomplete or inaccurate information must promptly notify the receiving agency and provide the correction. Regulation V requires reasonable written policies and procedures for the accuracy and integrity of furnished information. The bank owns that process and its evidence.

*Acceptance boundary.* Account 987’s unresolved charge-off produces `DA` in the 1,000-account replay. Account 327’s later numeric history supports reassessing a previously unresolved charge-off. A real deletion or subsequent furnishing requires its own recipient-level record. The sandbox builds account decisions and internal worklists. Its detailed standard examples use the publicly reviewable 2020 guide. CDIA lists a 2026 edition for authorized users. [Operational steps in the exhibit](docs/index.html#bank-remediation) · [Current CDIA access](https://www.cdiaonline.org/resources/furnishers-of-data-overview/metro2-information/) · [CDIA publications](https://www.cdiaonline.org/publications/) · [FCRA §623](https://www.govinfo.gov/content/pkg/USCODE-2024-title15/html/USCODE-2024-title15-chap41-subchapIII-sec1681s-2.htm) · [Regulation V, accuracy and integrity](https://www.consumerfinance.gov/rules-policy/regulations/1022/41/) · [Required written policies, §1022.42](https://www.consumerfinance.gov/rules-policy/regulations/1022/42/)

## Measured study outcome

The 25,000-account run kept 20,506 histories as reported, proposed monthly cleanup on 4,028 accounts and proposed deletion on 466. Those three counts partition the population. The 4,028 account corrections cover 11,071 monthly entries. The three worklists above identify who still has a decision to make. The scaled spring dashboard and the 1,000-account replay are separate populations.

[Validation and measured limits](VALIDATION.md) · [Code changelog](CHANGELOG.md) · [Issue-by-issue audit](CODE_AUDIT.md)
