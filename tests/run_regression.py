"""Run the native PostgreSQL regression suite in automatically created test databases."""
import argparse
import csv
import getpass
from io import StringIO
import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
import uuid
from contextlib import contextmanager
from pathlib import Path

from generator_controls import run_checks as generator_checks
from field25_controls import run_checks as field25_checks
from review_handoff_controls import run_checks as handoff_checks
from rolling_review_controls import run_checks as rolling_checks
from audit_counterexamples import run_checks as independent_checks

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
MODULE1 = ROOT / "src" / "module_01_metro2_synthetic_portfolio_generator.sql"
MODULE2 = ROOT / "src" / "module_02_metro2_remediation_engine.sql"


def psql_command(args):
    executable = args.psql or shutil.which("psql")
    if not executable and os.name == "nt":
        postgres = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "PostgreSQL"
        found = [p for p in postgres.glob("*/bin/psql.exe") if p.parents[1].name.isdigit()]
        if found:
            executable = max(found, key=lambda p: int(p.parents[1].name))
    if not executable:
        raise RuntimeError("Supply --psql with the path to the PostgreSQL client.")
    command = [str(executable), "-X", "-qAt", "--set=ON_ERROR_STOP=1"]
    for option in ("host", "port", "user"):
        value = getattr(args, option)
        if value:
            command.extend(["--username" if option == "user" else "--" + option, str(value)])
    return command


def invoke(client, database, sql=None, file=None, variables=(), expect_error=None):
    command = client + ["--no-password", "--dbname", database]
    for variable in variables:
        command += ["--set", variable]
    command += ["--file", str(file) if file else "-"]
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    result = subprocess.run(command, input=sql, capture_output=True, encoding="utf-8",
                            errors="replace", env=env)
    if expect_error:
        if result.returncode == 0 or expect_error not in result.stderr:
            raise RuntimeError(f"Expected database error {expect_error!r}; got {result.stderr.strip()!r}.")
    elif result.returncode:
        raise RuntimeError(result.stderr.strip() or f"psql ended with code {result.returncode}.")
    return result.stdout.strip()


@contextmanager
def fresh_database(client):
    # Test database names are generated here and cannot be supplied by a caller.
    name = "metro2_regression_" + uuid.uuid4().hex
    invoke(client, "postgres", sql=f"CREATE DATABASE {name} TEMPLATE template0;")
    try:
        yield name
    finally:
        invoke(client, "postgres", sql=f"DROP DATABASE {name};")


def check_engine_rollbacks(client, database):
    engine = MODULE2.read_text(encoding="utf-8")
    transaction = "BEGIN ISOLATION LEVEL REPEATABLE READ;"
    if engine.count(transaction) != 1:
        raise RuntimeError("Cannot locate the Module 2 transaction start for negative controls.")
    tables = ("metro2_remediation_input", "metro2_remediation_window_eval",
              "metro2_remediation_php_detail", "metro2_remediation_final")

    def fingerprint():
        return [invoke(client, database, sql=(
            f"SELECT count(*) || '/' || md5(string_agg(to_jsonb(t)::text, '' ORDER BY to_jsonb(t)::text)) "
            f"FROM module2.{table} AS t"
        )) for table in tables]

    original_outputs = fingerprint()
    account = 10029
    feb = f"account={account} AND byte_date='2020-02-01'"
    history = "module1.metro2_status_history"
    summary = "module1.metro2_final"
    malformed = {
        "missing month": f"DELETE FROM {history} WHERE {feb}",
        "not a month start": f"UPDATE {history} SET byte_date=byte_date+1 WHERE {feb}",
        "null original status": f"UPDATE {history} SET status=NULL WHERE {feb}",
        "duplicate month": f"INSERT INTO {history} SELECT * FROM {history} WHERE {feb}",
        "wrong PHP order": f"UPDATE {summary} SET full_php=reverse(full_php) WHERE account={account}",
        "orphan monthly rows": f"DELETE FROM {summary} WHERE account={account}",
        "missing history": f"DELETE FROM {history} WHERE account={account}",
        "future month beyond the original cutoff": (f"INSERT INTO {history} (account, byte_date, perf_age, status) "
            f"SELECT account, php_left_byte_date + INTERVAL '1 month', length(full_php)+1, '0' FROM {summary} "
            f"WHERE account={account}"),
        "duplicate account summary": f"INSERT INTO {summary} SELECT * FROM {summary} WHERE account={account}",
    }
    for label, edit in malformed.items():
        altered = engine.replace(transaction, transaction + "\n" + edit + ";", 1)
        invoke(client, database, sql=altered, expect_error="MODULE 2 INPUT VALIDATION FAILED")
        if fingerprint() != original_outputs:
            raise RuntimeError(f"Saved Module 2 tables changed after {label}.")
    marker = "CREATE TABLE module2.metro2_remediation_window_eval AS"
    if engine.count(marker) != 1:
        raise RuntimeError("Cannot locate the post-reset injection point for the rollback control.")
    invoke(client, database, sql=engine.replace(marker, "SELECT 1 / 0;\n" + marker), expect_error="division by zero")
    if fingerprint() != original_outputs:
        raise RuntimeError("An interrupted rebuild changed the prior Module 2 tables.")
    print("PASS  Nine malformed-source controls and one post-reset rollback across four output tables")


