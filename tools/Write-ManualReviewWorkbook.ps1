#requires -Version 5.1
<#
.SYNOPSIS
Writes the monthly case handoff to a filterable .xlsx using built-in .NET libraries.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$utf8 = New-Object System.Text.UTF8Encoding($false)
$culture = [Globalization.CultureInfo]::InvariantCulture
$source = (Resolve-Path -LiteralPath $CsvPath).ProviderPath
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([IO.File]::Exists($output)) { throw "Workbook already exists: $output" }

# The column order is the public contract of export_manual_review.sql.
$fields = @('account','review_reason','review_action','bank_impact_start','bank_impact_end','credit_impact_start','credit_impact_through','reporting_as_of','latest_history_month','original_status_17a','original_php_newest_first','post_impact_months','current_streak_start','current_streak_months','cure_months_required','next_history_month','proposed_treatment','proposed_php_newest_first','internal_fields_to_clear','original_payment_rating_17b','original_dofd','proposed_effective_status_17a','proposed_effective_rating_17b','proposed_effective_dofd')
$headings = @('Account ID','Review reason','Next review action','Bank impact start','Bank impact end','Credit impact start','Credit impact through','Reporting as of','Latest original month','Original status (17A)','Original history (newest first)','Post-impact months','Current streak start','Current streak months','Months required for cure','Earliest next history month','Proposed treatment','Proposed history (newest first)','Internal fields to clear','Original internal modeled payment rating','Original standard 17B (2020)','Original delinquency date (Field 25)','Proposed status (17A)','Proposed internal modeled payment rating','Proposed standard 17B (2020)','Proposed delinquency date (Field 25)','Reviewer','Disposition','Reviewer notes')
# The workbook inserts two explanatory columns beside the modeled ratings.
# The CSV schema stays intact for existing retained-data handoffs.
$displayFields = @($fields[0..19]) + @('original_standard_17b') + @($fields[20..22]) + @('proposed_standard_17b', $fields[23])
$widths = @(15,37,55,17,17,17,20,17,18,18,42,16,18,16,18,21,37,42,20,24,31,25,19,24,31,25,21,25,49)
$dates = @('bank_impact_start','bank_impact_end','credit_impact_start','credit_impact_through','reporting_as_of','latest_history_month','current_streak_start','next_history_month','original_dofd','proposed_effective_dofd')
$counts = @('post_impact_months','current_streak_months','cure_months_required')
$letters = @('A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','AA','AB','AC')
$header = [IO.File]::ReadLines($source) | Select-Object -First 1
if (!$header -or (($header -replace '"','') -cne ($fields -join ','))) { throw 'Unexpected handoff CSV header or field order.' }
$rows = @(Import-Csv -LiteralPath $source -Encoding UTF8)
if ($rows.Count -gt 1048575) { throw 'The review queue exceeds the row limit of a single Excel worksheet.' }
$last = $rows.Count + 1
$ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'

