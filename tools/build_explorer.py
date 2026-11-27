"""Export the retained synthetic Metro 2 tables into the account explorer's data.js."""
import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from contextlib import suppress
from datetime import date
from hashlib import sha256
from pathlib import Path


CURRENT_POLICY = "REVERSAL_AWARE_SEVERE_V2"
FIELD_POLICY = "EVIDENCE_SCOPED_FIELDS_V2"
PRIOR_FIELD_POLICY = "EVIDENCE_SCOPED_FIELDS_V1"
SUPERSEDED_POLICY = "CHARGEOFF_REQUIRES_CURE_V1"


def psql_path(explicit):
    if explicit:
        return explicit
    found = shutil.which("psql")
    if found:
        return found
    if os.name == "nt":
        postgres = Path(os.environ["ProgramFiles"]) / "PostgreSQL"
        installs = [path for path in postgres.glob("*/bin/psql.exe") if path.parents[1].name.isdigit()]
        if installs:
            return str(max(installs, key=lambda path: int(path.parents[1].name)))
    raise ValueError("Supply --psql with the path to psql, or use a DBeaver CSV with --csv.")


def export_csv(args, target):
    command = [psql_path(args.psql), "-X", "-q", "--csv", "--set=ON_ERROR_STOP=1",
               "--host", args.host, "--port", str(args.port), "--dbname", args.database]
    if args.user:
        command.extend(["--username", args.user])
    command.extend(["--output", str(target), "--command", "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
                    "--file", str(Path(__file__).with_name("export_explorer.sql")),
                    "--command", "COMMIT"])
    env = os.environ.copy()
    env["PGCLIENTENCODING"] = "UTF8"
    subprocess.run(command, check=True, env=env)


def month_index(value):
    day = date.fromisoformat(value)
    if day.day != 1 or day.isoformat() != value:
        raise ValueError(f"Expected first-of-month date, got {value!r}.")
    return 12 * day.year + day.month


ADVERSE_MARKS = frozenset('123456GHJKL')
CLOSURE_RATINGS = frozenset('123456GL')
RATING_REQUIRED = {'05', '13', '65', '88', '89', '94', '95'}
STATUS_FOR_MARK = dict(zip('0123456GHJKL', ('11', '71', '78', '80', '82', '83', '84', '93', '94', '95', '96', '97')))
PAID_MAJOR = {'61': 'J', '62': 'G', '63': 'K', '64': 'L', '65': 'H'}


