"""Replay one incident as original reporting months arrive; retain observed decisions for inspection."""
import json
from datetime import date

from review_handoff_controls import export_rows
from owner_case_controls import run_checks as owner_case_checks


ACCOUNT = 1201  # On fresh generation, this account's incident changes as its source history grows.
POLICY = "REVERSAL_AWARE_SEVERE_V2"
DELETE = "TRADELINE_DELETION"
CLEAN = "FULL_DEROGATORY_PHP_CLEANUP"
SHORT = "INSUFFICIENT_POST_IMPACT_HISTORY"
OPEN = "NO_CURE_OPEN_ACCOUNT"


def month(number):
    return date(2024, number, 1).isoformat() if number else None


# Each tuple specifies the new original mark, treatment, proposed history (oldest first),
# latest applicable severe month, first original reversal month, review, cure start and impact end.
PRIMARY = (
    ("L", DELETE, "L",          1, None, None,  None, 1),
    ("5", CLEAN,  "DD",         1, 2,    SHORT, None, 2),
    ("1", CLEAN,  "DDD",        1, 2,    SHORT, None, 3),
    ("2", CLEAN,  "DDDD",       1, 2,    OPEN,  None, 4),
    ("J", DELETE, "L512J",      5, None, None,  None, 5),
    ("4", CLEAN,  "DDDDDD",     5, 6,    OPEN,  None, 6),
    ("0", CLEAN,  "DDDDDD0",    5, 6,    OPEN,  None, 7),
    ("0", CLEAN,  "DDDDDD00",   5, 6,    OPEN,  None, 8),
    ("0", CLEAN,  "DDDDDD000",  5, 6,    None,  7,    6),
    ("H", CLEAN,  "DDDDDD000H", 5, 6,    None,  7,    6),
)
UNAVAILABLE = (
    ("L", DELETE, "L",       1, None, None, None, 1),
    ("D", DELETE, "LD",      1, None, None, None, 2),
    ("D", DELETE, "LDD",     1, None, None, None, 3),
    ("0", CLEAN,  "DDD0",    1, 4,    OPEN, None, 4),
    ("0", CLEAN,  "DDD00",   1, 4,    OPEN, None, 5),
    ("0", CLEAN,  "DDD000",  1, 4,    None, 4,    3),
    ("L", CLEAN,  "DDD000L", 1, 4,    None, 4,    3),
)


def add_original_month(execute, history):
    """Only this prefix exists in the study database. Append exactly one original month."""
    latest = history[-1]
    status = dict(zip("0123456GHJKL", ("11","71","78","80","82","83","84","93","94","95","96","97"))).get(latest)
    rating = latest if latest in "0123456GL" else None
    source = dict(
        account=ACCOUNT, profile_type="ROLLING_FIXTURE", full_php=history[::-1], php_right_byte_date=month(1),
        php_left_byte_date=month(len(history)), latest_doai=month(len(history)+1), account_status_17a=status,
        payment_rating_17b=rating,
    )
    payload = json.dumps(source)
    execute(sql=f"""
        UPDATE module1.metro2_account_blueprint SET history='{history}' WHERE account={ACCOUNT};
        INSERT INTO module1.metro2_status_history (account, byte_date, perf_age, status)
        VALUES ({ACCOUNT}, '{month(len(history))}', {len(history)}, '{latest}');
        DELETE FROM module1.metro2_final WHERE account={ACCOUNT};
        INSERT INTO module1.metro2_final SELECT * FROM jsonb_populate_record(NULL::module1.metro2_final, '{payload}');
    """)


def snapshot(execute):
    return json.loads(execute(sql="""
        SELECT to_jsonb(s) FROM (
            SELECT f.account, w.remediation_policy, f.impact_start_date AS bank_start, f.impact_end_date AS bank_end,
                   f.php_left_byte_date AS latest_month, f.latest_doai AS reporting_as_of,
                   reverse(f.full_php) AS original_history, f.credit_impact_start_date AS credit_start,
                   f.credit_impact_end_date AS credit_end, w.last_severe_month, w.severe_reversal_month,
                   f.credit_cure_date AS cure_start,
                   (f.credit_cure_date + make_interval(months => f.cure_consecutive_months_required-1))::date AS cure_confirmed,
                   f.remediation_treatment AS treatment, f.manual_review_flag AS review, f.manual_review_reason AS reason,
                   hist.proposed_history, hist.monthly_edits, f.remediated_account_status_17a AS replacement_17a,
                   f.remediated_full_php AS sparse_replacement_php
            FROM module2.metro2_remediation_final f JOIN module2.metro2_remediation_window_eval w USING (account)
            JOIN LATERAL (
                SELECT string_agg(m.remediated_status, '' ORDER BY m.byte_date) AS proposed_history,
                       count(*) FILTER (WHERE m.original_status IS DISTINCT FROM m.remediated_status) AS monthly_edits
                FROM module2.metro2_remediation_php_detail m WHERE m.account=f.account
            ) hist ON true
        ) s
    """))


