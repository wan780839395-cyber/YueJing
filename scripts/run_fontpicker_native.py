"""Fresh 0.2.26(28) font picker tests; re-query raw xcresults in the producing job."""
import argparse
from collections import Counter
from datetime import timezone
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time

import run_userfont_native as prior
import run_woff2_native as native
import workflow_development as dev
from workflow_process import run_logged

ROOT, OUTPUT = dev.ROOT, prior.OUTPUT
PLAN = ROOT / 'scripts/fontpicker_native_plan.json'
SCOPE, JOB = 'fontpicker-native-026', 'fontpicker_native'
HOST = 'YueJingHostTests/EPUBFontFilePickerTests.swift'
UI = 'YueJingEPUBUITests/EPUBFontPickerUITests.swift'
HOST_NAMES = ('genericProviderItemsAreBrowsableButOnlyFontURLsAreForwarded()',
              'pickerDeliversFirstSelectionOrCancellationOnlyOnce()')
COPY_ONLY = os.environ.get('VALIDATION_SCOPE') == 'fontcopy-native-027'
if COPY_ONLY:
    SCOPE, PLAN = 'fontcopy-native-027', ROOT / 'scripts/fontcopy_native_plan.json'
CASE_COUNT, SCHEME_COUNT = (1, 1) if COPY_ONLY else (3, 2)
UI_NAME = 'testRevisedCardOpensFilesAndReturns'
BUILD, TEST, CASE, TOTAL = prior.BUILD, prior.TEST, prior.CASE, prior.TOTAL
load, require = prior.load, dev.require


def read_cases():
    plan = load(PLAN)
    require((plan['scope'], plan['branch']) == (SCOPE, native.BRANCH), 'Scope/branch drift')
    require([plan[k + '_timeout_seconds'] for k in ('build', 'test', 'case', 'total')] ==
            [BUILD, TEST, CASE, TOTAL], 'Timeout drift')
    project = (ROOT/'project.yml').read_text(encoding='utf-8')
    for key, version in [('MARKETING_VERSION', '0.2.27' if COPY_ONLY else '0.2.26'), ('CURRENT_PROJECT_VERSION', '29' if COPY_ONLY else '28')]:
        require(re.findall(r'^\s*' + key + r': "([^"]+)"$', project, re.M) == [version], 'Version drift: ' + key)
    cases = plan['cases']
    require(cases == ([] if COPY_ONLY else [dict(file=HOST, name=n) for n in HOST_NAMES]) + [dict(file=UI, name=UI_NAME)], 'Case drift')
    host = (ROOT/'Tests'/HOST).read_text(encoding='utf-8')
    require(re.search(r'^struct EPUBFontFilePickerTests\b', host, re.M) and
            len(re.findall(r'^\s*@Test\b', host, re.M)) == 2 and
            Counter(re.findall(r'^\s*@Test\s+func (\w+\(\))', host, re.M)) == Counter(HOST_NAMES), 'Host suite drift')
    ui = (ROOT/'Tests'/UI).read_text(encoding='utf-8')
    require(re.search(r'^\s*(?:final )?class EPUBFontPickerUITests\s*:\s*XCTestCase\b', ui, re.M) and
            len(re.findall(r'^\s*(?:@MainActor\s+)?func ' + UI_NAME + r'\(\)', ui, re.M)) == 1, 'UI suite drift')
    return cases


def identity():
    env = os.environ
    head, digest = dev.git(ROOT, 'rev-parse', 'HEAD'), dev.sha(PLAN)
    require(env.get('VALIDATION_SCOPE') == SCOPE and env.get('GITHUB_JOB') == JOB and
            env.get('GITHUB_REF') == 'refs/heads/' + native.BRANCH and not env.get('PRIOR_VALIDATION_RUN') and
            env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1' and
            re.fullmatch(r'[1-9][0-9]*', env.get('GITHUB_RUN_ID', '')), 'Event/job/ref/scope/run/attempt mismatch')
    require(re.fullmatch('[a-f0-9]{40}', head) and head == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA')
            and digest == env.get('DEVELOPMENT_PLAN_SHA256'), 'Source or plan mismatch')
    require(not dev.git(ROOT, 'status', '--porcelain', '--untracked-files=all'), 'Clean checkout required')
    return dict(scope=SCOPE, branch=native.BRANCH, event=env['GITHUB_EVENT_NAME'], source_commit=head,
                development_source_sha=head, plan_sha256=digest, run_id=env['GITHUB_RUN_ID'], run_attempt='1',
                job=JOB, qualification='DEVELOPMENT_ONLY', release_qualified=False,
                selected_declarations=CASE_COUNT, planned_executions=CASE_COUNT)


