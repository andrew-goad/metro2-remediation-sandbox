#requires -Version 5.1
<#
.SYNOPSIS
Creates a fresh PostgreSQL database, runs both Metro 2 modules and exports reconciled results.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Run-Metro2Study.ps1 -AccountCount 25000
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 2147483647)][int]$AccountCount = 25000,
    [string]$Server = 'localhost',
    [ValidateRange(1, 65535)][int]$Port = 5432,
    [string]$User = 'postgres',
    [ValidatePattern('(?-i:\A[a-z_][a-z0-9_]{0,62}\z)')][string]$Database,
    [ValidatePattern('(?-i:\A[a-z_][a-z0-9_]{0,62}\z)')][string]$MaintenanceDatabase = 'postgres',
    [string]$Psql,
    [string]$OutputDirectory,
    [ValidateRange(1, 2147483647)][int]$CureMonths = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,6)
if (!$Database) { $Database = 'metro2_study_' + $AccountCount + '_' + $runId.ToLowerInvariant() }
if ($Database -in @('metro2_lab', 'postgres', 'template0', 'template1', $MaintenanceDatabase)) {
    throw "Select a new study database. '$Database' is reserved."
}
if (!$Psql) {
    $command = Get-Command psql -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $Psql = $command.Source }
    elseif ($env:ProgramFiles) {
        $installs = Get-ChildItem (Join-Path $env:ProgramFiles 'PostgreSQL') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } | Sort-Object { [int]$_.Name } -Descending
        foreach ($install in $installs) {
            $client = Join-Path $install.FullName 'bin/psql.exe'
            if (Test-Path -LiteralPath $client -PathType Leaf) { $Psql = $client; break }
        }
    }
}
if (!$Psql) { throw 'Supply -Psql with the path to the PostgreSQL client executable.' }
$common = @('-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', $Server, '-p', "$Port", '-U', $User)
function Invoke-StudySql([string]$Target, [string[]]$Options) {
    & $Psql @common -d $Target @Options
    if ($LASTEXITCODE -ne 0) { throw "psql exited with code $LASTEXITCODE in database '$Target'." }
}
$root = Split-Path -Parent $PSScriptRoot
$m1 = Join-Path $root 'src/module_01_metro2_synthetic_portfolio_generator.sql'
$m2 = Join-Path $root 'src/module_02_metro2_remediation_engine.sql'
$handoffSql = Join-Path $PSScriptRoot 'export_manual_review.sql'
if (!(Test-Path -LiteralPath $handoffSql -PathType Leaf)) { throw "Cannot find the manual review query at $handoffSql" }
$field25Sql = Join-Path $PSScriptRoot 'export_field25_exceptions.sql'
if (!(Test-Path -LiteralPath $field25Sql -PathType Leaf)) { throw "Cannot find the Field 25 source QA query at $field25Sql" }
$fieldReviewSql = Join-Path $PSScriptRoot 'export_account_field_review.sql'
if (!(Test-Path -LiteralPath $fieldReviewSql -PathType Leaf)) { throw "Cannot find the account field review query at $fieldReviewSql" }
$auditSql = Join-Path $PSScriptRoot 'verify_study.sql'
if (!(Test-Path -LiteralPath $auditSql -PathType Leaf)) { throw "Cannot find the independent study verifier at $auditSql" }
$workbookScript = Join-Path $PSScriptRoot 'Write-ManualReviewWorkbook.ps1'
if (!(Test-Path -LiteralPath $workbookScript -PathType Leaf)) { throw "Cannot find the manual review workbook writer at $workbookScript" }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$original = [IO.File]::ReadAllText($m1, $utf8)
$pattern = [regex]'(?m)^([ \t]*)5000000(,[ \t]*-- total number of synthetic accounts to generate[ \t]*\r?)$'
if ($pattern.Matches($original).Count -ne 1) { throw 'Expected one published Module 1 sample-size parameter.' }
if (!(Test-Path -LiteralPath $m2 -PathType Leaf)) { throw "Cannot find Module 2 at $m2" }
$configured = $pattern.Replace($original, '${1}' + $AccountCount + '${2}', 1)
$engineSource = [IO.File]::ReadAllText($m2, $utf8)
$curePattern = [regex]'(?m)^([ \t]*)3([ \t]+-- conservative remediation-policy default[ \t]*\r?)$'
if ($curePattern.Matches($engineSource).Count -ne 1) { throw 'Expected exactly one default Module 2 cure threshold.' }
$engineConfigured = $curePattern.Replace($engineSource, '${1}' + $CureMonths + '${2}', 1)

