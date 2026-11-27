"""Check that a continuing incident keeps its saved cure threshold and its previous results."""
import json
from pathlib import Path


def run_checks(client, fresh_database, invoke, study):
    """Use the real 1,000-account sample for account 57, then a small cohort for damaged-copy probes."""
    generator = next((study / "src").glob("module_01_*.sql")).read_text(encoding="utf-8")
    engine = next((study / "src").glob("module_02_*.sql")).read_text(encoding="utf-8")
    size_token = "5000000,   -- total number of synthetic accounts to generate"
    threshold_token = "3    -- conservative remediation-policy default"
    if generator.count(size_token) != 1 or engine.count(threshold_token) != 1:
        raise ValueError("Expected one sample size and cure-threshold configuration in the source templates.")
    sample = generator.replace(size_token, size_token.replace("5000000", "1000"))
    four = engine.replace(threshold_token, threshold_token.replace("3", "4"))
    reuse = "SET metro2.reuse_incident_dates='on';\n"
    tests = Path(__file__).resolve().parent
    results = {}

    def run(database, script):
        return invoke(client, database, sql=script)

    def fingerprint(database):
        result = {}
        for suffix in ("input", "window_eval", "php_detail", "final"):
            table = "module2.metro2_remediation_" + suffix
            sql = f"""SELECT count(*), md5(string_agg(to_jsonb(t)::text, '' ORDER BY to_jsonb(t)::text))
                      FROM {table} t"""
            result[suffix] = run(database, sql)
        return result

    def record(database):
        return json.loads(run(database, """SELECT to_jsonb(s) FROM (
            SELECT latest_doai, impact_start_date, impact_end_date, cure_consecutive_months_required,
                   credit_cure_date, manual_review_flag, manual_review_reason
            FROM module2.metro2_remediation_final WHERE account=57) s"""))

    def verify(database, threshold):
        receipt = json.loads(invoke(client, database, file=study / "tools/verify_study.sql",
                                    variables=["expected_accounts=1000", f"required_months={threshold}"]))
        if receipt["pass"] is not True:
            raise RuntimeError(f"Independent {threshold}-month verifier rejected the genuine cohort: {receipt}")
        return receipt["audit"]["monthly_records_compared"]

    def rejected(database, label, attempted):
        before = fingerprint(database)
        try:
            run(database, reuse + attempted)
        except RuntimeError as exc:
            diagnostic = str(exc).split("ERROR:")[-1].splitlines()[0]
            if "MODULE 2 INCIDENT REUSE FAILED" not in diagnostic or "threshold" not in diagnostic:
                raise
        else:
            raise RuntimeError(f"{label}: incompatible study was allowed to replace the previous decisions.")
        after = fingerprint(database)
        if after != before:
            raise RuntimeError(f"{label}: previous table fingerprints changed")
        results[label] = dict(rejected=True, diagnostic=diagnostic.strip(), before=before, after=after)

    with fresh_database(client) as database:
        run(database, sample)
        run(database, four)
        initial = record(database)
        assert initial["latest_doai"] == "2025-10-01" and initial["credit_cure_date"] is None
        assert initial["manual_review_flag"] == 1 and initial["cure_consecutive_months_required"] == 4
        assert (initial["impact_start_date"], initial["impact_end_date"]) == ("2024-05-01", "2025-06-01")
        before = fingerprint(database)
        run(database, reuse + four)
        assert fingerprint(database) == before and initial == record(database)
        results["same_cutoff_four"] = dict(record=initial, all_four_fingerprints=before)
        rejected(database, "wrong_three_month_file", engine)
        assert initial == record(database) and verify(database, 4) == 35395

        # October's fourth original zero first becomes visible at the November 1 DOAI.
        # Extend a single synthetic source; preserve the other 999 reporting cutoffs.
        run(database, """UPDATE module1.metro2_account_blueprint
            SET end_date=DATE '2025-11-01', months_reporting=months_reporting+1 WHERE account=57;
            UPDATE module1.metro2_status_history SET perf_age=perf_age+1 WHERE account=57;
            INSERT INTO module1.metro2_status_history (account, byte_date, perf_age, status)
            VALUES (57,DATE '2025-10-01',0,'0');
            UPDATE module1.metro2_final
            SET latest_doai=DATE '2025-11-01', php_left_byte_date=DATE '2025-10-01', full_php='0'||full_php
            WHERE account=57;""")
        run(database, reuse + four)
        advanced = record(database)
        assert (advanced["latest_doai"], advanced["credit_cure_date"], advanced["manual_review_flag"],
                advanced["cure_consecutive_months_required"]) == ("2025-11-01", "2025-07-01", 0, 4)
        assert (advanced["impact_start_date"], advanced["impact_end_date"]) == ("2024-05-01", "2025-06-01")
        results["one_account_advanced_under_four"] = dict(record=advanced, verified_original_months=verify(database, 4))

    with fresh_database(client) as database:
        run(database, sample)
        run(database, engine)
        three = record(database)
        assert (three["latest_doai"], three["credit_cure_date"], three["manual_review_flag"],
                three["cure_consecutive_months_required"]) == ("2025-10-01", "2025-07-01", 0, 3)
        results["independent_fresh_three"] = dict(record=three, verified_original_months=verify(database, 3))

    # Each stored decision layer must corroborate the original threshold on every account.
    # A declared, unsupported schema or a partly corrupted row must leave all existing bytes intact.
    with fresh_database(client) as database:
        invoke(client, database, file=tests / "policy_cases.sql")
        for suffix in ("window_eval", "final"):
            table = "module2.metro2_remediation_" + suffix
            for variant, edit in (
                ("different_one_account", f"UPDATE {table} SET cure_consecutive_months_required=2 WHERE account=10029"),
                ("unknown_one_account", f"UPDATE {table} SET cure_consecutive_months_required=NULL WHERE account=10029"),
                ("missing_saved_column", f"ALTER TABLE {table} DROP COLUMN cure_consecutive_months_required"),
            ):
                run(database, four)
                run(database, edit)
                rejected(database, suffix + "_" + variant, four)
        run(database, four)
        for suffix in ("window_eval", "final"):
            run(database, f"UPDATE module2.metro2_remediation_{suffix} SET cure_consecutive_months_required=3 WHERE account=10029")
        rejected(database, "same_corrupt_threshold_on_one_member_of_both_copies", four)
    return results
