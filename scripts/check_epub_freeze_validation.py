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
                text += ''.join(f"◇ Passing 1 argument {param['argument']} → {value} to {signature}\n" for value in param['values'])
            text += f'✔ Test {signature} passed after 0.1 seconds.\n'
    if spec['kind'] == 'ui':
        text += 'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n'
    else:
        text += f"✔ Test run with {len(spec['cases'])} tests passed after 0.2 seconds.\n"
    return (text + '** TEST SUCCEEDED **\n').encode('utf-8')

def expected_executions(group):
    return sum(len(r.inventory.PARAMETERIZED.get(name, {}).get('values', [None]))
               for name in r.GROUPS[group]['cases'])


assert r.BASE == 'b15c2f86434896124746db0cb0bf634a05c5d14e'
assert r.SCOPE == 'epub-reopen-fast-10'
assert r.VERSION == '0.2.12' and r.BUILD == '14'
assert r.QUALIFICATION == 'EPUB_REOPEN_FAST_10_TARGETED_NATIVE'
selected = r.selection()
expected_selected_files = [
    ('ReaderDomainTests/EPUBLibraryTests.swift', [
        'epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences',
        'epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime',
    ]),
    ('ReaderDomainTests/EPUBContentPoolTests.swift',
     r.inventory.FILES['ReaderDomainTests/EPUBContentPoolTests.swift'].split()),
    ('YueJingHostTests/EPUBReaderHostTests.swift', [
        'epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position',
        'epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU',
    ]),
]
assert list(r.SELECTED_FILES.items()) == expected_selected_files
expected_selected = {
    'domain-1': ['epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences'],
    'domain-2': ['epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime'],
    **{f'domain-{i}': [name] for i, name in enumerate(
        r.inventory.FILES['ReaderDomainTests/EPUBContentPoolTests.swift'].split(), 3)},
    'host-1': ['epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position'],
    'host-2': ['epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU'],
}
assert selected == expected_selected and list(selected) == list(expected_selected)
assert len(selected) == r.TOTAL == 10 and r.EXECUTIONS == 11 and all(len(n) == 1 for n in selected.values())
assert expected_executions('domain-2') == 2
assert all(expected_executions(group) == 1 for group in selected if group != 'domain-2')
assert sum(expected_executions(group) for group in selected) == r.EXECUTIONS == 11
release_groups = copy.deepcopy(r.GROUPS)
parameter = next(iter(r.inventory.PARAMETERIZED))
PARAM_GROUP = 'offline-parameter'
r.GROUPS[PARAM_GROUP] = dict(kind='domain', target='ReaderDomainTests', timeout=480,
    pairs=[('ReaderDomainTests/EPUBLibraryTests.swift', parameter)], cases=[parameter])
r.GROUPS['offline-ui'] = dict(kind='ui', target='YueJingEPUBUITests', timeout=480,
    pairs=[('YueJingEPUBUITests/EPUBFlowUITests.swift', 'testEPUBShelfCoverAndDirectoryCrossChapterNavigation')],
    cases=['testEPUBShelfCoverAndDirectoryCrossChapterNavigation'])
