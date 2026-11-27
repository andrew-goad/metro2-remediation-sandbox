# Explore the retained synthetic accounts

This export reads a single snapshot of Andrew’s existing PostgreSQL tables in `metro2_lab`. The explorer includes every account in `module2.metro2_remediation_final` and every represented month for each account. Module 1 may contain a larger or later population. Its blueprint row count is reported separately. The sizes next to the tables in DBeaver are storage sizes.

## From Windows

Open PowerShell at the root of the extracted DBeaver kit or a complete project checkout, alongside `tools`. The kits include a self-contained `explorer-template`. A full checkout provides the teaching exhibit in `docs`. Use the login shown in DBeaver. The connection in the supplied screenshot uses `localhost:5432` and database `metro2_lab`. The first three lines make a separate viewer for the retained results.

```powershell
$preview = 'metro2-retained-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$viewerSource = if (Test-Path -LiteralPath '.\explorer-template') { '.\explorer-template' } else { '.\docs' }
Copy-Item -LiteralPath $viewerSource -Destination $preview -Recurse
py -3 .\tools\build_explorer.py --database metro2_lab --user postgres --output "$preview\data.js"
if ($LASTEXITCODE -eq 0) { Invoke-Item "$preview\index.html" }
```

Python 3.8+ and the PostgreSQL client are sufficient. If Windows uses `python` instead of the Python launcher, replace `py -3` with `python`. The command finds `psql.exe` on PATH or in a standard PostgreSQL installation. For an explicit executable, add `--psql "C:\Program Files\PostgreSQL\17\bin\psql.exe"`. For another server or port, add `--host` and `--port`. PostgreSQL handles the password prompt. Use an account with schema usage and SELECT access to the five tables below. A Module 2 rerun recreates its four tables. If a read-only login loses access, ask the database owner to reapply its four table grants or configure the creating role’s default privileges. A denied export leaves the previous exhibit intact.

In the copied folder, open **index.html**. The kit viewer opens directly on **Your simulation** and **Account explorer**. In a full exhibit copy, choose **Account explorer** or **Explore the loaded accounts** to open **index.html#explorer**. Check the **Retained synthetic database** label and the loaded account count against your export before selecting a case. Account IDs belong to the selected population. In the full exhibit, the separate **25,000-account example** and its manual-review workbook use the packaged replay. To see your own flagged accounts, choose **Manual review** or **Account-field research** in your loaded explorer’s **Follow-up** filter. The two choices identify different work. The deposited 25,000-account files remain tied to their published study.

For a private review of your retained cohort, return the copied folder’s `data.js` or the DBeaver CSV. The file contains the full set of synthetic Module 2 results.

## From DBeaver

1. Open `tools/export_explorer.sql` in an SQL editor connected to the retained database. Execute its single SELECT. PostgreSQL reads all five tables from one statement snapshot.
2. Use **Export Data** on the result set. Export the whole result in its query order as UTF-8 CSV. Use a comma delimiter, double-quote quoting and escaping, and the column header `row_json`. Include the first metadata row. Download all rows if the grid currently displays only one page.
3. Copy the viewer using the first three PowerShell lines above. Run the builder against your CSV, then open the copy after verification succeeds.

```powershell
py -3 .\tools\build_explorer.py --csv .\metro2-retained.csv --output "$preview\data.js"
if ($LASTEXITCODE -eq 0) { Invoke-Item "$preview\index.html" }
```

## Coverage and reproducibility

