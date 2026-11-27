"""Replay the independent re-audit cases against a selected study in disposable databases."""
import argparse
import csv
import getpass
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import sys

from owner_case_controls import BASE, DEC, JAN, set_snapshot
from run_regression import fresh_database, invoke, psql_command


FINAL = "module2.metro2_remediation_final"
WINDOW = "module2.metro2_remediation_window_eval"
INCIDENT = "module2.metro2_remediation_input"
DETAIL = "module2.metro2_remediation_php_detail"
MAY = "2024-05-01"
NEXT_MAY = "2025-05-01"
OPEN = "SIMPLE_DELINQUENCY_PHP_CLEANUP"
FULL = "FULL_DEROGATORY_PHP_CLEANUP"
NONE = "NO_IMPACT_CLEAN_PHP_HISTORY"
DA = "TRADELINE_DELETION"
GAP = "ONSET_CONTINUITY_UNCONFIRMED"
MISSING_RATING = "MISSING_REQUIRED_PAYMENT_RATING"
ROOT = Path(__file__).resolve().parents[1]


def fingerprint(q):
    # Include every column and all duplicate rows in all four prior result tables.
    return {table: q(f"SELECT count(*), md5(string_agg(to_jsonb(t)::text,'' ORDER BY to_jsonb(t)::text)) FROM {table} t")
            for table in (INCIDENT, WINDOW, DETAIL, FINAL)}


def read_decision(q, account=17899):
    return json.loads(q(f"""
        SELECT to_jsonb(x) FROM (
          SELECT f.account, f.latest_doai AS report, f.full_php AS original,
            coalesce(f.remediated_full_php,f.full_php) AS proposed,
            f.impact_start_date AS bank_start, f.impact_end_date AS bank_end,
            f.credit_cure_date AS cure, f.manual_review_flag AS review,
            f.remediation_treatment AS treatment, f.account_field_review_reason AS reason,
            jsonb_build_array(f.account_status_17a,f.payment_rating_17b,f.date_of_first_delinquency) AS source,
            jsonb_build_array(f.remediated_account_status_17a,f.remediated_payment_rating_17b,
                              f.remediated_date_of_first_delinquency) AS replacements,
            jsonb_build_array(f.clear_account_status_17a,f.clear_payment_rating_17b,
                              f.clear_date_of_first_delinquency) AS clears
          FROM {FINAL} f WHERE f.account={account}
        ) x;
    """))