def expected_account_fields(row, field_policy):
    """Reconstruct sparse instructions from retained source fields and validated monthly history."""
    status, rating, dofd = (row[k] for k in ('account_status_17a', 'payment_rating_17b', 'date_of_first_delinquency'))
    closed, cutoff, latest = row['date_closed'], row['latest_doai'], row['php_left_byte_date']
    months = row['months']  # Verified newest first, without gaps.
    newest, proposed = months[0][1:3]
    treatment = row['remediation_treatment']
    cleanup = treatment.endswith('PHP_CLEANUP')
    paid_mark = PAID_MAJOR.get(status)
    removed_major = next((dt for dt, mark, after, _ in months if mark == paid_mark and mark != after), None)
    major_survives = any(after == paid_mark for _, _, after, _ in months)
    last_adverse = next((dt for dt, _, after, _ in months if after in ADVERSE_MARKS), None)
    last_unknown = next((dt for dt, mark, _, _ in months if mark == 'D'), None)
    onset = dofd[:7] + '-01' if dofd else None
    closure_index = month_index(closed[:7] + '-01') - 1 if closed else None
    closure_row = next((m for m in months if closure_index is not None and month_index(m[0]) == closure_index), None)
    closure_month, closure_mark, closure_edited = (closure_row[0], closure_row[1], closure_row[1] != closure_row[2]) if closure_row else (None, None, False)
    latest_edited = newest != proposed
    revised = field_policy == FIELD_POLICY

    def same_episode(basis):
        if not onset:
            return True
        if not basis or onset > basis:
            return False
        span = [(dt, mark) for dt, mark, _, _ in months if onset <= dt <= basis]
        return bool(span and span[-1][0] == onset and span[-1][1] in '123456' and
                    all(mark in ADVERSE_MARKS for _, mark in span))

    closure_rating_removed = bool(rating in CLOSURE_RATINGS and closure_edited and closure_mark == rating and
                                  (not last_adverse or last_adverse <= closure_month) and
                                  (not onset or onset <= closure_month) and (revised or closed <= cutoff))
    basis = None
    if cleanup:
        if (removed_major and closed and removed_major <= closed and (revised or closed <= cutoff)
                and not major_survives and (not last_unknown or last_unknown <= removed_major)
                and (not last_adverse or last_adverse <= removed_major) and (not onset or onset <= removed_major)
                and (rating in (None, '0', paid_mark) or closure_rating_removed)):
            basis = removed_major
        elif status == '13' and closure_rating_removed:
            basis = closure_month
        elif (latest_edited and status == STATUS_FOR_MARK.get(newest) and rating in (None, '0', newest)
              and (not onset or onset <= latest)):
            basis = latest

    blocked = None
    if revised and basis:
        close_month = closed[:7] + '-01' if closed else None
        if closed and ((not paid_mark and status != '13') or closed > cutoff or
                       any(dt >= close_month and mark in ADVERSE_MARKS for dt, mark, _, _ in months)):
            blocked = 'CLOSURE_TIMING_UNCONFIRMED'
        elif not same_episode(basis) or (paid_mark and rating not in (None, '0', paid_mark) and not same_episode(closure_month)):
            blocked = 'ONSET_CONTINUITY_UNCONFIRMED'
    elected = ('13' if paid_mark or status == '13' else '11') if basis and not blocked else None

    # Account-field research is independent of both cure reviews and Field 25 source exceptions.
    reason = None
    if not elected and treatment != 'TRADELINE_DELETION':
        if revised and status in RATING_REQUIRED and not (rating or '').strip(' '):
            reason = 'MISSING_REQUIRED_PAYMENT_RATING'
        elif cleanup:
            if blocked:
                reason = blocked
            elif paid_mark and not major_survives:
                reason = 'PAID_MAJOR_BASIS_UNCONFIRMED'
            elif status == '13' and rating in CLOSURE_RATINGS and (closure_mark != rating or closure_edited or (closed and closed > cutoff)):
                reason = 'CLOSURE_RATING_BASIS_UNCONFIRMED'
            elif not paid_mark and status != '13' and newest not in 'BD' and (status != STATUS_FOR_MARK[newest] or latest_edited):
                reason = 'AS_OF_FIELD_BASIS_UNCONFIRMED'
            elif not paid_mark and status != '13' and newest in ADVERSE_MARKS and onset and last_unknown and onset <= last_unknown:
                reason = 'ONSET_CONTINUITY_UNCONFIRMED'
    target_status = 'DA' if treatment == 'TRADELINE_DELETION' else elected
    return {
        'remediated_account_status_17a': target_status if target_status == 'DA' or target_status != status else None,
        'remediated_payment_rating_17b': '0' if elected and rating != '0' else None,
        'remediated_date_of_first_delinquency': None,
        'clear_account_status_17a': False, 'clear_payment_rating_17b': False,
        'clear_date_of_first_delinquency': bool(elected and dofd),
        'account_field_review_reason': reason,
    }


