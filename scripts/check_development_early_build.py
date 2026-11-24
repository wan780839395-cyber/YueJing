"""Offline scheduling regression: exercise the run CLI, never invoke Xcode or dispatch."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import validate_task3
import workflow_development as dev
import workflow_process
import workflow_tools

UDID = '01234567-89ab-cdef-0123-456789abcdef'
HOST, UI, DOMAIN = 'YueJingHost', 'YueJingEPUBUI', 'ReaderDomain'


def exercise(fault, schemes):
    plan = json.loads((dev.ROOT/dev.PLAN).read_text())
    available = {s: [(p, n) for p, names in dev.inventory.FILES.items()
                     if dev.SCHEMES.get(p.split('/')[0]) == s for n in names.split()
                     if n not in dev.inventory.PARAMETERIZED] for s in schemes}
    plan['cases'] = [dict(zip(('file', 'name'), available[s].pop(0))) for s in schemes]
    trace = []
    with tempfile.TemporaryDirectory(dir=os.environ.get('PI_SCRATCH_DIR')) as temp, ExitStack() as ctx:
        root = Path(temp)
        task = root/'artifacts/task3'
        output = root/'evidence'

        def resolved():
            trace.append('verified')
            if fault == 'pins':
                raise ValueError('injected pin mismatch')

        def run(cmd, log, budget, *, cwd):
            assert budget > 0 and cwd == root
            text, code = '', 0
            if cmd[1] in ('build-for-testing', 'test-without-building'):
                scheme = cmd[cmd.index('-scheme')+1]
                dest = cmd[cmd.index('-destination')+1]
                derived = Path(cmd[cmd.index('-derivedDataPath')+1])
                assert derived == root/'build/development'/scheme
                assert '-onlyUsePackageVersionsFromResolvedFile' in cmd
                if cmd[1] == 'build-for-testing':
                    trace.append('build:'+scheme)
                    assert dest == dev.GENERIC_SIM and budget <= plan['build_timeout_seconds']
                    if fault == 'app' and scheme == HOST:
                        text, code = "App.swift:4: error: injected (in target 'YueJing' from project 'YueJing')", 65
                    elif fault == 'cancel':
                        raise KeyboardInterrupt('injected cancellation')
                    else:
                        products = derived/'Build/Products'
                        products.mkdir(parents=True)
                        (products/'fixture').write_bytes(b'built')
                else:
                    trace.append('test:'+scheme)
                    assert dest == 'platform=iOS Simulator,id='+UDID and budget <= plan['test_timeout_seconds']
                    name = next(a for a in cmd if a.startswith('-only-testing:')).split('/')[-1].removesuffix('()')
                    text = (f'Test {name}() started.\nTest {name}() passed after 0.1 seconds.\n'
                            'Test run with 1 test passed after 0.1 seconds.\n** TEST EXECUTE SUCCEEDED **\n')
                    if fault == 'empty-log':
                        text = ''
                    Path(cmd[cmd.index('-resultBundlePath')+1]).mkdir()
            else:
                trace.append(log.stem)
                if log.stem in ('devices', 'inventory'):
                    text = json.dumps({'devices': {'newer-ios': [{'udid': '00000000-0000-0000-0000-000000000026', 'state': 'Booting'}],
                                                   'ios': [{'udid': UDID, 'state': 'Shutdown'}]}, 'runtimes': [{'identifier': 'ios'}]})
                if cmd[-1] == 'select-simulator':
                    validate_task3.select_simulator()
                if log.stem == 'simulator-ready':
                    assert cmd == ['xcrun', 'simctl', 'bootstatus', UDID, '-b']
                    if fault == 'setup':
                        code = 1
                    elif fault == 'drift':
                        (root/'build/development'/DOMAIN/'Build/Products/fixture').write_bytes(b'changed')
                if cmd[1] == 'xcresulttool':
                    text, code = '{}', int(fault == 'export')
            log.write_text(text, encoding='utf-8')
            return code, False

        for module, name, value in [
            (dev, 'ROOT', root), (dev, 'preflight', lambda *args: plan),
            (dev, 'tracked_fingerprints', lambda root: {}),
            (dev, 'build_identity', lambda *args: {'source': {}, 'destination': args[2]}),
            (workflow_tools, 'inspect_toolchain', lambda *args: {}),
            (validate_task3, 'resolved', resolved),
            (validate_task3, 'select_simulator', lambda: dev.write_json(task/'simulator-selection.json', {'udid': UDID})),
            (workflow_process, 'run_logged', run),
            (sys, 'argv', ['dev', 'run', '--output', str(output)]),
        ]:
            ctx.enter_context(patch.object(module, name, value))
        if fault == 'deadline':
            # The generic build consumed the last of the original total budget.
            def clock():
                return plan['total_timeout_seconds'] if 'build:'+DOMAIN in trace else 0
            ctx.enter_context(patch.object(dev, 'time', SimpleNamespace(monotonic=clock)))
        ctx.enter_context(patch.dict(os.environ, DEVELOPER_DIR='/fixture', RUNNER_TEMP=temp))
        try:
            if fault == 'legacy':
                assert dev.prepare_runtime(root) is None
                assert trace == ['simulator-warmup', 'dependencies', 'verified', 'devices', 'runtimes', 'simulator-boot', 'simulator-ready']
                return
            dev.main()
        except ValueError as exc:
            assert fault == 'pins' and str(exc) == 'injected pin mismatch' and trace == ['dependencies', 'verified']
            return
        except KeyboardInterrupt:
            assert fault == 'cancel'
        except SystemExit as exc:
            assert exc.code == int(bool(fault)), (exc.code, trace, output)
        data = json.loads((output/'development-summary.json').read_text())
        statuses = [row['status'] for row in data['cases']]
        built = [s for s in dict.fromkeys(schemes) if not (fault == 'app' and s == UI)]
        if fault == 'cancel':
            built = built[:1]
        before_sim = ['dependencies', 'verified'] + ['build:'+s for s in built]
        assert trace[:len(before_sim)] == before_sim
        if (fault == 'app' and DOMAIN not in schemes) or fault in ('cancel', 'deadline'):
            assert trace == before_sim
        else:
            setup = ['inventory', 'selection', 'simulator-ready']
            assert 'simulator-warmup' not in trace
            assert trace[len(before_sim):len(before_sim)+len(setup)] == setup
        expected = [('blocked' if s != DOMAIN else 'passed') if fault == 'app' else
                    {'cancel':'not_run','drift':'failed','setup':'blocked','deadline':'blocked','export':'failed','empty-log':'failed'}.get(fault,'passed') for s in schemes]
        assert statuses == expected, (statuses, data)
        expected_tests = [s for s in schemes if s == DOMAIN and fault not in ('setup', 'drift', 'cancel', 'deadline')]
        assert [e[5:] for e in trace if e.startswith('test:')] == expected_tests
        assert data['observed_passed_executions'] == statuses.count('passed') and not data['release_qualified']
        assert data['native_executions'] == (None if fault else len(schemes))
        if fault == 'cancel':
            assert data['stopped_reason'] == 'cancelled' and data['builds'][0]['status'] == 'cancelled'
        if fault == 'setup':
            assert data['simulator_setup']['status'] == 'failed'
        if fault == 'deadline':
            assert data['stopped_reason'] == 'budget_exhausted'


if __name__ == '__main__':
    for fault, schemes in [('app',[HOST, UI]), ('app',[HOST, UI, DOMAIN, DOMAIN]), ('app',[DOMAIN, HOST, UI]),
                           ('pins',[HOST]), ('cancel',[HOST, DOMAIN]), ('legacy',[HOST])] + [
                               (f,[DOMAIN]) for f in ('', 'drift', 'empty-log', 'export', 'setup', 'deadline')]:
        exercise(fault, schemes)
        print('PASS (offline)', fault or 'success', schemes)
