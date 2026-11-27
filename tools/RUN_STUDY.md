# Run the 25,000-account study on Windows

Use this launcher to generate a fresh population, run the remediation engine, and verify the results. It creates a new PostgreSQL study database. To examine the results already in `metro2_lab`, use the separate [read-only export](README.md).

## Run both modules

Extract the review ZIP. Open PowerShell in the folder containing `src` and `tools`. With your local PostgreSQL server running, enter this command.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./tools/Run-Metro2Study.ps1 -AccountCount 25000
```

The command uses Windows PowerShell 5.1, the PostgreSQL client and the default connection to `localhost:5432` as `postgres`. The login needs permission to create a database. The execution-policy option applies to this PowerShell process. The launcher finds `psql.exe` on PATH or under a standard PostgreSQL installation. If your settings differ, append the applicable options, such as `-Port 5433`, `-User your_login` or `-Psql "C:\Program Files\PostgreSQL\17\bin\psql.exe"`. Enter your PostgreSQL password if prompted. A matching PostgreSQL password-file entry can handle repeated connections. [PostgreSQL password file on Windows](https://www.postgresql.org/docs/17/libpq-pgpass.html)

The console prints the new database name and output directory, then announces each module. The bundled Module 1 validates the inputs before rebuilding its own tables in one transaction. It keeps the published 70% / 15% / 8% / 4% / 3% starting mix across current, mild, moderate, severe and derogatory profiles. The bundled Module 2 applies the owner's reversal-aware severe-event policy, `REVERSAL_AWARE_SEVERE_V2`. Locate the latest original G, H, J, K or L inside the credit-impact window. An original 0–6 after that event is the model’s proxy for a reversal, through cure confirmation or the last represented month if cure is unconfirmed. With that proxy, the study retains the tradeline and corrects adverse months in scope. Without it, the study selects tradeline deletion (`DA`). Servicing records establish whether a reversal actually occurred. The default cure test requires three consecutive original current months after bank impact ends. Set `-CureMonths` to test another positive integer threshold. Module 2 checks that every original month is present and agrees with the account summary before rebuilding its own tables. For the two cleanup treatments, read `clear_account_status_17a`, `clear_payment_rating_17b` and `clear_date_of_first_delinquency` before applying the sparse field values. A true flag clears the field. For a false flag, use a populated replacement or retain the original. The launcher also runs the independent SQL verifier in the snapshot that produced the three worklists. Read its result in `policy_audit.json`. The manifest records the field policy, verifier and report checksums, the treatment policy identifier, the published baseline revision and the exact bundled SQL checksum. To choose an explicit database name, append `-Database` and a fresh lowercase name. To put the result files on another drive, append `-OutputDirectory` and a new directory path. PostgreSQL stores database tables on the server independently of this file location.

## Open a private 187-account study

From the extracted study kit, run the following in PowerShell against a fresh database name. The launcher creates it and records both the SQL template and the configured four-month engine. The next steps copy the empty viewer and generate its data from that database. On Linux or macOS with PowerShell, replace `py -3` with `python3`. The output folder must be new.

```powershell
./tools/Run-Metro2Study.ps1 -AccountCount 187 -CureMonths 4 -Database metro_private_187 -OutputDirectory ./private-187
$study = Get-Content -Raw ./private-187/run.json | ConvertFrom-Json
Copy-Item -LiteralPath ./explorer-template -Destination ./private-187/explorer -Recurse
py -3 ./tools/build_explorer.py --database $study.database --host $study.server --port $study.port --user postgres --run-receipt ./private-187/run.json --output ./private-187/explorer/data.js
if ($LASTEXITCODE -eq 0) { Invoke-Item ./private-187/explorer/index.html }
```

Choose your PostgreSQL user if it differs from `postgres`. Confirm that the viewer shows 187 accounts and that a selected account requires four consecutive original current months. The packaged rehearsal’s exact receipt, workbook and source-row totals are under `cohorts/187-cure4/` in the results ZIP. Your new run will have its own database name, capture time and export digest.

## Compare two cure thresholds on the same synthetic population

From the extracted kit in PowerShell, choose fresh database and output names. The examples use the Windows Python launcher `py -3`. With PowerShell on Linux or macOS, use `python3` instead. Use the same account count for both runs. Module 1 uses deterministic original histories and Module 2 generates the same initial incident dates for matching inputs. The example varies only the number of consecutive original current months required after impact.

```powershell
./tools/Run-Metro2Study.ps1 -AccountCount 1000 -CureMonths 3 -Database metro_trial_c3 -OutputDirectory ./trial-c3
if ($LASTEXITCODE -eq 0) {
    ./tools/Run-Metro2Study.ps1 -AccountCount 1000 -CureMonths 4 -Database metro_trial_c4 -OutputDirectory ./trial-c4
}
```

Read `run.json`, `policy_audit.json`, `totals.csv` and `outcomes.csv` in both folders. Compare cure dates, credit-impact boundaries, affected monthly history, pending reviews and treatment. A row's source and incident dates must match across scenarios. The downloaded PowerShell study kit includes an empty local viewer. Copy it into the four-month results directory, load the verified result and open the viewer. From the full project checkout, the same viewer is included in the downloadable study kit. A full copy of `docs` is an alternative when you want the complete teaching exhibit.

```powershell
$receipt = Get-Content -Raw ./trial-c4/run.json | ConvertFrom-Json
$viewer = './trial-c4/explorer'
Copy-Item -LiteralPath ./explorer-template -Destination $viewer -Recurse
py -3 ./tools/build_explorer.py --database $receipt.database --port $receipt.port --host $receipt.server --user postgres --run-receipt ./trial-c4/run.json --output "$viewer/data.js"
if ($LASTEXITCODE -eq 0) { Invoke-Item "$viewer/index.html" }
```

The database access uses the same PostgreSQL login as the two runs. If you supplied a user other than `postgres`, replace that username in the export command. Select a case in your copy and check its source identity, threshold, incident dates and proposed reporting history.

Export the three-month study as well. The comparison checks equal source-account values, original dated monthly observations, account IDs and incident dates and then reports changed outcomes and a worked account. Choose a different output file if you want to preserve a previous comparison.

```powershell
$first = Get-Content -Raw ./trial-c3/run.json | ConvertFrom-Json
py -3 ./tools/build_explorer.py --database $first.database --port $first.port --host $first.server --user postgres --run-receipt ./trial-c3/run.json --output ./trial-c3/full.js
if ($LASTEXITCODE -eq 0) {
    py -3 ./tools/compare_study_thresholds.py ./trial-c3/full.js "$viewer/data.js" --output ./trial-c4/threshold_comparison.json
}
```

The comparator requires two **complete, individually verified full exports**. Each must be produced by the current builder with the corresponding native `run.json` receipt, the current field and treatment policies, the same Module 1 inputs and incident dates, and a different uniform cure threshold. Keep `compare_study_thresholds.py` and `build_explorer.py` together. The comparator rechecks saved decisions from the dated evidence, recomputes the digest that covers the ordered accounts and metadata, and checks the template and configured SQL hashes. The default template is the kit’s Module 2 SQL. Supply `--engine-template path/to/original_module.sql` to verify two compatible exports made with a different archived template. A digest helps detect changed content; an independently retained receipt or trusted copy establishes provenance.

An earlier viewer can still be read. To compare studies whose saved files lack the new integrity record, generate fresh full exports using the matching verified native receipts. A rejected comparison preserves the previous output file. Study three- versus four-month policies in **separate fresh databases**. Monthly reassessment of a single incident uses its original threshold and the matching configured Module 2 file.

The results ZIP separates the independently audited 25,000-account snapshot from the newly executed studies. The 25,000-account totals, CSVs and workbook retain the source hash and dates in the root `run.json` and `audited_25000/`. See `RETAINED_25000.md`. The current paired 1,000-account receipts are in `cohorts/1000/` and `cohorts/1000-cure4/`. The comparison and the date-by-date evidence for account 975 are under `checks/runtime/`.

Save both output folders with the code hashes, threshold and result comparison. This synthetic pre-production study measures the operational effects of a rule change. A production strategy also requires representative servicing data, approved rules and validation against bank outcomes.

## Read the results

A successful run prints **Verified 25000 accounts** followed by the account-month count. Results go in `study_results\<run ID>\` beneath the starting folder by default.

| File | What to inspect |
| --- | --- |
| `totals.csv` | Account counts from the generator through the final table, monthly row counts, changed months, review count, observed cures and counts of explicit field clears. |
| `outcomes.csv` | Account counts grouped by synthetic profile, treatment, review flag and reason, and whether the engine observed cure. |
| `manual_review_handoff.xlsx` | Filterable worksheet of flagged accounts, with review context and space for reviewer decisions. |
| `manual_review_handoff.csv` | The same source cases and 24 data fields for reconciliation or import. |
| `account_field_review.csv` | Servicing referrals for unresolved account-field evidence or a missing required payment rating. Read the assigned next step and Field 25 assessment alongside each reason. |
| `policy_audit.json` | The independent SQL decision checks in the same release snapshot. |
| `field25_source_exceptions.csv` | Retained tradelines where the source review query identifies a missing date of first delinquency. Check the source records for supporting evidence. |
| `run.json` | Verification result, database and software versions, settings, export columns and row counts, run times, and SHA-256 checksums for the workbook, the three CSV worklists, the independent verifier and its output. |
| `module_01_configured.sql` and `module_02_configured.sql` | The executed generator and engine SQL. The receipt records both template and configured hashes for each. |
| `module1.log` and `module2.log` | Query outputs from the two modules, including their review queries. |

For a results review, return `run.json`, `totals.csv` and `outcomes.csv`. For account-level investigation, connect DBeaver to the generated database named in `run.json`; its tables remain available after the launcher exits. The [export instructions](README.md) also work against that database name. If a run stops early, the launcher reports the error and leaves any created study database and output files available for inspection.

## Work the monthly review list

Open `manual_review_handoff.xlsx` and work in a copy so the original can be reconciled to `run.json`. The queue contains one row for every account with `manual_review_flag = 1`, ordered by the next expected history month and account. The launcher reconciles those exact account IDs against the same database snapshot as the study totals. It also reopens the workbook and checks the source fields against the CSV. A run with no flagged accounts still supplies the column headers.

| Review question | Fields and interpretation |
| --- | --- |
| Why is this account here? | `account`, `review_reason` and `review_action` identify the case and next step. `INSUFFICIENT_POST_IMPACT_HISTORY` means fewer post-issue months have arrived than the cure threshold. `NO_CURE_OPEN_ACCOUNT` means enough months have arrived, with no qualifying run. |
| Which dates govern the decision? | Keep `bank_impact_start` and `bank_impact_end` fixed for the incident across monthly reviews. `credit_impact_start` and `credit_impact_through` delimit the inclusive credit window assessed so far. `reporting_as_of` is the latest synthetic date of account information. `latest_history_month` dates the newest payment-history byte. |
| What does the original record show? | `original_status_17a`, `original_payment_rating_17b` and `original_dofd` give the original account status, internal modeled payment rating and date of first delinquency. A missing source date stays blank. `original_php_newest_first` starts with the newest month at the left. Move one character to the right for each earlier month. Keep PHP and code fields as text when importing the CSV. |
| How close is cure? | `post_impact_months` counts represented months strictly after the bank issue ended. `current_streak_months` counts the uninterrupted original `0` marks ending at the latest history month. `current_streak_start` is blank at zero. `cure_months_required` is the study threshold. A partial streak has no confirmed cure date. |
| What happens next? | At `next_history_month`, obtain that month’s original performance and preserve the incident dates. A new in-window severe event supersedes the prior event for the reversal test. Without later evidence, the study selects deletion. A later original 0–6 permits targeted cleanup. Confirming the qualifying current streak closes the cure review. Cure starts at the first qualifying current month, confirmation occurs in the Nth, and the correction window closes the month before cure start. |
| What has the engine proposed? | `proposed_treatment` names the sandbox action. Compare `proposed_php_newest_first` with the original string for proposed edits. Compare `proposed_effective_status_17a`, `proposed_effective_rating_17b` and `proposed_effective_dofd` with their original fields. These are the resulting values after applying the revised engine’s replacements, explicit clears and retained originals. `internal_fields_to_clear` names each internal clear. For example, an original date followed by a blank proposed date and `DOFD` in the clear list records a proposed date removal. Reviewers determine any furnishing action and encoding through their approved process. |

The two CSV fields with `rating_17b` in their names carry **internal modeled payment ratings**. In Excel the column beside each one shows standard 17B applicability for its own account status. The 2020 CRRG requires 17B for 05, 13, 65, 88, 89, 94 and 95, with a blank for other account statuses. Obtain a required rating from source evidence. Missing status leaves applicability unknown. Both 71 → 11 (17899) and 84 → 11 (24064) use a blank standard 17B on each side. Status 05 was later retired. [Historical CRRG, p. 4-10](https://autodealerplus.com/dealerzone/metro2.pdf#page=64)

**Start with 24064 in the 25,000-account worklist.** Filter `Account ID` to `24064`. The bank issue ran from December 2023 through January 2024. November’s original `1` remains. The proposal changes December through April to five `D`s because the original delinquency continued after January. April’s original `6` is the first history byte on the May 1, 2024 snapshot. The three post-issue original months supply zero current months. Obtain May performance as the first history byte on the June 1 snapshot, keep the incident dates fixed and reassess.

In the 1,000-account explorer, **175** shows the opposite outcome. The issue ended in March 2025, April still needed correction, and the original May–July current run established cure starting in May. **327** shows how reversal differs from cure. A March 2025 charge-off was followed by an April numeric delinquency; check the reversal in servicing records. September supplied only the first current month, so review continued.

The internal `DOFD` flag proposes removing the stored date. Apply the current CDIA CRRG when furnishing. For a standard 426-character Metro 2 record, Field 25 is `00000000` when no date applies under its reporting hierarchy. The publicly available 2020 guide documents this rule on page 4-16. CDIA controls access to the current guide. [CDIA Metro 2 access](https://www.cdiaonline.org/resources/furnishers-of-data-overview/metro2-information/) · [2020 CRRG, Field 25](https://autodealerplus.com/dealerzone/metro2.pdf#page=70)

**Field 25 example · Account 17899 in the 25,000-account worklist.** The bank issue starts and ends in January 2025. Account status (17A) describes the account as of the February 1, 2025 date of account information (DOAI). The payment history runs one month behind. In that snapshot, January is the first byte and changes from `1` to `D`. December is the second byte and its `1` stays. The known historical December status `71` and the source `71` on February 1 refer to different reporting dates. The sandbox chooses `71` → `11` for **February 1**, proposes modeled rating `0` and explicitly clears the original `2024-12-01` DOFD.

January contributes zero cure months. Reassess the original February performance when it first appears in the March 1 snapshot. A February `D` leaves that month unknown and the cure streak at zero. If February, March and April are all original `0`s, the May 1 snapshot confirms the three-month run, with cure start in February. Keep the January incident dates at every review. A new unresolved severe event follows the deletion rule; a later reversal proxy calls for servicing review and targeted cleanup.

To inspect the underlying database values, open `module2.metro2_remediation_final` in DBeaver and filter by the handoff’s `account`. Compare each original 17A, internal modeled payment rating and date of first delinquency with its `remediated_*` value and corresponding `clear_*` flag. For a dated list of individual PHP edits, filter `module2.metro2_remediation_php_detail` to that account and compare `original_status` with `remediated_status` by `byte_date`.

To export the CSV again from a database generated by this revised study, supply its name in place of `your_study_database` and choose a new output path. The standalone query reads the existing snapshot. Against an older retained Module 2 schema, it exports the cases flagged by that historical engine, adds a legacy-review instruction and shows `UNAVAILABLE_IN_SOURCE` for missing clear flags. A superseded study with explicit clear flags keeps those values and calls for checking the archived decision against its receipt. An explicit stored replacement is shown. When the historical data cannot establish whether the engine kept or cleared a field, the proposed value stays blank and the reviewer must reconcile it to source evidence. A monthly reassessment requires adding the next original cycle and reevaluating the same bank issue dates.

```powershell
psql -X -q --csv -v ON_ERROR_STOP=1 -h localhost -p 5432 -U postgres -d your_study_database -o manual_review_handoff.csv -f ./tools/export_manual_review.sql
```

## Reassess the same incident next month

1. Preserve the preceding database results or a database backup, together with the dated handoff and reviewed workbook. Module 2 rebuilds its decision tables on each assessment. A fresh study starts a new generated population.
2. In the same study, load the new original monthly evidence into `module1.metro2_status_history` and refresh the matching `module1.metro2_final` account summary. Keep the account ID, original dated history, bounds, newest-first PHP, date of account information and current source fields consistent. Maintain a contiguous history for every account, including those with no new observation. The prepared Module 1 tables are the input to this follow-up. Re-running the synthetic generator would replace that input.
3. Reassess with the saved incident dates. In PowerShell, run this single psql invocation so the setting and SQL file use the same connection. Replace `your_study_database` with the database holding the earlier decision and refreshed original data. Supply the executed `module_02_configured.sql` from the original output folder, shown here as `trial-c4`, so the selected threshold stays fixed.

```powershell
psql -X -v ON_ERROR_STOP=1 -h localhost -p 5432 -U postgres -d your_study_database -c "SET metro2.reuse_incident_dates = 'on'" -f ./trial-c4/module_02_configured.sql
```

In DBeaver, execute `SET metro2.reuse_incident_dates = 'on'` in the same session as that saved configured Module 2 script and execute `RESET metro2.reuse_incident_dates` afterward. The reuse setting must match the incident and cutoff on the preceding decision. An earlier cutoff, a conflict between saved incident dates, or a threshold that differs from either preceding decision table stops the rerun before replacement. Use a fresh study for a different threshold. Keep dated prior evidence separately. If all stored copies have been changed together, a protected earlier snapshot is needed to substantiate the original dates. The default fresh-study mode generates incident dates.

4. After a successful assessment, create a new dated output folder. Using the same database, capture the new review CSV and workbook. These files reflect the revised cycle. Keep the prior receipt with the earlier snapshot.

```powershell
$cycle = "monthly-review-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $cycle -ErrorAction Stop | Out-Null
psql -X -q --csv -v ON_ERROR_STOP=1 -h localhost -p 5432 -U postgres -d your_study_database -o "$cycle/manual_review_handoff.csv" -f ./tools/export_manual_review.sql
if ($LASTEXITCODE -eq 0) {
    & ./tools/Write-ManualReviewWorkbook.ps1 -CsvPath "$cycle/manual_review_handoff.csv" -OutputPath "$cycle/manual_review_handoff.xlsx"
}
```

For a retained account with a reversal proxy, the handoff names the latest severe month and the qualifying later month. Reconcile the actual servicing decision, then continue original-month review while the case remains open. An unreversed severe event selects deletion and leaves this queue. Its original evidence stays in the account explorer and final table. When observed history confirms cure, record both cure dates and close that case’s monthly review. Each assessment uses evidence supplied for that cycle. Loading, scheduling, reviewer assignments and preserving prior case decisions remain with the reviewer.

## Investigate account fields and missing Field 25 evidence

Open `account_field_review.csv` when the successor retains account fields for servicing research. Look up the account, reporting date, referral reason and original field values. Verify the basis in servicing records before changing a field. Read `servicing_next_step` and `field25_review_scope` beside the stored reason. Obtain a missing historically required payment rating from servicing. At status 13 or historical 05, that missing rating can leave the represented Field 25 basis undetermined. At 65 the status independently requires a date, so both lists can apply. The 24-column monthly cure queue continues to track original post-issue performance separately. The receipt shows the policy and row count, including zero. To reproduce the list on the successor schema, execute `tools/export_account_field_review.sql` in DBeaver.

Open `field25_source_exceptions.csv` for a separate check of retained tradelines. Its rows compare the source and effective 17A, internal modeled payment rating and Field 25 with the specific `exception_reason`, `date_evidence_gap` and a proposed follow-up. Check the original delinquency records and retain the evidence behind the next decision. The report carries the existing bank dates, cure context and cure-review decision for reference. Keep the Field 25 investigation open until the source records support a date. A header-only file means the screen found no matching cases.

To reproduce this source check, point the read-only query at a study using the revised Module 2 schema.

```powershell
psql -X -q --csv -v ON_ERROR_STOP=1 -h localhost -p 5432 -U postgres -d your_study_database -o field25_source_exceptions.csv -f ./tools/export_field25_exceptions.sql
```

## Verify the policy decisions from original histories

For an additional check, run this from the extracted folder in PowerShell. Replace the database name in quotes with the generated name printed by the launcher. The query runs read-only and recomputes the policy decisions from the original monthly evidence.

```powershell
psql -X -qAt -v ON_ERROR_STOP=1 -v expected_accounts=25000 -v required_months=3 -h localhost -p 5432 -U postgres -d "replace_with_study_database" -o policy_audit.json -f ./tools/verify_study.sql
```

If `psql` is outside your PATH, substitute `& "C:\Program Files\PostgreSQL\17\bin\psql.exe"` for `psql`. Match the connection options to your database. Set `expected_accounts` and `required_months` to `account_count` and `cure_months` in that run’s receipt. The command shown uses the 25,000-account, three-month study. Open `policy_audit.json` and check that `pass` is `true`. A completed query can also return `pass: false` with mismatch counts for review.