def verify_fields(row, field_policy, require):
    if field_policy:
        for key, expected in expected_account_fields(row, field_policy).items():
            require(key in row and type(row[key]) is type(expected) and row[key] == expected,
                    f'{key} differs from the {field_policy} decision supported by source evidence')
    flags = {key: row.get('clear_' + key) for key in ('account_status_17a', 'payment_rating_17b', 'date_of_first_delinquency')}
    # Legacy tables without explicit clear flags have ambiguous null instructions.
    # Their recorded field-group summaries cannot be reconstructed from sparse output.
    if any(value is None for value in flags.values()):
        return
    status = row['remediated_account_status_17a'] is not None or flags['account_status_17a']
    other = any(row['remediated_' + key] is not None or flags[key] for key in ('payment_rating_17b', 'date_of_first_delinquency'))
    php = row['remediated_full_php'] is not None
    names = {(False, False, False): 'NONE', (True, False, False): 'PHP_ONLY',
             (False, True, False): 'STATUS_ONLY', (False, False, True): 'DERIVED_FIELDS_ONLY',
             (True, True, False): 'PHP_AND_STATUS', (True, False, True): 'PHP_AND_DERIVED_FIELDS',
             (False, True, True): 'STATUS_AND_DERIVED_FIELDS', (True, True, True): 'PHP_STATUS_AND_DERIVED_FIELDS'}
    require(type(row['remediation_applied_flag']) is int and row['remediation_applied_flag'] == int(php or status or other),
            'applied flag disagrees with the actual sparse field actions')
    require(row['remediation_fields_modified'] == names[(php, status, other)], 'field summary disagrees with the actual sparse actions')
    deletion = row['remediation_treatment'] == 'TRADELINE_DELETION'
    require((row['remediated_account_status_17a'] == 'DA') == deletion and (not deletion or not (php or other)),
            'DA must be the sole action for tradeline deletion')


