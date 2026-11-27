"""Independently reconcile the human-review CSV against explicit, dated fixture histories."""
import csv
from datetime import date
from io import StringIO
import json
import os
from pathlib import Path
import subprocess

TOOLS = Path(__file__).resolve().parent.parent / "tools"
COLUMNS = (
    "account review_reason review_action bank_impact_start bank_impact_end credit_impact_start "
    "credit_impact_through reporting_as_of latest_history_month original_status_17a original_php_newest_first "
    "post_impact_months current_streak_start current_streak_months cure_months_required next_history_month "
    "proposed_treatment proposed_php_newest_first internal_fields_to_clear original_payment_rating_17b "
    "original_dofd proposed_effective_status_17a proposed_effective_rating_17b proposed_effective_dofd"
).split()


def export_rows(client, database, legacy=False, changes=None):
    command = client + ["--no-password", "--dbname", database, "--csv", "--pset=tuples_only=off"]
    command.extend(["-c", "BEGIN" if legacy or changes else "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"])
    if changes:
        command.extend(["-c", changes])
    if legacy:
        # Re-create the earlier retained table's columns inside a rolled-back test transaction.
        command.extend(["-c", """
            ALTER TABLE module2.metro2_remediation_final
                DROP COLUMN clear_account_status_17a, DROP COLUMN clear_payment_rating_17b,
                DROP COLUMN clear_date_of_first_delinquency
        """])
    command.extend(["-f", str(TOOLS / "export_manual_review.sql"), "-c", "ROLLBACK"])
    exported = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace",
                              env=dict(os.environ, PGCLIENTENCODING="UTF8"))
    if exported.returncode:
        raise RuntimeError(exported.stderr.strip())
    reader = csv.DictReader(StringIO(exported.stdout, newline=""))
    if reader.fieldnames != COLUMNS:
        raise RuntimeError(f"Review CSV columns differ from the contract: {reader.fieldnames!r}")
    return list(reader)