def run_series(client, database, execute, module, verifier, series):
    execute(sql=f"""
        TRUNCATE module1.metro2_status_history, module1.metro2_final, module1.metro2_account_blueprint;
        INSERT INTO module1.metro2_account_blueprint VALUES ({ACCOUNT}, '');
    """)
    observed = []
    history = ""
    for mark, treatment, proposed, severe, reversal, reason, cure, credit_end in series:
        history += mark
        n = len(history)
        add_original_month(execute, history)
        mode = "off" if n == 1 else "on"
        execute(sql=f"SET metro2.reuse_incident_dates='{mode}';\n" + module)
        row = snapshot(execute)
        expected = dict(
            account=ACCOUNT, remediation_policy=POLICY, bank_start=month(1), bank_end=month(1),
            latest_month=month(n), reporting_as_of=month(n+1), original_history=history,
            credit_start=month(1), credit_end=month(credit_end), last_severe_month=month(severe),
            severe_reversal_month=month(reversal), cure_start=month(cure), cure_confirmed=month(cure+2) if cure else None,
            treatment=treatment, reason=reason, review=int(reason is not None), proposed_history=proposed,
            monthly_edits=sum(a != b for a, b in zip(history, proposed)),
            sparse_replacement_php=proposed[::-1] if proposed != history else None,
        )
        for key, value in expected.items():
            if row[key] != value:
                raise RuntimeError(f"Cutoff {history}, {key}: expected {value!r}, got {row[key]!r}.")
        if (row["replacement_17a"] == "DA") != (treatment == DELETE):
            raise RuntimeError(f"Cutoff {history}: unexpected whole-tradeline instruction.")
        queue = export_rows(client, database)
        if [r["account"] for r in queue] != ([str(ACCOUNT)] if reason else []):
            raise RuntimeError(f"Cutoff {history}: expected exactly the current referral in the handoff.")
        audit = json.loads(execute(file=verifier, variables=["expected_accounts=1", "required_months=3"]))
        if audit["pass"] is not True:
            raise RuntimeError(f"Cutoff {history}: independent study audit failed: {audit!r}")
        observed.append(row)
    return observed


def reuse_failures(execute, module):
    table = "module2.metro2_remediation_input"
    baseline = "regression.saved_incident"
    execute(sql=f"CREATE TABLE {baseline} AS TABLE {table}")
    tests = {
        "missing incident account": f"DELETE FROM {table}",
        "extra incident account": f"INSERT INTO {table} VALUES (99999,'2024-01-01','2024-01-01')",
        "duplicate incident account": f"INSERT INTO {table} SELECT * FROM {table}",
        "null start": f"UPDATE {table} SET impact_start_date=NULL",
        "null end": f"UPDATE {table} SET impact_end_date=NULL",
        "start after end": f"UPDATE {table} SET impact_start_date='2024-02-01'",
        "start within a month": f"UPDATE {table} SET impact_start_date='2024-01-02',impact_end_date='2024-02-01'",
        "end within a month": f"UPDATE {table} SET impact_end_date='2024-01-02'",
        "start before history": f"UPDATE {table} SET impact_start_date='2023-12-01'",
        "end after history": f"UPDATE {table} SET impact_end_date='2024-08-01'",
        "missing incident table": f"ALTER TABLE {table} RENAME TO test_saved_input",
    }
    relations = ("metro2_remediation_input", "metro2_remediation_window_eval",
                 "metro2_remediation_php_detail", "metro2_remediation_final")

    def fingerprint():
        results = []
        for name in relations:
            relation = "module2." + name
            if execute(sql=f"SELECT to_regclass('{relation}') IS NULL") == "t":
                results.append(None)
            else:
                results.append(execute(sql=f"""
                    SELECT count(*), md5(string_agg(to_jsonb(r)::text,'' ORDER BY to_jsonb(r)::text))
                    FROM {relation} r
                """))
        return results

    for label, alteration in tests.items():
        execute(sql=alteration)
        before = fingerprint()
        execute(sql="SET metro2.reuse_incident_dates='on';\n" + module, expect_error="MODULE 2 INCIDENT REUSE FAILED")
        if fingerprint() != before:
            raise RuntimeError(f"A failed same-incident replay altered saved outputs: {label}.")
        if label == "missing incident table":
            execute(sql=f"ALTER TABLE module2.test_saved_input RENAME TO metro2_remediation_input")
        else:
            execute(sql=f"TRUNCATE {table}; INSERT INTO {table} TABLE {baseline}")
    return list(tests)


def run_checks(client, database, execute, module_path, tests, verifier):
    execute(file=tests / "policy_cases.sql")
    module = module_path.read_text(encoding="utf-8")
    primary = run_series(client, database, execute, module, verifier, PRIMARY)
    # Prove same-incident mode mattered: ordinary fresh generation for ten
    # represented months yields a different bank start and end for this test ID.
    execute(sql="SET metro2.reuse_incident_dates='off';\n" + module)
    dates = execute(sql="SELECT impact_start_date,impact_end_date FROM module2.metro2_remediation_input")
    if dates != "2024-02-01|2024-08-01":
        raise RuntimeError(f"Expected independently calculated fresh incident Feb–Aug 2024, saw {dates!r}.")
    gap = run_series(client, database, execute, module, verifier, UNAVAILABLE)
    failures = reuse_failures(execute, module)
    print(f"PASS  Rolling study: {len(primary)+len(gap)} native as-of snapshots, fixed incident, "
          f"severe recurrence, reversal, cure and {len(failures)} fail-closed incident controls")
    generator = module_path.parent / "module_01_metro2_synthetic_portfolio_generator.sql"
    owner_case = owner_case_checks(client, database, execute, module, verifier, generator)
    return {"policy": POLICY, "account": ACCOUNT, "primary": primary, "missing_history": gap, "account_17899": owner_case,
            "deliberate_incident_errors_preserving_prior_outputs": failures}
