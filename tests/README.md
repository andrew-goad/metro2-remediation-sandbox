# Run the native PostgreSQL regression suite

From the repository root, run the following command in PowerShell. Use a PostgreSQL 15+ test server, Python 3.8+ and a PostgreSQL login with permission to create databases. The runner creates uniquely named disposable databases from `template0` for the generator, remediation and Field 25 controls, manual-review handoff, and rolling incident replay. It removes each test database on exit.

```powershell
py -3 .\tests\run_regression.py --host localhost --port 5432 --user postgres --prompt-password
```

The optional password prompt reads the password once for this run. Omit `--prompt-password` if your PostgreSQL client already authenticates with its normal connection settings. The runner locates `psql` on PATH or in a standard Windows installation. Supply `--psql "C:\Program Files\PostgreSQL\17\bin\psql.exe"` for an explicit path. On Linux or macOS use `python3 tests/run_regression.py` with the same connection options. The process returns exit code zero when all checks pass. Save rolling results with `--rolling-evidence .\rolling-snapshots.json`. Save the independent audit fixture readback with `--audit-evidence .\counterexamples.json`.

## Follow account 17899

The [account case controls](owner_case_controls.py) reproduce the **February 1, 2025 date of account information (DOAI)** in the 25,000-account study. Field 17A describes the account on that reporting date. Payment history (Field 18) runs one month behind. The first byte in that snapshot is January’s original `1` and the second is December’s `1`. May through November 2024 were current. Both bank-impact dates use January 1, the key for the January issue month.

At the **January 1 DOAI**, the generator’s latest-field calculation using only original history through December reconstructs 71, synthetic rating 1 and an internal December 1 delinquency date. At the **February 1 DOAI**, the retained source also carries 71, synthetic rating 1 and the December 1 date. The test compares those February 1 fields with the model proposal. February’s own PHP byte first appears at the March 1 DOAI.

| Evidence cutoff | What the test checks |
| --- | --- |
| February 1 DOAI, retained source through January | December’s second byte remains 1. January’s first byte becomes D inside the bank window. The model proposes February 1 status 11 and synthetic rating 0. Its explicit Field 25 clear flag removes the internal date. Zero post-bank PHP months are available. The handoff requests February performance when the March 1 report arrives. |
| March 1, April 1 and May 1 DOAIs, hypothetical current performance for February–April | One and two original current months leave the case open. At the May 1 report, the third consecutive original zero for April confirms a February cure start. January becomes the final affected month and monthly review closes. |
| Alternative February–April, hypothetical adverse months | February 2 extends cleanup beyond January. A March L leads to a DA proposal with zero monthly changes at that cutoff. April 5 supplies a modeled reversal, returning the case to full cleanup and review. |
| Alternative original D | For an open or unknown incoming status, an original D preserves the incoming status, rating and delinquency date when an older adverse month is corrected. Tests exercise the existing closed-account and deletion rules separately. |
| Separate deterioration after confirmed cure | Hypothetical May 2, June D and July 3 stay outside January’s closed impact window. The supplied May onset and independently furnished status and rating carry forward. June’s original D supplies no evidence to move the date to July. |

The receipt records the January 1 reconstruction, the retained February 1 snapshot, and 13 hypothetical continuations or boundary controls separately. The tests check the current reporting date, first PHP month, next expected PHP month, and the difference between retaining a source value and explicitly clearing it. The suite tests internal SQL decisions.

## Regression coverage

