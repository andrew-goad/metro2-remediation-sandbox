"""Exercise the Field 25 evidence report with independent status, rating and field-action cases."""
import csv
from io import StringIO
import json


def run_checks(execute, read_csv, sql_file):
    rows = []
    expected = {}
    status_reason = "DATE_REQUIRED_BY_STATUS"
    closed_reason = "DATE_REQUIRED_BY_STATUS_AND_RATING"
    legacy_reason = "DATE_REQUIRED_BY_HISTORICAL_05_AND_RATING"

    def add(status, rating, reason=None, **changes):
        account = len(rows) + 1
        row = dict(
            account=account, account_status_17a=status, payment_rating_17b=rating,
            latest_doai="2020-10-01", php_left_byte_date="2020-09-01",
            impact_start_date="2020-02-01", impact_end_date="2020-03-01",
            credit_impact_start_date="2020-02-01", credit_impact_end_date="2020-04-01",
            credit_cure_date="2020-05-01", cure_consecutive_months_required=3,
            remediation_treatment="NO_IMPACT_CLEAN_PHP_HISTORY", manual_review_flag=0,
            clear_account_status_17a=False, clear_payment_rating_17b=False, clear_date_of_first_delinquency=False,
        )
        row.update(changes)
        rows.append(row)
        if reason:
            expected[account] = reason
        return account

    # Historical Field 25 status groups, including the paid or closed derogatory statuses.
    for status in "61 62 63 64 65 71 78 80 82 83 84 88 89 93 94 95 96 97".split():
        add(status, None, status_reason)
    for status, reason in (("13", closed_reason), ("05", legacy_reason)):
        for rating in "123456GL":
            add(status, rating, reason)
        for rating in (None, "0", "H", "J", "K"):
            add(status, rating)
    for status in ("11", "60", "66", "70", "72", "81", "85", "87", "90", "92", "98", None):
        add(status, "L")

    # Independent controls for sparse replacements, explicit clears, deletion and cure disposition.
    replaced_status = add("11", None, status_reason, remediated_account_status_17a="97")
    replaced_rating = add("13", "0", closed_reason, remediated_payment_rating_17b="G")
    cleared_date = add("71", None, status_reason, date_of_first_delinquency="2020-01-01",
                       clear_date_of_first_delinquency=True, credit_cure_date=None, manual_review_flag=1,
                       manual_review_reason="NO_CURE_OPEN_ACCOUNT", credit_impact_end_date="2020-09-01",
                       remediation_treatment="SIMPLE_DELINQUENCY_PHP_CLEANUP")
    add("97", None, date_of_first_delinquency="2020-01-01")
    add("97", None, remediated_date_of_first_delinquency="2020-01-01")
    add("97", None, clear_account_status_17a=True)
    add("97", None, remediated_account_status_17a="11")
    add("13", "L", clear_payment_rating_17b=True)
    add("13", "L", remediated_payment_rating_17b="0")
    add("97", "L", remediation_treatment="TRADELINE_DELETION")
    add("97", "L", remediation_treatment="TRADELINE_DELETION", remediated_account_status_17a="DA")

    # The caller owns this uniquely named, disposable database. Populate its existing
    # final table type so schema regressions fail at the ordinary report entry point.
    final = "module2.metro2_remediation_final"
    payload = "'" + json.dumps(rows).replace("'", "''") + "'"
    execute(sql=f"""
        TRUNCATE {final};
        INSERT INTO {final}
        SELECT * FROM jsonb_populate_recordset(NULL::{final}, {payload}::jsonb);
    """)
    columns = (
        "account reporting_as_of latest_history_month source_status_17a source_rating_17b source_field25 "
        "effective_status_17a effective_rating_17b effective_field25 exception_reason date_evidence_gap "
        "proposed_action bank_impact_start bank_impact_end credit_impact_start credit_impact_through "
        "cure_start cure_confirmed_through proposed_treatment bank_cure_review_flag bank_cure_review_reason"
    ).split()

    def export():
        reader = csv.DictReader(StringIO(read_csv(file=sql_file), newline=""))
        if reader.fieldnames != columns:
            raise RuntimeError(f"Unexpected Field 25 CSV columns: {reader.fieldnames!r}.")
        return list(reader)

    records = export()
    if [(int(r["account"]), r["exception_reason"]) for r in records] != sorted(expected.items()):
        raise RuntimeError("Field 25 exception membership, order, uniqueness or reason failed.")
    for r in records:
        account = int(r["account"])
        source = rows[account - 1]
        clear = account == cleared_date
        details = {
            "reporting_as_of": "2020-10-01", "latest_history_month": "2020-09-01",
            "source_status_17a": source["account_status_17a"], "source_rating_17b": source["payment_rating_17b"] or "",
            "source_field25": "2020-01-01" if clear else "", "effective_field25": "",
            "effective_status_17a": "97" if account == replaced_status else source["account_status_17a"],
            "effective_rating_17b": "G" if account == replaced_rating else (source["payment_rating_17b"] or ""),
            "date_evidence_gap": "DATE_CLEARED_BY_PROPOSAL" if clear else "DATE_ABSENT_IN_SOURCE",
            "bank_impact_start": "2020-02-01", "bank_impact_end": "2020-03-01", "credit_impact_start": "2020-02-01",
            "credit_impact_through": "2020-09-01" if clear else "2020-04-01",
            "cure_start": "" if clear else "2020-05-01", "cure_confirmed_through": "" if clear else "2020-07-01",
            "proposed_treatment": source["remediation_treatment"], "bank_cure_review_flag": "1" if clear else "0",
            "bank_cure_review_reason": "NO_CURE_OPEN_ACCOUNT" if clear else "",
        }
        for field, value in details.items():
            if r[field] != value:
                raise RuntimeError(f"Field 25 account {account}, {field}: expected {value!r}, got {r[field]!r}.")
        if "servicing" not in r["proposed_action"].lower():
            raise RuntimeError(f"Missing servicing-evidence instruction for Field 25 account {account}.")
    execute(sql=f"UPDATE {final} SET date_of_first_delinquency=DATE '2020-01-01', clear_date_of_first_delinquency=false;")
    if export():
        raise RuntimeError("Field 25 export must preserve headers and have zero rows when every date is present.")
    print(f"PASS  Field 25 CSV: {len(rows)} controlled inputs, {len(records)} exact eligible rows, "
          "sparse field actions, dated context, independent cure disposition and header-only empty export")