def verify_account(row, policy=None, field_policy=None, receipt_cure=None):
    def require(condition, reason):
        if not condition:
            raise ValueError(f"Account {row['account']}: {reason}")

    months = row["months"]
    require(isinstance(months, list) and len(months) > 0, "no monthly detail")
    require(months[0][0] == row["php_left_byte_date"] and months[-1][0] == row["php_right_byte_date"],
            "monthly detail differs from stored PHP endpoints")
    newest_index = month_index(row["php_left_byte_date"])
    require(month_index(row["latest_doai"]) == newest_index + 1,
            "reporting date must be the first day of the month after the newest original PHP month")
    require(re.fullmatch(r"[0-6DGHJKL]*B*", row["full_php"]) is not None,
            "unsupported original mark or B after reporting began")
    require(row.get("account_field_policy") == field_policy, "mixed account-field policies in the export")
    if receipt_cure is not None:
        require(row["cure_consecutive_months_required"] == receipt_cure, "cure threshold differs from the study receipt")
    for key in ("account_status_17a", "payment_rating_17b", "date_of_first_delinquency", "date_closed"):
        require(row[key] is None or isinstance(row[key], str), f"invalid source value for {key}")
    for key in ("date_of_first_delinquency", "date_closed"):
        if row[key] is not None:
            require(date.fromisoformat(row[key]).isoformat() == row[key], f"invalid source date for {key}")
    if policy == CURRENT_POLICY:
        bank_start, bank_end = month_index(row['impact_start_date']), month_index(row['impact_end_date'])
        require(month_index(row['php_right_byte_date']) <= bank_start <= bank_end <= newest_index,
                "bank issue dates are outside represented monthly history or reversed")
    for offset, (period, before, after, inside) in enumerate(months):
        require(month_index(period) == newest_index - offset, "missing, repeated or unordered months")
        require(before and after and len(before) == len(after) == 1, "invalid monthly symbol")
        require(after in "0123456BDGHJKL", f"unsupported proposed mark at {period}")
        expected_window = int(row["credit_impact_start_date"] <= period <= row["credit_impact_end_date"])
        require(type(inside) is int and inside == expected_window, f"window flag differs at {period}")
        require(before == after or inside, f"change outside evaluation window at {period}")
    before_php = "".join(month[1] for month in months)
    after_php = "".join(month[2] for month in months)
    require(before_php == row["full_php"], "original PHP differs from monthly evidence")
    expected_delta = after_php if after_php != before_php else None
    require(row["remediated_full_php"] == expected_delta, "stored PHP delta differs from monthly evidence")
    later = sum(month[0] > row["impact_end_date"] for month in months)
    require(type(row["post_impact_month_count"]) is int and later == row["post_impact_month_count"], "post-impact month count differs")
    chargeoff = row.get("has_chargeoff_in_credit_window")
    if chargeoff is not None or policy in (SUPERSEDED_POLICY, CURRENT_POLICY):
        original_l = any(original == "L" and inside == 1 for _, original, _, inside in months)
        require(type(chargeoff) is int and chargeoff == int(original_l),
                "in-window charge-off flag differs from the original dated history")
        if policy == SUPERSEDED_POLICY and original_l and row["credit_cure_date"] is None:
            require(row["remediation_treatment"] == "TRADELINE_DELETION",
                    "in-window charge-off without confirmed cure must select deletion")
    if row.get("remediation_policy") is not None:
        require(row["remediation_policy"] == policy, "mixed policy identifiers in source decisions")
    if policy == CURRENT_POLICY:
        require(row.get("remediation_policy") == CURRENT_POLICY, "decision row lacks the matching policy identifier")
        ordered = list(reversed(months))
        for key in ("has_derog_in_credit_window", "has_delinquency_in_credit_window", "has_post_derog_recovery_evidence", "manual_review_flag"):
            require(type(row[key]) is int and row[key] in (0, 1), f"invalid recorded flag for {key}")
        required = row["cure_consecutive_months_required"]
        require(type(required) is int and required > 0, "invalid cure threshold")
        streak = []
        cure_start = confirmed = None
        for period, original, _, _ in ordered:
            if period <= row["impact_end_date"]:
                continue
            if original == "0":
                streak.append(period)
                if len(streak) == required:
                    cure_start, confirmed = streak[0], period
                    break
            else:
                streak.clear()
        require(row["credit_cure_date"] == cure_start, "stored cure differs from consecutive post-issue original zeros")
        end_index = month_index(cure_start) - 1 if cure_start else newest_index
        require(row["credit_impact_start_date"] == row["impact_start_date"] and
                month_index(row["credit_impact_end_date"]) == end_index, "credit window differs from the issue and cure evidence")
        last_severe = max((period for period, original, _, inside in ordered if inside and original in "GHJKL"), default=None)
        evidence_end = confirmed or row["php_left_byte_date"]
        reversal = next((period for period, original, _, _ in ordered
                         if last_severe and last_severe < period <= evidence_end and original in "0123456"), None)
        require(row["last_severe_month"] == last_severe and row["severe_reversal_month"] == reversal,
                "severe or reversal-proxy month differs from the original history")
        numeric = any(inside and original in "123456" for _, original, _, inside in months)
        require(row["has_derog_in_credit_window"] == int(last_severe is not None)
                and row["has_delinquency_in_credit_window"] == int(numeric)
                and row["has_post_derog_recovery_evidence"] == int(reversal is not None),
                "stored severe, delinquency or reversal flags differ from original evidence")
        if last_severe:
            treatment = "FULL_DEROGATORY_PHP_CLEANUP" if reversal else "TRADELINE_DELETION"
        else:
            treatment = "SIMPLE_DELINQUENCY_PHP_CLEANUP" if numeric else "NO_IMPACT_CLEAN_PHP_HISTORY"
        require(row["remediation_treatment"] == treatment, "treatment differs from scoped original evidence")
        cleanup = treatment.endswith("PHP_CLEANUP")
        for period, before, after, inside in months:
            expected = "D" if cleanup and inside and before in "123456GHJKL" else before
            require(after == expected, f"proposed payment history lacks a matching treatment at {period}")
        closed = row["account_status_17a"] in ("13", "61", "62", "63", "64", "65")
        reason = None
        if not closed and not cure_start and treatment.endswith("PHP_CLEANUP"):
            reason = "INSUFFICIENT_POST_IMPACT_HISTORY" if later < required else "NO_CURE_OPEN_ACCOUNT"
        require((row["manual_review_flag"], row["manual_review_reason"]) == (int(reason is not None), reason),
                "ongoing review differs from cure, closure and treatment")
    # Old database and CSV exports predate explicit clear actions. A policy
    # receipt makes the new fields mandatory even when all three actions are false.
    for key in ("account_status_17a", "payment_rating_17b", "date_of_first_delinquency"):
        clear = row.get("clear_" + key)
        if clear is not None or policy in (SUPERSEDED_POLICY, CURRENT_POLICY):
            require(type(clear) is bool, f"missing or invalid clear action for {key}")
            if clear:
                require(row[key] is not None and row["remediated_" + key] is None,
                        f"clear action for {key} conflicts with the original or proposed value")
                require(row["remediation_treatment"] != "TRADELINE_DELETION",
                        f"deletion also requests a field clear for {key}")
    verify_fields(row, field_policy, require)
    return len(months)