expected_allowed = {
    '.github/workflows/task3-validate.yml',
    'Sources/ReaderDomain/EPUB/EPUBContentPool.swift',
    'Sources/ReaderDomain/EPUB/EPUBMetadataSnapshot.swift',
    'Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift',
    'Sources/ReaderDomain/EPUB/EPUBResourceStore.swift',
    'Sources/ReaderDomain/LibraryService.swift',
    'Sources/ReaderDomain/LibraryStore.swift',
    'Tests/ReaderDomainTests/EPUBContentPoolTests.swift',
    'docs/EPUB_FREEZE_RELEASE.md',
    'project.yml',
    'scripts/check_epub_freeze_validation.py',
    'scripts/check_epub_metadata_reopen.py',
    'scripts/check_epub_reopen_fast.py',
    'scripts/run_epub_freeze_validation.py',
}
assert len(r.ALLOWED) == 14 and r.ALLOWED == expected_allowed and r.NEW == {'scripts/check_epub_reopen_fast.py'}
reviewed = r.inventory.validate_source()
assert json.loads(json.dumps(reviewed)) == reviewed
assert reviewed['selected'] == 229 and reviewed['selected_executions'] == 230
assert reviewed['selected'] - r.TOTAL == 219 and reviewed['selected_executions'] - r.EXECUTIONS == 219
checks.append('candidate inventory survives JSON roundtrip')
checks.append('exact Domain8 (domain-2 Bool 2x) Host2 selected, no UI; offline-parameter/UI fixtures isolated / inventory229 declarations, 230 expansions, 219 unselected')
destination = 'platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555'
for group in r.GROUPS:
    raw = fixture(group)
    parsed = r.parse_log(group, raw, 0, False)
    assert parsed['passed'] == r.GROUPS[group]['cases']
    assert parsed['executions'] == expected_executions(group)
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
    expected_suffix = '/' + r.GROUPS[group]['cases'][0] + (
        '' if r.GROUPS[group]['kind'] == 'ui' else
        r.inventory.PARAMETERIZED.get(r.GROUPS[group]['cases'][0], {}).get('signature', '()'))
    assert any(a.endswith(expected_suffix) for a in command if a.startswith('-only-testing:'))
    assert command.count('180') == 2 and r.GROUPS[group]['timeout'] == 480
    assert command[command.index('-scheme') + 1] == ('ReaderDomain' if r.GROUPS[group]['kind'] == 'domain' else 'YueJingUI')
rejects('device destination', lambda: r.command('host-1', 'generic/platform=iOS', Path('synthetic')))
for param_group in ('domain-2', PARAM_GROUP):
    raw = fixture(param_group)
    arg_line = next(line for line in raw.splitlines(keepends=True) if b'Passing ' in line)
    decorated = raw.replace(arg_line, '\u200b'.encode('utf-8') + arg_line)
    assert r.parse_log(param_group, decorated, 0, False)['executions'] == 2
    for label, altered in [('unknown argument decoration', raw.replace(arg_line, b'foreign ' + arg_line)),
                           ('missing argument', raw.replace(arg_line, b'')),
                           ('duplicate argument', raw.replace(arg_line, arg_line * 2)),
                           ('foreign argument', raw.replace(b'false to ', b'unknown to ')),
                           ('argument after finish', raw.replace(arg_line, b'') + arg_line),
                           ('expanded count pretending declarations', raw.replace(b'1 tests passed', b'2 tests passed'))]:
        rejects(param_group + ': ' + label, lambda g=param_group, a=altered: r.parse_log(g, a, 0, False))
checks.append('Swift Testing line-leading zero-width decoration preserves argument identity')
del r.GROUPS[PARAM_GROUP], r.GROUPS['offline-ui']
assert r.GROUPS == release_groups and r.selection() == selected
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
assert 'epub-recent-' not in workflow
assert 'epub-freeze-diagnostic' not in workflow and 'epub-freeze-3' not in workflow
assert 'run-all' in job and 'for group in host-1' not in job and 'run domain' not in job
assert 'Show every selected result and the complete UI inventory\n        if: always()' in job
assert 'run_epub_freeze_validation.py report' in job
assert job.index('run-all') < job.index('run_epub_freeze_validation.py gate') < job.index('Compile actual unsigned') < job.index('package-gate-epub-freeze') < job.index('verify-ipa-epub-freeze')
assert job.count('!cancelled() && inputs.build_ipa &&') == 2 and "BUILD_IPA: ${{ inputs.build_ipa && 'true' || 'false' }}" in job
assert 'continue-on-error' not in job and 'Publish verified unsigned IPA' in job and 'if: success()' not in job
checks.append('exclusive scope routing / independent device build / strict native and delivery gates separated')

