"""Reconcile four published cases using only the Python standard library.

From a Pages checkout: python tests/verify_featured_cases.py --output featured-cases.json
For standalone study kits, pass --replay and --scale paths to the corresponding
1,000- and 25,000-account build_explorer exports or to their Pages data.js files.
"""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
POLICY = "REVERSAL_AWARE_SEVERE_V2"
FIELD_POLICY = "EVIDENCE_SCOPED_FIELDS_V2"
LATE = "123456"
SEVERE = "GHJKL"
# Pin the article's original source histories (newest first) and bank incident anchors.
# Derive the corrections, cure, reversal, dates, field actions and review from those inputs below.
FEATURES = {
    25000: {
        24064: ("2024-05-01", "2023-12-01", "2024-01-01", "654321" + "0"*7),
        17899: ("2025-02-01", "2025-01-01", "2025-01-01", "11" + "0"*7),
    },
    1000: {
        175: ("2025-10-01", "2024-04-01", "2025-03-01", "00000121" + "0"*41),
        327: ("2025-10-01", "2024-12-01", "2025-01-01", "012345L54321" + "0"*10),
    },
}


def check(actual, expected, label):
    if actual != expected:
        raise ValueError(f"{label}: expected {expected!r}, got {actual!r}")


def shift(value, offset):
    d = date.fromisoformat(value)
    check(d.day, 1, "monthly key day")
    y, m = divmod(d.year*12 + d.month-1 + offset, 12)
    return date(y, m+1, 1).isoformat()


def read_cases(path, cohort):
    raw = path.read_bytes()
    prefix, delimiter, body = raw.decode("utf-8-sig").partition("=")
    if not delimiter or prefix not in {"window.METRO2_PACKED", "window.METRO2_DATA"}:
        raise ValueError(f"{path}: expected a study explorer export")
    # Parse just the JSON literal. Never execute the export as JavaScript.
    literal = body.strip()
    content = json.loads(literal[:-1] if literal.endswith(";") else literal)
    metadata = content["meta"]
    check(metadata["accountCount"], cohort, "source cohort")
    check(metadata["databasePolicy"], POLICY, "database policy")
    check(metadata["policyId"], POLICY, "export policy")
    check(metadata["accountFieldPolicy"], FIELD_POLICY, "current field evidence model")
    ids = FEATURES[cohort]
    if prefix == "window.METRO2_PACKED":
        entries = content["rows"]
        keys = content["fields"]
        account_index = keys.index("account")
        books = content["dictionaries"]
        selected = [{key: books[key][v] if v is not None and key in books else v
                     for key, v in zip(keys, row)} for row in entries if row[account_index] in ids]
    else:
        entries = content["accounts"]
        selected = [row for row in entries if row["account"] in ids]
    check(len(entries), cohort, "number of exported accounts")
    check(sorted(r["account"] for r in selected), sorted(ids), "selected unique accounts")
    resolved = path.resolve()
    try:
        name = resolved.relative_to(ROOT).as_posix()
    except ValueError:
        name = Path(path.parent.name, path.name).as_posix()
    return selected, {"file": name, "sha256": hashlib.sha256(raw).hexdigest(), "database": metadata["database"],
                      "accounts": cohort, "source_months": metadata["monthCount"], "policy": metadata["policyId"],
                      "account_field_policy": FIELD_POLICY, "module2_sha256": metadata["module2Sha256"]}