def js_json(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=True).replace("<", r"\u003c")


EXPORT_BINDING = "metro2-full-export-v1"


def new_export_digest():
    return sha256((EXPORT_BINDING + "\n").encode("ascii"))


def bind_record(digest, kind, record):
    # A canonical record encoding also works for files transferred between Windows and Unix.
    encoded = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    digest.update(kind.encode("ascii") + b"\t" + encoded.encode("ascii") + b"\n")


def receipt_metadata(receipt, snapshot):
    field_policy = snapshot.get("accountFieldPolicy")
    if field_policy not in (None, PRIOR_FIELD_POLICY, FIELD_POLICY):
        raise ValueError(f"Unrecognized account-field policy {field_policy!r}.")
    if field_policy and snapshot.get('databasePolicy') != CURRENT_POLICY:
        raise ValueError("The recorded account-field policy requires the reversal-aware source policy.")
    for column_key, policy_key in [('hasDecisionPolicyColumn', 'databasePolicy'), ('hasFieldPolicyColumn', 'accountFieldPolicy')]:
        if column_key in snapshot and (type(snapshot[column_key]) is not bool or snapshot[column_key] != (snapshot.get(policy_key) is not None)):
            raise ValueError(f"Policy value {policy_key} differs from the source schema.")
    if receipt is not None and receipt.get("account_field_policy") != field_policy:
        raise ValueError("Study receipt and source database have different account-field policies.")
    stored = snapshot.get("databasePolicy")
    if stored is not None and stored not in (CURRENT_POLICY, SUPERSEDED_POLICY):
        raise ValueError(f"Unrecognized source policy {stored!r}.")
    supplied_id = snapshot.get("policyId")
    verified_id = receipt.get('module2_policy') if receipt else stored
    if supplied_id is not None and supplied_id != verified_id:
        raise ValueError("Claimed policy ID differs from the source policy and receipt.")
    # Derived metadata in a previously converted CSV must never authenticate a new export.
    for key in ("policyId", "policyStatus", "module2Sha256", "configuredModule2Sha256", "baselineCommit", "sourceCommit", "cureMonths", "exportIntegrity", "verifiedRun"):
        snapshot.pop(key, None)
    if receipt is None:
        if stored is None:
            return {"policyStatus": "unversioned"}
        return {"policyId": stored, "policyStatus": "current" if stored == CURRENT_POLICY else "superseded"}
    policy = receipt.get("module2_policy")
    if receipt.get("state") != "verified" or policy not in (CURRENT_POLICY, SUPERSEDED_POLICY):
        raise ValueError("Expected a verified study receipt for a supported policy.")
    if (stored is not None and stored != policy) or (policy == CURRENT_POLICY and stored is None):
        raise ValueError("Study receipt policy differs from the policy recorded by this database export.")
    if (receipt["database"], receipt["account_count"], receipt["postgres"]) != (
            snapshot["database"], snapshot["accountCount"], snapshot["postgresVersion"]):
        raise ValueError("Study receipt database, population or server version differs from this export.")
    if (policy == CURRENT_POLICY or "represented_months" in receipt) and receipt.get("represented_months") != snapshot["monthCount"]:
        raise ValueError("Study receipt monthly population differs from this export. Use the receipt for this cycle.")
    baseline = receipt["public_baseline_revision"]
    module_hash = receipt["module2_source_sha256"].lower()
    if not re.fullmatch(r"[0-9a-f]{40}", baseline) or not re.fullmatch(r"[0-9a-f]{64}", module_hash):
        raise ValueError("Study receipt lacks a valid baseline revision or Module 2 SHA-256.")
    configured_hash = receipt.get("module2_configured_sha256", module_hash).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", configured_hash):
        raise ValueError("Study receipt lacks a valid configured Module 2 SHA-256.")
    metadata = {"policyId": policy, "policyStatus": "current" if policy == CURRENT_POLICY else "superseded",
                "module2Sha256": module_hash, "configuredModule2Sha256": configured_hash, "baselineCommit": baseline}
    if "cure_months" in receipt:
        if type(receipt["cure_months"]) is not int or receipt["cure_months"] < 1:
            raise ValueError("Study receipt cure threshold must be a positive integer.")
        metadata["cureMonths"] = receipt["cure_months"]
    elif field_policy == FIELD_POLICY:
        raise ValueError("The current study receipt lacks a cure threshold.")
    # Preserve the native receipt claims needed to compare policies without exporting host or login details.
    # Older receipts and unreceipted histories remain usable as individual viewers.
    required_claims = ("database", "account_count", "represented_months", "cure_months", "module2_policy",
                       "account_field_policy", "module2_source_sha256", "module2_configured_sha256",
                       "manual_review_handoff_rows", "account_field_review_rows")
    if all(name in receipt for name in required_claims):
        metadata["verifiedRun"] = {name: receipt[name] for name in required_claims}
    return metadata