def runtime_evidence(source, dest):
    task = ROOT/'artifacts/task3'
    runtime = OUTPUT.parent/'runtime'
    prep = load(task/'preparation.json')
    tools = prep['identity']['toolchain']
    require(prep['source_commit'] == source['source_commit'] and prep['status'] == 'passed' and
            prep['identity']['project_generated'] is True and prep['identity']['xcodegen']['version'] == '2.46.0' and
            (tools['xcode_version'], tools['xcode_build'], tools['swift_version'], tools['architecture']) ==
            ('16.4', '16F6', '6.1.2', 'arm64'), 'Invalid tool preparation')
    timing = load(runtime/'timing.json')
    required = {'dependencies', 'devices', 'runtimes', 'simulator-ready'}
    require(set(timing) in (required, required | {'simulator-boot'}) and
            all(t['exit_code'] == 0 and t['timed_out'] is False and t['elapsed_seconds'] >= 0 for t in timing.values()),
            'Incomplete runtime startup')
    require(dest.split('id=')[1] in (runtime/'simulator-ready.log').read_text(encoding='utf-8'), 'Wrong bootstatus device')
    paths = [task/'preparation.json', task/'simulator-selection.json', task/'dependency-resolution.json',
             runtime/'timing.json', *(runtime/(k + '.log') for k in timing)]
    return dict(source=source, destination=dest, evidence={p.name: dev.sha(p) for p in paths})


def verify_ui_log(case, text):
    target, suite, name = native.selector(case).split('/')
    suites = ['Selected tests', target + '.xctest', suite]
    case_id = re.escape(f"Test Case '-[{target}.{suite} {name}]'")
    number = r'\d+(?:\.\d+)?'
    patterns = [re.escape(f"Test Suite '{s}' started at ") + r'.+\.' for s in suites]
    patterns += [case_id + r' started\.', case_id + r' passed \((' + number + r') seconds?\)\.']
    for s in reversed(suites):
        patterns += [re.escape(f"Test Suite '{s}' passed at ") + r'.+\.',
                     r'Executed 1 test, with 0 failures \(0 unexpected\) in ' + number + r' \(' + number + r'\) seconds?']
    patterns.append(r'\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*')
    index = 0
    for line in text.splitlines():
        line = line.lstrip(' \t\ufeff\u200b')
        require(not re.match(r'[◇✔✘↷]|\*\* .*FAILED \*\*', line) and 'exceeded execution time allowance' not in line,
                'Unexpected Swift, failure, skip or timeout event in UI log')
        if line == 'Test session results, code coverage, and logs:':
            continue
        if line.startswith(('Test ', 'Executed ', 'Suite ', 'Passing ', '** TEST ')):
            m = index < len(patterns) and re.fullmatch(patterns[index], line)
            require(m, 'Unexpected or out-of-order XCTest event')
            if index == 4:
                require(float(m[1]) <= CASE, 'UI case allowance exceeded')
            index += 1
    require(index == len(patterns), 'Incomplete XCTest log')


