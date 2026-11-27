"""Compact a verified full-data export for the separate large-cohort account explorer."""
import argparse
from datetime import date
import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

PREFIX = 'window.METRO2_DATA={"accounts":['
RAW_HISTORY = {"full_php", "remediated_full_php"}
DECODER = json.JSONDecoder()


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).replace("<", r"\u003c")


def check_months(row):
    """Recover exactly the same dated record as the browser's selected-account view."""
    latest = date.fromisoformat(row["php_left_byte_date"])
    serial = latest.year * 12 + latest.month - 1
    before = row["full_php"]
    after = row["remediated_full_php"] or before
    rows = row["months"]
    if not len(before) == len(after) == len(rows):
        raise ValueError(f"Account {row['account']} has conflicting history lengths")
    for offset, raw in enumerate(rows):
        year, month_index = divmod(serial - offset, 12)
        period = date(year, month_index + 1, 1).isoformat()
        inside = int(row["credit_impact_start_date"] <= period <= row["credit_impact_end_date"])
        if raw != [period, before[offset], after[offset], inside]:
            raise ValueError(f"Failed monthly reconstruction for account {row['account']}, {period}")
    return len(rows)


def collect_examples(guides, row):
    treatment = row["remediation_treatment"]
    account = row["account"]
    last_severe = row.get("last_severe_month")
    reversal = row.get("severe_reversal_month")
    if (treatment == "FULL_DEROGATORY_PHP_CLEANUP" and last_severe and reversal and row["manual_review_flag"]
            and any(period == last_severe and original == "L" for period, original, _, _ in row["months"])
            and any(period == reversal and original in "123456" for period, original, _, _ in row["months"])):
        if account == 327 or "reversal" not in guides:
            guides["reversal"] = account
    if treatment == "TRADELINE_DELETION":
        impact_start = row["impact_start_date"]
        impact_end = row["impact_end_date"]
        chargeoff_dates = [period for period, original, _, inside in row["months"] if original == "L" and inside]
        first_charge_off = min((period for period, original, _, _ in row["months"] if original == "L"), default=None)
        if (first_charge_off and impact_start <= first_charge_off <= impact_end
                and (not last_severe or last_severe in chargeoff_dates)):
            guides.setdefault("chargeOff", account)
        # The preceding study sometimes selected deletion after a return to payment reporting.
        if (last_severe is None and chargeoff_dates and impact_end < min(chargeoff_dates) and row["credit_cure_date"] is None
                and any(period > max(chargeoff_dates) and original in "0123456"
                        for period, original, _, _ in row["months"])):
            if account == 327 or "chargeOffAfterIssue" not in guides:
                guides["chargeOffAfterIssue"] = account
    if treatment == "SIMPLE_DELINQUENCY_PHP_CLEANUP" and row["credit_cure_date"] and "extended" not in guides:
        end = row["impact_end_date"]
        late_at_end = any(period == end and original in "123456"
                          for period, original, _, _ in row["months"])
        if late_at_end and any(period > end and original != revised
                               for period, original, revised, _ in row["months"]):
            guides["extended"] = account
    if (treatment == "FULL_DEROGATORY_PHP_CLEANUP" and row["manual_review_flag"]
            and not any(original == "L" and inside for _, original, _, inside in row["months"])):
        guides.setdefault("openRecovery", account)
    if (treatment == "SIMPLE_DELINQUENCY_PHP_CLEANUP" and row["manual_review_reason"] == "NO_CURE_OPEN_ACCOUNT"
            and row["months"][0][1] in "123456"):
        guides.setdefault("ongoing", account)
    if row["remediated_account_status_17a"] is not None and row["remediated_payment_rating_17b"] is not None:
        guides.setdefault("fieldChange", account)
    if treatment == "NO_IMPACT_CLEAN_PHP_HISTORY":
        guides.setdefault("clean", account)


def compact(source, destination):
    dictionaries = {}
    fields = []
    count = months = 0
    guides = {}
    meta = None
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with source.open(encoding="utf-8") as src, NamedTemporaryFile(dir=destination.parent, mode="w", encoding="utf-8", delete=False) as dst:
            temp = Path(dst.name)
            if src.readline().strip() != PREFIX:
                raise ValueError("Use the data.js produced by build_explorer.py")
            dst.write('window.METRO2_PACKED={"rows":[\n')
            for line in src:
                row, end = DECODER.raw_decode(line)
                trailing = line[end:].strip()
                if not fields:
                    fields = [key for key in row if key != "months"]
                if (set(row) - {"months"}) != set(fields):
                    raise ValueError("Inconsistent account columns")
                months += check_months(row)
                collect_examples(guides, row)
                values = []
                for key in fields:
                    value = row[key]
                    if isinstance(value, str) and key not in RAW_HISTORY:
                        book = dictionaries.setdefault(key, {})
                        value = book.setdefault(value, len(book))
                    values.append(value)
                if count:
                    dst.write(",\n")
                dst.write(encode(values))
                count += 1
                if trailing == ",":
                    continue
                if not trailing.startswith('],"meta":') or not trailing.endswith("};"):
                    raise ValueError("Missing export metadata")
                meta = json.loads(trailing[len('],"meta":'):-2])
                if src.read().strip():
                    raise ValueError("Unexpected trailing data")
                break
            if not meta or (count, months) != (meta["accountCount"], meta["monthCount"]):
                raise ValueError("Reconstructed totals do not match the verified export")
            books = {key: list(book) for key, book in dictionaries.items()}
            dst.write('],"fields":' + encode(fields) + ',"dictionaries":' + encode(books) +
                      ',"guideIds":' + encode(guides) + ',"meta":' + encode(meta) + '};\n')
        os.chmod(temp, 0o644)
        temp.replace(destination)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)
    print(f"{count:,} accounts and {months:,} monthly rows reconstructed; {destination.stat().st_size:,} bytes.")
    print("Case selections:", json.dumps(guides, sort_keys=True))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path, help="full data.js from build_explorer.py")
    p.add_argument("destination", type=Path, help="output scale/data.js")
    args = p.parse_args()
    if args.source.resolve() == args.destination.resolve():
        p.error("Source and destination must be different files.")
    compact(args.source, args.destination)