def check_verifier(client, database, count):
    # Falsify eight audit dimensions in existing outputs. Original source rows are untouched.
    invoke(client, database, sql="""
        UPDATE module2.metro2_remediation_final
        SET remediation_treatment='NO_IMPACT_CLEAN_PHP_HISTORY', manual_review_flag=0, credit_cure_date='1990-01-01'
        WHERE account=10029;
        UPDATE module2.metro2_remediation_final SET clear_date_of_first_delinquency=true,
            remediation_fields_modified='NONE' WHERE account=60003;
        UPDATE module2.metro2_remediation_php_detail SET remediated_status='D'
        WHERE account=40003 AND byte_date='2020-01-01';
        UPDATE module2.metro2_remediation_window_eval
        SET last_severe_month='1990-01-01', severe_reversal_month='2099-01-01',
            remediation_policy='CHARGEOFF_REQUIRES_CURE_V1' WHERE account=10029;
    """)
    audit = json.loads(invoke(client, database, file=ROOT / "tools" / "verify_study.sql",
                              variables=[f"expected_accounts={count}", "required_months=3"]))
    keys = ("treatment_mismatches", "review_disposition_mismatches", "cure_start_or_threshold_mismatches",
            "explicit_clear_flag_mismatches", "applied_or_field_summary_mismatches",
            "monthly_edit_or_source_mismatches", "severe_event_date_mismatches", "policy_identifier_mismatches")
    if audit.get("pass") is not False or any(audit["audit"][key] != 1 for key in keys):
        raise RuntimeError("Verifier failed to detect deliberately altered outputs: " + json.dumps(audit))
    print("PASS  Deliberate output corruption detected in eight independent audit dimensions")


def check_thresholds(client, database):
    engine = MODULE2.read_text(encoding="utf-8")
    setting = "3    -- conservative remediation-policy default"
    if engine.count(setting) != 1:
        raise RuntimeError("Cannot locate the cure threshold in Module 2.")
    cases = (
        # With a two-month threshold, the two zeros after the charge-off establish cure.
        (2, 50030, "FULL_DEROGATORY_PHP_CLEANUP|2020-03-01|0"),
        # Three zeros cannot meet a four-month threshold at the same reporting cutoff.
        (4, 70044, "FULL_DEROGATORY_PHP_CLEANUP||1"),
    )
    for threshold, account, expected in cases:
        configured = engine.replace(setting, str(threshold) + setting[1:])
        invoke(client, database, sql=configured)
        observed = invoke(client, database, sql=(
            "SELECT remediation_treatment,credit_cure_date,manual_review_flag "
            f"FROM module2.metro2_remediation_final WHERE account={account}"
        ))
        if observed != expected:
            raise RuntimeError(f"Threshold {threshold}: expected {expected!r}, got {observed!r}.")
    invoke(client, database, sql=engine.replace(setting, "0" + setting[1:]),
           expect_error="MODULE 2 PARAMETER VALIDATION FAILED")
    print("PASS  Nondefault two- and four-month thresholds and rejection of a zero threshold")