if (!$OutputDirectory) { $OutputDirectory = Join-Path (Get-Location).Path ("study_results/" + $runId) }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw "Choose a new output directory. This path exists: $OutputDirectory" }
$existing = Invoke-StudySql $MaintenanceDatabase @('-At', '-c', "SELECT count(*) FROM pg_database WHERE datname = '$Database'")
if ($existing -ne '0') { throw "Database '$Database' already exists. Choose a fresh database name." }
New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop | Out-Null
$studyM1 = Join-Path $OutputDirectory 'module_01_configured.sql'
[IO.File]::WriteAllText($studyM1, $configured, $utf8)
$studyM2 = Join-Path $OutputDirectory 'module_02_configured.sql'
[IO.File]::WriteAllText($studyM2, $engineConfigured, $utf8)
$started = [DateTime]::UtcNow
try {
    Write-Host "Creating $Database on $Server (port $Port). Results: $OutputDirectory"
    # CREATE fails atomically if another session claimed this name after the existence check.
    # Pass a quoted identifier on stdin so a valid lowercase keyword or underscore works
    # identically with Windows PowerShell and PowerShell 7 native argument handling.
    "CREATE DATABASE `"$Database`" TEMPLATE template0;" | & $Psql @common -d $MaintenanceDatabase -f -
    if ($LASTEXITCODE -ne 0) { throw "Could not create study database '$Database'." }
    Write-Host "Running Module 1 for $AccountCount synthetic accounts..."
    # Each bundled module owns its transaction, including when run directly in DBeaver.
    # The temporary controls remain available on this connection after Module 1 commits.
    $checkMix = @'
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_temp.module1_params
        WHERE (pct_current, pct_mild, pct_mod, pct_severe, pct_derog) = (0.70, 0.15, 0.08, 0.04, 0.03)
    ) THEN
        RAISE EXCEPTION 'The executed Module 1 profile shares differ from the study defaults.';
    END IF;
END $$;
'@
    Invoke-StudySql $Database @('-o',(Join-Path $OutputDirectory 'module1.log'),'-f',$studyM1,'-c',$checkMix)
    Write-Host "Running Module 2 with $CureMonths original current months required for cure..."
    Invoke-StudySql $Database @('-o',(Join-Path $OutputDirectory 'module2.log'),'-f',$studyM2)

    $totalsSql = @'
SELECT
    (SELECT count(*) FROM module1.metro2_account_blueprint) AS blueprint_accounts,
    (SELECT count(*) FROM module1.metro2_final) AS generator_accounts,
    (SELECT count(*) FROM module2.metro2_remediation_input) AS incident_accounts,
    (SELECT count(*) FROM module2.metro2_remediation_window_eval) AS evaluated_accounts,
    (SELECT count(*) FROM module1.metro2_status_history) AS original_months,
    (SELECT count(*) FROM module2.metro2_remediation_php_detail) AS detail_months,
    (SELECT count(*) FROM module2.metro2_remediation_php_detail WHERE original_status IS DISTINCT FROM remediated_status) AS changed_months,
    count(*) AS final_accounts,
    count(DISTINCT account) AS distinct_final_accounts,
    count(*) FILTER (WHERE manual_review_flag = 1) AS review_accounts,
    count(credit_cure_date) AS observed_cures,
    count(*) FILTER (WHERE account_field_policy='EVIDENCE_SCOPED_FIELDS_V2') AS field_policy_accounts,
    count(account_field_review_reason) AS field_review_accounts,
    count(*) FILTER (WHERE clear_account_status_17a) AS clear_status_accounts,
    count(*) FILTER (WHERE clear_payment_rating_17b) AS clear_rating_accounts,
    count(*) FILTER (WHERE clear_date_of_first_delinquency) AS clear_dofd_accounts,
    count(*) FILTER (WHERE clear_account_status_17a OR clear_payment_rating_17b OR clear_date_of_first_delinquency) AS any_clear_accounts,
    min(cure_consecutive_months_required) AS min_cure_months,
    max(cure_consecutive_months_required) AS max_cure_months,
    pg_database_size(current_database()) AS database_bytes,
    -- Persist the two observed dates in the count reconciliation. The revised
    -- policy uses the latest severe event; a later numeric mark and cure are
    -- separate tests. The source byte L alone never decides deletion.
    (SELECT count(*) FROM module2.metro2_remediation_window_eval
       WHERE last_severe_month IS NOT NULL AND severe_reversal_month IS NULL) AS unresolved_severe_accounts,
    (SELECT count(*) FROM module2.metro2_remediation_window_eval
       WHERE severe_reversal_month IS NOT NULL) AS reversed_severe_accounts,
    count(*) FILTER (WHERE remediation_treatment='TRADELINE_DELETION') AS deletion_accounts,
    count(*) FILTER (WHERE remediation_treatment='FULL_DEROGATORY_PHP_CLEANUP') AS full_cleanup_accounts
FROM module2.metro2_remediation_final
'@
    $groupSql = @'
SELECT profile_type, remediation_treatment, manual_review_flag, manual_review_reason,
       (credit_cure_date IS NOT NULL) AS observed_cure,
       count(*) AS accounts
FROM module2.metro2_remediation_final
GROUP BY profile_type, remediation_treatment, manual_review_flag, manual_review_reason,
         (credit_cure_date IS NOT NULL)
ORDER BY 1, 2, 3, 4, 5
'@
    $totalsPath = Join-Path $OutputDirectory 'totals.csv'
    $groupsPath = Join-Path $OutputDirectory 'outcomes.csv'
    $handoffPath = Join-Path $OutputDirectory 'manual_review_handoff.csv'
    $field25Path = Join-Path $OutputDirectory 'field25_source_exceptions.csv'
    $fieldReviewPath = Join-Path $OutputDirectory 'account_field_review.csv'
    $auditPath = Join-Path $OutputDirectory 'policy_audit.json'
    $idsPath = Join-Path $OutputDirectory ("expected_review_ids_" + $runId + ".csv")
    try {
        # One read-only snapshot supplies the counts, issued handoff and independent source IDs.
        # psql path variables keep spaces and other literal characters in client-side paths.
        $exportArgs = @('--single-transaction','--csv','-o',$totalsPath,
            '-v',"groups_path=$groupsPath",'-v',"handoff_path=$handoffPath",'-v',"ids_path=$idsPath",'-v',"field25_path=$field25Path",'-v',"field_review_path=$fieldReviewPath",'-v',"audit_path=$auditPath",'-v',"expected_accounts=$AccountCount",'-v',"required_months=$CureMonths",'-v','metro2_existing_snapshot=1',
            '-c','SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY',
            '-c',"SET LOCAL DateStyle TO 'ISO, YMD'",'-c',$totalsSql,
            '-c','\o :groups_path','-c',$groupSql,
            '-c','\o :handoff_path','-f',$handoffSql,
            '-c','\o :field25_path','-f',$field25Sql,
            '-c','\o :field_review_path','-f',$fieldReviewSql,
            '-c','\o :ids_path','-c','SELECT account FROM module2.metro2_remediation_final WHERE manual_review_flag = 1',
            '-c','\o :audit_path','-c','\pset format unaligned','-c','\t on','-f',$auditSql)
        Invoke-StudySql $Database $exportArgs

        $expectedIds = New-Object 'System.Collections.Generic.HashSet[string]'
        Import-Csv -LiteralPath $idsPath | ForEach-Object {
            if (!$expectedIds.Add($_.account)) { throw "Duplicate source review account $($_.account)." }
        }
        $reviewCount = $expectedIds.Count
        Import-Csv -LiteralPath $handoffPath | ForEach-Object {
            if (!$expectedIds.Remove($_.account)) { throw "Unexpected or duplicate handoff account $($_.account)." }
        }
        if ($expectedIds.Count -ne 0) { throw "$($expectedIds.Count) flagged accounts are missing from the handoff." }
        $handoffColumns = (Get-Content -LiteralPath $handoffPath -TotalCount 1) -split ','
    }
    finally {
        if (Test-Path -LiteralPath $idsPath) { Remove-Item -LiteralPath $idsPath -ErrorAction Stop }
    }
    $field25Count = (Import-Csv -LiteralPath $field25Path | Measure-Object).Count
    $field25Columns = (Get-Content -LiteralPath $field25Path -TotalCount 1) -split ','
    $totals = Import-Csv -LiteralPath $totalsPath
    $audit = Get-Content -Raw -LiteralPath $auditPath | ConvertFrom-Json
    if ($audit.pass -ne $true -or $audit.requested_accounts -ne $AccountCount) {
        throw 'Independent study verification failed. Inspect policy_audit.json.'
    }
    $fieldReviewCount = (Import-Csv -LiteralPath $fieldReviewPath | Measure-Object).Count
    if ($fieldReviewCount -ne [long]$totals.field_review_accounts -or [long]$totals.field_policy_accounts -ne $AccountCount) {
        throw 'The field-review export or field policy does not reconcile to the source.'
    }
    if ($reviewCount -ne [long]$totals.review_accounts) { throw 'The handoff does not reconcile to the review account total.' }
    if ([long]$totals.unresolved_severe_accounts -ne [long]$totals.deletion_accounts -or
        [long]$totals.reversed_severe_accounts -ne [long]$totals.full_cleanup_accounts) {
        throw 'Severe-event dates do not reconcile to the deletion and full-cleanup totals.'
    }
    foreach ($column in @('blueprint_accounts','generator_accounts','incident_accounts','evaluated_accounts','final_accounts','distinct_final_accounts')) {
        if ([long]$totals.$column -ne $AccountCount) { throw "Validation failed for $column." }
    }
    if ([long]$totals.original_months -ne [long]$totals.detail_months -or [long]$totals.detail_months -lt 1) {
        throw 'Validation failed for original and remediation account-month totals.'
    }
    if ([int]$totals.min_cure_months -ne $CureMonths -or [int]$totals.max_cure_months -ne $CureMonths -or [int]$audit.threshold -ne $CureMonths) {
        throw "The study outputs or independent audit disagree with the requested cure threshold of $CureMonths."
    }
    $groups = Import-Csv -LiteralPath $groupsPath
    if (($groups | Measure-Object -Property accounts -Sum).Sum -ne $AccountCount) {
        throw 'The outcomes table does not reconcile to the final account denominator.'
    }
    $workbookPath = Join-Path $OutputDirectory 'manual_review_handoff.xlsx'
    # The workbook writer reopens the saved sheet and checks all source fields against this validated CSV.
    & $workbookScript -CsvPath $handoffPath -OutputPath $workbookPath
    $version = Invoke-StudySql $Database @('-At','-c','SHOW server_version')
    $manifest = [ordered]@{
        state = 'verified'; database = $Database; account_count = $AccountCount
        represented_months = [long]$totals.detail_months
        server = $Server; port = $Port; postgres = "$version"; powershell = "$($PSVersionTable.PSVersion)"
        started_utc = $started.ToString('o'); finished_utc = [DateTime]::UtcNow.ToString('o')
        module2_policy = 'REVERSAL_AWARE_SEVERE_V2'; public_baseline_revision = '1201adcc0b3a74a0f81e8f456a9e3d901f0aaca7'
        superseded_private_policy = 'CHARGEOFF_REQUIRES_CURE_V1'
        superseded_private_module2_sha256 = '8CF4C6973C80BEBBCEC4447BB5BE489A0F59959E23A0C4B95327FBBADEABEDD8'
        default_base_profile_shares_percent = @(70,15,8,4,3); cure_months = $CureMonths
        independent_verifier_sha256 = (Get-FileHash -LiteralPath $auditSql -Algorithm SHA256).Hash
        independent_audit_sha256 = (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash
        account_field_policy = 'EVIDENCE_SCOPED_FIELDS_V2'
        account_field_review_rows = $fieldReviewCount
        account_field_review_schema = 'v2'
        account_field_review_sha256 = (Get-FileHash -LiteralPath $fieldReviewPath -Algorithm SHA256).Hash
        account_field_review_query_sha256 = (Get-FileHash -LiteralPath $fieldReviewSql -Algorithm SHA256).Hash
        module1_source_sha256 = (Get-FileHash -LiteralPath $m1 -Algorithm SHA256).Hash
        module1_configured_sha256 = (Get-FileHash -LiteralPath $studyM1 -Algorithm SHA256).Hash
        module2_source_sha256 = (Get-FileHash -LiteralPath $m2 -Algorithm SHA256).Hash
        module2_configured_sha256 = (Get-FileHash -LiteralPath $studyM2 -Algorithm SHA256).Hash
        totals_sha256 = (Get-FileHash -LiteralPath $totalsPath -Algorithm SHA256).Hash
        outcomes_sha256 = (Get-FileHash -LiteralPath $groupsPath -Algorithm SHA256).Hash
        manual_review_handoff_schema = 'v2'
        manual_review_handoff_rows = $reviewCount
        manual_review_handoff_columns = $handoffColumns
        manual_review_handoff_sha256 = (Get-FileHash -LiteralPath $handoffPath -Algorithm SHA256).Hash
        manual_review_query_sha256 = (Get-FileHash -LiteralPath $handoffSql -Algorithm SHA256).Hash
        manual_review_workbook_sha256 = (Get-FileHash -LiteralPath $workbookPath -Algorithm SHA256).Hash
        manual_review_workbook_writer_sha256 = (Get-FileHash -LiteralPath $workbookScript -Algorithm SHA256).Hash
        manual_review_workbook_verified_rows = $reviewCount
        field25_source_exceptions_schema = 'v1'
        field25_source_exceptions_rows = $field25Count
        field25_source_exceptions_columns = $field25Columns
        field25_source_exceptions_sha256 = (Get-FileHash -LiteralPath $field25Path -Algorithm SHA256).Hash
        field25_source_query_sha256 = (Get-FileHash -LiteralPath $field25Sql -Algorithm SHA256).Hash
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'run.json'), ($manifest | ConvertTo-Json), $utf8)
    Write-Host "Verified $AccountCount accounts and $($totals.detail_months) account-months in '$Database'."
    Write-Host "Results: $OutputDirectory"
}
catch {
    Write-Warning "Study stopped. The output directory and any created study database are retained for inspection."
    throw
}