| Test | Evidence checked |
| --- | --- |
| Severe-event policy and calendar | The 27 fixed histories in [policy_cases.sql](policy_cases.sql) cover 130 original reporting months. Each account has explicit expected bank dates, cure start, treatment, review disposition and proposed monthly values. Cases place a charge-off before, during and after the evaluated window; interrupt a current streak; distinguish two from three current months; and exercise each other major derogatory code. |
| Independent reconstruction | The [study verifier](../tools/verify_study.sql) rederives outcomes from dated original performance and compares all published account and month records, written replacements and clear instructions. The runner falsifies eight audit dimensions, including the stored policy identifier and dates for the severe event and its reversal proxy. |
| Module 2 integrity | Nine malformed source variations exercise missing and duplicate months, off-month dates, null original status, reversed PHP, missing monthly and summary rows, duplicate summaries, and an original month beyond the reporting cutoff. A mid-rebuild failure exercises rollback. Fingerprints cover all four retained output tables. A same-named table in the public schema serves as a reset control. |
| Fixed incident across reports | [Rolling controls](rolling_review_controls.py) run the unmodified Module 2, study verifier and review export at 17 successive cutoffs across two versions of one synthetic history. Eleven malformed prior-incident cases must fail without changing the saved outputs. |
| Adjustable cure threshold | Two and four required months change which observed streaks qualify. A zero-month threshold must fail validation. |
| Field instructions | A corrected latest adverse month with a matching current status can elect synthetic 11/0 and explicitly clear an internal date. A documented later episode, an unrelated current-field basis and a source D retain the supplied fields. |
| Module 2 field readouts | The runner captures QA 13, 14 and 15 directly from a normal execution of Module 2. It checks the rows, order and values for supported status replacements (including DA), changed PHP, date clears and preservation of unrelated dates. Unchanged source fields and a whole-tradeline deletion carrying a source date exercise the exclusions. These three SQL readouts show the first 100 eligible accounts in account order. |
| Manual-review CSV | The native export must return the exact ordered set of eligible fixture IDs once each, with both referral reasons represented. The tests compare the original and proposed histories, original and effective 17A/17B/25, bank and credit-impact dates, evidence cutoff, trailing current months, required cure months, next evidence month and explicit field clears. Separate runs exercise a two-month streak, a streak spanning the bank issue’s end, a four-month threshold, an account closing, deletion exclusions and a header-only empty queue. A rolled-back historical schema test checks that stored replacements remain visible, that ambiguous changes stay unknown, and that reviewers see an instruction to reassess the saved decision. The current handoff must name the original severe and reversal months when applicable. Earlier tables with clear flags but no policy marker must identify their results as archived. |
| Field 25 source exceptions | [Status, rating and field-action fixtures](field25_controls.py) exercise the represented status/rating clauses in the 2020 Field 25 guidance, including historical status 05. The native export must preserve exact eligibility, distinct reasons, dated context and the existing cure flag. Tests include deleted tradelines, differences between a missing source and a proposed clear, source/replacement dates, and an empty export. Bankruptcy and receivership indicators are unavailable in the study. |
| Module 1 generator | A 500-account run checks dated monthly snapshots, history lengths, endpoints and index uniqueness. Controlled failures exercise validation and rollback, then a repeat run checks all four output tables for identical rows. |

The fixture dates are reporting months. Synthetic IDs were chosen so the engine's own incident generator produces the intended windows. Dates and outcomes in the fixture table are fixed expectations. Changed source histories, parameter settings and induced failures exist only inside the test databases or an in-memory copy of SQL.

## Read a rolling case

The principal fixture uses account 1201 in the test database. Both bank dates are January 1, 2024, a one-month incident. Every new source snapshot adds one original reporting month. The test sets `metro2.reuse_incident_dates` to `on` for the later evaluations. It checks the actual saved incident on every pass. As a control, fresh incident generation for this same ten-month history yields February through August 2024.

| Latest original month | New evidence | Expected decision on that evidence |
| --- | --- | --- |
| January | L | The unreversed charge-off yields a whole-tradeline DA proposal. The monthly cure handoff is empty. |
| February | 5 | The numeric code supplies a modeled reversal. Full cleanup covers January and February. Review opens for the next original month. |
| March and April | 1, then 2 | The original delinquencies extend cleanup. Neither provides a current month toward cure. |
| May | J | The new severe event supersedes February’s reversal. DA returns, with zero monthly substitutions and no cure referral at this cutoff. |
| June | 4 | The first numeric after May supports reversal of that event. Cleanup and monthly review resume. |
| July and August | 0, then 0 | Two original current months are visible. Each snapshot remains under review. |
| September | Third consecutive 0 | The July–September run confirms cure. The modeled credit window ends in June and the cure referral closes. |
| October | H | The later severe event is outside the closed credit window. The October byte remains H and the July–September cure stands. |

A second history contains January L followed by original D in February and March. The decision remains DA through March. April’s original 0 provides the first modeled reversal and begins the run that eventually confirms cure in June. A July charge-off remains outside this incident. Both histories are analytical reruns of the original evidence. A numeric return is a proxy that calls for verification against servicing records. DA is a proposed instruction at its reporting cutoff.

These expectations exercise `REVERSAL_AWARE_SEVERE_V2`. The archived `CHARGEOFF_REQUIRES_CURE_V1` study kept an uncured in-window charge-off at DA even after an original numeric return. The current verifier checks the policy identifier, and the historical handoff tests preserve saved decisions and their provenance.


## Independently challenged inputs

The [audit controls](audit_counterexamples.py) send the reviewer’s source cases through the ordinary Module 2, study verifier and Field 25 export. They include a separate [six-account source fixture](closed_field_cases.sql) with paid-derogatory statuses 61–65 and status 13 carrying an adverse rating. The test repeats those same inputs with their dates absent. The missing-date screen then needs to identify all six, including the case qualifying through its status and rating.