def run(client, root):
    module = root / "src/module_02_metro2_remediation_engine.sql"
    engine = module.read_text(encoding="utf-8")
    verifier = root / "tools/verify_study.sql"
    reuse = "SET metro2.reuse_incident_dates='on';\n" + engine
    checks = []

    def check(label, got, expected):
        differences = {key: {"expected": wanted, "actual": got.get(key)}
                       for key, wanted in expected.items() if got.get(key) != wanted}
        checks.append(dict(case=label, passed=not differences, expected=expected, actual=got, differences=differences))

    with fresh_database(client) as db:
        def execute(**kwargs):
            return invoke(client, db, **kwargs)

        def q(sql):
            return execute(sql=sql)

        def audit(n=1):
            return json.loads(execute(file=verifier, variables=[f"expected_accounts={n}", "required_months=3"]))

        def worklist(name):
            rows = invoke(client + ["--csv", "--pset=tuples_only=off"], db,
                          file=root / "tools" / f"export_{name}.sql")
            return {int(r["account"]):r for r in csv.DictReader(StringIO(rows))}

        def fresh():
            # Each alternative branch starts with an actual February 1 result and its January incident.
            set_snapshot(execute, "", "71", "1", DEC)
            q(engine)

        def source(history, status, rating, onset, closure):
            set_snapshot(execute, history[len(BASE):], status, rating, onset)
            # History strings in this test are original evidence, oldest month first.
            # NULL explicitly represents unavailable servicing evidence.
            closed = f"DATE '{closure}'" if closure else "NULL"
            q(f"""UPDATE module1.metro2_status_history SET status=substr('{history}',perf_age,1);
                  UPDATE module1.metro2_account_blueprint SET history='{history}';
                  UPDATE module1.metro2_final SET full_php=reverse('{history}'),date_closed={closed};""")

        def field_case(label, original, status, rating, onset, closure, proposed, replacements, clear,
                       treatment, referral=None, exception=None):
            fresh()
            source(original, status, rating, onset, closure)
            q(reuse)
            result = read_decision(q)
            account_work = worklist("account_field_review").get(17899, {})
            date_work = worklist("field25_exceptions").get(17899, {})
            result.update(verifier_pass=audit()["pass"], research_export=account_work.get("account_field_review_reason"),
                          date_exception=date_work.get("exception_reason"))
            check(label, result, dict(source=[status,rating,onset], original=original[::-1],
                proposed=proposed[::-1], replacements=replacements, clears=[False,False,clear],
                treatment=treatment, reason=referral, research_export=referral,
                date_exception=exception, verifier_pass=True))
            if referral == MISSING_RATING:
                if status in ("05", "13"):
                    scope = "CONDITIONAL_ON_MISSING_RATING"
                else:
                    scope = "REQUIRED_BY_STATUS_DATE_PRESENT" if onset else "REQUIRED_BY_STATUS_DATE_ABSENT"
                check(label+" · worklist instructions", {
                    "next_step":account_work.get("servicing_next_step", "").startswith(
                        "Obtain the payment rating and its supporting servicing records."),
                    "field25_scope":account_work.get("field25_review_scope")},
                    {"next_step":True,"field25_scope":scope})
            return result

        # The fixed expectations below express the business rationale independently of the production code.
        execute(file=ROOT / "tests/policy_cases.sql")
        keep = [None,None,None]
        elect = ["11","0",None]
        field_case("six observed current months separate the supplied May onset", "200000011",
                   "71","1",MAY,None,"20000001D",keep,False,OPEN,GAP)
        field_case("unknown in an otherwise separated source-onset episode", "20D000011",
                   "71","1",MAY,None,"20D00001D",keep,False,OPEN,GAP)
        field_case("December onset with a February original D before March delinquency", BASE+"D2",
                   "78","2",DEC,None,BASE[:-1]+"DDD",keep,False,OPEN,GAP)
        field_case("known zero between December onset and March adverse mark", BASE+"02",
                   "78","2",DEC,None,BASE[:-1]+"D0D",keep,False,OPEN,GAP)
        field_case("continuous numeric delinquency corroborates the bank election", BASE+"12",
                   "78","2",DEC,None,BASE[:-1]+"DDD",elect,True,OPEN)
        field_case("pre-incident onset continuously adverse across the full original history", "211111111",
                   "71","1",MAY,None,"21111111D",elect,True,OPEN)
        field_case("original source D at latest is evidence of neither performance nor cure", BASE+"D",
                   "71","1",DEC,None,BASE[:-1]+"DD",keep,False,OPEN)
        field_case("documented onset outside represented monthly evidence", BASE,
                   "71","1","2024-04-01",None,BASE[:-1]+"D",keep,False,OPEN,GAP)
        field_case("supplied onset points at a current month within represented history", BASE,
                   "71","1","2024-11-01",None,BASE[:-1]+"D",keep,False,OPEN,GAP)
        field_case("open status contradicts closure before the latest affected month", BASE+"2",
                   "78","2",DEC,DEC,BASE[:-1]+"DD",keep,False,OPEN,"CLOSURE_TIMING_UNCONFIRMED")
        field_case("reported closure month itself has a later adverse observation", BASE+"23",
                   "13","2",DEC,"2025-03-01",BASE[:-1]+"DDD",keep,False,OPEN,"CLOSURE_TIMING_UNCONFIRMED")
        field_case("demonstrably removed pre-closure rating still qualifies", BASE+"2",
                   "13","2",DEC,"2025-03-01",BASE[:-1]+"DD",[None,"0",None],True,OPEN)
        field_case("severe event has no later reversal", BASE+"L",
                   "97","L",DEC,None,BASE+"L",["DA",None,None],False,DA)
        field_case("latest numeric after severe supports modeled reversal within the same onset", BASE+"L5",
                   "83","5",DEC,None,BASE[:-1]+"DDD",elect,True,FULL)

        for rating,onset,wanted,exception in (
            (None,None,MISSING_RATING,None),
            (None,NEXT_MAY,MISSING_RATING,None),
            ("2",None,None,"DATE_REQUIRED_BY_STATUS_AND_RATING"),
            ("2",NEXT_MAY,None,None),
        ):
            field_case(f"closed 13 after cure, original rating {rating}, date {onset}", BASE+"0002",
                       "13",rating,onset,"2025-06-01",BASE[:-1]+"D0002",keep,False,OPEN,wanted,exception)
        field_case("closed 13 with no bank cleanup still routes missing rating", "000000000",
                   "13",None,None,"2025-02-01","000000000",keep,False,NONE,MISSING_RATING)
        field_case("closed 13 with a known current rating and no date", "000000000",
                   "13","0",None,"2025-02-01","000000000",keep,False,NONE)
        field_case("retained status 65 with a missing rating and missing required date", "000000000",
                   "65",None,None,"2025-02-01","000000000",keep,False,NONE,MISSING_RATING,"DATE_REQUIRED_BY_STATUS")
        field_case("retained status 95 with source date still needs missing rating research", "000000000",
                   "95",None,DEC,None,"000000000",keep,False,NONE,MISSING_RATING)

        field_case("a whitespace-only closure rating requires servicing", "000000000",
                   "13"," ",None,"2025-02-01","000000000",keep,False,NONE,MISSING_RATING)
        for status in ("05","88","89","94"):
            field_case("historically required missing retained rating "+status, "000000000",
                       status,None,DEC,None,"000000000",keep,False,NONE,MISSING_RATING)
        # Spoof the predecessor's favorable action. The independent verifier must detect each cause.
        for label,history,onset,edit,counter in [
            ("unlinked onset", "200000011", MAY, """remediated_account_status_17a='11',
             remediated_payment_rating_17b='0',clear_date_of_first_delinquency=true,account_field_review_reason=NULL""",
             "unsupported_onset_episode_actions"),
            ("omitted justified election", BASE, DEC, """remediated_account_status_17a=NULL,
             remediated_payment_rating_17b=NULL,clear_date_of_first_delinquency=false""","account_field_delta_mismatches"),
        ]:
            fresh()
            source(history,"71","1",onset,None)
            q(reuse)
            q(f"UPDATE {FINAL} SET {edit}")
            verified=audit()
            check("verifier rejects "+label, {"pass":verified["pass"],"counter":verified["audit"].get(counter)},
                  {"pass":False,"counter":1})
        fresh()
        source("000000000","13",None,None,"2025-02-01")
        q(reuse)
        q(f"UPDATE {FINAL} SET account_field_review_reason=NULL")
        verified=audit()
        check("verifier catches removed missing-rating servicing referral",
              {"pass":verified["pass"],"counter":verified["audit"].get("unreferred_required_rating_gaps")},
              {"pass":False,"counter":1})

        def rejection(label, mutator, verify_counter=None):
            fresh()
            mutator()
            before=fingerprint(q)
            previous=read_decision(q) if q(f"SELECT count(*) FROM {FINAL} WHERE account=17899")=="1" else None
            prior_audit=audit() if verify_counter else None
            try:
                q(reuse)
                diagnostic=None
            except RuntimeError as exc:
                diagnostic=str(exc).split("ERROR:")[-1].splitlines()[0].strip()
            after=fingerprint(q)
            result=dict(rejected=bool(diagnostic and "INCIDENT REUSE FAILED" in diagnostic),
                        previous_result_preserved=(before==after), diagnostic=diagnostic,
                        prior_fingerprints=before, subsequent_fingerprints=after, previous=previous)
            expected={"rejected":True,"previous_result_preserved":True}
            if prior_audit:
                result.update(verifier_pass=prior_audit["pass"],counter=prior_audit["audit"].get(verify_counter))
                expected.update(verifier_pass=False,counter=1)
            check(label,result,expected)

        def stale_source():
            set_snapshot(execute,"000","11","0",None)
            q(reuse)
            set_snapshot(execute,"00","11","0",None)
        rejection("older valid April report cannot reopen the May confirmed cure", stale_source)

        for name in (INCIDENT,WINDOW,FINAL):
            rejection(f"one altered prior incident start in {name}",
                      lambda name=name:q(f"UPDATE {name} SET impact_start_date='{DEC}'"))
            rejection(f"missing prior account in {name}",lambda name=name:q(f"DELETE FROM {name} WHERE account=17899"))
        rejection("previous window and final reporting cutoffs disagree",
                  lambda:q(f"UPDATE {WINDOW} SET latest_doai='2025-01-01'"))
        rejection("duplicate prior window member", lambda:q(f"INSERT INTO {WINDOW} SELECT * FROM {WINDOW}"))
        rejection("duplicate prior final member", lambda:q(f"INSERT INTO {FINAL} SELECT * FROM {FINAL}"))
        def erased_cutoffs():
            for name in (WINDOW,FINAL):
                q(f"UPDATE {name} SET latest_doai=NULL")
        rejection("both prior decisions lack a cutoff",erased_cutoffs)
        def invalid_dates():
            for name in (INCIDENT,WINDOW,FINAL):
                q(f"UPDATE {name} SET impact_end_date='2025-01-02'")
        rejection("all three stored incident copies agree on invalid day",invalid_dates,"invalid_incident_month_keys")

        fresh()
        before=fingerprint(q)
        q(reuse)
        check("same valid cutoff and identical source is idempotent",
              {"unchanged":before==fingerprint(q),"verified":audit()["pass"]}, {"unchanged":True,"verified":True})
        source("200000011","71","1",MAY,None)
        q(reuse)
        row=read_decision(q)
        check("same cutoff accepts a supported correction while retaining January incident",row,
              {"original":"110000002","bank_start":JAN,"bank_end":JAN,"reason":GAP,"clears":[False]*3})
        fresh()
        # Copy a second original account whose source cutoff stays unchanged as the first advances.
        q("""INSERT INTO module1.metro2_account_blueprint SELECT 17898,history FROM module1.metro2_account_blueprint;
             INSERT INTO module1.metro2_status_history SELECT 17898,byte_date,perf_age,status FROM module1.metro2_status_history;
             INSERT INTO module1.metro2_final SELECT (jsonb_populate_record(NULL::module1.metro2_final,
                 to_jsonb(f)||'{"account":17898}'::jsonb)).* FROM module1.metro2_final f;""")
        q(engine)
        stable=read_decision(q,17898)
        q("""UPDATE module1.metro2_account_blueprint SET history=history || '0' WHERE account=17899;
             INSERT INTO module1.metro2_status_history VALUES(17899,'2025-02-01',10,'0');
             UPDATE module1.metro2_final SET latest_doai='2025-03-01',php_left_byte_date='2025-02-01',
                 full_php='0'||full_php,account_status_17a='11',payment_rating_17b='0',
                 date_of_first_delinquency=NULL WHERE account=17899;""")
        q(reuse)
        row=read_decision(q)
        row.update(stable_account_unchanged=(stable==read_decision(q,17898)), pass_verifier=audit(2)["pass"])
        check("ordinary one-account advance with another account unchanged at its own cutoff", row,
              dict(stable_account_unchanged=True, report="2025-03-01", bank_start=JAN, bank_end=JAN,
                   cure=None, review=1, proposed="0D10000000", pass_verifier=True))

    failures=[item["case"] for item in checks if not item["passed"]]
    return {"passed":not failures,"checks":len(checks),"failures":failures,
            "module2_sha256":hashlib.sha256(module.read_bytes()).hexdigest(),
            "verifier_sha256":hashlib.sha256(verifier.read_bytes()).hexdigest(),"findings":checks}


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--study-root",type=Path,default=ROOT)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--host")
    parser.add_argument("--port",type=int)
    parser.add_argument("--user")
    parser.add_argument("--psql")
    parser.add_argument("--prompt-password",action="store_true")
    args=parser.parse_args()
    if args.prompt_password:
        os.environ["PGPASSWORD"]=getpass.getpass("PostgreSQL password: ")
    result=run(psql_command(args),args.study_root.resolve())
    args.output.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(f"{result['checks']} re-audit controls, {len(result['failures'])} failed")
    sys.exit(int(not result["passed"]))
