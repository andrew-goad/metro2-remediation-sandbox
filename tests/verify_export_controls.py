"""Check the retained-CSV entry point and atomic preservation of a valid explorer."""
import argparse
import copy
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

def load_cases(path):
    text = path.read_text(encoding="utf-8")
    study = json.loads(text.removeprefix("window.METRO2_DATA=").strip().removesuffix(";"))
    cleanup = next(row for row in study["accounts"]
                   if row["remediation_treatment"].endswith("PHP_CLEANUP") and
                   any(m[1] == "0" and m[3] for m in row["months"]) and
                   any(m[1] in "123456GHJKL" and m[3] for m in row["months"]))
    deletion = next(row for row in study["accounts"] if row["remediation_treatment"] == "TRADELINE_DELETION")
    clean = next(row for row in study["accounts"] if row["remediation_treatment"] == "NO_IMPACT_CLEAN_PHP_HISTORY")
    clear = next(row for row in study["accounts"] if row["clear_date_of_first_delinquency"])
    return study["meta"], cleanup, deletion, clean, clear

def altered_history(row, position, mark, *, original=False):
    if original:
        row["months"][position][1] = mark
        row["full_php"] = "".join(month[1] for month in row["months"])
    row["months"][position][2] = mark
    new_php = "".join(month[2] for month in row["months"])
    row["remediated_full_php"] = new_php if new_php != row["full_php"] else None

def test(full):
    meta, cleanup, deletion, clean, clear = load_cases(full)
    cases = []
    def add(name, row, modify, error):
        row = copy.deepcopy(row)
        modify(row)
        cases.append((name,row,error))
    inside_current = next(i for i,m in enumerate(cleanup["months"]) if m[1]=="0" and m[3])
    removed = next(i for i,m in enumerate(cleanup["months"]) if m[1] in "123456GHJKL" and m[3])
    deletion_month = next(i for i,m in enumerate(deletion["months"]) if m[1] in "GHJKL" and m[3])
    add("future evidence", cleanup, lambda r:r.update(latest_doai=r["php_left_byte_date"]), "reporting date")
    add("mid-month cutoff", cleanup, lambda r:r.update(latest_doai=r["latest_doai"][:-2]+"02"), "first-of-month")
    add("unsupported original in summary and detail", cleanup, lambda r:altered_history(r,0,"X",original=True), "unsupported original")
    add("padding after reporting began", cleanup, lambda r:altered_history(r,0,"B",original=True), "unsupported original")
    add("unsupported proposal in summary and detail", cleanup, lambda r:altered_history(r,removed,"X"), "unsupported proposed")
    add("unwarranted suppression of current", cleanup, lambda r:altered_history(r,inside_current,"D"), "matching treatment")
    add("missing elected cleanup", cleanup, lambda r:altered_history(r,removed,r["months"][removed][1]), "matching treatment")
    add("month edit on deletion", deletion, lambda r:altered_history(r,deletion_month,"D"), "matching treatment")
    add("invented DOFD", cleanup, lambda r:r.update(remediated_date_of_first_delinquency="2025-03-01"), "remediated_date_of_first_delinquency")
    add("delete an unaffected account", clean, lambda r:r.update(remediated_account_status_17a="DA", remediation_applied_flag=1, remediation_fields_modified="STATUS_ONLY"), "remediated_account_status_17a")
    add("omit an elected clear", clear, lambda r:r.update(clear_date_of_first_delinquency=False), "clear_date_of_first_delinquency")
    add("extra internal rating on deletion", deletion, lambda r:r.update(remediated_payment_rating_17b="0"), "remediated_payment_rating_17b")
    add("fabricated field referral", clear, lambda r:r.update(account_field_review_reason="MISSING_REQUIRED_PAYMENT_RATING"), "account_field_review_reason")
    add("incorrect field groups", clean, lambda r:r.update(remediation_fields_modified="PHP_ONLY"), "field summary")
    add("field action flag as Boolean", clean, lambda r:r.update(remediation_applied_flag=False), "applied flag")
    add("clear flag as integer", clean, lambda r:r.update(clear_date_of_first_delinquency=0), "invalid clear action")
    add("missing incident month boundary", cleanup, lambda r:r.update(impact_end_date=r["impact_end_date"][:-2]+"02"), "first-of-month")
    add("different policy on account", clear, lambda r:r.update(account_field_policy="unknown"), "mixed account-field policies")
    results = {}
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        fixture, output = work/"input.csv", work/"data.js"
        cmd = [sys.executable,str(Path(__file__).resolve().parents[1]/"tools/build_explorer.py"),
               "--csv",str(fixture),"--output",str(output)]
        def write(row):
            row=dict(row,sources_agree=True)
            bound=dict(meta,blueprintCount=1,inputCount=1,evaluationCount=1,accountCount=1,monthCount=len(row["months"]))
            with fixture.open("w",encoding="utf-8",newline="") as f:
                writer=csv.writer(f)
                writer.writerow(["row_json"])
                for rec in (bound,row):writer.writerow([json.dumps(rec)])
        write(cleanup)
        subprocess.run(cmd,capture_output=True,text=True,check=True)
        before = output.read_bytes()
        for name,row,reason in cases:
            write(row)
            run = subprocess.run(cmd,capture_output=True,text=True)
            assert run.returncode and reason in run.stderr,(name,run.returncode,run.stderr)
            assert output.read_bytes()==before, name
            results[name] = run.stderr.strip()
    return {"pass":True,"validated_previous_export_sha256":hashlib.sha256(before).hexdigest(),
            "rejected_and_previous_file_preserved":results}

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full-export", type=Path,required=True)
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    receipt=json.dumps(test(args.full_export),indent=2)+"\n"
    if args.output:args.output.write_text(receipt,encoding="utf-8")
    else:print(receipt,end="")