def period(offset):
    """Dates in policy_cases.sql start at January 2020 and advance by one month."""
    return date(2020 + offset // 12, 1 + offset % 12, 1).isoformat()


def expect(row, expected):
    for field, value in expected.items():
        if row[field] != str(value):
            raise RuntimeError(f"Review account {row['account']}, {field}: expected {value!r}; got {row[field]!r}")


def compare_baseline(rows, fixtures):
    # Fixed policy_cases.sql expectations select the eligible IDs independently of the queue.
    by_id = {str(case["account"]): case for case in fixtures if case["review_reason"] is not None}
    expected_ids = sorted(by_id, key=lambda key: (period(len(by_id[key]["original"])), int(key)))
    if [row["account"] for row in rows] != expected_ids:
        raise RuntimeError("Review CSV membership, row uniqueness or next-month/account ordering differs from fixtures.")
    for row in rows:
        case = by_id[row["account"]]
        history = case["original"]
        end = date.fromisoformat(case["bank_end"])
        end_index = (end.year - 2020) * 12 + end.month - 1
        later = history[end_index + 1:]
        streak = len(later) - len(later.rstrip("0"))
        status = {"0": "11", "L": "97", "2": "78"}.get(history[-1], "71")
        expect(row, {
            "review_reason": case["review_reason"],
            "bank_impact_start": case["bank_start"], "bank_impact_end": case["bank_end"],
            "credit_impact_start": case["bank_start"], "credit_impact_through": period(len(history) - 1),
            "latest_history_month": period(len(history) - 1), "reporting_as_of": period(len(history)),
            "next_history_month": period(len(history)), "original_status_17a": status,
            "original_payment_rating_17b": "0", "original_dofd": period(0) if history in ("1D", "112") else "",
            "proposed_effective_status_17a": "71" if history == "1D" else "11",
            "proposed_effective_rating_17b": "0", "proposed_effective_dofd": period(0) if history == "1D" else "",
            "original_php_newest_first": history[::-1], "proposed_php_newest_first": case["revised"][::-1],
            "proposed_treatment": case["treatment"], "cure_months_required": 3, "post_impact_months": len(later),
            "current_streak_months": streak, "current_streak_start": period(len(history) - streak) if streak else "",
        })
        clears = [v.strip() for v in row["internal_fields_to_clear"].split(",") if v.strip()]
        expected_clears = {"112": ["DOFD"]}.get(history, [])
        if clears != expected_clears:
            raise RuntimeError(f"Unexpected explicit clear instructions for review account {row['account']}: {clears!r}")
    actions = {row["review_reason"]: row["review_action"].strip() for row in rows
               if row["proposed_treatment"] == "SIMPLE_DELINQUENCY_PHP_CLEANUP"}
    if set(actions) != {"INSUFFICIENT_POST_IMPACT_HISTORY", "NO_CURE_OPEN_ACCOUNT"} or any(
            not row["review_action"].strip() for row in rows) or len(set(actions.values())) != 2:
        raise RuntimeError("The two review reasons must provide distinct, nonempty reviewer instructions.")
    for row in rows:
        case = by_id[row["account"]]
        if case["treatment"] != "FULL_DEROGATORY_PHP_CLEANUP":
            continue
        start = date.fromisoformat(case["bank_start"])
        start_index = 12 * (start.year - 2020) + start.month - 1
        original = case["original"]
        major = max(i for i in range(start_index, len(original)) if original[i] in "GHJKL")
        reversal = next(i for i in range(major + 1, len(original)) if original[i] in "0123456")
        if (f"Severe month {period(major)[:7]}. Reversal proxy {period(reversal)[:7]}." not in row["review_action"]
                or "servicing" not in row["review_action"]):
            raise RuntimeError(f"Missing dated severe/reversal evidence in handoff for account {row['account']}.")


def run_checks(client, database, execute, module, tests):
    execute(file=tests / "policy_cases.sql")
    execute(file=module)
    fixtures = json.loads(execute(sql="SELECT jsonb_agg(to_jsonb(c)) FROM regression.policy_cases c"))
    rows = export_rows(client, database)
    compare_baseline(rows, fixtures)
    legacy_rows = export_rows(client, database, legacy=True)
    if [r["account"] for r in legacy_rows] != [r["account"] for r in rows] or any(
        r["internal_fields_to_clear"] != "UNAVAILABLE_IN_SOURCE"
        or not r["review_action"].startswith("Review the legacy decision under the current study policy")
        for r in legacy_rows
    ):
        raise RuntimeError("The legacy handoff must preserve stored referrals and disclose unavailable clear flags.")
    for row in legacy_rows:
        expect(row, {"proposed_effective_status_17a": "11" if row["account"] in {"10029", "190003"} else "",
                     "proposed_effective_rating_17b": "", "proposed_effective_dofd": ""})
    previous = export_rows(client, database, changes="""
        ALTER TABLE module2.metro2_remediation_window_eval DROP COLUMN remediation_policy,
            DROP COLUMN last_severe_month, DROP COLUMN severe_reversal_month
    """)
    if [r["account"] for r in previous] != [r["account"] for r in rows] or any(
        "archived decision" not in r["review_action"] for r in previous
    ):
        raise RuntimeError("Unversioned decisions with explicit clears need archived provenance in the handoff.")
    # Control retained nonnull source fields and known explicit replacements in both schema generations.
    changes = """
        UPDATE module2.metro2_remediation_final SET date_of_first_delinquency='2019-12-01' WHERE account=170086;
        UPDATE module2.metro2_remediation_final SET remediated_account_status_17a='83',
            remediated_payment_rating_17b='5', remediated_date_of_first_delinquency='2020-02-01' WHERE account=80010;
    """
    for legacy in (False, True):
        revised = {r["account"]: r for r in export_rows(client, database, legacy=legacy, changes=changes)}
        expect(revised["170086"], {"original_dofd": "2019-12-01",
                                   "proposed_effective_dofd": "" if legacy else "2019-12-01"})
        expect(revised["80010"], {"proposed_effective_status_17a": "83",
                                  "proposed_effective_rating_17b": "5", "proposed_effective_dofd": "2020-02-01"})

    # One new two-zero ending, one streak straddling the bank end, and one otherwise eligible closed account.
    execute(sql="""
        UPDATE module1.metro2_status_history SET status='0'
        WHERE (account=170086 AND byte_date='2020-04-01') OR (account=80010 AND byte_date='2020-03-01');
        UPDATE module1.metro2_final SET full_php='00212' WHERE account=170086;
        UPDATE module1.metro2_final SET full_php='001L' WHERE account=80010;
        UPDATE module1.metro2_final SET account_status_17a='13', date_closed=latest_doai WHERE account=190003;
    """)
    execute(file=module)
    altered = export_rows(client, database)
    by_id = {row["account"]: row for row in altered}
    expected = {row["account"] for row in rows} - {"190003"}
    if len(altered) != len(expected) or set(by_id) != expected:
        raise RuntimeError("Closing one review account should remove exactly its row.")
    expect(by_id["170086"], {"current_streak_months": 2, "current_streak_start": "2020-04-01",
                             "post_impact_months": 3, "next_history_month": "2020-06-01"})
    expect(by_id["80010"], {"current_streak_months": 1, "current_streak_start": "2020-04-01",
                            "post_impact_months": 1, "next_history_month": "2020-05-01"})

    setting = "3    -- conservative remediation-policy default"
    native = module.read_text(encoding="utf-8")
    if native.count(setting) != 1:
        raise RuntimeError("Cannot locate the candidate's cure threshold for handoff controls.")
    execute(sql=native.replace(setting, "4" + setting[1:]))
    threshold_rows = {row["account"]: row for row in export_rows(client, database)}
    expect(threshold_rows["170086"], {"cure_months_required": 4, "current_streak_months": 2,
                                      "review_reason": "INSUFFICIENT_POST_IMPACT_HISTORY"})

    # The zero-referral scenario uses a real rebuild after closing every synthetic account.
    execute(sql="UPDATE module1.metro2_final SET account_status_17a='13', date_closed=latest_doai")
    execute(file=module)
    if export_rows(client, database):
        raise RuntimeError("A population with zero review referrals should export column headers only.")
    print(f"PASS  Review CSV: {len(rows)} exact unique fixture accounts, both reasons, original evidence, "
          "zero/one/two-month streaks, nondefault threshold, closed/deleted exclusions, legacy and empty exports")
