"""Trace account 17899 at its February 1 DOAI (January first PHP byte) and controlled later cutoffs."""
import json
from datetime import date

from review_handoff_controls import export_rows


ACCOUNT = 17899
BASE = "000000011"  # May 2024 to January 2025, oldest first.
DEC = "2024-12-01"
JAN = "2025-01-01"
SIMPLE = "SIMPLE_DELINQUENCY_PHP_CLEANUP"
FULL = "FULL_DEROGATORY_PHP_CLEANUP"
DELETE = "TRADELINE_DELETION"
SHORT = "INSUFFICIENT_POST_IMPACT_HISTORY"
OPEN = "NO_CURE_OPEN_ACCOUNT"


def reporting_month(extension_length):
    return date(2025, extension_length + 1, 1).isoformat()


def december_source(execute, generator):
    # Module 1 stores latest-state fields on its final table. Run its unchanged final
    # derivation on the eight retained months available through December, before
    # January's issue. Do not present this reconstruction as a saved furnishing.
    start = "CREATE TABLE module1.metro2_final AS"
    end = "CREATE UNIQUE INDEX ix_final_account"
    native = generator.read_text(encoding="utf-8")
    if native.count(start) != 1 or native.count(end) != 1:
        raise RuntimeError("Cannot locate the Module 1 final account derivation for the December cutoff.")
    derivation = native[native.index(start):native.index(end)]
    original = BASE[:-1]
    record = json.loads(execute(sql=f"""
        BEGIN;
        TRUNCATE module1.metro2_account_blueprint, module1.metro2_status_history;
        ALTER TABLE module1.metro2_account_blueprint ADD COLUMN profile_type text, ADD COLUMN end_date date,
            ADD COLUMN date_closed date, ADD COLUMN close_status_code text;
        INSERT INTO module1.metro2_account_blueprint (account, history, profile_type, end_date)
        VALUES ({ACCOUNT}, '{original}', 'MILD', '{JAN}');
        INSERT INTO module1.metro2_status_history (account, byte_date, perf_age, status)
        SELECT {ACCOUNT}, (DATE '2024-05-01' + make_interval(months => pos-1))::date, pos,
               substring('{original}', pos, 1) FROM generate_series(1,8) pos;
        ALTER TABLE module1.metro2_final RENAME TO test_saved_final;
        {derivation}
        SELECT to_jsonb(f) FROM module1.metro2_final f;
        ROLLBACK;
    """))
    expected = ("2024-12-01", "2025-01-01", "10000000", "71", "1", DEC)
    observed = tuple(record[k] for k in ("php_left_byte_date", "latest_doai", "full_php", "account_status_17a",
                                         "payment_rating_17b", "date_of_first_delinquency"))
    if expected != observed:
        raise RuntimeError(f"December 17899 source reconstruction: expected {expected!r}, got {observed!r}")
    return record


def set_snapshot(execute, extension, status, rating, original_date):
    """Construct just the original months represented at this reporting cutoff."""
    history = BASE + extension
    account = dict(account=ACCOUNT, profile_type="MILD", latest_doai=reporting_month(len(extension)+1),
                   php_right_byte_date="2024-05-01", php_left_byte_date=reporting_month(len(extension)),
                   account_status_17a=status, payment_rating_17b=rating, date_of_first_delinquency=original_date,
                   full_php=history[::-1], date_closed=reporting_month(len(extension)) if status == "13" else None)
    execute(sql=f"""
        TRUNCATE module1.metro2_account_blueprint, module1.metro2_status_history, module1.metro2_final;
        INSERT INTO module1.metro2_account_blueprint VALUES ({ACCOUNT}, '{history}');
        INSERT INTO module1.metro2_status_history (account, byte_date, perf_age, status)
        SELECT {ACCOUNT}, (DATE '2024-05-01' + make_interval(months => pos-1))::date,
               pos, substring('{history}', pos, 1) FROM generate_series(1,{len(history)}) pos;
        INSERT INTO module1.metro2_final SELECT * FROM jsonb_populate_record(NULL::module1.metro2_final, '{json.dumps(account)}');
    """)


