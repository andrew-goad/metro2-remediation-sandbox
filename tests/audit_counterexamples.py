"""Independent adjudication of retained-field, reporting-clock and source-alphabet counterexamples."""
import csv
from io import StringIO
import json
from pathlib import Path

from owner_case_controls import set_snapshot

JAN = "2025-01-01"
MAY = "2025-05-01"
DEC = "2024-12-01"
SIMPLE = "SIMPLE_DELINQUENCY_PHP_CLEANUP"
FULL = "FULL_DEROGATORY_PHP_CLEANUP"
DA = "TRADELINE_DELETION"
FINAL = "module2.metro2_remediation_final"
WINDOW = "module2.metro2_remediation_window_eval"
INCIDENT = "module2.metro2_remediation_input"


def run_checks(client, fresh_database, invoke, root, tests, enforce=True):
    """A caller may collect failed assertions to compare a frozen earlier engine on a separate server."""
    engine = (root / "src/module_02_metro2_remediation_engine.sql").read_text(encoding="utf-8")
    tools = root / "tools"
    reuse = "SET metro2.reuse_incident_dates='on';\n" + engine
    findings = []

    def observe(label, observed, expected):
        mismatches = {key: {"expected": v, "observed": observed.get(key)} for key, v in expected.items()
                      if observed.get(key) != v}
        findings.append({"case": label, "pass": not mismatches, "observed": observed, "mismatches": mismatches})

    def setup(database):
        def execute(**kwargs):
            return invoke(client, database, **kwargs)
        return execute

    def verify(execute, size):
        return json.loads(execute(file=tools / "verify_study.sql",
                                  variables=[f"expected_accounts={size}", "required_months=3"]))

    def gaps(database):
        data = invoke(client + ["--csv", "--pset=tuples_only=off"], database, file=tools / "export_field25_exceptions.sql")
        return {int(r["account"]): [r["exception_reason"], r["date_evidence_gap"]]
                for r in csv.DictReader(StringIO(data))}

    def referrals(database):
        query = tools / "export_account_field_review.sql"
        if not query.is_file():  # Archived comparison engine predates this report.
            return {}
        data = invoke(client + ["--csv", "--pset=tuples_only=off"], database, file=query)
        rows = list(csv.DictReader(StringIO(data)))
        if len(rows) != len({r["account"] for r in rows}):
            raise ValueError("Duplicate account-field referral")
        return {int(r["account"]): r for r in rows}

    def fields(execute, account):
        return json.loads(execute(sql=f"""
            SELECT to_jsonb(q) FROM (
                SELECT f.account, latest_doai AS reporting_date, php_left_byte_date AS latest_php_month,
                       impact_start_date AS bank_start, impact_end_date AS bank_end, credit_impact_end_date AS credit_end,
                       credit_cure_date AS cure, manual_review_flag AS review, remediation_treatment AS treatment,
                       full_php AS original_php, remediated_full_php AS replacement_php,
                       jsonb_build_array(account_status_17a,payment_rating_17b,date_of_first_delinquency) AS source,
                       jsonb_build_array(remediated_account_status_17a,remediated_payment_rating_17b,
                                         remediated_date_of_first_delinquency) AS replacements,
                       jsonb_build_array(clear_account_status_17a,clear_payment_rating_17b,clear_date_of_first_delinquency) AS clears,
                       jsonb_build_array(CASE WHEN NOT clear_account_status_17a THEN coalesce(remediated_account_status_17a,account_status_17a) END,
                                         CASE WHEN NOT clear_payment_rating_17b THEN coalesce(remediated_payment_rating_17b,payment_rating_17b) END,
                                         CASE WHEN NOT clear_date_of_first_delinquency THEN coalesce(remediated_date_of_first_delinquency,date_of_first_delinquency) END) AS effective
                FROM {FINAL} f WHERE account={account}
            ) q
        """))

    def fingerprint(execute):
        names = [INCIDENT, WINDOW, "module2.metro2_remediation_php_detail", FINAL]
        return [execute(sql=f"SELECT count(*), md5(string_agg(to_jsonb(t)::text,'' ORDER BY to_jsonb(t)::text)) FROM {name} t")
                for name in names]

    def invalid(execute, label, size, counter):
        before = fingerprint(execute)
        rejected = False
        try:
            execute(sql=reuse)
        except RuntimeError as exc:
            if "MODULE 2 INPUT VALIDATION FAILED" not in str(exc):
                raise
            rejected = True
        result = verify(execute, size)
        observe(label, {"rejected": rejected, "all_four_tables_preserved": fingerprint(execute) == before,
                        "verifier_rejected": result["pass"] is False,
                        "independent_source_error_count": result["audit"].get(counter)},
                {"rejected": True, "all_four_tables_preserved": True, "verifier_rejected": True,
                 "independent_source_error_count": 1})

    def retained(source):
        return {"source": list(source), "effective": list(source), "replacements": [None]*3, "clears": [False]*3}

    with fresh_database(client) as db:
        execute = setup(db)
        execute(file=tests / "policy_cases.sql")
        execute(sql=engine)
        # The original current September 17A is independently supplied. August's L is outside the closed window.
        execute(sql="UPDATE module1.metro2_final SET account_status_17a='11',payment_rating_17b='0',date_of_first_delinquency=NULL WHERE account=130090")
        execute(sql=engine)
        r = fields(execute, 130090)
        r["verifier_pass"] = verify(execute, 27)["pass"]
        r["field_referral"] = referrals(db).get(130090, {}).get("account_field_review_reason")
        observe("130090 current September status with unrelated August charge-off", r, dict(
            retained(("11", "0", None)), reporting_date="2020-09-01", credit_end="2020-02-01", cure="2020-03-01",
            original_php="L22000L1", replacement_php="L22000DD", field_referral="AS_OF_FIELD_BASIS_UNCONFIRMED",
            verifier_pass=True))
        # Simulate the old published wrong action, leaving all original evidence untouched.
        execute(sql=f"UPDATE {FINAL} SET remediated_account_status_17a='97',remediated_payment_rating_17b='L', "
                    "remediated_date_of_first_delinquency='2020-06-01' WHERE account=130090")
        v = verify(execute, 27)
        observe("verifier rejects fabricated 130090 current-field replacements",
                {"verifier_rejected": v["pass"] is False, "unsupported_actions": v["audit"].get("unjustified_current_field_actions")},
                {"verifier_rejected": True, "unsupported_actions": 1})
        if "field_policy_identifier_mismatches" in v["audit"]:
            execute(sql=engine)
            execute(sql=f"UPDATE {FINAL} SET account_field_policy='WRONG' WHERE account=130090")
            bad_marker = verify(execute, 27)
            observe("verifier rejects wrong field-evidence policy on otherwise unchanged records",
                    {"verifier_rejected": bad_marker["pass"] is False,
                     "field_policy_mismatches": bad_marker["audit"]["field_policy_identifier_mismatches"]},
                    {"verifier_rejected": True, "field_policy_mismatches": 1})
        else:
            observe("verifier rejects wrong field-evidence policy on otherwise unchanged records",
                    {"verifier_rejected": False, "field_policy_mismatches": None},
                    {"verifier_rejected": True, "field_policy_mismatches": 1})
        if "field_evidence_referral_mismatches" in v["audit"]:
            execute(sql=engine)
            execute(sql=f"UPDATE {FINAL} SET account_field_review_reason=NULL WHERE account=130090")
            bad_reason = verify(execute, 27)["audit"]["field_evidence_referral_mismatches"]
        else:
            bad_reason = None
        observe("verifier detects deletion of required field referral", {"field_referral_mismatches": bad_reason},
                {"field_referral_mismatches": 1})
        execute(sql=engine)
        execute(sql="UPDATE module1.metro2_final SET latest_doai='2020-07-01' WHERE account=60003")
        invalid(execute, "60003 July history on July 1 reporting date", 27, "reporting_clock_mismatches")
        execute(sql=f"UPDATE {WINDOW} SET latest_doai='2020-07-01' WHERE account=60003; "
                    f"UPDATE {FINAL} SET latest_doai='2020-07-01' WHERE account=60003;")
        v = verify(execute, 27)
        observe("verifier detects impossible clock even when all three stored reporting dates agree",
                {"verifier_rejected": v["pass"] is False, "source_clock_mismatches": v["audit"].get("reporting_clock_mismatches"),
                 "disagreement_between_copies": v["audit"].get("source_snapshot_copy_mismatches")},
                {"verifier_rejected": True, "source_clock_mismatches": 1, "disagreement_between_copies": 0})

    with fresh_database(client) as db:
        execute = setup(db)
        # Exact six synthetic source records from the independent audit.
        execute(file=tests / "closed_field_cases.sql")
        execute(sql=engine)
        # Construct one coherent January incident across the three copies before testing closed-account fields.
        for table in (INCIDENT, WINDOW, FINAL):
            execute(sql=f"UPDATE {table} SET impact_start_date='2020-01-01',impact_end_date='2020-01-01'")
        for missing in (False, True):
            if missing:
                execute(sql="UPDATE module1.metro2_final SET date_of_first_delinquency=NULL")
            execute(sql=reuse)
            exceptions = gaps(db)
            valid = verify(execute, 6)["pass"]
            for account, status in enumerate(("64","13","61","62","63","65"), 1):
                src = (status, "2" if status == "13" else None, None if missing else "2020-05-01")
                r = fields(execute, account)
                r.update(field25_exception=exceptions.get(account), verifier_pass=valid)
                required = "DATE_REQUIRED_BY_STATUS_AND_RATING" if status=="13" else "DATE_REQUIRED_BY_STATUS"
                observe(f"closed account {account} / {status} / {'missing' if missing else 'documented'} onset", r,
                        dict(retained(src), cure="2020-02-01", credit_end="2020-01-01", review=0,
                             replacement_php=r["original_php"][:-1]+"D", verifier_pass=True,
                             field25_exception=[required,"DATE_ABSENT_IN_SOURCE"] if missing else None))

    with fresh_database(client) as db:
        execute = setup(db)
        execute(file=tests / "policy_cases.sql")
        set_snapshot(execute, "", "71", "1", DEC)
        execute(sql=engine)
        # Chronology and source fields from the supplied independent 17899 probe.
        cases = [
            ("bank-imposed D", "", ("71","1",DEC), ["11","0",None], SIMPLE, None, None),
            ("original latest D", "D", ("71","1",DEC), None, SIMPLE, None, None),
            ("valid April 1 with two current months", "00", ("11","0",None), None, SIMPLE, None, None),
            ("valid May 1 with third current month", "000", ("11","0",None), None, SIMPLE, "2025-02-01", None),
            ("D within later dated adverse episode", "0002D3", ("80","3",MAY), None, SIMPLE, "2025-02-01", None),
            ("independent current status after D gap", "0002D3", ("78","2",MAY), None, SIMPLE, "2025-02-01", None),
            ("later original L following D gap", "0002DL", ("97","L",MAY), None, SIMPLE, "2025-02-01", None),
            ("missing independently sourced later onset", "0002D3", ("80","3",None), None, SIMPLE, "2025-02-01", "DATE_REQUIRED_BY_STATUS"),
            ("documented later paid charge-off", "00023L", ("64",None,MAY), None, SIMPLE, "2025-02-01", None),
            ("missing date on later paid charge-off", "00023L", ("64",None,None), None, SIMPLE, "2025-02-01", "DATE_REQUIRED_BY_STATUS"),
            ("closed 13 with supported adverse rating", "00021", ("13","1",MAY), None, SIMPLE, "2025-02-01", None),
            ("verified removal of matching closed paid-derog basis", "L0", ("64",None,DEC), ["13","0",None], FULL, None, None),
            ("verified suppression of matching closure rating", "2", ("13","2",DEC), ["13","0",None], SIMPLE, None, None),
            ("unconfirmed paid major basis", "00023", ("64",None,MAY), None, SIMPLE, "2025-02-01", None),
            ("unconfirmed closure rating basis", "00023", ("13","2",MAY), None, SIMPLE, "2025-02-01", None),
            ("adverse latest mark with contradictory DOAI status", "2", ("11","0",None), None, SIMPLE, None, None),
            ("qualifying status but later source onset than edited month", "2", ("78","2","2025-03-01"), None, SIMPLE, None, None),
            ("removed paid basis without a documented closure", "L0", ("64",None,DEC), None, FULL, None, None),
            ("original D follows removed closed-event basis", "L0D", ("64",None,DEC), None, FULL, None, None),
        ]
        reasons = {"D within later dated adverse episode": "ONSET_CONTINUITY_UNCONFIRMED",
                   "independent current status after D gap": "AS_OF_FIELD_BASIS_UNCONFIRMED",
                   "later original L following D gap": "ONSET_CONTINUITY_UNCONFIRMED",
                   "unconfirmed paid major basis": "PAID_MAJOR_BASIS_UNCONFIRMED",
                   "unconfirmed closure rating basis": "CLOSURE_RATING_BASIS_UNCONFIRMED",
                   "adverse latest mark with contradictory DOAI status": "AS_OF_FIELD_BASIS_UNCONFIRMED",
                   "qualifying status but later source onset than edited month": "AS_OF_FIELD_BASIS_UNCONFIRMED",
                   "removed paid basis without a documented closure": "PAID_MAJOR_BASIS_UNCONFIRMED",
                   "original D follows removed closed-event basis": "PAID_MAJOR_BASIS_UNCONFIRMED"}
        for label, ext, src, effective, treatment, cure, exc in cases:
            # Each counterfactual branches from the observed February 1 snapshot.
            set_snapshot(execute, "", "71", "1", DEC)
            execute(sql=engine)
            set_snapshot(execute, ext, *src)
            if src[0] in ("61","62","63","64","65","13") and "without a documented closure" not in label:
                execute(sql="UPDATE module1.metro2_final SET date_closed=latest_doai")
            execute(sql=reuse)
            r = fields(execute, 17899)
            r.update(field25_exception=gaps(db).get(17899),verifier_pass=verify(execute,1)["pass"])
            referral = referrals(db).get(17899)
            r["field_referral"] = referral["account_field_review_reason"] if referral else None
            if referral:
                pairs = (("original_status_17a","proposed_status_17a"), ("original_internal_rating","proposed_internal_rating"),
                         ("original_dofd","proposed_dofd"))
                if any(referral[a] != (src[i] or "") or referral[b] != (r["effective"][i] or "")
                       for i,(a,b) in enumerate(pairs)) or int(referral["bank_cure_review_flag"]) != r["review"]:
                    raise RuntimeError("Account-field research handoff lost original/proposed fields or cure disposition.")
            required = retained(src)
            if effective is not None:
                required["effective"] = effective
                required["replacements"] = [end if end != start else None for start, end in zip(src,effective)]
                required["clears"] = [start is not None and end is None for start, end in zip(src,effective)]
            observe(label, r, dict(required, bank_start=JAN, bank_end=JAN, cure=cure, treatment=treatment,
                                   review=int(cure is None and src[0] not in ("13","64")),
                                   field_referral=reasons.get(label),
                                   field25_exception=[exc,"DATE_ABSENT_IN_SOURCE"] if exc else None, verifier_pass=True))
        # Invalid sources are each tested with the last good four materialized tables present.
        for label, extension, override, counter in (
            ("17899 April 1 consumes April PHP", "000", "latest_doai='2025-04-01'", "reporting_clock_mismatches"),
            ("17899 missing report date", "000", "latest_doai=NULL", "reporting_clock_mismatches"),
            ("17899 unaligned day", "000", "latest_doai='2025-05-02'", "reporting_clock_mismatches"),
            ("17899 skipped reporting month", "000", "latest_doai='2025-06-01'", "reporting_clock_mismatches"),
            ("17899 unsupported question mark", "?", None, "unsupported_or_misplaced_source_symbols"),
            ("17899 unknown X", "X", None, "unsupported_or_misplaced_source_symbols"),
            ("17899 latest B after known history", "B", None, "unsupported_or_misplaced_source_symbols"),
            ("17899 interior B after known history", "B1", None, "unsupported_or_misplaced_source_symbols"),
        ):
            set_snapshot(execute, extension, "71", "1", DEC)
            if override:
                execute(sql="UPDATE module1.metro2_final SET "+override)
            invalid(execute, label, 1, counter)
        for label, after in (("oldest B padding", "BB0000011"), ("all-B boundary history", "BBBBBBBBB")):
            set_snapshot(execute, "", "71", "1", DEC)
            execute(sql=f"""
                UPDATE module1.metro2_status_history SET status=substring('{after}',perf_age,1);
                UPDATE module1.metro2_final SET full_php=reverse('{after}');
            """)
            execute(sql=engine)
            r = fields(execute, 17899)
            observe(label, {"history": r["original_php"], "verifier_pass": verify(execute,1)["pass"]},
                    {"history": after[::-1], "verifier_pass": True})

        # The 1,000-account exported account 327, including all 22 original months.
        # Use a single-account database to check the audit's X mutation at its ordinary entry point.
        original = "012345L543210000000000"
        execute(sql=f"""
            TRUNCATE module1.metro2_account_blueprint,module1.metro2_status_history,module1.metro2_final;
            INSERT INTO module1.metro2_account_blueprint VALUES (327,reverse('{original}'));
            INSERT INTO module1.metro2_status_history
            SELECT 327,(DATE '2023-12-01'+make_interval(months=>i-1))::date,i,
                   substring(reverse('{original}'),i,1) FROM generate_series(1,22) i;
            INSERT INTO module1.metro2_final
                (account,profile_type,latest_doai,php_right_byte_date,php_left_byte_date,full_php,
                 account_status_17a,payment_rating_17b)
            VALUES (327,'REVERSED_MAJOR_DEROG','2025-10-01','2023-12-01','2025-09-01','{original}','11','0');
        """)
        execute(sql=engine)
        execute(sql="""
            UPDATE module1.metro2_status_history SET status='X' WHERE byte_date='2025-09-01';
            UPDATE module1.metro2_final SET full_php='X'||substr(full_php,2);
        """)
        invalid(execute, "327 September original 0 changed to X", 1, "unsupported_or_misplaced_source_symbols")

    failures = [f["case"] for f in findings if not f["pass"]]
    if enforce and failures:
        raise RuntimeError("Independent counterexamples failed: " + ", ".join(failures))
    return {"all_expected": not failures,"checks": len(findings),"failures": failures,"findings": findings}


if __name__ == "__main__":
    import argparse
    import getpass
    import os
    import sys
    from run_regression import fresh_database, invoke, psql_command

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--study-root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="root of the frozen or current study to execute, with src/ and tools/")
    parser.add_argument("--psql", help="PostgreSQL client executable")
    parser.add_argument("--host", help="PostgreSQL test server")
    parser.add_argument("--port", type=int, help="PostgreSQL test port")
    parser.add_argument("--user", help="database login with CREATEDB")
    parser.add_argument("--prompt-password", action="store_true")
    parser.add_argument("--output", required=True, type=Path, help="save every observed and expected difference as JSON")
    args = parser.parse_args()
    if args.prompt_password:
        os.environ["PGPASSWORD"] = getpass.getpass("PostgreSQL password: ")
    try:
        result = run_checks(psql_command(args), fresh_database, invoke, args.study_root.resolve(),
                            Path(__file__).resolve().parent, enforce=False)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"{result['checks']} checks; {len(result['failures'])} failed. Receipt: {args.output}")
        sys.exit(0 if result["all_expected"] else 1)
    except (OSError, RuntimeError, ValueError) as exc:
        sys.exit(str(exc))
