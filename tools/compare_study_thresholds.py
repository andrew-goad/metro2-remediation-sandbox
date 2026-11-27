"""Compare two full explorer exports from recorded native runs with different cure thresholds."""
import argparse
from collections import Counter
from hashlib import sha256
from itertools import zip_longest
import json
import os
import re
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

from build_explorer import CURRENT_POLICY, FIELD_POLICY, EXPORT_BINDING, bind_record, new_export_digest, verify_account


DEFAULT_ENGINE = Path(__file__).resolve().parents[1] / 'src' / 'module_02_metro2_remediation_engine.sql'
CURE_PARAMETER = re.compile(rb'(?m)^([ \t]*)3([ \t]+-- conservative remediation-policy default[ \t]*\r?)$')


def validate_export(meta, totals, threshold, digest, template):
    seal = meta.get('exportIntegrity')
    if not isinstance(seal, dict) or seal.get('format') != EXPORT_BINDING:
        raise ValueError('Unbound or unsupported viewer. Re-export using build_explorer.py and the verified run receipt to compare policies.')
    bind_record(digest, 'metadata', {key: value for key, value in meta.items() if key != 'exportIntegrity'})
    if digest.hexdigest() != seal.get('sha256'):
        raise ValueError('The export digest differs from the saved accounts or run metadata.')
    receipt = meta.get('verifiedRun')
    if not isinstance(receipt, dict):
        raise ValueError('This viewer lacks a verified native run receipt. Re-export with --run-receipt.')
    n = totals['accounts']
    for key, expected in {'accountCount': n, 'inputCount': n, 'evaluationCount': n, 'blueprintCount': n,
                          'monthCount': totals['represented_months'], 'cureMonths': threshold}.items():
        if type(meta.get(key)) is not int or meta[key] != expected:
            raise ValueError(f'Export metadata {key} differs from the observed accounts, months or threshold.')
    if meta.get('blueprintAlignment') != {'matching fields': n} or meta.get('formatVersion') != 1:
        raise ValueError('Expected a complete study with a matching synthetic blueprint.')
    if (meta.get('databasePolicy'), meta.get('policyId'), meta.get('accountFieldPolicy')) != (CURRENT_POLICY, CURRENT_POLICY, FIELD_POLICY):
        raise ValueError('The recorded policy versions are unsupported for this comparison.')
    native_totals = {'account_count': n, 'represented_months': totals['represented_months'], 'cure_months': threshold,
                     'manual_review_handoff_rows': totals['monthly_cure_reviews'], 'account_field_review_rows': totals['field_research']}
    for key, expected in native_totals.items():
        if type(receipt.get(key)) is not int or receipt[key] != expected:
            raise ValueError(f'Native receipt {key} differs from the observed study.')
    if (receipt.get('database'), receipt.get('module2_policy'), receipt.get('account_field_policy')) != (meta['database'], CURRENT_POLICY, FIELD_POLICY):
        raise ValueError('Native receipt and export disagree on the database or policy identity.')
    # PowerShell ReadAllText consumes an optional UTF-8 BOM; WriteAllText emits UTF-8 without it.
    sql = template[3:] if template.startswith(b'\xef\xbb\xbf') else template
    if len(CURE_PARAMETER.findall(sql)) != 1:
        raise ValueError('The Module 2 template must contain one published cure threshold parameter.')
    configured = CURE_PARAMETER.sub(lambda match: match[1] + str(threshold).encode('ascii') + match[2], sql)
    for raw, meta_key, receipt_key in ((template, 'module2Sha256', 'module2_source_sha256'),
                                       (configured, 'configuredModule2Sha256', 'module2_configured_sha256')):
        expected = sha256(raw).hexdigest()
        if meta.get(meta_key) != expected or str(receipt.get(receipt_key, '')).lower() != expected:
            raise ValueError(f'{meta_key} differs from the supplied Module 2 template or its configured threshold. Use the template from these runs.')
    return seal['sha256']


