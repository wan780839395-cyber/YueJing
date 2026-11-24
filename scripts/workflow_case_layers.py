"""Display-only analysis of a single case's retained evidence; never a release gate."""
import argparse
import json
from pathlib import Path
import re

from workflow_failure_details import ASSERTION, MAX_BYTES


def _read(path):
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError('Not a bounded regular file')
    return path.read_text(encoding='utf-8-sig')


def case_layers(folder, row):
    folder = Path(folder)
    name = re.escape(row['name'])
    # Count only the selected leaf. XCT/Swift suite and enclosing test-run totals overlap it.
    duration = rf"(?:Test Case '-\[[^\]\n]+ {name}\]' (?:passed|failed) \(([0-9.]+) seconds?\)|\bTest {name}\(\) (?:passed|failed) after ([0-9.]+) seconds?)"
    observed = {'outcome': 'unknown', 'first_assertion': None, 'body_seconds': None}
    try:
        text = _read(folder/'native.log')
        if text is not None:
            lines = text.splitlines()
            assertion = next(((i, line.strip()) for i, line in enumerate(lines, 1) if ASSERTION.search(line)), None)
            if assertion:
                observed.update(outcome='assertion_failed', first_assertion={'line': assertion[0], 'message': assertion[1][:2000]})
            finishes = list(re.finditer(duration, text))
            if len(finishes) == 1:
                observed['body_seconds'] = float(finishes[0][1] or finishes[0][2])
                if not assertion:
                    observed['outcome'] = 'observed_failed' if ' failed ' in finishes[0][0] else 'observed_passed'
        elif not row.get('invocation_started') and row.get('status') in ('blocked', 'not_run'):
            observed['outcome'] = 'not_started'
    except (OSError, ValueError) as exc:
        observed['read_error'] = str(exc)
    exports = {}
    for section in ('summary', 'tests'):
        try:
            value = _read(folder/f'xcresult-{section}.json')
            if value is None:
                exports[section] = 'missing'
            else:
                doc = json.loads(value)
                key = 'testNodes' if section == 'tests' else 'totalTestCount'
                exports[section] = 'readable' if isinstance(doc, dict) and key in doc else 'invalid'
        except (ValueError, OSError, RecursionError):
            exports[section] = 'unreadable'
    return dict(qualification='DISPLAY_ONLY', native_status=row['status'], business=observed,
                invocation={k: row.get(k) for k in ('exit_code', 'timed_out', 'case_timed_out', 'elapsed_seconds')},
                export=dict(sections=exports, error=row.get('export_error') or
                            (row.get('error') if 'export' in str(row.get('error', '')).lower() else None)),
                ipa_integrity='not_assessed_by_test_job')


def replay(directory):
    directory = Path(directory)
    receipt = json.loads((directory/'development-summary.json').read_bytes())
    return [dict(name=row['name'], **case_layers(directory/f'case-{i:02d}', row))
            for i, row in enumerate(receipt['cases'], 1)]


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('execution_directory', type=Path)
    print(json.dumps(replay(ap.parse_args().execution_directory), indent=2, ensure_ascii=False))
