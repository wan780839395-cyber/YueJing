"""Targeted offline checks for the new reuse gate and system Swift package resolver."""
import argparse
import ast
import copy
import io
import json
from pathlib import Path
import stat
from unittest.mock import patch
import zipfile

import reuse_native_evidence as reuse
import validate_task3 as validation


def rejected(fn):
    try:
        fn()
    except (ValueError, KeyError, StopIteration, zipfile.BadZipFile):
        return
    raise AssertionError('Invalid reuse input accepted')


def check():
    regular = ['100644', 'blob', 'a' * 40]
    previous = {'App/Main.swift': regular, 'project.yml': regular}
    current = dict(previous, **{'scripts/reuse_native_evidence.py': regular})
    assert reuse.validate_scope(previous, current) == ['scripts/reuse_native_evidence.py']
    for name in ('App/Main.swift', 'Sources/ReaderDomain/X.swift', 'Tests/X.swift', 'project.yml',
                 'scripts/task3_test_inventory.py', 'scripts/audit_native_case_events.py', 'scripts/package_ipa.py'):
        mutated = dict(current);mutated[name] = ['100644', 'blob', 'b' * 40]
        rejected(lambda: reuse.validate_scope(previous, mutated))
    rejected(lambda: reuse.validate_scope(previous, {'project.yml': regular}))
    mutated = dict(current);mutated['scripts/reuse_native_evidence.py'] = ['120000', 'blob', 'a' * 40]
    rejected(lambda: reuse.validate_scope(previous, mutated))
    run = dict(id=reuse.RUN, head_sha=reuse.BASE, run_attempt=1, workflow_id=398234793,
               event='workflow_dispatch', head_branch='main', status='completed', conclusion='failure')
    artifact = dict(id=reuse.ARTIFACT, expired=False, name=f'task3-evidence-{reuse.RUN}-{reuse.BASE}',
                    workflow_run=dict(id=reuse.RUN, head_sha=reuse.BASE), size_in_bytes=reuse.ARCHIVE_BYTES,
                    digest='sha256:' + reuse.ARCHIVE_SHA256)
    reuse.validate_run(run, artifact)
    for key, value in [('id', 1), ('head_sha', 'f' * 40), ('run_attempt', 2), ('workflow_id', 1),
                       ('event', 'push'), ('head_branch', 'other'), ('status', 'in_progress')]:
        changed = dict(run);changed[key] = value;rejected(lambda: reuse.validate_run(changed, artifact))
    for key, value in [('id', 1), ('expired', True), ('name', 'other'), ('size_in_bytes', 1), ('digest', 'sha256:bad'),
                       ('workflow_run', dict(id=1, head_sha=reuse.BASE))]:
        changed = dict(artifact);changed[key] = value;rejected(lambda: reuse.validate_run(run, changed))
    totals = dict(passed=205, failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0)
    groups = [dict(target=str(i), cases=[dict(name=str(i))], raw_sha256=str(i)) for i in range(8)]
    raw = dict(full_selected_passed=True, selected=205, groups=groups, totals=totals)
    receipt = dict(source_commit=reuse.BASE, run_id=str(reuse.RUN), run_attempt='1', passed=True,
                   native_passed=205, verified_passed=205, failed=0, skipped=0, unexecuted=0, unverified=0,
                   groups=[dict(target=str(i), passed=[str(i)], log_sha256=str(i)) for i in range(8)])
    reuse.validate_native(raw, receipt)
    for key in totals:
        changed = copy.deepcopy(raw);changed['totals'][key] += 1
        rejected(lambda: reuse.validate_native(changed, receipt))
    changed = copy.deepcopy(raw);changed['full_selected_passed'] = False
    rejected(lambda: reuse.validate_native(changed, receipt))
    changed = copy.deepcopy(receipt);changed['groups'][0]['passed'] = ['wrong']
    rejected(lambda: reuse.validate_native(raw, changed))
    changed = copy.deepcopy(receipt);changed['source_commit'] = 'f' * 40
    rejected(lambda: reuse.validate_native(raw, changed))
    def archive(names, mode=0o100644):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as z:
            for name in names:
                info = zipfile.ZipInfo(name)
                info.filename = name  # Preserve hostile bytes on Windows too.
                info.external_attr = mode << 16
                z.writestr(info, b'evidence')
        stream.seek(0);return stream
    assert reuse.zip_members(archive(['task3/proof.json']))['task3/proof.json']['bytes'] == 8
    for names in (['../escape'], ['/absolute'], ['a\\b'], ['C:/file'], ['a/./b'], ['a//b'], ['a', 'A']):
        rejected(lambda: reuse.zip_members(archive(names)))
    rejected(lambda: reuse.zip_members(archive(['link'], stat.S_IFLNK | 0o777)))
    with patch.object(reuse, 'verify', return_value={'native_tests_executed_this_run': 0}), \
         patch.object(reuse, 'load', return_value={'native_tests_executed_this_run': 205}):
        rejected(reuse.validate_saved)
    # The native full branch remains default; the new branch must validate reuse
    # before touching the device output, never replace it with a passed counter.
    class GateReached(Exception): pass
    with patch.object(validation.sys, 'platform', 'darwin'), \
         patch.object(reuse, 'validate_saved', side_effect=GateReached):
        try:validation.package_gate(reused=True)
        except GateReached:pass
        else:raise AssertionError('reuse prerequisite not invoked')
    tree = ast.parse(Path(validation.__file__).read_text(encoding='utf-8'))
    gate = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'package_gate')
    assert isinstance(gate.args.defaults[0], ast.Constant) and gate.args.defaults[0].value is False
    branch = next(n for n in gate.body if isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == 'reused')
    assert 'all_test_evidence()' in ast.unparse(ast.Module(body=branch.orelse, type_ignores=[]))
    workflow = (reuse.ROOT / '.github/workflows/task3-validate.yml').read_text(encoding='utf-8')
    assert "    if: ${{ inputs.validation_scope != 'reuse-native-205-d2110a9' && inputs.validation_scope != 'epub-compat-33' }}" in workflow
    new_job = workflow.split('\n  package_reused:\n', 1)[1].split('\n  epub_compat:\n', 1)[0]
    assert "    if: ${{ inputs.validation_scope == 'reuse-native-205-d2110a9' }}" in new_job
    assert all(s not in new_job for s in ('xcodebuild test', 'simctl', 'run_reading_ui_tests.py', 'all-test-gate'))
    assert all(s in new_job for s in ('package-gate-reused', 'verify-ipa-reused', 'reuse_native_evidence.py qualify',
                                      'Xcode 16.4', 'Build version 16F6', 'ARCHS=arm64 ONLY_ACTIVE_ARCH=NO'))
    # Invoke only the previously changed Swift resolver checks, not the full old suite.
    from check_task3_validation import check_system_swift_runtime
    check_system_swift_runtime()
    return dict(passed=True,scope='reuse provenance/scope/native-receipt/ZIP/gate routing + system Swift resolver',
                native_executions=0, cloud_dispatches=0)


def check_original_evidence(folder):
    import audit_native_case_events
    raw = audit_native_case_events.audit_evidence(folder, reuse.BASE, reuse.RUN)
    reuse.validate_native(raw, reuse.load(folder / 'task3/native-test-gate.json'))
    source = reuse.load(folder / 'task3/candidate-sources.json')
    for name, expected in source['files'].items():
        if name not in reuse.ALLOWED:
            assert reuse.digest((reuse.ROOT / name).read_bytes()) == expected, name
    return dict(reused_passed=205, executed_tests=0, baseline_source=reuse.BASE, baseline_run=reuse.RUN)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    result = check()
    if args.evidence:
        result['historical_raw_evidence_replay'] = check_original_evidence(args.evidence)
    print(json.dumps(result, indent=2))
