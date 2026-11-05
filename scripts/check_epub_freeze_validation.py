"""Offline checks only. No Swift, simulator, build, dispatch or native acceptance."""
import copy
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

import run_epub_freeze_validation as r
import validate_task3 as v

checks = []

def rejects(label, action):
    try:
        action()
    except (ValueError, OSError):
        checks.append(label)
    else:
        raise AssertionError('Expected rejection: ' + label)


def fixture(group):
    names = r.GROUPS[group]['cases']
    if group == 'host':
        text = ''.join(f'◇ Test {n}() started.\n✔ Test {n}() passed after 0.1 seconds.\n' for n in names)
        text += '✔ Test run with 2 tests passed after 0.2 seconds.\n'
    else:
        text = ''.join(f"Test Case '-[EPUBFlowUITests {n}]' started.\nTest Case '-[EPUBFlowUITests {n}]' passed (0.1 seconds).\n" for n in names)
        text += 'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n'
    return (text + '** TEST SUCCEEDED **\n').encode('utf-8')


assert sum(map(len, r.selection().values())) == 3
checks.append('exact existing Host2/UI1 selection within inventory214')
for group in r.GROUPS:
    raw = fixture(group)
    assert r.parse_log(group, raw, 0, False)['passed'] == r.GROUPS[group]['cases']
    checks.append(group + ' valid synthetic event parse (not native execution)')
    rejects(group + ' nonzero exit', lambda: r.parse_log(group, raw, 65, False))
    rejects(group + ' timeout', lambda: r.parse_log(group, raw, 0, True))
    rejects(group + ' missing success', lambda: r.parse_log(group, raw.replace(b'** TEST SUCCEEDED **', b''), 0, False))
    rejects(group + ' late pass', lambda: r.parse_log(group, raw.replace(b'0.1 seconds', b'181.1 seconds'), 0, False))
    rejects(group + ' duplicate events', lambda: r.parse_log(group, raw + raw, 0, False))
    rejects(group + ' missing case', lambda: r.parse_log(group, raw.replace(r.GROUPS[group]['cases'][0].encode(), b'foreignCase'), 0, False))
    command = r.command(group, 'platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555', Path('synthetic.xcresult'))
    assert len([a for a in command if a.startswith('-only-testing:')]) == len(r.GROUPS[group]['cases'])
    assert '-parallel-testing-enabled' in command and command.count('180') == 2
rejects('device destination', lambda: r.command('host', 'generic/platform=iOS', Path('synthetic')))

base_project = r.git('show', r.BASE + ':project.yml')
old = {p: ['100644', 'blob', '1'*40] for p in r.ALLOWED - r.NEW}
old['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '3'*40]
current = {**old, **{p: ['100644', 'blob', '2'*40] for p in r.ALLOWED}}
head = 'a'*40
env = dict(VALIDATION_SCOPE=r.SCOPE, GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
           GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='wan780839395-cyber/YueJing', GITHUB_SHA=head, GITHUB_RUN_ID='12345')
def fakegit(*args):
    if args == ('rev-parse', 'HEAD'): return head.encode()
    if args[0] in ('merge-base', 'status'): return b''
    if args == ('show', r.BASE + ':project.yml'): return base_project
    raise AssertionError(args)
with patch.dict(os.environ, env), patch.object(r, 'git', side_effect=fakegit), patch.object(r, 'tree', side_effect=lambda rev: old if rev == r.BASE else current):
    receipt = r.scope_receipt()
    assert receipt['native_tests_planned'] == 3 and 'verified_passed' not in receipt
    checks.append('valid frozen source scope does not claim test execution')
    for key, value in [('VALIDATION_SCOPE', 'full'), ('GITHUB_SHA', 'b'*40), ('GITHUB_RUN_ATTEMPT', '2'),
                       ('GITHUB_REPOSITORY', 'foreign/repo'), ('GITHUB_REF', 'refs/heads/other')]:
        with patch.dict(os.environ, {key: value}):
            rejects('foreign ' + key, r.scope_receipt)
    current['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '4'*40]
    rejects('unapproved product drift', r.scope_receipt)
    current['Sources/ReaderDomain/untouched.swift'] = old['Sources/ReaderDomain/untouched.swift']
    with patch.dict(os.environ, {'VALIDATION_SCOPE': r.DIAGNOSTIC_SCOPE}):
        diagnostic = r.scope_receipt()
        assert diagnostic['selected'] == {} and diagnostic['native_tests_planned'] == 0

with tempfile.TemporaryDirectory(prefix='epub-freeze-selfcheck-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
    out = Path(temp)
    with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', out/'epub-freeze'), \
         patch.object(r, 'GATE_JSON', out/'gate.json'), patch.object(r, 'live_scope', return_value=diagnostic):
        qualified = r.qualification()
        assert qualified['coverage'] == 'UI_NOT_QUALIFIED' and qualified['native_tests_executed_this_run'] == 0
        assert qualified['qualification'] == 'DEVICE_DIAGNOSTIC_ONLY' and qualified['verified_passed'] == 0
        (out/'gate.json').write_text(json.dumps(qualified), encoding='utf-8')
        assert r.validate_saved() == qualified
        checks.append('explicit diagnostic disclosure with zero executed/pass count')
        altered = copy.deepcopy(qualified); altered['native_tests_executed_this_run'] = 3
        (out/'gate.json').write_text(json.dumps(altered), encoding='utf-8')
        rejects('forged diagnostic pass receipt', r.validate_saved)
        (out/'simulator-selection.json').write_text('{}', encoding='utf-8')
        rejects('diagnostic mixed with simulator evidence', r.qualification)
        (out/'simulator-selection.json').unlink()
        (out/'epub-freeze').mkdir()
        rejects('diagnostic mixed with test output', r.qualification)
with patch.object(v.sys, 'platform', 'darwin'):
    rejects('mixed device package qualification', lambda: v.package_gate(epub_freeze=True, diagnostic=True))
    rejects('mixed IPA qualification', lambda: v.verify_ipa(epub_freeze=True, epub_reading=True))
print(json.dumps(dict(offline_checks_passed=len(checks), checks=checks, native_tests_executed=0), indent=2))
