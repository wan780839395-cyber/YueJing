"""Offline, synthetic gate checks only: no build, dispatch, Swift or native acceptance."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
from unittest.mock import patch
import zipfile

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
    spec = r.GROUPS[group]
    text = ''
    for name in spec['cases']:
        if spec['kind'] == 'ui':
            text += f"Test Case '-[EPUBFlowUITests {name}]' started.\nTest Case '-[EPUBFlowUITests {name}]' passed (0.1 seconds).\n"
        else:
            param = r.inventory.PARAMETERIZED.get(name)
            signature = name + (param['signature'] if param else '()')
            text += f'◇ Test {signature} started.\n'
            if param:
                text += ''.join(f'◇ Passing 1 argument symlink → {value} to {signature}\n' for value in param['values'])
            text += f'✔ Test {signature} passed after 0.1 seconds.\n'
    if spec['kind'] == 'ui':
        text += 'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n'
    else:
        text += f"✔ Test run with {len(spec['cases'])} tests passed after 0.2 seconds.\n"
    return (text + '** TEST SUCCEEDED **\n').encode('utf-8')


selected = r.selection()
assert [len(n) for n in selected.values()] == [18, 1, 1, 1, 1]
assert len(r.ALLOWED) == 20 and not r.NEW
reviewed = r.inventory.validate_source()
assert json.loads(json.dumps(reviewed)) == reviewed
checks.append('candidate inventory survives JSON roundtrip')
checks.append('exact Domain18 Host3 UI1 / inventory222 declarations, 223 expansions')
destination = 'platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555'
for group in r.GROUPS:
    raw = fixture(group)
    parsed = r.parse_log(group, raw, 0, False)
    assert parsed['passed'] == r.GROUPS[group]['cases']
    assert parsed['executions'] == (19 if group == 'domain' else 1)
    checks.append(group + ' valid synthetic events, not native execution')
    rejects(group + ' nonzero exit', lambda: r.parse_log(group, raw, 65, False))
    rejects(group + ' bool exit', lambda: r.parse_log(group, raw, False, False))
    rejects(group + ' timeout', lambda: r.parse_log(group, raw, 0, True))
    rejects(group + ' missing success', lambda: r.parse_log(group, raw.replace(b'** TEST SUCCEEDED **', b''), 0, False))
    rejects(group + ' late pass', lambda: r.parse_log(group, raw.replace(b'0.1 seconds', b'181.1 seconds'), 0, False))
    rejects(group + ' duplicate events', lambda: r.parse_log(group, raw + raw, 0, False))
    rejects(group + ' missing case', lambda: r.parse_log(group, raw.replace(r.GROUPS[group]['cases'][0].encode(), b'foreignCase'), 0, False))
    rejects(group + ' failed despite green', lambda: r.parse_log(group, raw + b'Test extra failed\n', 0, False))
    rejects(group + ' skipped despite green', lambda: r.parse_log(group, raw + b'Test extra skipped\n', 0, False))
    command = r.command(group, destination, Path('synthetic.xcresult'))
    assert len([a for a in command if a.startswith('-only-testing:')]) == len(r.GROUPS[group]['cases'])
    assert command.count('180') == 2 and r.GROUPS[group]['timeout'] == 480
    assert command[command.index('-scheme') + 1] == ('ReaderDomain' if group == 'domain' else 'YueJingUI')
rejects('device destination', lambda: r.command('host-1', 'generic/platform=iOS', Path('synthetic')))
raw = fixture('domain')
arg_line = next(line for line in raw.splitlines(keepends=True) if b'Passing ' in line)
for label, altered in [('missing argument', raw.replace(arg_line, b'')),
                       ('duplicate argument', raw.replace(arg_line, arg_line * 2)),
                       ('foreign argument', raw.replace(b'false to ', b'unknown to ')),
                       ('argument after finish', raw.replace(arg_line, b'') + arg_line),
                       ('expanded count pretending declarations', raw.replace(b'18 tests passed', b'19 tests passed'))]:
    rejects(label, lambda: r.parse_log('domain', altered, 0, False))
with patch.dict(r.SELECTED_FILES, {'ReaderDomainTests/EPUBCompatibilityTests.swift': ['foreignCase']}):
    rejects('selection identity drift', r.selection)

parameter = next(iter(r.inventory.PARAMETERIZED))
result_tree = {'testNodes': [{'name': parameter + '(symlink:)', 'result': 'Passed', 'children': [
    {'name': 'symlink: false', 'nodeType': 'Arguments', 'result': 'Passed'},
    {'name': 'symlink: true', 'nodeType': 'Arguments', 'result': 'Passed'}]}]}
assert r.parameter_result(result_tree)['passed_arguments'] == ['false', 'true']
checks.append('both parameter xcresult leaves required')
for label, mutate in [
    ('missing parameter leaf', lambda x: x['testNodes'][0]['children'].pop()),
    ('duplicate parameter leaf', lambda x: x['testNodes'][0]['children'].append(x['testNodes'][0]['children'][0])),
    ('skipped parameter leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Skipped')),
    ('failed parameter leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Failed')),
    ('failed parameter parent', lambda x: x['testNodes'][0].update(result='Failed')),
    ('substring parameter impostor', lambda x: x['testNodes'][0].update(name='foreign' + parameter + '(symlink:)')),
    ('foreign parameter tree', lambda x: x['testNodes'][0].update(name='foreign')),
]:
    altered = copy.deepcopy(result_tree); mutate(altered)
    rejects(label, lambda: r.parameter_result(altered))

# Text routing check is dependency-free and scoped to this existing workflow.
workflow = (r.ROOT / '.github/workflows/task3-validate.yml').read_text(encoding='utf-8')
job = workflow.split('\n  epub_freeze:\n')[1]
assert 'default: ' + r.SCOPE in workflow
assert "inputs.validation_scope != '" + r.SCOPE + "'" in workflow.split('\n  epub_freeze:\n')[0]
assert "if: ${{ inputs.validation_scope == '" + r.SCOPE + "' }}" in job
assert 'epub-freeze-diagnostic' not in workflow and 'epub-freeze-3' not in workflow
assert 'run domain' in job and 'for group in host-1 host-2 host-3' in job and 'run ui' in job
assert job.index('run_epub_freeze_validation.py gate') < job.index('Compile actual unsigned') < job.index('package-gate-epub-freeze') < job.index('verify-ipa-epub-freeze')
assert 'continue-on-error' not in job and 'Publish verified unsigned IPA' in job and 'if: success()' in job
checks.append('exclusive new scope routing / no fallback / release follows native gate')

base_project = r.git('show', r.BASE + ':project.yml')
old = {p: ['100644', 'blob', '1'*40] for p in r.ALLOWED}
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
# Scope fixtures isolate the boundary validator; actual missing UI coverage is disclosed below.
with patch.dict(os.environ, env), patch.object(r, 'git', side_effect=fakegit), \
     patch.object(r, 'tree', side_effect=lambda rev: old if rev == r.BASE else current), \
     patch.object(r, 'ui_reopen_contract'):
    receipt = r.scope_receipt()
    assert receipt['native_tests_planned'] == 23 and 'verified_passed' not in receipt
    checks.append('scope binds exact20 paths and makes no native-pass claim')
    for key, value in [('VALIDATION_SCOPE', 'full'), ('VALIDATION_SCOPE', r.DIAGNOSTIC_SCOPE),
                       ('GITHUB_SHA', 'b'*40), ('GITHUB_RUN_ATTEMPT', '2'),
                       ('GITHUB_REPOSITORY', 'foreign/repo'), ('GITHUB_REF', 'refs/heads/other')]:
        with patch.dict(os.environ, {key: value}):
            rejects('foreign ' + key + '=' + value, r.scope_receipt)
    current['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '4'*40]
    rejects('unapproved product drift', r.scope_receipt)
    current['Sources/ReaderDomain/untouched.swift'] = old['Sources/ReaderDomain/untouched.swift']
    current['project.yml'] = old['project.yml']
    rejects('missing required path change', r.scope_receipt)
    current['project.yml'] = ['120000', 'blob', '2'*40]
    rejects('symlink candidate', r.scope_receipt)

ui_fixture = 'func testEPUBShelfCoverAndDirectoryCrossChapterNavigation() { exitReader(app, x); openEPUB(x) } func testEPUBProgressSurvivesExitAndProcessRelaunch()'
r.ui_reopen_contract(ui_fixture)
rejects('UI coverage cannot silently omit reopen', lambda: r.ui_reopen_contract(ui_fixture.replace('openEPUB(x)', '')))
rejects('process relaunch cannot substitute warm reopen', lambda: r.ui_reopen_contract(ui_fixture.replace('openEPUB(x)', 'app.terminate(); openEPUB(x)')))
blockers = []
try:
    r.ui_reopen_contract((r.ROOT / 'Tests/YueJingEPUBUITests/EPUBFlowUITests.swift').read_text(encoding='utf-8'))
except ValueError as error:
    blockers.append(str(error))

with tempfile.TemporaryDirectory(prefix='epub-reopen-selfcheck-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
    out = Path(temp)
    native = out / 'epub-freeze'
    native.mkdir()
    (out/'simulator-selection.json').write_text(json.dumps(dict(udid=destination.split('id=')[1])), encoding='utf-8')
    with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', native), patch.object(r, 'GATE_JSON', out/'gate.json'), \
         patch.object(r, 'live_scope', return_value=receipt), \
         patch.object(r.compat, 'validate_toolchain_and_dependencies'), patch.object(r.compat, 'validate_destination'), \
         patch.object(r.reading, 'validate_group_settings'), patch.object(r.paging, 'require_xcresult'), \
         patch.object(r.subprocess, 'check_output', return_value=json.dumps(result_tree).encode()):
        for group, spec in r.GROUPS.items():
            folder = native/group; folder.mkdir()
            bundle = folder/(spec['target']+'.xcresult')
            want = r.provenance(group, destination, bundle, receipt)
            r.write(folder/'selection.json', want)
            r.write(folder/'execution.json', dict(**want, native_exit=0, timed_out=False))
            (folder/(spec['target']+'.log')).write_bytes(fixture(group))
            parsed = r.parse_log(group, fixture(group), 0, False)
            parsed['parameter_xcresult'] = r.parameter_evidence(group, folder, bundle, export=True)
            r.write(folder/'counts.json', parsed)
        qualified = r.qualification()
        r.write(out/'gate.json', qualified)
        assert r.release_gate()['verified_passed'] == 23
        checks.append('synthetic complete artifact / release acceptance (native helpers mocked)')
        for filename, field, value in [('selection.json', 'source_commit', 'b'*40),
                                       ('execution.json', 'timed_out', True),
                                       ('execution.json', 'run_id', '999'),
                                       ('counts.json', 'executions', 18)]:
            path = native/'domain'/filename
            original = path.read_bytes(); data = json.loads(original); data[field] = value
            path.write_text(json.dumps(data), encoding='utf-8')
            rejects('artifact drift ' + filename + ':' + field, r.release_gate)
            path.write_bytes(original)
        with patch.object(r.paging, 'require_xcresult', side_effect=ValueError('missing bundle')):
            rejects('missing xcresult bundle', r.release_gate)
        with patch.object(r.subprocess, 'check_output', return_value=b'{"testNodes": []}'):
            rejects('export differs from actual bundle', r.release_gate)
        (native/'extra').mkdir()
        rejects('extra native group', r.release_gate)
        (native/'extra').rmdir()
        altered = copy.deepcopy(qualified); altered['verified_passed'] = 24
        (out/'gate.json').write_text(json.dumps(altered), encoding='utf-8')
        rejects('forged saved gate', r.release_gate)
    for field, value in [('scope', r.DIAGNOSTIC_SCOPE), ('qualification', 'DEVICE_DIAGNOSTIC_ONLY'),
                         ('verified_passed', 22), ('verified_declarations', 23), ('version', '0.2.5'),
                         ('build', '7'), ('full_regression_passed', True)]:
        altered = {**qualified, field: value}
        with patch.object(r, 'validate_saved', return_value=altered):
            rejects('formal release rejects ' + field, r.release_gate)

    # Exercise the unchanged IPA byte/provenance gate with synthetic files, not an App build.
    artifacts = out/'artifacts'; artifacts.mkdir()
    app = out/'YueJing.app'; app.mkdir()
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=r.VERSION, CFBundleVersion=r.BUILD)))
    (app/'Assets.car').write_bytes(b'synthetic icon')
    ipa = artifacts/f'YueJing-{r.VERSION}.ipa'
    def package(tamper=False):
        with zipfile.ZipFile(ipa, 'w') as archive:
            for path in app.iterdir():
                archive.writestr('Payload/YueJing.app/'+path.name, b'tampered' if tamper and path.name == 'Assets.car' else path.read_bytes())
        manifest = dict(version=r.VERSION, build=r.BUILD, ipa_file=ipa.name, source_commit=head, signing='unsigned',
                        ipa_bytes=ipa.stat().st_size, ipa_sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(), app_icon_files=['Assets.car'])
        (artifacts/'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
    package()
    with patch.object(v, 'ROOT', out), patch.object(v, 'APP', app), patch.object(v, 'report'), \
         patch.dict(os.environ, env), patch.object(r, 'release_gate', return_value=qualified):
        v.verify_ipa(epub_freeze=True)
        checks.append('synthetic IPA provenance and payload-byte positive control')
        package(tamper=True)
        rejects('IPA bytes differ even with matching manifest digest', lambda: v.verify_ipa(epub_freeze=True))
        package()
        with patch.dict(os.environ, {'GITHUB_SHA': 'b'*40}):
            rejects('IPA foreign SHA', lambda: v.verify_ipa(epub_freeze=True))
    with patch.object(v.sys, 'platform', 'darwin'), patch.object(r, 'release_gate', side_effect=ValueError('not qualified')):
        rejects('device package cannot bypass native release gate', lambda: v.package_gate(epub_freeze=True))
    with patch.object(v, 'ROOT', out), patch.object(v, 'APP', app), patch.dict(os.environ, env), \
         patch.object(r, 'release_gate', side_effect=ValueError('not qualified')):
        rejects('IPA cannot bypass native release gate', lambda: v.verify_ipa(epub_freeze=True))
with patch.object(v.sys, 'platform', 'darwin'):
    rejects('mixed device package qualification', lambda: v.package_gate(epub_freeze=True, diagnostic=True))
    rejects('mixed IPA qualification', lambda: v.verify_ipa(epub_freeze=True, epub_reading=True))
print(json.dumps(dict(offline_checks_passed=len(checks), checks=checks, native_tests_executed=0,
                     release_source_ready=not blockers, source_blockers=blockers), indent=2))