def reconcile(r, cohort):
    account = r["account"]
    report, start, end, original = FEATURES[cohort][account]
    check((r["latest_doai"], r["impact_start_date"], r["impact_end_date"], r["full_php"]),
          (report, start, end, original), f"account {account} published input")
    check(r["date_closed"], None, "featured open account")
    check(r["remediation_policy"], POLICY, "account policy")
    check(r["account_field_policy"], FIELD_POLICY, "account field policy")
    check(r["account_field_review_reason"], None, "featured field review")
    check(r["cure_consecutive_months_required"], 3, "cure months")
    latest = shift(report, -1)
    first = shift(report, -len(original))
    check((r["php_right_byte_date"], r["php_left_byte_date"]), (first, latest), "PHP bounds")
    months = [(shift(first, i), mark) for i, mark in enumerate(reversed(original))]
    after = [(d, v) for d, v in months if d > end]
    later_bytes = "".join(v for _, v in after)
    idx = later_bytes.find("000")
    cure = after[idx][0] if idx >= 0 else None
    confirm = shift(cure, 2) if cure else None
    through = shift(cure, -1) if cure else latest
    inside = [(d, v) for d, v in months if start <= d <= through]
    severe = next((d for d, mark in reversed(inside) if mark in SEVERE), None)
    reversal = next((d for d, mark in months if severe and severe < d <= (confirm or latest)
                     and mark in "0123456"), None)
    if severe:
        treatment = "FULL_DEROGATORY_PHP_CLEANUP" if reversal else "TRADELINE_DELETION"
    elif any(v in LATE for _, v in inside):
        treatment = "SIMPLE_DELINQUENCY_PHP_CLEANUP"
    else:
        treatment = "NO_IMPACT_CLEAN_PHP_HISTORY"
    suppress = {"FULL_DEROGATORY_PHP_CLEANUP": LATE+SEVERE, "SIMPLE_DELINQUENCY_PHP_CLEANUP": LATE}.get(treatment, "")
    reason = None
    if suppress and not cure:
        reason = "INSUFFICIENT_POST_IMPACT_HISTORY" if len(after) < 3 else "NO_CURE_OPEN_ACCOUNT"
    details = [[d, v, "D" if start <= d <= through and v in suppress else v, int(start <= d <= through)]
               for d, v in months]
    revised = "".join(row[2] for row in reversed(details))
    changed = [[d, v, new] for d, v, new, _ in details if v != new]
    check((r["credit_impact_start_date"], r["credit_impact_end_date"], r["credit_cure_date"],
           r["last_severe_month"], r["severe_reversal_month"]), (start, through, cure, severe, reversal), "dated decision")
    check((r["remediation_treatment"], r["manual_review_flag"], r["manual_review_reason"], r["post_impact_month_count"]),
          (treatment, int(reason is not None), reason, len(after)), "treatment and review")
    check(r["remediated_full_php"], revised if revised != original else None, "written newest-first PHP")
    if "months" in r:
        check(r["months"], list(reversed(details)), "explicit account-month rows")

    # All four cases are open, and their latest original code is ordinary numeric.
    status_map = dict(zip("0123456", ("11","71","78","80","82","83","84")))
    latest_code = original[0]
    source_status = status_map[latest_code]
    if latest_code == "0":
        source_date = None
    else:
        pos = 0
        while pos < len(original) and original[pos] in LATE:
            pos += 1
        source_date = shift(latest, 1-pos)
    check((r["account_status_17a"], r["payment_rating_17b"], r["date_of_first_delinquency"]),
          (source_status, latest_code, source_date), "observed account fields")
    current = "0" if revised[0] == "D" and original[0] != "D" else revised[0]
    check(current, "0", "featured latest effective synthetic performance")
    check((r["remediated_account_status_17a"], r["remediated_payment_rating_17b"], r["remediated_date_of_first_delinquency"],
           r["clear_account_status_17a"], r["clear_payment_rating_17b"], r["clear_date_of_first_delinquency"]),
          ("11" if source_status != "11" else None, "0" if latest_code != "0" else None, None,
           False, False, source_date is not None), "sparse field replacements and explicit clears")
    return {
        "source_cohort": cohort, "account": account, "reporting_date_field24": report,
        "account_field_policy": FIELD_POLICY, "account_field_review_reason": r["account_field_review_reason"],
        "latest_php_month": latest, "oldest_php_month": first, "represented_months": len(months),
        "bank_start": start, "bank_end": end, "bank_end_original_mark": dict(months)[end],
        "credit_impact_start": start, "credit_impact_through": through, "cure_start": cure, "cure_confirmed_through": confirm,
        "first_reporting_date_with_cure_evidence": shift(confirm, 1) if confirm else None,
        "latest_severe_month": severe, "first_subsequent_numeric_month": reversal,
        "treatment": treatment, "monthly_review_flag": int(reason is not None), "review_reason": reason,
        "original_post_bank_months": len(after), "trailing_post_bank_current_months": len(later_bytes)-len(later_bytes.rstrip("0")),
        "next_php_month_if_under_review": report if reason else None,
        "next_reporting_date_if_under_review": shift(report, 1) if reason else None,
        "original_php_newest_first": original, "proposed_php_newest_first": revised,
        "changes_month_original_proposed": changed, "changed_months": len(changed),
        "changes_after_bank_end": sum(d > end for d, _, _ in changed),
        "pre_issue_adverse_months_preserved": [[d, v] for d, v, new, _ in details if d < start and v in LATE+SEVERE and v == new],
        "status_17a_at_reporting_date": {"original": source_status, "proposed": "11"},
        "synthetic_rating_17b": {"original": latest_code, "proposed": "0"},
        "internal_field25": {"original": source_date, "proposed": None,
                             "action": "clear" if source_date is not None else "retain absent"},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, default=ROOT/"docs"/"data.js", help="1,000-account export")
    parser.add_argument("--scale", type=Path, default=ROOT/"docs"/"scale"/"data.js", help="25,000-account export")
    parser.add_argument("--output", type=Path, help="write JSON here (default: stdout)")
    args = parser.parse_args()
    results = {}
    sources = []
    for cohort, path in ((1000, args.replay), (25000, args.scale)):
        rows, metadata = read_cases(path, cohort)
        sources.append(metadata)
        for row in rows:
            results[(cohort, row["account"])] = reconcile(row, cohort)
    order = [(25000,24064), (1000,175), (1000,327), (25000,17899)]
    receipt = {"pass": True, "scope": "Four featured synthetic accounts in their specified replay cohorts",
               "sources": sources, "cases": [results[key] for key in order]}
    output = json.dumps(receipt, indent=2) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        sys.exit("FAIL  " + str(error))