def accounts(path, metadata):
    decoder = json.JSONDecoder()
    with path.open(encoding="utf-8") as stream:
        if stream.readline().strip() != 'window.METRO2_DATA={"accounts":[':
            raise ValueError(f"Expected a full export from build_explorer.py: {path}")
        for line in stream:
            row, end = decoder.raw_decode(line)
            yield row
            tail = line[end:].strip()
            if tail == ",":
                continue
            if not tail.startswith('],"meta":') or not tail.endswith("};") or stream.read().strip():
                raise ValueError(f"Invalid export trailer: {path}")
            metadata.update(json.loads(tail[len('],"meta":'):-2]))
            return
        raise ValueError(f"Missing metadata: {path}")


def add_digest(digest, values):
    digest.update(json.dumps(values, separators=(",", ":"), ensure_ascii=True).encode("ascii") + b"\n")


def confirm(cure, threshold):
    if cure is None:
        return None
    year, month = map(int, cure[:7].split("-"))
    y, m = divmod(12 * year + month - 1 + threshold - 1, 12)
    return f"{y:04}-{m + 1:02}-01"


def decision(row):
    cure = row["credit_cure_date"]
    return {"threshold":row["cure_consecutive_months_required"],"cure_start":cure,
            "confirmed_through":confirm(cure,row["cure_consecutive_months_required"]),
            "credit_through":row["credit_impact_end_date"],"treatment":row["remediation_treatment"],
            "cure_review":row["manual_review_flag"],"review_reason":row["manual_review_reason"],
            "monthly_edits":sum(m[1]!=m[2] for m in row["months"])}