def run_checks(client, database, execute, engine, verifier, generator):
    def verify(extension, source, treatment, proposed_tail, review, impact_end, streak=0, cured=False,
               proposed_status=None, proposed_rating=None, proposed_date=None, clear_date=False,
               severe=None, reversal=None):
        """Every expected field action is explicit; a nullable replacement without a clear means keep."""
        set_snapshot(execute, extension, *source)
        reuse = "on" if extension else "off"
        execute(sql=f"SET metro2.reuse_incident_dates='{reuse}';\n" + engine)
        got = json.loads(execute(sql="""
            SELECT to_jsonb(s) FROM (
              SELECT f.account, f.latest_doai AS reporting_as_of, f.php_left_byte_date AS latest_history_month,
                     f.impact_start_date AS bank_start, f.impact_end_date AS bank_end,
                     f.credit_impact_start_date AS credit_start, f.credit_impact_end_date AS credit_end,
                     w.post_impact_month_count AS post_bank_months, w.last_severe_month, w.severe_reversal_month,
                     f.credit_cure_date AS cure_start,
                     (f.credit_cure_date + make_interval(months=>f.cure_consecutive_months_required-1))::date AS cure_confirmed,
                     f.manual_review_flag AS review_flag, f.manual_review_reason AS review_reason,
                     f.remediation_treatment AS treatment, f.full_php AS original_php_newest_first,
                     f.account_status_17a AS source_17a, f.payment_rating_17b AS source_17b,
                     f.date_of_first_delinquency AS source_dofd, f.remediated_account_status_17a AS replacement_17a,
                     f.remediated_payment_rating_17b AS replacement_17b, f.remediated_date_of_first_delinquency AS replacement_dofd,
                     f.clear_account_status_17a AS clear_17a, f.clear_payment_rating_17b AS clear_17b,
                     f.clear_date_of_first_delinquency AS clear_dofd, f.remediated_full_php AS replacement_php_newest_first,
                     (SELECT string_agg(remediated_status,'' ORDER BY byte_date)
                      FROM module2.metro2_remediation_php_detail) AS proposed_history_oldest_first
              FROM module2.metro2_remediation_final f JOIN module2.metro2_remediation_window_eval w USING (account)
            ) s;
        """))
        original = BASE + extension
        revised = BASE[:-1] + proposed_tail
        expect = dict(account=ACCOUNT, reporting_as_of=reporting_month(len(extension)+1),
                      latest_history_month=reporting_month(len(extension)), bank_start=JAN, bank_end=JAN, credit_start=JAN,
                      credit_end=impact_end, post_bank_months=len(extension), last_severe_month=severe,
                      severe_reversal_month=reversal, cure_start="2025-02-01" if cured else None,
                      cure_confirmed="2025-04-01" if cured else None, review_flag=int(review is not None),
                      review_reason=review, treatment=treatment, original_php_newest_first=original[::-1],
                      source_17a=source[0], source_17b=source[1], source_dofd=source[2],
                      replacement_17a=proposed_status, replacement_17b=proposed_rating, replacement_dofd=proposed_date,
                      clear_17a=False, clear_17b=False, clear_dofd=clear_date,
                      replacement_php_newest_first=revised[::-1] if revised != original else None,
                      proposed_history_oldest_first=revised)
        if got != expect:
            diff = {k: (v, got.get(k)) for k, v in expect.items() if v != got.get(k)}
            raise RuntimeError(f"Account 17899 extension {extension!r}, expected and observed fields: {diff!r}")
        queue = export_rows(client, database)
        if [r["account"] for r in queue] != ([str(ACCOUNT)] if review else []):
            raise RuntimeError(f"Account 17899 extension {extension!r}: unexpected monthly handoff.")
        if queue:
            dates = queue[0]
            expected_queue = dict(reporting_as_of=reporting_month(len(extension)+1), latest_history_month=reporting_month(len(extension)),
                                  original_status_17a=source[0] or "", original_payment_rating_17b=source[1] or "",
                                  original_php_newest_first=original[::-1], proposed_php_newest_first=revised[::-1],
                                  proposed_effective_status_17a=proposed_status or source[0] or "",
                                  next_history_month=reporting_month(len(extension)+1), current_streak_months=str(streak),
                                  post_impact_months=str(len(extension)), cure_months_required="3",
                                  original_dofd=source[2] or "", proposed_effective_dofd="" if clear_date else
                                  (proposed_date or source[2] or ""), internal_fields_to_clear="DOFD" if clear_date else "")
            if any(dates[k] != v for k, v in expected_queue.items()):
                raise RuntimeError(f"Account 17899 extension {extension!r}: unexpected handoff evidence.")
        audit = json.loads(execute(file=verifier, variables=["expected_accounts=1", "required_months=3"]))
        if audit["pass"] is not True:
            raise RuntimeError(f"Account 17899 extension {extension!r} failed source reconstruction: {audit!r}")
        return dict(got, next_history_month=queue[0]["next_history_month"] if queue else None,
                    current_streak_at_referral=streak if queue else None)

    december = december_source(execute, generator)
    observed = verify("", ("71","1",DEC), SIMPLE, "D", SHORT, JAN,
                      proposed_status="11", proposed_rating="0", clear_date=True)
    current = [
        verify("0", ("11","0",None), SIMPLE, "D0", SHORT, "2025-02-01", streak=1),
        verify("00", ("11","0",None), SIMPLE, "D00", SHORT, "2025-03-01", streak=2),
        verify("000", ("11","0",None), SIMPLE, "D000", None, JAN, cured=True),
        verify("0002", ("78","2","2025-05-01"), SIMPLE, "D0002", None, JAN, cured=True),
        verify("0002D", ("78","2","2025-05-01"), SIMPLE, "D0002D", None, JAN, cured=True),
        verify("0002D3", ("80","3","2025-05-01"), SIMPLE, "D0002D3", None, JAN, cured=True),
    ]
    # These alternatives start at the same historical February 1 record. A later
    # cutoff from another branch must never be fed into live same-incident reuse.
    set_snapshot(execute, "", "71", "1", DEC)
    execute(sql=engine)
    continued = [
        verify("2", ("78","2",DEC), SIMPLE, "DD", SHORT, "2025-02-01",
               proposed_status="11", proposed_rating="0", clear_date=True),
        verify("2L", ("97","L",DEC), DELETE, "12L", None, "2025-03-01", proposed_status="DA", severe="2025-03-01"),
        verify("2L5", ("83","5",DEC), FULL, "DDDD", OPEN, "2025-04-01",
               proposed_status="11", proposed_rating="0", clear_date=True, severe="2025-03-01", reversal="2025-04-01"),
    ]
    set_snapshot(execute, "", "71", "1", DEC)
    execute(sql=engine)
    original_d = [
        verify("D", ("71","1",DEC), SIMPLE, "DD", SHORT, "2025-02-01"),
        verify("D", (None,"1",DEC), SIMPLE, "DD", SHORT, "2025-02-01"),
        # The supplied February closure makes the edited January 1 the preceding
        # closure-rating byte. February's unavailable D supplies no new evidence.
        verify("D", ("13","1",DEC), SIMPLE, "DD", None, "2025-02-01", proposed_rating="0", clear_date=True),
        verify("2LD", ("97","L",DEC), DELETE, "12LD", None, "2025-04-01", proposed_status="DA", severe="2025-03-01"),
    ]
    print("PASS  Account 17899: Jan 1 status with December first byte, Feb 1 status with January first byte, "
          "and 13 hypothetical cutoffs — next review, "
          "three observed zeros, source D, later delinquency, severe escalation and reversal")
    return {"account": ACCOUNT, "january_1_reconstruction_through_december": december,
            "february_1_retained_snapshot_through_january": observed, "hypothetical_continuations": {
        "current_then_separate_later_delinquency": current, "continued_adverse_then_severe_reversal": continued,
        "source_D_open_unknown_closed_and_deleted_controls": original_d}}
