"""Exercise Module 1 in an empty disposable PostgreSQL database selected via libpq settings."""
import hashlib
import json
from pathlib import Path


def run_checks(source, psql):
    sql = Path(source).read_text(encoding='utf-8')
    count_text = '5000000,   -- total number of synthetic accounts to generate'
    if sql.count(count_text) != 1:
        raise ValueError('Cannot locate the generator sample-size control')
    names = ('metro2_account_blueprint', 'metro2_status_history', 'metro2_sample', 'metro2_final')
    def fingerprint():
        return {name: psql(f"SELECT count(*) || '/' || md5(string_agg(to_jsonb(t)::text, E'\\n' ORDER BY to_jsonb(t)::text)) FROM module1.{name} AS t") for name in names}

    if psql("SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('module1','public') AND table_name IN ('module1_params','metro2_account_blueprint','metro2_status_history','metro2_sample','metro2_final')") != '0':
        raise ValueError('Generator control needs an empty disposable database')
    psql("CREATE TABLE public.metro2_final(marker int); INSERT INTO public.metro2_final VALUES (19); CREATE TABLE public.module1_params(marker int); INSERT INTO public.module1_params VALUES (23)")
    generated = sql.replace(count_text, '500,   -- total number of synthetic accounts to generate')
    psql(generated)
    first = fingerprint()
    if psql('SELECT (SELECT marker FROM public.metro2_final), (SELECT marker FROM public.module1_params)') != '19|23':
        raise AssertionError('Module 1 touched a same-name public table')
    # A bad parameter must leave the existing rows intact, as must a failure after the reset.
    psql(generated.replace('0.700000,', '0.600000,'), 'profile percentages must sum')
    if first != fingerprint():
        raise AssertionError('Invalid configuration changed an output table')
    psql(generated.replace('CREATE UNIQUE INDEX ix_blueprint_account', 'SELECT 1/0;\nCREATE UNIQUE INDEX ix_blueprint_account'), 'division by zero')
    if first != fingerprint():
        raise AssertionError('Partial rebuild changed an output table')
    # This input sits at the published inclusive upper share tolerance.
    psql(generated.replace('0.700000,', '0.700001,'))
    psql(generated)
    if first != fingerprint():
        raise AssertionError('Two runs with identical defaults produced different rows')
    comparisons = json.loads(psql("""
WITH bad_snapshots AS (
  SELECT s.account, s.date_of_account_information
  FROM module1.metro2_sample AS s
  JOIN module1.metro2_final AS f USING (account)
  WHERE s.php <> rpad(substr(f.full_php, 1 + (extract(year FROM age(f.latest_doai,s.date_of_account_information))*12
                          + extract(month FROM age(f.latest_doai,s.date_of_account_information)))::int, 24),24,'B')
), bad_final AS (
  SELECT f.account FROM module1.metro2_final AS f JOIN module1.metro2_account_blueprint AS b USING (account)
  WHERE length(f.full_php) <> b.months_reporting OR f.php_left_byte_date <> (f.latest_doai - interval '1 month')::date
     OR f.php_right_byte_date <> (b.start_date - interval '1 month')::date OR f.latest_doai <> b.end_date
), history_counts AS (
  SELECT (SELECT sum(months_reporting) FROM module1.metro2_account_blueprint) AS designed,
         (SELECT count(*) FROM module1.metro2_status_history) AS represented,
         (SELECT count(*) FROM module1.metro2_sample) AS snapshots
) SELECT json_build_object('accounts',(SELECT count(*) FROM module1.metro2_final),
  'designed_months',designed,'represented_months',represented,'snapshots',snapshots,
  'snapshot_mismatches',(SELECT count(*) FROM bad_snapshots),'final_date_or_length_mismatches',(SELECT count(*) FROM bad_final),
  'unique_keys',(SELECT count(*) FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid WHERE i.indisunique AND t.relnamespace='module1'::regnamespace),
  'adverse_open_null_dofd',(SELECT count(*) FROM module1.metro2_final WHERE date_closed IS NULL AND left(full_php,1) IN ('1','2','3','4','5','6','G','H','J','K','L') AND date_of_first_delinquency IS NULL),
  'unexpected_dofd',(SELECT count(*) FROM module1.metro2_final WHERE date_of_first_delinquency IS NOT NULL AND (date_closed IS NOT NULL OR left(full_php,1) NOT IN ('1','2','3','4','5','6','G','H','J','K','L'))))
FROM history_counts"""))
    if not (comparisons['accounts'] == 500 and comparisons['designed_months'] == comparisons['represented_months'] == comparisons['snapshots'] and comparisons['unique_keys'] == 4 and not any(comparisons[key] for key in ('snapshot_mismatches','final_date_or_length_mismatches','unexpected_dofd'))):
        raise AssertionError(comparisons)
    arithmetic = psql('SELECT 2147483647::bigint * 13 % 42, LEAST(2147483647, floor(2147483647::numeric * 1.000001))::int')
    if arithmetic != str((2147483647 * 13) % 42) + '|2147483647':
        raise AssertionError(arithmetic)
    return {'pass': True, 'module1_sha256': hashlib.sha256(Path(source).read_bytes()).hexdigest(),
            'public_sentinels': [19,23], 'invalid_config_rollback': True, 'mid_refresh_rollback': True,
            'upper_share_tolerance_accepted': True, 'rerun_equal': True, 'table_fingerprints': first,
            'extreme_arithmetic': arithmetic, 'checks': comparisons}