base_project = r.git('show', r.BASE + ':project.yml')
old = {p: ['100644', 'blob', '1'*40] for p in r.ALLOWED if p not in r.NEW}
old['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '3'*40]
current = {**old, **{p: ['100644', 'blob', '2'*40] for p in r.ALLOWED}}
head = 'a'*40
env = dict(VALIDATION_SCOPE=r.SCOPE, GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
           GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='wan780839395-cyber/YueJing', GITHUB_SHA=head, GITHUB_RUN_ID='12345',
           GITHUB_EVENT_PATH=__file__, ALLOW_UNQUALIFIED_IPA='false', BUILD_IPA='true')
def fakegit(*args):
    if args == ('rev-parse', 'HEAD'): return head.encode()
    if args[0] in ('merge-base', 'status'): return b''
    if args == ('show', r.BASE + ':project.yml'): return base_project
    raise AssertionError(args)
# Scope fixtures isolate the boundary validator; actual missing UI coverage is disclosed below.
with patch.dict(os.environ, env), patch.object(r, 'git', side_effect=fakegit), \
     patch.object(r, 'tree', side_effect=lambda rev: old if rev == r.BASE else current), \
     patch.object(r, 'ui_reopen_contract'), patch.object(r, 'dispatch_permission', return_value=False):
    receipt = r.scope_receipt()
    assert receipt['native_tests_planned'] == 11 and receipt['selected_declarations'] == 10
    assert receipt['full_inventory_declared'] == 229 and receipt['full_inventory_executions'] == 230
    assert 'verified_passed' not in receipt
    checks.append('scope binds exact14 paths including one addition and makes no native-pass claim')
    for key, value in [('VALIDATION_SCOPE', 'full'), ('VALIDATION_SCOPE', r.DIAGNOSTIC_SCOPE),
                       ('GITHUB_SHA', 'b'*40), ('GITHUB_RUN_ATTEMPT', '2'),
                       ('GITHUB_REPOSITORY', 'foreign/repo'), ('GITHUB_REF', 'refs/heads/other')]:
        with patch.dict(os.environ, {key: value}):
            rejects('foreign ' + key + '=' + value, r.scope_receipt)
    for added in r.NEW:
        saved = current.pop(added)
        rejects('missing approved addition ' + added, r.scope_receipt)
        current[added] = saved
        old[added] = ['100644', 'blob', '1'*40]
        rejects('approved addition must really be new ' + added, r.scope_receipt)
        del old[added]
    current['foreign.swift'] = ['100644', 'blob', '2'*40]
    rejects('unapproved added path', r.scope_receipt)
    del current['foreign.swift']
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
        qualified_gate = r.release_gate()
        assert qualified_gate['verified_passed'] == 11 and qualified_gate['verified_declarations'] == 10
        assert qualified_gate['not_executed_this_run'] == 219 and qualified_gate['qualification'] == r.QUALIFICATION
        domain2_counts = r.load(native/'domain-2/counts.json')
        assert domain2_counts['executions'] == 2 and domain2_counts['parameter_xcresult']['passed_arguments'] == ['false', 'true']
        checks.append('synthetic complete artifact / release acceptance (native helpers mocked)')
        for failure_path in (native/'host-1/failure.json', out/'case-scheduling-error.json'):
            r.write(failure_path, dict(error='synthetic failure after passing receipt'))
            rejects('failure record overrides complete green receipts: ' + failure_path.name, r.release_gate)
            failure_path.unlink()
        broken = native/'host-1/counts.json'
        previous = broken.read_bytes()
        broken.write_bytes(b'{invalid')
        summary = r.summarize()
        assert summary['counts']['error'] == 1 and summary['counts']['passed'] == 9
        assert len(summary['ui_inventory']) == 15 and all(x['status'] == 'not_selected' for x in summary['ui_inventory'])
        broken.write_bytes(previous)
        checks.append('one corrupt result is visible and does not hide remaining UI cases')
        for filename, field, value in [('selection.json', 'source_commit', 'b'*40),
                                       ('execution.json', 'timed_out', True),
                                       ('execution.json', 'run_id', '999'),
                                       ('counts.json', 'executions', 18)]:
            path = native/'domain-1'/filename
            original = path.read_bytes(); data = json.loads(original); data[field] = value
            path.write_text(json.dumps(data), encoding='utf-8')
            rejects('artifact drift ' + filename + ':' + field, r.release_gate)
            path.write_bytes(original)
        with patch.object(r.paging, 'require_xcresult', side_effect=ValueError('missing bundle')):
            rejects('missing xcresult bundle', r.release_gate)
        # Verify real scheduled domain-2 and isolated parameter-fixture xcresult export drift checks.
        with patch.object(r.subprocess, 'check_output', return_value=b'{"testNodes": []}'):
            rejects('domain-2 xcresult differs from export', r.release_gate)
        xc_export = native/'domain-2/xcresult-tests.json'
        xc_original = xc_export.read_bytes()
        xc_tampered = json.loads(xc_original)
        xc_tampered['testNodes'][0]['children'].pop()
        xc_export.write_text(json.dumps(xc_tampered), encoding='utf-8')
        rejects('domain-2 tampered xcresult export', r.release_gate)
        xc_export.write_bytes(xc_original)
        with patch.dict(r.GROUPS, {PARAM_GROUP: dict(kind='domain', cases=[parameter])}):
            parameter_folder = out/'parameter-fixture'; parameter_folder.mkdir()
            r.parameter_evidence(PARAM_GROUP, parameter_folder, out/'parameter.xcresult', export=True)
            with patch.object(r.subprocess, 'check_output', return_value=b'{"testNodes": []}'):
                rejects('export differs from actual bundle', lambda: r.parameter_evidence(
                    PARAM_GROUP, parameter_folder, out/'parameter.xcresult'))
        assert r.GROUPS == release_groups
        (native/'extra').mkdir()
        rejects('extra native group', r.release_gate)
        (native/'extra').rmdir()
        altered = copy.deepcopy(qualified); altered['verified_passed'] = 9
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
         patch.dict(os.environ, env), patch.object(r, 'complete_delivery', return_value=qualified):
        v.verify_ipa(epub_freeze=True)
        checks.append('synthetic IPA provenance and payload-byte positive control')
        package(tamper=True)
        rejects('IPA bytes differ even with matching manifest digest', lambda: v.verify_ipa(epub_freeze=True))
        package()
        with patch.dict(os.environ, {'GITHUB_SHA': 'b'*40}):
            rejects('IPA foreign SHA', lambda: v.verify_ipa(epub_freeze=True))
    with patch.object(v.sys, 'platform', 'darwin'), patch.object(r, 'delivery_gate', side_effect=ValueError('not qualified')):
        rejects('device package cannot bypass explicit delivery gate', lambda: v.package_gate(epub_freeze=True))
    with patch.object(v, 'ROOT', out), patch.object(v, 'APP', app), patch.dict(os.environ, env), \
         patch.object(r, 'complete_delivery', side_effect=ValueError('not qualified')):
        rejects('IPA cannot bypass explicit delivery gate', lambda: v.verify_ipa(epub_freeze=True))
with patch.object(v.sys, 'platform', 'darwin'):
    rejects('mixed device package qualification', lambda: v.package_gate(epub_freeze=True, diagnostic=True))
    rejects('mixed IPA qualification', lambda: v.verify_ipa(epub_freeze=True, epub_reading=True))
# Exercise the production scheduler with isolated synthetic native boundaries.
import contextlib
import io
import sys
import subprocess
with tempfile.TemporaryDirectory(prefix='epub-continue-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
    root = Path(temp)
    scope = dict(scope=r.SCOPE, source_commit='a'*40, run_id='synthetic')
    for scenario in ('mixed', 'early_failure', 'all_pass', 'preflight', 'cancelled'):
        out = root/scenario
        visited = []
        def prepare(kind, folder, source_commit, **kwargs):
            visited.append(folder.name)
            if scenario == 'mixed' and folder.name == 'domain-2':
                raise ValueError('synthetic individual settings failure')
        def stream(args, log, timeout):
            group = log.parent.name
            assert len([s for s in args if s.startswith('-only-testing:')]) == 1
            assert timeout == 480
            if scenario == 'cancelled' and group == 'domain-2':
                raise KeyboardInterrupt()
            raw = fixture(group)
            if scenario in ('mixed', 'early_failure') and group == 'domain-1':
                log.write_bytes(raw.replace(b'passed', b'failed').replace(b'TEST SUCCEEDED', b'TEST FAILED'))
                return 65, False
            if scenario == 'mixed' and group == 'host-1':
                log.write_bytes(b'synthetic timeout')
                return -9, True
            log.write_bytes(raw)
            return 0, False
        def preflight(*args, **kwargs):
            if scenario == 'preflight':
                raise ValueError('synthetic common toolchain unavailable')
        with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', out/'epub-freeze'), \
             patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(out/'synthetic-step-summary.md')}), \
             patch.object(r, 'live_scope', return_value=scope), \
             patch.object(r.compat, 'validate_toolchain_and_dependencies', side_effect=preflight), \
             patch.object(r.compat, 'validate_destination'), \
             patch.object(r.reading, 'prepare_group_settings', side_effect=prepare), \
             patch.object(r, 'stream_case', side_effect=stream), \
             patch.object(r.paging, 'require_xcresult'), \
             patch.object(r.subprocess, 'check_output', return_value=json.dumps(result_tree).encode()), \
             contextlib.redirect_stdout(io.StringIO()):
            if scenario == 'preflight':
                rejects('common prerequisite fails once without running tests', lambda: r.run_all(destination))
                assert not visited
            elif scenario == 'cancelled':
                try:
                    r.run_all(destination)
                except KeyboardInterrupt:
                    pass
                else:
                    raise AssertionError('Cancellation swallowed')
                assert visited == ['domain-1', 'domain-2'] and 'domain-3' not in visited and 'host-1' not in visited
                checks.append('cancellation stops scheduling without falsely skipping/passing remaining cases')
            else:
                assert r.run_all(destination) == (scenario == 'all_pass')
                assert visited == list(r.GROUPS)
                checks.append(scenario + ': production scheduler attempted every selected identity once')
            report = r.summarize(publish=True)
            assert len(report['cases']) == 10 and len(report['ui_inventory']) == 15
            assert sum(x['status'] == 'not_selected' for x in report['ui_inventory']) == 15
            assert {x['case'] for x in report['ui_inventory']} == set(r.inventory.expected_names('YueJingUITests') + r.inventory.expected_names('YueJingEPUBUITests'))
            if scenario == 'mixed':
                assert report['counts'] == dict(passed=7, failed=1, timed_out=1, error=0, blocked=1, not_run=0)
                rejects('failed/blocked/timed-out cases cannot qualify', r.qualification)
                checks.append('failure, settings error and timeout all attempted and retained')
            elif scenario == 'early_failure':
                assert report['counts'] == dict(passed=9, failed=1, timed_out=0, error=0, blocked=0, not_run=0)
                assert all(x['status'] == 'passed' for x in report['cases'] if x['group'] != 'domain-1')
                rejects('early failure cannot qualify despite later successful cases', r.qualification)
            elif scenario == 'all_pass':
                assert report['counts']['passed'] == 10
                assert sum(x['planned_executions'] for x in report['cases']) == 11
                assert [x['planned_executions'] for x in report['cases']] == [expected_executions(g) for g in r.GROUPS]
            elif scenario == 'preflight':
                assert report['counts']['blocked'] == 10 and report['counts']['passed'] == 0
            else:
                assert report['counts']['passed'] == 1 and report['counts']['not_run'] == 9
            markdown = (out/'case-results.md').read_text('utf-8')
            assert all(x['case'] in markdown for x in report['ui_inventory'])
            checks.append(scenario + ': complete UI display and truthful selected/unselected states')
            rejects('existing case evidence cannot be overwritten/retried', lambda: r.run_all(destination)) if scenario != 'preflight' else None

    # Real local process exits/timeouts; these are Python processes, NOT Swift tests.
    assert r.stream_case([sys.executable, '-c', 'print("ok")'], root/'success.log', 10) == (0, False)
    assert r.stream_case([sys.executable, '-c', 'raise SystemExit(7)'], root/'failure.log', 10) == (7, False)
    code, expired = r.stream_case([sys.executable, '-c', 'import time; time.sleep(20)'], root/'timeout.log', 0.2)
    assert expired and code != 0
    assert r.stream_case([sys.executable, '-c', 'print("after timeout")'], root/'after.log', 10) == (0, False)
    checks.append('real local child success/nonzero/timeout followed by next process; no pipe hang')
# Dependency expressions are evaluated against synthetic step outcomes, not global success.
import re
blocks = {re.search(r'\n        id: (\w+)', block)[1]: block for block in job.split('      - name: ')
          if re.search(r'\n        id: (\w+)', block)}
def admitted(step, outcomes, cancelled=False, build_ipa=True):
    expression = re.search(r'\n        if: \$\{\{ (.+) \}\}', blocks[step])[1]
    expression = expression.replace('!cancelled()', str(not cancelled)).replace('&&', ' and ')
    expression = expression.replace('inputs.build_ipa', str(build_ipa))
    expression = re.sub(r"steps\.(\w+)\.outcome", lambda m: repr(outcomes.get(m[1], 'skipped')), expression)
    return eval(expression, {'__builtins__': {}}, {})
good = dict(scope='success', toolchain='success', dependencies='success', device='success',
            simulator='success', boot='success', tests='failure', native_gate='failure')
assert admitted('device', good) and admitted('package', good) and admitted('simulator_linkage', good)
assert not admitted('device', good, build_ipa=False) and not admitted('package', good, build_ipa=False)
assert admitted('tests', good, build_ipa=False)
checks.append('validation-only dispatch still runs tests but cannot build/package')
checks.append('UI/test failure does not block device, package or simulator linkage integrity validation')
assert admitted('simulator', {**good, 'device': 'failure'}) and admitted('tests', {**good, 'device': 'failure'})
checks.append('device failure does not block independent simulator/tests')
for prerequisite in ('scope', 'toolchain', 'dependencies'):
    assert not admitted('package', {**good, prerequisite: 'failure'})
    assert not admitted('device', {**good, prerequisite: 'failure'})
    checks.append('shared prerequisite failure blocks delivery: ' + prerequisite)
assert not admitted('package', good, cancelled=True)
assert "!cancelled() && steps.package.outcome == 'success'" in job
assert 'allow_unqualified_ipa:' in workflow and 'type: boolean\n        default: false' in workflow
checks.append('cancelled package/upload excluded; diagnostic permission defaults false')

with tempfile.TemporaryDirectory(prefix='epub-delivery-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
    out = Path(temp)
    event = out/'event.json'
    with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event), 'ALLOW_UNQUALIFIED_IPA': 'false', 'BUILD_IPA': 'false'}):
        event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE))))
        assert r.dispatch_permission() is False
        checks.append('missing explicit dispatch permission defaults false')
        with patch.dict(os.environ, {'ALLOW_UNQUALIFIED_IPA': 'true'}):
            rejects('environment true cannot forge omitted dispatch permission', r.dispatch_permission)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, allow_unqualified_ipa=True))))
            assert r.dispatch_permission() is True
            checks.append('explicit true dispatch and environment agree')
        rejects('dispatch true cannot be changed to environment false', r.dispatch_permission)
        event.write_text(json.dumps(dict(inputs=dict(validation_scope='full', allow_unqualified_ipa=False))))
        rejects('diagnostic permission cannot cross scope', r.dispatch_permission)
        event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=True))))
        rejects('build environment cannot differ from dispatch stage', r.dispatch_permission)
        with patch.dict(os.environ, {'BUILD_IPA': 'true'}):
            assert r.dispatch_permission() is False
            checks.append('explicit build phase bound to dispatch event')
    frozen = out/'frozen.json'
    frozen.write_text(json.dumps(receipt))
    with patch.object(r, 'SCOPE_JSON', frozen), patch.object(r, 'scope_receipt', return_value={**receipt, 'allow_unqualified_ipa': True}):
        rejects('frozen false permission cannot be changed to true after scope gate', r.live_scope)
    native = out/'epub-freeze'; native.mkdir()
    scope = {**receipt, 'allow_unqualified_ipa': True}
    for name in ('toolchain.log', 'xcodegen.log', 'dependency-resolution.json', 'app-build.log', 'epub-freeze-scope.json'):
        (out/name).write_text('synthetic')
    (out/'app-build-exit-code.txt').write_text('0')
    group = 'domain-1'; spec = r.GROUPS[group]
    folder = native/group; folder.mkdir()
    want = r.provenance(group, destination, folder/(spec['target']+'.xcresult'), scope)
    r.write(folder/'selection.json', want)
    r.write(folder/'execution.json', dict(**want, native_exit=0, timed_out=False))
    (folder/(spec['target']+'.log')).write_bytes(fixture(group))
    with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', native), \
         patch.object(r, 'PACKAGE_JSON', out/'package.json'), patch.object(r, 'live_scope', return_value=scope), \
         patch.object(r.compat, 'validate_toolchain_and_dependencies'), patch.object(r, 'validate_linkage', return_value='c'*64), \
         patch.object(r, 'release_gate', side_effect=ValueError('UI failed')):
        result = r.delivery_gate()
        assert result['qualification'] == 'DEVICE_DIAGNOSTIC_ONLY' and result['coverage'] == 'UI_NOT_QUALIFIED'
        assert result['verified_passed'] is None and result['native_tests_executed_this_run'] is None
        assert result['known_executions'] == 1 and len(result['unknown_execution_groups']) == 9
        assert len(result['cases']) == 10 and result['evidence_sha256']
        assert not (out/'package.json').exists()
        checks.append('partial evidence retains one known execution, unknown remainder, no fake zero/11 or premature IPA receipt')
        with patch.object(r, 'live_scope', return_value={**scope, 'build_ipa': False}):
            rejects('validation-only source receipt cannot package even with diagnostic opt-in', r.delivery_gate)
        with patch.object(r, 'live_scope', return_value={**scope, 'allow_unqualified_ipa': False}):
            rejects('UI failure without explicit diagnostic permission refuses delivery', r.delivery_gate)
        with patch.object(r, 'live_scope', side_effect=ValueError('source mismatch')):
            rejects('explicit permission cannot bypass source integrity', r.delivery_gate)
        with patch.object(r, 'live_scope', side_effect=[scope, {**scope, 'source_commit': 'b'*40}]):
            rejects('source mutation during native qualification cannot be downgraded', r.delivery_gate)
        with patch.object(r, 'validate_linkage', side_effect=ValueError('device linkage failed')):
            rejects('explicit permission cannot bypass device WebKit integrity', r.delivery_gate)
        with patch.object(r.compat, 'validate_toolchain_and_dependencies', side_effect=ValueError('dependency mismatch')):
            rejects('explicit permission cannot bypass common toolchain/dependency integrity', r.delivery_gate)
        (out/'app-build-exit-code.txt').write_text('65')
        rejects('explicit permission cannot bypass failed device build', r.delivery_gate)
        (out/'app-build-exit-code.txt').write_text('0')
        rejects('explicit permission cannot bypass missing device integrity receipt', lambda: r.complete_delivery({'ipa_sha256': 'a'*64}, 2))
        assert not (out/'package.json').exists()
        with patch.object(r, 'release_gate', return_value=qualified):
            formal = r.delivery_gate()
            assert formal['strict_native_qualification'] == 'passed' and formal['verified_passed'] == 11
            checks.append('formal delivery still obtains strict release_gate qualification')
        artifacts = out/'artifacts'; artifacts.mkdir()
        app = out/'YueJing.app'; app.mkdir()
        (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=r.VERSION, CFBundleVersion=r.BUILD)))
        (app/'Assets.car').write_bytes(b'synthetic icon')
        (app/'YueJing').write_bytes(b'synthetic device image')
        ipa = artifacts/f'YueJing-{r.VERSION}.ipa'
        # Reuse the real synthetic ZIP writer; no native build is claimed.
        package()
        r.write(out/'app-dependency-gate.json', dict(source_commit=head, run_id=scope['run_id'], run_attempt='1',
                signing='unsigned', actual_images=[dict(binary='YueJing', sha256=r.sha(app/'YueJing'))]))
        with patch.object(v, 'ROOT', out), patch.object(v, 'APP', app), patch.object(v, 'report'), patch.dict(os.environ, env):
            v.verify_ipa(epub_freeze=True)
            saved = r.load(out/'package.json')
            assert saved['ipa_integrity'] == 'passed' and saved['qualification'] == 'DEVICE_DIAGNOSTIC_ONLY'
            assert saved['source_commit'] == head and saved['run_id'] == scope['run_id']
            assert saved['ipa_sha256'] == r.sha(ipa) and saved['verified_passed'] is None
            checks.append('explicit diagnostic package receipt emitted only after actual synthetic IPA byte verification')
            (out/'package.json').unlink()
            package(tamper=True)
            rejects('explicit true still rejects corrupt IPA payload', lambda: v.verify_ipa(epub_freeze=True))
            assert not (out/'package.json').exists()
            package()
            (app/'YueJing').write_bytes(b'changed image')
            package()
            rejects('matching ZIP cannot conceal changed device dependency image', lambda: v.verify_ipa(epub_freeze=True))
            assert not (out/'package.json').exists()
    linkage = out/'webkit-device-linkage'; linkage.mkdir()
    (linkage/'image').write_bytes((app/'YueJing').read_bytes())
    link_record = dict(source_commit=head, run_id=scope['run_id'], run_attempt='1', passed=True, errors=[],
                       binaries=[dict(path='YueJing', evidence='image', passed=True, nm_exit=0, sha256=r.sha(app/'YueJing'))])
    r.write(linkage/'verification.json', link_record)
    with patch.object(r, 'OUT', out), patch.object(v, 'APP', app):
        assert r.validate_linkage('device', scope) == r.sha(linkage/'verification.json')
        checks.append('device linkage receipt binds source/run and actual/evidence image hashes')
        rejects('linkage receipt cannot be reused across runs', lambda: r.validate_linkage('device', {**scope, 'run_id': '999'}))
        (linkage/'image').write_bytes(b'changed linkage evidence')
        rejects('linkage evidence hash drift rejected', lambda: r.validate_linkage('device', scope))

ui_source = (r.ROOT/'Tests/YueJingEPUBUITests/EPUBFlowUITests.swift').read_text('utf-8')
assert 'waitFor { abs(Double(coordinate("scrollX") - initialX) - Double(initialFrame.width)) <= 2 }' in ui_source
assert 'XCTAssertEqual(Double(nextX - initialX), Double(view.frame.width), accuracy: 2)' in ui_source
assert 348 > 0 and not abs(348 - 375) <= 2 and abs(375 - 375) <= 2
checks.append('existing exact paging completion wait and final assertion preserved')

print(json.dumps(dict(offline_checks_passed=len(checks), checks=checks, native_tests_executed=0,
                     release_source_ready=not blockers, source_blockers=blockers), indent=2))