def check_clear_fields(client, database):
    # An unchanged latest original D and an unrelated retained charge-off both preserve current fields.
    # The comparison is independent of the policy fixture expected rows used earlier.
    edit = """
        UPDATE module1.metro2_status_history SET status='D'
        WHERE account=170086 AND byte_date='2020-05-01';
        UPDATE module1.metro2_final SET full_php='D1212', date_of_first_delinquency='2020-01-01'
        WHERE account=170086;
        UPDATE module1.metro2_final SET account_status_17a='64', payment_rating_17b='L',
            date_closed=latest_doai, date_of_first_delinquency='2020-01-01' WHERE account=90044;
        -- Documented dates on a cured earlier incident, a whole-tradeline deletion and no impact.
        UPDATE module1.metro2_final SET date_of_first_delinquency='2020-01-01'
        WHERE account IN (130090,40003,140007);
    """
    invoke(client, database, sql=edit)
    # Capture the actual result sets emitted by the normal script entry point.
    output = invoke(client + ["--csv", "--pset=tuples_only=off"], database, file=MODULE2)
    actual = invoke(client, database, sql="""
        SELECT account, clear_account_status_17a, clear_payment_rating_17b, clear_date_of_first_delinquency,
               remediated_account_status_17a IS NULL, remediated_payment_rating_17b IS NULL,
               remediated_date_of_first_delinquency IS NULL, remediation_fields_modified, remediation_applied_flag
        FROM module2.metro2_remediation_final WHERE account IN (170086,90044) ORDER BY account
    """)
    expected = (
        "90044|f|f|f|t|t|t|PHP_ONLY|1\n"
        "170086|f|f|f|t|t|t|PHP_ONLY|1"
    )
    if actual != expected:
        raise RuntimeError(f"Explicit-clear controls expected {expected!r}; observed {actual!r}.")
    print("PASS  Historical-only PHP actions preserve current status, payment rating and source delinquency dates")
    check_display_queries(client, database, output)


def check_display_queries(client, database, output):
    reports = list(csv.reader(StringIO(output, newline="")))
    saved = json.loads(invoke(client, database, sql="""
        SELECT jsonb_agg(to_jsonb(f) ORDER BY account) FROM module2.metro2_remediation_final f
    """))

    def display(field, clear=None):
        replacement = "remediated_" + field
        columns = ["account", field, replacement] + ([clear] if clear else []) + [
            "remediation_treatment", "remediation_fields_modified"]
        headings = [i for i, line in enumerate(reports) if line == columns]
        if len(headings) != 1:
            raise RuntimeError(f"Expected exactly one native {field} QA result set with columns {columns}.")
        lines = []
        for line in reports[headings[0] + 1:]:
            if not line or len(line) != len(columns) or not line[0].isdigit():
                break
            lines.append(line)
        eligible = [row for row in saved if row[replacement] is not None or (clear and row[clear])]
        expected = []
        for row in eligible[:100]:
            values = []
            for column in columns:
                value = row[column]
                if isinstance(value, bool):
                    values.append("t" if value else "f")
                else:
                    values.append("" if value is None else str(value))
            expected.append(values)
        if lines != expected:
            raise RuntimeError(f"Native {field} QA selection, clear flag, values, order or limit differ.")
        return {int(r[0]): dict(zip(columns, r)) for r in lines}

    status = display("account_status_17a", "clear_account_status_17a")
    php = display("full_php")
    dates = display("date_of_first_delinquency", "clear_date_of_first_delinquency")
    if 170086 in status or status[40003]["remediated_account_status_17a"] != "DA" or status[190003]["remediated_account_status_17a"] != "11" or 140007 in status:
        raise RuntimeError("QA 13 must show supported status proposals and omit retained status.")
    if 170086 not in php or 40003 in php or 140007 in php:
        raise RuntimeError("QA 14 must show changed history and omit deletion and unchanged history.")
    if (dates[190003]["clear_date_of_first_delinquency"] != "t"
            or dates[190003]["remediated_date_of_first_delinquency"] != ""
            or any(account in dates for account in (170086,130090,40003,140007))):
        raise RuntimeError("QA 15 must show the supported clear and exclude unrelated current dates.")
    print("PASS  Native QA 13/14/15 readouts: exact ordered membership, supported clears and preserved source fields")


def audit_generator(client):
    with fresh_database(client) as database:
        result = generator_checks(MODULE1, lambda sql, failure=None: invoke(
            client, database, sql=sql, expect_error=failure))
        checked = result["checks"]
        print(f"PASS  Generator: {checked['accounts']} accounts and {checked['snapshots']} snapshots, "
              "calendar bounds, repeatability, reset protections and invalid configuration")