def compare(first, second, engine_template=DEFAULT_ENGINE):
    template = Path(engine_template).read_bytes()
    metadata=[{},{}]
    digests = [new_export_digest(), new_export_digest()]
    previous_account = None
    treatment_example = None
    treatment_priority = -1
    hashes=[{k:sha256() for k in ("account_ids","source_account_fields","original_dated_months","incident_dates")} for _ in range(2)]
    outcomes=[Counter(),Counter()]
    thresholds=[set(),set()]
    changes=Counter()
    example=None
    example_priority=-1
    source_fields=("account","profile_type","latest_doai","date_closed","account_status_17a","payment_rating_17b",
                   "date_of_first_delinquency","full_php","php_left_byte_date","php_right_byte_date")
    for a,b in zip_longest(accounts(first,metadata[0]),accounts(second,metadata[1])):
        if a is None or b is None or a["account"]!=b["account"]:
            raise ValueError("Cohort size or ordered account IDs differ.")
        if type(a["account"]) is not int or type(b["account"]) is not int or (previous_account is not None and a["account"] <= previous_account):
            raise ValueError("Expected strictly increasing, unique account IDs.")
        previous_account = a["account"]
        decisions=[]
        for i,row in enumerate((a,b)):
            account=row["account"]
            if row.get("remediation_policy") != CURRENT_POLICY or row.get("account_field_policy") != FIELD_POLICY:
                raise ValueError("This historical or unversioned decision can be opened in the viewer. Comparison requires receipt-backed exports of the supported policies.")
            if row.get('blueprint_alignment') != 'matching fields':
                raise ValueError(f'Account {account}: mismatch with the study blueprint.')
            verify_account(row, CURRENT_POLICY, FIELD_POLICY)
            bind_record(digests[i], 'account', row)
            thresholds[i].add(row["cure_consecutive_months_required"])
            d=decision(row); decisions.append(d)
            h=hashes[i]
            add_digest(h["account_ids"],account)
            add_digest(h["source_account_fields"],[row[k] for k in source_fields])
            add_digest(h["incident_dates"],[account,row["impact_start_date"],row["impact_end_date"]])
            add_digest(h["original_dated_months"],[account,[[m[0],m[1]] for m in row["months"]]])
            totals=outcomes[i]
            totals["accounts"]+=1;totals["represented_months"]+=len(row["months"])
            totals["confirmed_cures"]+=int(d["cure_start"] is not None)
            totals["monthly_cure_reviews"]+=d["cure_review"];totals["monthly_edits"]+=d["monthly_edits"]
            totals["field_research"]+=int(row.get("account_field_review_reason") is not None)
            totals["explicit_dofd_clears"]+=int(row["clear_date_of_first_delinquency"])
            totals["accounts_with_monthly_edits"]+=int(d["monthly_edits"]>0)
            totals[d["treatment"]]+=1
        x,y=decisions
        for k in ("cure_start","confirmed_through","credit_through","treatment","cure_review","review_reason","monthly_edits"):
            changes[k]+=int(x[k]!=y[k])
        priority=3 if x["cure_review"]!=y["cure_review"] else 2 if x["credit_through"]!=y["credit_through"] else 1 if x["confirmed_through"]!=y["confirmed_through"] else 0
        treatment_rank = -1
        if x["treatment"] != y["treatment"]:
            treatment_rank = int('TRADELINE_DELETION' in (x['treatment'], y['treatment']))
        if priority > example_priority or treatment_rank > treatment_priority:
            case={"account":a["account"],"bank_start":a["impact_start_date"],"bank_end":a["impact_end_date"],
                     "as_of":a["latest_doai"],"latest_original_month":a["php_left_byte_date"],
                     "original_history_newest_first":a["full_php"],"first":x,"second":y}
            if priority > example_priority:
                example, example_priority = case, priority
            if treatment_rank > treatment_priority:
                treatment_example, treatment_priority = case, treatment_rank
    if not all(len(t)==1 for t in thresholds) or thresholds[0]==thresholds[1]:
        raise ValueError("Supply two cohorts with a different, uniform cure threshold.")
    seals = [validate_export(m, totals, next(iter(t)), digest, template)
             for m, totals, t, digest in zip(metadata, outcomes, thresholds, digests)]
    if metadata[0]['configuredModule2Sha256'] == metadata[1]['configuredModule2Sha256']:
        raise ValueError('Different cure thresholds cannot use the same configured Module 2 SQL.')
    proof=[{k:h.hexdigest() for k,h in hs.items()} for hs in hashes]
    if proof[0]!=proof[1]:
        raise ValueError("Original account fields, dated monthly observations or incident dates differ.")
    identity=[{"database":m["database"],"cure_months":next(iter(t)),"module2_source_sha256":m["module2Sha256"],
               "module2_configured_sha256":m["configuredModule2Sha256"],"snapshot_utc":m["snapshotUTC"],"export_sha256":seal}
              for m,t,seal in zip(metadata,thresholds,seals)]
    return {"pass":True,"studies":identity,"identical_input_sha256":proof[0],"first":dict(outcomes[0]),"second":dict(outcomes[1]),
            "accounts_changed_by_measure":dict(changes),"example":example if example_priority>0 else None,
            "treatment_example":treatment_example}


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline",type=Path);parser.add_argument("alternative",type=Path)
    parser.add_argument("--output",type=Path)
    parser.add_argument("--engine-template",type=Path,default=DEFAULT_ENGINE,
                        help="original Module 2 SQL from both studies (defaults to the kit's src directory)")
    opts=parser.parse_args()
    if opts.output and opts.output.resolve() in {p.resolve() for p in (opts.baseline,opts.alternative,opts.engine_template)}:
        parser.error("Use a separate file for the comparison.")
    try:
        result = json.dumps(compare(opts.baseline, opts.alternative, opts.engine_template), indent=2) + "\n"
        if opts.output:
            temp = None
            try:
                with NamedTemporaryFile(dir=opts.output.parent, mode='w', encoding='utf-8', newline='\n', delete=False) as handle:
                    temp = Path(handle.name)
                    handle.write(result)
                os.chmod(temp, 0o644)
                os.replace(temp, opts.output)
            finally:
                if temp is not None and temp.exists():
                    temp.unlink()
        else:
            print(result, end="")
    except (ValueError, OSError, KeyError, TypeError, IndexError) as exc:
        sys.exit(f"Comparison failed: {exc}")