def pack(csv_path, output, kind, commit, receipt=None):
    previous = None
    count = month_count = 0
    cure_reviews = field_reviews = 0
    study_threshold = None
    digest = new_export_digest()
    alignment = Counter()
    output.parent.mkdir(parents=True, exist_ok=True)
    partial_path = None
    try:
        with csv_path.open(encoding="utf-8-sig", newline="") as source, tempfile.NamedTemporaryFile(
                dir=output.parent, mode="w", encoding="utf-8", newline="\n", delete=False) as target:
            partial_path = Path(target.name)
            reader = csv.DictReader(source, strict=True)
            if reader.fieldnames != ["row_json"]:
                raise ValueError("Expected one comma-delimited CSV column with header row_json.")
            meta = json.loads(next(reader)["row_json"])
            if meta.get("formatVersion") != 1 or not meta["accountCount"]:
                raise ValueError("The export metadata is missing or the final account table is empty.")
            for key in ('blueprintCount', 'inputCount', 'evaluationCount', 'accountCount', 'monthCount'):
                if type(meta[key]) is not int or meta[key] < 0:
                    raise ValueError(f"Invalid source count {key}.")
            if not (meta["inputCount"] == meta["evaluationCount"] == meta["accountCount"]):
                raise ValueError("Source counts disagree across the three Module 2 account tables.")
            meta.update(receipt_metadata(receipt, meta))
            target.write('window.METRO2_DATA={"accounts":[\n')
            for record in reader:
                if None in record or record["row_json"] is None:
                    raise ValueError("Malformed CSV record.")
                row = json.loads(record["row_json"])
                account = row["account"]
                if type(account) is not int or (previous is not None and account <= previous):
                    raise ValueError(f"Expected unique, ascending synthetic account IDs, got {account!r}.")
                previous = account
                if row.pop("sources_agree", None) is not True:
                    raise ValueError(f"Account {account}: input, window evaluation, details and final must agree")
                month_count += verify_account(row, meta.get("policyId"), meta.get("accountFieldPolicy"), meta.get("cureMonths"))
                if meta.get("policyId") == CURRENT_POLICY:
                    threshold = row["cure_consecutive_months_required"]
                    if study_threshold is not None and threshold != study_threshold:
                        raise ValueError(f"Account {account}: cure threshold differs from the rest of the study.")
                    study_threshold = threshold
                cure_reviews += row["manual_review_flag"] == 1
                field_reviews += row.get("account_field_review_reason") is not None
                alignment[row["blueprint_alignment"]] += 1
                if count:
                    target.write(",\n")
                bind_record(digest, "account", row)
                target.write(js_json(row))
                count += 1
            if (count, month_count) != (meta["accountCount"], meta["monthCount"]):
                raise ValueError(f"Read {count} accounts / {month_count} months; expected "
                                 f"{meta['accountCount']} / {meta['monthCount']}. "
                                 "Export the whole result set, including the last row.")
            if receipt and (meta["blueprintCount"] != count or alignment["matching fields"] != count):
                raise ValueError("The supplied study receipt requires a complete, matching Module 1 cohort.")
            native = meta.get("verifiedRun")
            if native:
                for key, observed in (("manual_review_handoff_rows", cure_reviews), ("account_field_review_rows", field_reviews)):
                    if type(native[key]) is not int or native[key] != observed:
                        raise ValueError(f"Study receipt {key} differs from the observed decisions.")
            if study_threshold is not None:
                meta["cureMonths"] = study_threshold
            meta["sourceKind"] = kind
            meta["label"] = "Controlled SQL replay" if kind == "replay" else "Retained synthetic database"
            meta["blueprintAlignment"] = dict(alignment)
            if commit:
                meta["sourceCommit"] = commit
            bind_record(digest, "metadata", meta)
            meta["exportIntegrity"] = {"format": EXPORT_BINDING, "sha256": digest.hexdigest()}
            target.write('],"meta":' + js_json(meta) + "};\n")
        os.chmod(partial_path, 0o644)
        os.replace(partial_path, output)
    finally:
        if partial_path:
            with suppress(FileNotFoundError):
                partial_path.unlink()
    print(f"Verified {count:,} accounts and {month_count:,} represented months. "
          f"Module 1 blueprint rows: {meta['blueprintCount']:,}.")
    print(f"Blueprint cross-check on final IDs: {dict(alignment)}")
    print(f"Saved {output.resolve()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--csv", type=Path, help="CSV exported from export_explorer.sql in DBeaver")
    inputs.add_argument("--database", default="metro2_lab", help="PostgreSQL database (default: metro2_lab)")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--user", help="PostgreSQL login used by your DBeaver connection")
    parser.add_argument("--psql", help="optional full path to psql.exe or psql")
    parser.add_argument("--output", type=Path, required=True, help="validated JavaScript data file")
    parser.add_argument("--source-kind", choices=["retained", "replay"], default="retained")
    parser.add_argument("--source-commit", help="source commit when independently known")
    parser.add_argument("--run-receipt", type=Path, help="verified run.json from this policy study")
    args = parser.parse_args()
    receipt = json.loads(args.run_receipt.read_text(encoding="utf-8-sig")) if args.run_receipt else None
    if args.csv:
        if args.csv.resolve() == args.output.resolve():
            parser.error("Choose an output file different from the input CSV.")
        pack(args.csv, args.output, args.source_kind, args.source_commit, receipt)
    else:
        with tempfile.TemporaryDirectory() as work:
            snapshot = Path(work) / "metro2.csv"
            export_csv(args, snapshot)
            pack(snapshot, args.output, args.source_kind, args.source_commit, receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, IndexError, StopIteration, csv.Error,
            subprocess.CalledProcessError) as exc:
        sys.exit(f"Export failed: {exc or 'incomplete input'}")