For account 130090, an earlier bank correction changes only January–February history, while September’s current 11/0 and its missing date stay intact. For 17899, the supplied later May date survives the intervening D. The suite deliberately falsifies current-field outputs and the field-policy marker, then requires independent verifier failure. It also checks that a July 1 report containing July PHP is rejected even when the input, window table and final table all copy that same invalid reporting date.

The source alphabet admits numeric 0–6, D and the modeled severe codes G/H/J/K/L. B is permitted as the oldest padding prefix, including an entirely padded history. Unsupported X or ?, or B following any known history, now fail the rebuild. Each rejection is checked against the previous contents of all four Module 2 tables. Current regression fixtures use D for a genuinely missing observation after known history. Earlier examples using B there, automatically clearing retained fields, or assigning a July date from post-gap delinquency have been withdrawn.

The source-date exception export and bank-cure queue have separate eligibility rules. A missing date can require investigation after bank cure was already confirmed. A retained 13 with an adverse rating remains eligible for the missing-date screen. The independent field-research export is checked separately for conflicting as-of status, uncertain paid-major or closure-rating bases, and unknown onset continuity; these records retain their original fields and cure disposition. An explicit nonnull replacement supplied in an external stored-delta fixture can still be read by a handoff. Module 2 itself has no authoritative servicing input from which to create a replacement onset date.

To test the CSV-export path independently of PostgreSQL, run `python tests/verify_export_controls.py --full-export <full-1000-account-data.js>` with a complete 1,000-account build_explorer export.

To compare releases, run `python tests/audit_counterexamples.py --study-root <release-root> --host localhost --port <test-port> --user <test-login> --output <receipt.json>` once for each release, using separate PostgreSQL test instances. Use the same successor test script for both commands. The script creates its own randomly named databases and removes them on exit. It writes the observed failures before returning a nonzero exit code for an older release. The successor must return zero.

## Reproduce the continued-incident and account-field re-audit

The [follow-up controls](followup_controls.py) exercise the saved decision on a later reporting date and the evidence behind each proposed field change. The normal regression command runs these checks. Add `--followup-evidence .\followup.json` to retain every expected value, observed value and discrepancy. To compare a particular earlier release, run the **same test script** once against each release’s source using separate PostgreSQL test instances. The selected directory must contain the study’s `src` and `tools` folders.

```powershell
py -3 .\tests\followup_controls.py --study-root . --host localhost --port 5432 --user postgres --prompt-password --output .\followup.json
```

| Control | Required result |
| --- | --- |
| Per-account continuity | A new original month advances the account. Another account in the same batch may retain its cutoff. An unchanged same-date replay yields identical rows. A supported same-date source correction keeps the bank window fixed. A stale April cutoff cannot reopen a cure observed on the May record. |
| Saved incident agreement | A discrepancy in any of the three stored bank-date copies, a missing or duplicate decision, contradictory or absent prior cutoffs, or a shared mid-month incident key blocks continuing-incident processing. The controls compare four complete table fingerprints before and after each rejection. A separate fresh test database can reconstruct an earlier chronology. |
| Open-account field evidence | January still receives its supported PHP correction when six current months separate the supplied May onset from December and January delinquency. A gap of original `D` also leaves the onset unconfirmed. Both preserve the disputed current fields and refer the case for servicing. Continuous original adverse evidence can still support the favorable election, including a documented pre-incident onset. The tests cover retained original `D`, an unrepresented onset, a source date on a current month, severe escalation and later reversal. |
| Closure and missing ratings | A conflicting closure date or adverse performance in the reported closure month prevents a favorable election without corroboration. A demonstrated correction to the relevant preclosure rating remains eligible. A missing or whitespace-only rating at retained status 13 reaches servicing even without bank cleanup. With no such rating, Field 25 is conditional. Status 65 can need both rating research and a required-date referral. |
| Independent detection | Changing field outputs to clear a disconnected date, hiding a required-rating referral, omitting a supported election, or agreeing across all three stored dates on an invalid day must fail independent verification. A valid monthly correction on the same account may still stand. |

The archived release re-audited on November 27, 2026 passed 13 of these 55 checks and failed 42. Its earlier 48-check suite passed. The 55 controls use all three prior incident copies to set up controlled histories, and each alternate chronology starts from the same observed February 1 case. The contradictory inputs are introduced separately in the negative tests. Both native suites use synthetic fixtures and isolated databases.