def verify_result(case, scheme, tests, summary):
    # XCTest's selection flag omits (), but the exported leaf/identifier includes it.
    target, suite, name = native.selector(case).split('/')
    ui = case['file'].startswith('YueJingEPUBUITests/')
    sig = name + '()' if ui else name
    nodes = tests['testNodes']
    for kind, label in [('Test Plan', scheme), ('UI test bundle' if ui else 'Unit test bundle', target),
                        ('Test Suite', suite), ('Test Case', sig)]:
        require(len(nodes) == 1, 'Missing or foreign xcresult node')
        node = nodes[0]
        require((node['nodeType'], node['name'], node['result']) == (kind, label, 'Passed'), 'Wrong xcresult identity/status')
        nodes = node.get('children', [])
    # Xcode omits both duration fields for fast Swift tests. The timed log event is mandatory.
    require(not nodes and node['nodeIdentifier'] == suite + '/' + sig and
            node['nodeIdentifierURL'] == 'test://com.apple.xcode/YueJing/' + '/'.join((target, suite, name)) and
            ('durationInSeconds' not in node or 0 <= node['durationInSeconds'] <= CASE), 'Wrong leaf identity or duration')
    for key, value in [('totalTestCount', 1), ('passedTests', 1), ('failedTests', 0), ('skippedTests', 0), ('expectedFailures', 0)]:
        require(type(summary[key]) is int and summary[key] == value, 'XCResult count differs: ' + key)
    require(summary['result'] == 'Passed' and summary['testFailures'] == [] and summary['title'] == 'Test - ' + scheme,
            'Unsuccessful or unexpected xcresult summary')
    devices = tests['devices']
    configs = summary['devicesAndConfigurations']
    require(len(configs) == len(devices) == 1 and configs[0]['device'] == devices[0] and
            all(configs[0][k] == summary[k] for k in ('passedTests', 'failedTests', 'skippedTests', 'expectedFailures')),
            'Inconsistent per-device result')


def jobs(cases, dest):
    for rel in ((UI,) if COPY_ONLY else (HOST, UI)):
        scheme = dev.SCHEMES[rel.split('/')[0]]
        derived = ROOT/'build'/SCOPE/scheme
        folder = OUTPUT/('build-' + scheme)
        yield 'builds', scheme, derived, folder, dev.build_command(scheme, dest, derived, folder/'build.xcresult'), None
        for i, case in enumerate(cases, 1):
            if case['file'] == rel:
                folder = OUTPUT/f'case-{i:02}'
                yield ('cases', scheme, derived, folder,
                       native.test_command(case, scheme, dest, derived, folder/'test.xcresult', CASE), case)


def check_evidence(folder, cmd, case, dest, row, deadline, *, replay):
    text = (folder/'native.log').read_text(encoding='utf-8')
    prior.verify_command(text, cmd)
    bundle = folder/('test.xcresult' if case else 'build.xcresult')
    info = plistlib.loads((bundle/'Info.plist').read_bytes())
    created = info['dateCreated'].replace(tzinfo=timezone.utc).timestamp()
    require(row['started_at'] - 1 <= created <= row['ended_at'] + 1, 'Stale result bundle')
    if not case:
        require(re.findall(r'^\*\* TEST BUILD .* \*\*$', text, re.M) == ['** TEST BUILD SUCCEEDED **'], 'Missing successful build')
        return
    if case['file'] == UI:
        verify_ui_log(case, text)
    else:
        prior.verify_log(case, text)
    with tempfile.TemporaryDirectory(dir=os.environ.get('RUNNER_TEMP') or os.environ.get('PI_SCRATCH_DIR')) as temp:
        out = Path(temp) if replay else folder
        dev.export_results(out, bundle, deadline=deadline, root=ROOT, runner=run_logged)
        tests, summary = (load(out/f'xcresult-{k}.json') for k in ('tests', 'summary'))
        verify_result(case, row['scheme'], tests, summary)
        require(row['started_at'] - 1 <= summary['startTime'] <= summary['finishTime'] <= row['ended_at'] + 1,
                'XCResult time outside invocation')
        device = tests['devices'][0]
        require((device['platform'], device['architecture'], device['deviceId']) ==
                ('iOS Simulator', 'arm64', dest.split('id=')[1]), 'XCResult simulator mismatch')
        if replay:
            require(tests == load(folder/'xcresult-tests.json') and summary == load(folder/'xcresult-summary.json'),
                    'Saved exports differ from raw xcresult')