The export preserves the source column `payment_rating_17b` as the **internal modeled payment rating** and `remediated_payment_rating_17b` as its proposed replacement. Use the original or proposed effective account status to determine standard Field 17B applicability. Under the 2020 character layout, 17B is blank for statuses 71, 84 and 11. Status 65 requires a rating, including when the synthetic record lacks one. [2020 CRRG, Field 17B, p. 4-10](https://autodealerplus.com/dealerzone/metro2.pdf#page=64)

| Input | Evidence used |
| --- | --- |
| `module1.metro2_account_blueprint` | Total blueprint rows and a cross-check of persona, latest reporting date, closure date and history length on each final ID. |
| `module2.metro2_remediation_input` | Account count and bank-impact dates. |
| `module2.metro2_remediation_window_eval` | Account count, cure and review evidence, post-impact month count and recovery indicators. |
| `module2.metro2_remediation_php_detail` | All original and resulting month codes, dates and evaluated-window flags. |
| `module2.metro2_remediation_final` | All final synthetic IDs, original fields, treatment, review, and written field deltas. |

The exporter scans the blueprint for its count and retrieves matching fields for final IDs. Its output size scales with the represented Module 2 histories. Large retained tables can take time to count. The Python builder streams one account at a time. The browser loads the finished dataset into memory. The packaged 1,000-account replay has 35,395 represented months. The separate study holds 873,193 represented months for 25,000 accounts. A much larger Module 2 result can be inspected directly in PostgreSQL.

The builder checks unique final IDs, the three account-table totals, the complete detail-row denominator, date order and continuity, the credit-window flags, post-impact count, original history and remediated PHP deltas. Missing joins, duplicate final IDs or a partial export stop the build and preserve the previous data file. Metadata records the source database name, PostgreSQL version, extraction time (UTC), five counts, and blueprint comparisons. Match the retained counts and known examples against archived evidence to identify the historical run. Matching IDs and blueprint fields alone cannot date a run.

For any blueprint ID, including accounts outside the remediation population, replace `12345` below and run this bounded query in DBeaver.

```sql
SELECT b.account, b.profile_type, b.start_date, b.end_date, b.months_reporting,
       b.pattern_mode, b.close_status_code, f.remediation_treatment,
       f.manual_review_reason, f.account IS NOT NULL AS has_module2_result
FROM module1.metro2_account_blueprint AS b
LEFT JOIN module2.metro2_remediation_final AS f USING (account)
WHERE b.account = 12345;
```

If the query returns a blueprint with `has_module2_result = false`, that ID has no final remediation decision in this snapshot. Explore the generator attributes on the left. For IDs with results, search the numeric ID in the browser to inspect each represented month.

The browser stores full histories newest month first and can display them chronologically. Its written deltas retain SQL nulls. The full tradeline-deletion treatment is an account-level decision in this model. Monthly PHP remains available as evidence for the drill-down.

For your own generated study, pass `--source-kind replay --run-receipt <path-to-run.json>` and save into a separate exhibit copy. The builder compares the receipt’s database, population, PostgreSQL version, month count, field policy and cure threshold with the export. The generated metadata keeps both the source-template and configured Module 2 checksums when available. A receipt identifies a run and settings. The same evidence and action checks still run on every row even when the database name and counts match. The current engine records `REVERSAL_AWARE_SEVERE_V2` in the database. The builder reconstructs cure, the last in-window severe event, the first later original 0–6 within the evidence period, the treatment, and the monthly review disposition. The exported `last_severe_month` and `severe_reversal_month` come from original history. The latter is a model proxy that a reviewer can reconcile to servicing records.

Both PostgreSQL and DBeaver CSV use the same account-level checks before atomically replacing the copy’s `data.js`. For `EVIDENCE_SCOPED_FIELDS_V2`, each field replacement or clear must agree with the original account fields, observed monthly history, applicable closure timing, scope of the delinquency episode and elected treatment. Field-group summaries and servicing research reasons must agree as well. For example, an original D in the newest month supplies no evidence of recovery. Cleaning an older late month can leave the original status, internal rating and dated delinquency intact. The earlier `EVIDENCE_SCOPED_FIELDS_V1` is checked under its own rules and labeled in the explorer.

The five-table export verifies the decisions against the retained original values. To establish that these values themselves match the original run, compare with its independently retained input, CSV or database backup. A coordinated change to every copy cannot be authenticated from the changed snapshot alone.

A verified `CHARGEOFF_REQUIRES_CURE_V1` receipt preserves that superseded study's separate rule for an in-window charge-off. Historical exports keep their original recorded outcomes. An older snapshot without a matching receipt or stored policy identifier is labeled unversioned. Where a historical schema lacks explicit field-clear flags, a blank override leaves the action unknown.

For a new observation on the same incident, follow [the monthly reassessment instructions](RUN_STUDY.md#reassess-the-same-incident-next-month). Export the reevaluated cohort to a new file. Its database policy identifier remains available without the original launch receipt.
