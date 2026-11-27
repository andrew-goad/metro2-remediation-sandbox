# Code changelog

## 27 November 2026 · Keep the selected cure policy fixed

The independent auditor rated private package `a1c3b077f0e3…` **Ready after listed changes**. Its ordinary 1,000-account comparison correctly reported 133 open reviews under three months and 147 under four. Two altered-input paths could still give a reader a false policy result. This update addresses the comparison file and the continuing database study. [Developer retest](docs/retest.html) · [Business requirements](BUSINESS_REQUIREMENTS.md#br-11)

| Entry point | Previous result | New acceptance rule |
| --- | --- | --- |
| Saved threshold comparison | Closing account 57 in a copy of the four-month viewer produced 146 reviews. Relabeling three-month rows as four gave 133 versus 133. Removing the same account from both inputs yielded a passing comparison of 999 against a declared 1,000. | Bind the complete viewer to its export-time digest. Before writing a comparison, check both viewers’ integrity, declared population and history size, policy threshold and configured SQL identity, then compare the original evidence. Reject altered inputs and preserve the previous comparison. [Comparator](tools/compare_study_thresholds.py) |
| Continuing incident | On the same October 1 cutoff, selecting stock three-month SQL for the saved four-month study closed account 57 effective July. The external four-month verifier detected the switch only after the tables had changed. | Check the incoming threshold against all saved window and final thresholds before rebuilding. Accept same-threshold reprocessing and newly observed performance. Test an alternative threshold in its own fresh study. [Engine preflight](src/module_02_metro2_remediation_engine.sql#L506) |
| Rating interpretation | The internal `1 → 0` sentence followed the 17899 variation that retains rating `1`. A nonblank invalid source rating at status 13 could also leave historical Field 25 eligibility indeterminate. | Associate `1 → 0` with the supported February 1 election. Keep `1` and the May onset in the disconnected-episode variation. Document the import check for nonblank unsupported ratings. [BR-08](BUSINESS_REQUIREMENTS.md#br-08) · [BR-10](BUSINESS_REQUIREMENTS.md#br-10) |

The two policies can still be run on the same 35,395 original observations in separate studies. Four months adds 14 monthly reviews. Account 975 explains the additional deletion. Under three months, December 2024–February 2025 establishes cure. Under four, March delinquency interrupts the streak, and September’s unresolved charge-off remains inside the modeled impact window. [Threshold comparison](docs/downloads/Metro2_Threshold_Comparison_1000.json) · [Validation report](VALIDATION.md)

## 27 November 2026 · Protect the saved incident and the delinquency episode

The independent re-audit found that even a correctly dated monthly correction could remove a date belonging to an earlier delinquency. It also found that an older cutoff, an altered incident start or an invalid explorer rebuild could replace a good decision. The corrected private release keeps `REVERSAL_AWARE_SEVERE_V2` for severe events and advances account-field decisions from `EVIDENCE_SCOPED_FIELDS_V1` to `EVIDENCE_SCOPED_FIELDS_V2`. The re-audited package is `57390959d867…`. The earlier independent audit reviewed `c946f81efe7a…`. The public Git baseline is `1201adcc0b3a74a0f81e8f456a9e3d901f0aaca7`. [Validation, hashes and limits](VALIDATION.md) · [Code audit](CODE_AUDIT.md)

| Component | Change and reason |
| --- | --- |
| [Module 2](src/module_02_metro2_remediation_engine.sql) · continuing incident | When a reviewer reuses a saved incident, check its dates against the previous decisions and compare each incoming reporting cutoff with its prior cutoff before rebuilding. This protects December’s pre-issue delinquency on 17899 from a changed January start and preserves a May cure decision if an April snapshot arrives late. Same-cutoff corrections and forward progress are supported. |
| [Module 2](src/module_02_metro2_remediation_engine.sql) · account fields | Before clearing a supplied DOFD, require an original numeric delinquency in its onset month and continuous adverse original observations through the corrected basis. An intervening current month separates episodes. An original unknown month leaves continuity unresolved. Retain the supplied fields and refer contradictory closure timing or unsupported onset evidence for servicing research. A documented, continuing pre-incident delinquency can still support the bank’s favorable election. |
| [Servicing research export](tools/export_account_field_review.sql) · historical 17B and Field 25 | Route retained records with a missing applicable historical payment rating to an owner, even without a monthly edit. Include the servicing action and scope of the date check. For status 13 with unknown rating, the conditional Field 25 result remains unresolved. For status 65, the separate required-date screen can still identify an absent date. |
| [Explorer builder](tools/build_explorer.py) · SELECT-only and CSV paths | Validate policy-specific treatment, monthly edits, sparse field actions, change summaries and referrals against the exported original history. Reject a contradictory proposal before replacing the reader’s last valid file. Preserve retained historical studies with their policy identity. |
| [Independent SQL verifier](tools/verify_study.sql) · [regression suite](tests/README.md) | Check original onset-to-basis continuity with an independent reconstruction, reject invalid incident month keys even when downstream copies agree, and require appropriate missing-rating research. The new controls cover direct mutations, rejected stale input, same-cutoff replay and genuine monthly advance. |
| [Study guide](docs/run.html) · configurable cure threshold | Supply an end-to-end path from generating a portfolio to comparing a second cure threshold on the same original observations and incident dates. On 1,000 accounts, changing three required current months to four moved observed cures from 555 to 494 and monthly reviews from 133 to 147. |

**Measured effect.** On the 25,000-account study, all 873,193 monthly decisions, every effective account field and all 2,340 date clears matched the re-audited release. All 329 pre-incident clear candidates had documented onset and continuous adverse evidence. The current field-research worklist adds 26 missing-rating referrals at statuses 65 (3), 94 (9) and 95 (14). The three at status 65 also appear in the 130 confirmed status/rating-based missing-date exceptions. Neither source worklist overlaps the 3,048 monthly cure reviews. [Three worklists and reconciliation](VALIDATION.md#population-reconciliation) · [Results and receipts](docs/downloads/Metro2_25000_Results.zip)

**Retest.** On the new 55 paired assertions the re-audited release failed 42 and the corrected release failed zero. Both passed the first audit’s 48 controls. The separate SQL verifier passed 22 independently specified accounts and rejected 13 deliberate mutations. Developer retest is complete for these controls. Independent re-review and the owner’s publication decision remain open. [Acceptance results](VALIDATION.md#audit-findings) · [Reviewer handoff](AUDIT_PROMPT.md)


## 27 November 2026 · Business requirements and validation

The companion documents trace the owner’s remediation policy from source history to the next monthly decision. Thirteen numbered requirements link each rule to its implementation and worked evidence. The validation report records what was exercised and the limits of the tests. This documentation change adds no account treatment or field action. [Business requirements](BUSINESS_REQUIREMENTS.md) · [Validation report](VALIDATION.md)

## 27 November 2026 · Successor to the candidate placed on hold

The independent auditor reproduced the featured cases and the 1,000- and 25,000-account studies, then found three high-severity and four medium-severity issues on other inputs and reader routes. The hold applies to the reviewed archive (`c946f81e…edebca8`). This historical entry records the first successor, subsequently re-audited as archive `57390959d867…`. The entry above records its replacement. [What changed after audit](docs/retest.html) · [Technical findings](CODE_AUDIT.md)

| Finding | Change and reason |
| --- | --- |
| H1 / H2 · Account fields after a historical correction | Scope a proposed field change to the reporting condition it corrects. Preserve a later independently supplied status, a surviving adverse rating and its supported delinquency onset. Closure or an unknown month cannot establish that a separate delinquency ended. Preserve the bank’s favorable election where suppression actually removes its basis. The successor supplies no new onset from payment history alone. |
| H3 / M1 · Reporting date and source history | Check the monthly cutoff and allowed history before deriving cure or replacing a previous run. April’s original history first becomes observable on May 1. An unsupported mark or invalid placement cannot silently clear a supplied field. |
| M2 / M3 · Links to accounts and retained data | Distinguish the locally loaded study from the packaged 25,000 example. A handoff address should survive a search, copy, reload and back navigation and still identify the account on screen. |
| M4 · Internal modeled payment rating | Identify the internal rating where a reader sees it. At 84 → 11 or 71 → 11, the 2020 standard leaves Field 17B blank on both sides. Three retained status-65 accounts in the study illustrate a required rating absent from the model. |

That first successor’s 25,000-account run produced 3,048 monthly cure referrals, 130 source-date exceptions and zero referrals in its separate `account_field_review.csv`. Two focused verifier cases exercised that last route with conflicting as-of and onset evidence. The three worklists answer different questions. [Study and receipt](docs/downloads/Metro2_25000_Results.zip)

The old 17899 follow-up expected the July date after May delinquency, June unknown history and July delinquency. The fixture rewarded moving an onset without evidence that the May episode had ended. The previous 130090 readout similarly treated a recalculated June date after an earlier cure as a valid replacement. Their previous pass results document the defect. Against 48 paired audit controls the held input failed 34 expectations and the successor passed all 48. The full 25,000-account comparison found zero differences in preexisting field outcomes and 873,193 matching original/proposed month records. [Reporting-field findings](CODE_AUDIT.md) · [Field 17B, 2020 guide](https://autodealerplus.com/dealerzone/metro2.pdf#page=64)

## 27 November 2026 · Teaching cases in decision order

The revised walkthrough opens with account 24064. Its November 2023 delinquency stays, the December–January bank issue starts the credit-impact window, and three further delinquent months extend the correction through April 2024. There are five proposed monthly changes and no confirmed cure at the May 1 cutoff. Account 175 then shows how three observed current months establish and confirm cure. Account 327 shows why a severe-event reversal can lead to continued cleanup and review. Account 17899 closes the sequence with the exact reporting dates, fields and no-date instruction. All four cases use recorded study output. [24064](docs/scale/index.html#account=24064) · [175](docs/index.html#account=175) · [327](docs/index.html#account=327) · [17899](docs/scale/index.html#account=17899)

## 27 November 2026 · Account 17899, the origin of D and the Field 25 sample

- **Documented the bank’s election.** December 2024’s history byte `1` remains accurately late. The January 1 reconstruction uses status `71`, internal modeled payment rating `1` and a December 1 DOFD. After its January error, the bank cannot establish whether the customer would have caught up and chooses to bear that uncertainty. The February 1 source snapshot has current-cycle status `71` and a previous-month January PHP of `1`. January’s byte changes to `D`. The bank elects 17A `11` as of February 1 and explicitly proposes removing the active date. Its internal modeled payment rating becomes `0`. Standard character Field 17B is blank for both `71` and `11` under the 2020 guide. The December 1 DOFD remains in the source evidence. There are zero original post-issue months. February is the next original observation for cure review, available in the March 1 snapshot. [Account 17899](docs/scale/index.html#account=17899)
- **Preserved unknown source history.** Module 2 distinguishes an adverse byte changed to `D` by the bank’s correction from an original `D` that stays `D`. While correcting an older month on an open or unclassified account, the latest unchanged `D` preserves supplied 17A, 17B and DOFD. Closed-account rules and a whole-tradeline deletion have their own precedence. The independent verifier and controlled fixtures exercise the distinction. A fresh 25,000-account comparison found identical rows in all four Module 2 outputs. [Module 2](src/module_02_metro2_remediation_engine.sql) · [Independent SQL check](tools/verify_study.sql)
- **Corrected the analyst’s QA sample.** Module 2 QA 15 previously selected only non-null replacement dates and displayed zero of 2,340 explicit date clears in the 25,000-account study. The updated query shows the clear flag and returns the first 100 qualifying accounts. Account 17899 is 134th and appears in the complete export. QA 13 likewise includes clears in its account-status sample. Both queries read recorded decisions. [Code audit](CODE_AUDIT.md)
- **Clarified standard reporting guidance.** The teaching page and handoff distinguish the SQL’s proposed effective date from the character-format Field 25 value. Historical Field 25 guidance specifies zero fill where no date applies, with exceptions based on account condition and consumer indicators. The current CDIA guide governs the standard. [Field 25 guide](docs/index.html#field-25) · [Current CDIA access](https://www.cdiaonline.org/resources/furnishers-of-data-overview/metro2-information/)

## 27 November 2026 · Reversed charge-offs return to cleanup and review

**Policy correction.** The previous private candidate incorrectly required confirmed cure to retain a tradeline after any charge-off in the credit-impact window. That condition overrode the model’s evidence for a reversal. The current candidate evaluates the most recent severe event in the affected period and uses the original current-month streak to decide when ongoing impact ends.

| Observed evidence at this reporting cutoff | Current treatment | Follow-up |
| --- | --- | --- |
| Latest in-window severe event (`G`, `H`, `J`, `K` or `L`) still unresolved | Propose deletion of the tradeline using `DA` in 17A | Retain evidence. Track any actual submission separately. |
| A later original `0`–`6` is the sandbox proxy for reversal of that event | Retain the tradeline and clean affected delinquency and derogatory months | While open and uncured, obtain the next original performance month. |
| Later delinquency during continuing impact | Correct the affected month | Continue review. |
| Another severe event during continuing impact | Reassess the most recent event for reversal | Deletion is back in consideration if that event remains unresolved. |
| Consecutive original current months establish cure | Close the credit window immediately before the first qualifying month | End monthly review for this incident. |

**Account 327.** The bank issue ended in January 2025. March’s `L` brought deletion into consideration at that cutoff. April’s original `5` models a reversal to delinquent performance. Using September’s history in the October 1 snapshot, the rule proposes nine monthly suppressions, retains earlier delinquency and sends the case to October review with one of three qualifying current months. Each cutoff produces a proposal from the evidence then available. [Open the case](docs/manual-review/index.html#account=327)

### Same accounts across three policy versions

The spring public implementation recognized modeled reversals. The intervening private candidate added the charge-off cure override. The corrected candidate removes that override, dates the reversal evidence and preserves independent controls for source calendars, field deltas and the reviewer handoff.

| 25,000-account measure | Spring public SQL | Superseded private candidate | Corrected candidate |
| --- | ---: | ---: | ---: |
| Retained accounts with severe-history cleanup | 124 | 61 | 124 |
| Proposed whole-tradeline deletions | 466 | 529 | 466 |
| Proposed monthly substitutions | 11,071 | 10,431 | 11,071 |
| Open cure reviews | 3,048 | 2,985 | 3,048 |

All 63 accounts that changed treatment from the preceding private candidate return to cleanup and monthly review. Their affected histories account for 640 proposed monthly corrections. The matched comparison holds the original monthly evidence and the bank-issue dates fixed. [Comparison and execution receipts](docs/downloads/Metro2_25000_Results.zip)

### Code and handoff changes

- **Module 2.** Identify the most recent severe event within the inclusive credit-impact window. Record its month and the first subsequent original numeric month used as the reversal proxy, using only evidence available through the reporting cutoff or cure confirmation. Apply this decision consistently to the account treatment, monthly changes and review queue. Source comments explain the date boundaries.
- **Monthly follow-up.** An opt-in rerun of Module 2 keeps the existing account-level bank-issue dates while evaluating an updated original history. Invalid or mismatched incident inputs stop the rerun. First-time studies still generate synthetic incident dates.
- **Exports and workbook.** Record the policy identity. Preserve the decisions from retained historical studies with their provenance. The account explorer, manual-review page, Excel and CSV are generated for the corrected study. The workbook gives reviewers actions for subsequent delinquency, a new severe event, reversal and cure.
- **Tests.** Evaluate the same account at successive evidence cutoffs, including a second severe event and cure. Validate the rebuilt browser exports, handoff and retained-source checks against PostgreSQL. [Regression suite](tests/README.md)
- **Prior controls retained.** The previous package added explicit clear flags for sparse status, rating and delinquency-date fields, transactions and reset protections, source validation, a Field 25 research export and reproducible study outputs. These address data quality and auditability independently of the withdrawn policy.

[Code audit](CODE_AUDIT.md) · [SQL changes against the public revision](docs/downloads/Metro2_SQL_Changes.patch) · [Public source baseline](https://github.com/andrew-goad/metro2-remediation-sandbox/tree/1201adcc0b3a74a0f81e8f456a9e3d901f0aaca7)