def execute(cases, dest, source):
    OUTPUT.mkdir(parents=True, exist_ok=False)
    result = dict(source, destination=dest, builds=[], cases=[], started=time.monotonic(), started_at=time.time())
    deadline = result['started'] + TOTAL
    schedule = []
    for kind, scheme, derived, folder, cmd, case in jobs(cases, dest):
        row = dict(status='not_run', scheme=scheme)
        if case:
            row['selector'] = native.selector(case)
        result[kind].append(row)
        schedule.append((row, scheme, derived, folder, cmd, case))
    built = set()
    try:
        for row, scheme, derived, folder, cmd, case in schedule:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise dev.BudgetExhausted('Execution budget exhausted')
            if case and scheme not in built:
                row.update(status='blocked', blocked_by=scheme)
                continue
            try:
                folder.mkdir()
                require(case or not derived.exists(), 'Refusing stale DerivedData')
                row.update(status='running', command=cmd, timeout_seconds=min(TEST if case else BUILD, remaining),
                           started_at=time.time())
                code, timeout = run_logged(cmd, folder/'native.log', row['timeout_seconds'], cwd=ROOT)
                row.update(exit_code=code, timed_out=timeout, ended_at=time.time())
                require(code == 0 and not timeout, f'Native exit={code}, timed_out={timeout}')
                check_evidence(folder, cmd, case, dest, row, deadline, replay=False)
                row['status'] = 'passed'
                if case:
                    row['executions'] = 1
                else:
                    built.add(scheme)
            except (ValueError, KeyError, IndexError, OSError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as exc:
                row.update(status='timed_out' if row.get('timed_out') else 'failed', error=str(exc))
    except dev.BudgetExhausted as exc:
        result['stopped_reason'] = str(exc)
    except KeyboardInterrupt:
        row['status'] = 'cancelled'
        raise
    finally:
        for row in result['builds'] + result['cases']:
            if row['status'] == 'running':
                row['status'] = 'incomplete'
        passed = sum(c['status'] == 'passed' for c in result['cases'])
        ok = len(built) == SCHEME_COUNT and passed == CASE_COUNT
        result.update(status='passed' if ok else 'failed', observed_passed_executions=passed,
                      native_executions=CASE_COUNT if ok else None)
        dev.write_json(OUTPUT/'development-summary.json', result)
    return ok


def verify(cases, dest, source):
    result = load(OUTPUT/'development-summary.json')
    expected = dict(source, destination=dest, status='passed', native_executions=CASE_COUNT, observed_passed_executions=CASE_COUNT)
    require(all(result[k] == v for k, v in expected.items()), 'Summary identity/count/status mismatch')
    require(len(result['builds']) == SCHEME_COUNT and len(result['cases']) == CASE_COUNT, 'Expected two builds and three cases')
    require(0 <= time.monotonic() - result['started'] < TOTAL and 0 <= time.time() - result['started_at'] < TOTAL,
            'Not a current same-job execution')
    deadline = result['started'] + TOTAL
    previous = result['started_at']
    rows = {k: iter(result[k]) for k in ('builds', 'cases')}
    for kind, scheme, _, folder, cmd, case in jobs(cases, dest):
        row = next(rows[kind])
        require(row['scheme'] == scheme and row['command'] == cmd and row['status'] == 'passed' and
                type(row['exit_code']) is int and row['exit_code'] == 0 and row['timed_out'] is False and
                previous <= row['started_at'] <= row['ended_at'] <= time.time() and
                0 < row['timeout_seconds'] <= (TEST if case else BUILD), 'Invocation mismatch: ' + folder.name)
        previous = row['ended_at']
        if case:
            require(row['selector'] == native.selector(case) and row['executions'] == 1, 'Wrong test receipt')
        check_evidence(folder, cmd, case, dest, row, deadline, replay=True)
    print('Verified same-job raw xcresults and logs: ' + str(CASE_COUNT) + ' selected test(s).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preflight', 'prepare-runtime', 'run', 'verify'))
    parser.add_argument('--destination')
    args = parser.parse_args()
    cases, source = read_cases(), identity()
    runtime = OUTPUT.parent/'runtime/fontpicker-runtime.json'
    if args.action == 'preflight':
        require(not (ROOT/'artifacts/task3/preparation.json').exists() and not OUTPUT.exists() and
                not runtime.parent.exists(), 'Refusing stale preparation or execution')
        print(json.dumps(dict(source, selectors=list(map(native.selector, cases))), indent=2))
    elif args.action == 'prepare-runtime':
        dev.prepare_runtime()
        dev.write_json(runtime, runtime_evidence(source, prior.destination(None)))
    else:
        dest = prior.destination(args.destination)
        require(load(runtime) == runtime_evidence(source, dest), 'Runtime receipt differs from current job')
        if args.action == 'run':
            return int(not execute(cases, dest, source))
        verify(cases, dest, source)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