def audit_policy(client):
    with fresh_database(client) as database:
        invoke(client, database, sql=(
            "CREATE TABLE public.module2_params(marker int); INSERT INTO public.module2_params VALUES (17);"
            "CREATE TABLE public.metro2_remediation_final(marker int); INSERT INTO public.metro2_remediation_final VALUES (29);"
        ))
        invoke(client, database, file=TESTS / "policy_cases.sql")
        invoke(client, database, file=MODULE2)
        invoke(client, database, file=TESTS / "check_policy_cases.sql")
        count = invoke(client, database, sql="SELECT count(*) FROM regression.policy_cases;")
        audit = json.loads(invoke(client, database, file=ROOT / "tools" / "verify_study.sql",
                                  variables=[f"expected_accounts={count}", "required_months=3"]))
        if audit.get("pass") is not True:
            raise RuntimeError("Independent account/month reconstruction failed: " + json.dumps(audit))
        sentinels = invoke(client, database, sql=(
            "SELECT (SELECT marker FROM public.module2_params), (SELECT marker FROM public.metro2_remediation_final)"
        ))
        if sentinels != "17|29":
            raise RuntimeError("The Module 2 reset touched a same-named public table.")
        rows = audit["audit"]["monthly_records_compared"]
        print(f"PASS  {count} policy fixtures, {rows} monthly records and independent reconstruction")
        check_engine_rollbacks(client, database)
        check_verifier(client, database, count)
        check_thresholds(client, database)
        check_clear_fields(client, database)
        field25_checks(lambda **kwargs: invoke(client, database, **kwargs),
                       lambda **kwargs: invoke(client + ["--csv", "--pset=tuples_only=off"], database, **kwargs),
                       ROOT / "tools" / "export_field25_exceptions.sql")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--psql", help="PostgreSQL client executable")
    parser.add_argument("--host", help="PostgreSQL host (or PGHOST)")
    parser.add_argument("--port", type=int, help="PostgreSQL port (or PGPORT)")
    parser.add_argument("--user", help="PostgreSQL login with CREATEDB (or PGUSER)")
    parser.add_argument("--audit-evidence", type=Path, help="write detailed audit-counterexample results as JSON")
    parser.add_argument("--followup-evidence", type=Path, help="write second audit incident and episode controls as JSON")
    parser.add_argument("--threshold-evidence", type=Path, help="write saved cure-threshold controls and prior-table digests")
    parser.add_argument("--rolling-evidence", type=Path, help="write the successful rolling snapshot results as JSON")
    parser.add_argument("--prompt-password", action="store_true",
                        help="prompt once for PostgreSQL authentication during this run")
    args = parser.parse_args()
    if args.prompt_password:
        os.environ["PGPASSWORD"] = getpass.getpass("PostgreSQL password: ")
    client = psql_command(args)
    audit_policy(client)
    receipt = independent_checks(client, fresh_database, invoke, ROOT, TESTS)
    if args.audit_evidence:
        args.audit_evidence.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"PASS  {receipt['checks']} independent evidence, clock, source-alphabet and verifier controls")
    from followup_controls import run as followup_checks
    followup = followup_checks(client, ROOT)
    if args.followup_evidence:
        args.followup_evidence.write_text(json.dumps(followup, indent=2) + "\n", encoding="utf-8")
    if not followup["passed"]:
        raise RuntimeError("Follow-up controls failed: " + ", ".join(followup["failures"]))
    print(f"PASS  {followup['checks']} continued-incident, supported-onset and missing-rating controls")
    from threshold_reuse_controls import run_checks as threshold_reuse_checks
    threshold_result = threshold_reuse_checks(client, fresh_database, invoke, ROOT)
    if args.threshold_evidence:
        args.threshold_evidence.write_text(json.dumps(threshold_result, indent=2) + "\n", encoding="utf-8")
    print(f"PASS  {len(threshold_result)} threshold-preserving follow-up, separate-study and rollback controls")
    audit_generator(client)
    with fresh_database(client) as database:
        handoff_checks(client, database, lambda **kwargs: invoke(client, database, **kwargs), MODULE2, TESTS)
    with fresh_database(client) as database:
        evidence = rolling_checks(client, database, lambda **kwargs: invoke(client, database, **kwargs),
                                  MODULE2, TESTS, ROOT / "tools" / "verify_study.sql")
        if args.rolling_evidence:
            args.rolling_evidence.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, AssertionError) as exc:
        sys.exit("FAIL  " + str(exc))
