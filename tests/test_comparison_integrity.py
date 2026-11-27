"""Run end-to-end comparison controls on the native 1,000-account K3 and K4 full exports."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def load_view(path):
    text = path.read_text(encoding='utf-8')
    return json.loads(text.split('=', 1)[1].strip()[:-1])


def save_view(path, view, renew=False):
    # Independently implement the published record digest to exercise the separate semantic checks.
    if renew:
        algorithm = 'metro2-full-export-v1'
        digest = hashlib.sha256((algorithm + '\n').encode('ascii'))
        records = [('account', row) for row in view['accounts']]
        records.append(('metadata', {k: v for k, v in view['meta'].items() if k != 'exportIntegrity'}))
        for kind, record in records:
            encoded = json.dumps(record, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False)
            digest.update((kind + '\t' + encoded + '\n').encode('ascii'))
        view['meta']['exportIntegrity'] = {'format': algorithm, 'sha256': digest.hexdigest()}
    with path.open('w', encoding='utf-8', newline='\n') as out:
        out.write('window.METRO2_DATA={"accounts":[\n')
        for i, row in enumerate(view['accounts']):
            if i:
                out.write(',\n')
            out.write(json.dumps(row, separators=(',', ':')))
        out.write('],"meta":' + json.dumps(view['meta'], separators=(',', ':')) + '};\n')


def run_controls(k3, k4, template):
    script = Path(__file__).resolve().parents[1] / 'tools' / 'compare_study_thresholds.py'
    original = [load_view(k3), load_view(k4)]
    results = {}
    with tempfile.TemporaryDirectory() as work:
        folder = Path(work)
        output = folder / 'comparison.json'
        def compare(a, b):
            return subprocess.run([sys.executable, str(script), str(a), str(b), '--engine-template', str(template),
                                   '--output', str(output)], capture_output=True, text=True)
        valid = compare(k3, k4)
        assert valid.returncode == 0, valid.stderr
        last_good = output.read_bytes()
        study = json.loads(last_good)
        assert [study[side]['monthly_cure_reviews'] for side in ('first', 'second')] == [133, 147]
        assert study['example']['account'] == 57 and study['treatment_example']['account'] == 975

        def reject(name, change, *, renew=False, expected=''):
            left, right = copy.deepcopy(original)
            change(left, right)
            a, b = folder/'first.js', folder/'second.js'
            save_view(a, left, renew)
            save_view(b, right, renew)
            attempt = compare(a, b)
            assert attempt.returncode != 0 and expected in attempt.stderr, (name, attempt.stderr)
            assert output.read_bytes() == last_good, name
            results[name] = attempt.stderr.strip()

        def close_57(left, right):
            account = next(a for a in right['accounts'] if a['account'] == 57)
            account.update(manual_review_flag=0, manual_review_reason=None)

        def mislabeled(left, right):
            right.update(copy.deepcopy(left))
            for row in right['accounts']:
                row['cure_consecutive_months_required'] = 4

        def truncate(left, right, rewrite_counts=False):
            for view in (left, right):
                removed = view['accounts'].pop(0)
                if rewrite_counts:
                    for name in ('accountCount', 'inputCount', 'evaluationCount', 'blueprintCount'):
                        view['meta'][name] -= 1
                    view['meta']['blueprintAlignment']['matching fields'] -= 1
                    view['meta']['monthCount'] -= len(removed['months'])

        def copied_config(left, right):
            wrong = left['meta']['configuredModule2Sha256']
            right['meta']['configuredModule2Sha256'] = wrong
            right['meta']['verifiedRun']['module2_configured_sha256'] = wrong

        reject('changed referral', close_57, expected='ongoing review')
        reject('relabeled three-month rows', mislabeled, expected='Comparison failed')
        reject('corresponding filtered accounts', truncate, expected='digest')
        reject('changed referral with recomputed digest', close_57, renew=True, expected='ongoing review')
        reject('corresponding filtered accounts with recomputed digests', truncate, renew=True, expected='accountCount')
        reject('rewritten counts with genuine run receipt', lambda a, b: truncate(a, b, True), renew=True, expected='Native receipt account_count')
        reject('copied configured SQL identity', copied_config, renew=True, expected='configuredModule2Sha256')
        reject('changed metadata', lambda a, b: b['meta'].update(snapshotUTC='2025-01-01T00:00:00Z'), expected='digest')
        reject('unbound older viewer', lambda a, b: b['meta'].pop('exportIntegrity'), expected='Unbound')
        reject('missing native run receipt', lambda a, b: b['meta'].pop('verifiedRun'), renew=True, expected='lacks a verified native run receipt')
        return {'pass': True, 'native_open_reviews': [133, 147], 'example': 57, 'treatment_example': 975,
                'last_good_comparison_sha256': hashlib.sha256(last_good).hexdigest(),
                'rejections_preserved_prior_bytes': results}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('k3', type=Path)
    parser.add_argument('k4', type=Path)
    parser.add_argument('--engine-template', type=Path, default=Path(__file__).resolve().parents[1] / 'src' / 'module_02_metro2_remediation_engine.sql')
    parser.add_argument('--output', type=Path)
    opts = parser.parse_args()
    text = json.dumps(run_controls(opts.k3, opts.k4, opts.engine_template), indent=2) + '\n'
    if opts.output:
        opts.output.write_text(text, encoding='utf-8')
    else:
        print(text, end='')