function New-TextCell([string]$address, [string]$value, [int]$style) {
    $escaped = [Security.SecurityElement]::Escape($value)
    return "<c r=`"$address`" s=`"$style`" t=`"inlineStr`"><is><t xml:space=`"preserve`">$escaped</t></is></c>"
}

# Historical 2020 CRRG p. 4-10. A modeled value does not establish a furnished
# rating. Missing retained status or rating stays visible instead of implying zero.
function Get-StandardRatingNote([string]$status, [string]$rating) {
    if ([string]::IsNullOrWhiteSpace($status)) { return 'Unknown: verify source status' }
    if ($status -in @('DA','DF')) { return 'Whole-account deletion instruction' }
    if ($status -in @('05','13','65','88','89','94','95')) {
        if ([string]::IsNullOrWhiteSpace($rating)) { return 'Required: modeled rating missing' }
        return 'Required: verify rating from source'
    }
    return 'Blank for this status'
}

function Get-DisplayValue($row, [string]$field) {
    if ($field -eq 'original_standard_17b') {
        return Get-StandardRatingNote $row.original_status_17a $row.original_payment_rating_17b
    }
    if ($field -eq 'proposed_standard_17b') {
        return Get-StandardRatingNote $row.proposed_effective_status_17a $row.proposed_effective_rating_17b
    }
    return [string]$row.$field
}

function Add-Part($zip, [string]$path, [string]$xml) {
    $entry = $zip.CreateEntry($path, [IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $writer = New-Object System.IO.StreamWriter($stream, $utf8)
        try { $writer.Write($xml) } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}

$queue = New-Object Text.StringBuilder
[void]$queue.Append("$declaration<worksheet xmlns=`"$ns`"><sheetPr><tabColor rgb=`"FF17695F`"/></sheetPr><dimension ref=`"A1:AC$last`"/><sheetViews><sheetView showGridLines=`"0`" workbookViewId=`"0`"><pane xSplit=`"1`" ySplit=`"1`" topLeftCell=`"B2`" activePane=`"bottomRight`" state=`"frozen`"/><selection pane=`"bottomRight`" activeCell=`"B2`" sqref=`"B2`"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=`"17`"/><cols>")
for ($i=0; $i -lt $widths.Count; $i++) {
    [void]$queue.Append(('<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($i+1), $widths[$i]))
}
[void]$queue.Append('</cols><sheetData><row r="1" ht="39" customHeight="1">')
for ($i=0; $i -lt $headings.Count; $i++) {
    $style = if ($i -ge $displayFields.Count) { 2 } else { 1 }
    [void]$queue.Append((New-TextCell ($letters[$i]+'1') $headings[$i] $style))
}
[void]$queue.Append('</row>')
for ($r=0; $r -lt $rows.Count; $r++) {
    $number = $r+2
    [void]$queue.Append("<row r=`"$number`" ht=`"64`" customHeight=`"1`">")
    for ($i=0; $i -lt $headings.Count; $i++) {
        $address = $letters[$i]+$number
        $style = 3
        $value = ''
        if ($i -ge $displayFields.Count) { $style = 8 }
        else {
            $field = $displayFields[$i]
            $value = Get-DisplayValue $rows[$r] $field
            if ($field -in $dates) { $style = 4 }
            elseif ($field -in $counts) { $style = 5 }
            elseif ($i -in @(10,17)) { $style = 6 }
            elseif ($i -eq 1) { $style = 7 }
        }
        if ($value.Length -eq 0) { [void]$queue.Append("<c r=`"$address`" s=`"$style`"/>"); continue }
        if ($style -eq 4) {
            $value = [DateTime]::ParseExact($value, 'yyyy-MM-dd', $culture).ToOADate().ToString('0', $culture)
        }
        if ($style -eq 4 -or $style -eq 5) {
            if ($value -notmatch '^\d+$') { throw "Invalid numeric field $address" }
            [void]$queue.Append("<c r=`"$address`" s=`"$style`"><v>$value</v></c>")
        } else { [void]$queue.Append((New-TextCell $address $value $style)) }
    }
    [void]$queue.Append('</row>')
}
[void]$queue.Append("</sheetData><autoFilter ref=`"A1:AC$last`"/></worksheet>")

$guidance = @(
    @('Monthly account review','How to review the queue'),
    @('Scope', ('{0:N0} synthetic accounts were flagged for manual review in this study. Each row is one account. Filter the queue by review reason, earliest next history month or reviewer.' -f $rows.Count)),
    @('Bank issue dates','Bank impact start and end identify the incident period. Credit impact through is the last month the engine evaluated in this snapshot. Later original reporting may extend the review.'),
    @('Reporting and history','17A is the account status as of the reporting date (DOAI). The first payment-history byte represents the prior month, and each byte to its right goes back one month. Read original and proposed histories on that same calendar.'),
    @('Read the original months','An original 0 represents current. Codes 1 through 6 represent increasing delinquency. G, H, J, K and L represent major derogatory events, including L for charge-off. An original D supplies no evidence of current performance. A proposed D can mark a month selected for cleanup.'),
    @('Progress toward cure','The streak counts consecutive original current months strictly after bank impact end through the latest original month. A blank streak start means zero qualifying months at that endpoint. Proposed D values do not count toward cure.'),
    @('Next observation','The earliest next history month is the first as-yet-unobserved reporting month. Obtain its original performance, re-evaluate the streak and record the result. An expected month or a proposed correction alone cannot establish cure.'),
    @('Review reasons','INSUFFICIENT_POST_IMPACT_HISTORY means too few original months follow the issue to test the full threshold. NO_CURE_OPEN_ACCOUNT means the open account has enough monthly observations to evaluate, and has yet to satisfy the threshold.'),
    @('Original and proposed','Original history is the source evidence. Proposed history shows the sandbox cleanup. Internal field-clear names record proposed database actions. The CSV and workbook contain no bureau submission or acknowledgment.'),
    @('Check the account fields','Compare original and proposed 17A, internal modeled payment rating and Field 25. The adjacent 2020 standard 17B note uses the status on its own side. Both 71 and 11 (account 17899) and both 84 and 11 (account 24064) require blank standard 17B.'),
    @('Read a blank date','On a revised study row, DOFD in Internal fields to clear records an explicit clear. A blank proposed date alone cannot establish that instruction. UNAVAILABLE_IN_SOURCE means the retained schema lacks clear flags. Check the source record before inferring an action.'),
    @('Choose a disposition','Await the next original month if the threshold is unmet. With enough original current months, record the first month of the qualifying streak and the month that completed it before confirming cure.'),
    @('Reassess severe events','When new original history includes G, H, J, K or L inside the credit window, reassess the latest severe month. Without a later original 0 through 6 by the evaluation cutoff, the study selects tradeline deletion (DA).'),
    @('Check reversal evidence','A later original 0 through 6 is a proxy for a reversal of the latest severe event. Verify it in servicing records. The study retains a reversed tradeline for full cleanup. An open case remains under review until original history confirms cure.'),
    @('Keep the incident dates','Archive this decision, add the next original cycle to the same study and rerun Module 2 with incident-date reuse enabled. Keep the new dated handoff alongside the prior one. See tools/RUN_STUDY.md.'),
    @('Record the review','Use Reviewer, Disposition and Reviewer notes in a working copy. Record the new evidence and who reviewed it. Worksheet edits stay in that copy. Each new study writes a fresh handoff.'),
    @('Start with account 24064','In the 25,000-account worklist, filter Account ID to 24064. The bank issue ran from December 2023 through January 2024. November''s 1 stays. Five proposed D entries cover December through April because the original delinquency continued after the issue.'),
    @('24064 at the next review','April''s original 6 is the first PHP byte on the May 1, 2024 snapshot. The original cure streak is zero. Obtain May performance in the June 1 snapshot and reassess the same incident.'),
    @('Companion cases','In the 1,000-account explorer, 175 shows a confirmed cure and 327 shows reversal evidence with cure still pending. In the 25,000-account worklist, filter to 17899 for the Field 25 example below.'),
    @('17899 on February 1','In the 25,000-account study, the bank issue spans January 2025. On the February 1 snapshot, January''s first PHP byte changes from 1 to D. December''s second byte stays 1. For February 1, the sandbox proposes 17A 71 to 11 and explicitly clears Field 25 (2024-12-01).'),
    @('Two status observations','The known December status 71 belongs to the earlier reporting period. Source 17A 71 on February 1 is a separate as-of observation. December remains visible as the second PHP byte in the February 1 snapshot.'),
    @('17899 in the next cycle','January contributes zero cure months. February''s original PHP first appears in the March 1 snapshot. Reassess each cycle with the same incident dates until original performance confirms cure or a new severe event changes the treatment.'),
    @('Standard Metro 2','A blank proposed date plus the DOFD clear flag is an internal decision. In the standard 426-character Metro 2 format, use 00000000 when no Field 25 date applies. Consult the current CDIA CRRG. The public 2020 reference gives the rule on page 4-16.'),
    @('Standard payment rating','The 2020 CRRG p. 4-10 requires 17B for 05, 13, 65, 88, 89, 94 and 95. Source evidence must establish the rating. Other account statuses take a blank. Code 05 was later retired. A missing status leaves applicability unknown. The CSV retains the two original study column names for modeled ratings.'),
    @('Servicing referrals','The separate account_field_review.csv lists unresolved account-field evidence. When required payment rating is missing, obtain it from servicing. For a status 13 with no rating, the Field 25 rating-dependent condition remains undetermined. Status 65 independently requires its date.'),
    @('Source','The companion manual_review_handoff.csv comes from tools/export_manual_review.sql and module2.metro2_remediation_final. Use the matching run.json to identify the source database and SQL revision.')
)
$guide = New-Object Text.StringBuilder
[void]$guide.Append("$declaration<worksheet xmlns=`"$ns`"><sheetPr><tabColor rgb=`"FF34536C`"/></sheetPr><sheetViews><sheetView showGridLines=`"0`" workbookViewId=`"0`"/></sheetViews><sheetFormatPr defaultRowHeight=`"17`"/><cols><col min=`"1`" max=`"1`" width=`"27`" customWidth=`"1`"/><col min=`"2`" max=`"2`" width=`"101`" customWidth=`"1`"/></cols><sheetData>")
for ($i=0; $i -lt $guidance.Count; $i++) {
    $n=$i+1
    $height = if ($i -eq 0) {34} else {50}
    [void]$guide.Append("<row r=`"$n`" ht=`"$height`" customHeight=`"1`">")
    $left = if ($i -eq 0) {1} else {7}
    $right = if ($i -eq 0) {1} else {3}
    [void]$guide.Append((New-TextCell "A$n" $guidance[$i][0] $left))
    [void]$guide.Append((New-TextCell "B$n" $guidance[$i][1] $right))
    [void]$guide.Append('</row>')
}
[void]$guide.Append('</sheetData></worksheet>')

$styles = @'
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>
<fonts count="4"><font><sz val="11"/><color rgb="FF1F3743"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><sz val="10"/><color rgb="FF264B54"/><name val="Consolas"/></font><font><b/><sz val="10"/><color rgb="FF19574E"/><name val="Calibri"/></font></fonts>
<fills count="6"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF17394C"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF17695F"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF0F6F4"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF8E5"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="hair"><color rgb="FFD4E0DF"/></bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="9">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="1" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="49" fontId="2" fillId="0" borderId="1" xfId="0" applyFont="1" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="3" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
'@
$temp = Join-Path ([IO.Path]::GetDirectoryName($output)) ([IO.Path]::GetRandomFileName())
try {
    $zip = [IO.Compression.ZipFile]::Open($temp, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-Part $zip '[Content_Types].xml' ($declaration+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
        Add-Part $zip '_rels/.rels' ($declaration+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        Add-Part $zip 'xl/workbook.xml' ($declaration+'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="0"/></bookViews><sheets><sheet name="Review queue" sheetId="1" r:id="rId1"/><sheet name="How to review" sheetId="2" r:id="rId2"/></sheets></workbook>')
        Add-Part $zip 'xl/_rels/workbook.xml.rels' ($declaration+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
        Add-Part $zip 'xl/styles.xml' ($declaration+$styles)
        Add-Part $zip 'xl/worksheets/sheet1.xml' $queue.ToString()
        Add-Part $zip 'xl/worksheets/sheet2.xml' $guide.ToString()
    } finally { $zip.Dispose() }

    # Verify saved cells before publishing. This also covers empty queues and numeric-looking histories.
    $zip = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        function Read-Part([string]$path) {
            $stream = $zip.GetEntry($path).Open()
            try { $doc = New-Object Xml.XmlDocument; $doc.Load($stream); return ,$doc } finally { $stream.Dispose() }
        }
        $book = Read-Part 'xl/workbook.xml'
        if (($book.workbook.sheets.sheet.name -join ',') -cne 'Review queue,How to review') { throw 'Workbook tab verification failed.' }
        $doc = Read-Part 'xl/worksheets/sheet1.xml'
        $xmlRows = @($doc.worksheet.sheetData.row)
        if ($xmlRows.Count -ne $last -or $doc.worksheet.autoFilter.ref -cne "A1:AC$last") { throw 'Workbook row count or filter verification failed.' }
        for ($i=0; $i -lt $headings.Count; $i++) {
            if ($xmlRows[0].ChildNodes.Item($i).InnerText -cne $headings[$i]) { throw 'Workbook header mismatch.' }
        }
        for ($r=0; $r -lt $rows.Count; $r++) {
            $cells = $xmlRows[$r+1].ChildNodes
            for ($i=0; $i -lt $displayFields.Count; $i++) {
                $field = $displayFields[$i]
                $cell = $cells.Item($i)
                $value = $cell.InnerText
                if ($value -and $field -in $dates) {
                    $value = [DateTime]::FromOADate([double]::Parse($value, $culture)).ToString('yyyy-MM-dd', $culture)
                }
                if ($value -cne (Get-DisplayValue $rows[$r] $field)) { throw "Workbook value differs from source at $($cell.GetAttribute('r'))." }
                if ($value -and $field -in @('account','original_status_17a','original_php_newest_first','proposed_php_newest_first','original_payment_rating_17b','proposed_effective_status_17a','proposed_effective_rating_17b') -and $cell.GetAttribute('t') -cne 'inlineStr') { throw 'Workbook must preserve identifiers and histories as text.' }
            }
        }
    } finally { $zip.Dispose() }
    [IO.File]::Move($temp, $output)
} finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
