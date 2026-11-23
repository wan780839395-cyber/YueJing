"""Fresh 0.2.25(27) simulator evidence; verify in the producing job before packaging."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time

import run_woff2_native as native
import workflow_development as dev
from workflow_process import run_logged

ROOT = dev.ROOT
OUTPUT = ROOT / 'artifacts/development/execution'
PLAN = ROOT / 'scripts/userfont_native_plan.json'
SCOPE = 'userfont-native-025'
DOMAIN = 'ReaderDomainTests/EPUBUserFontStoreTests.swift'
HOST = 'YueJingHostTests/EPUBFontLoadingHostTests.swift'
HOST_NAMES = ['userBodyFontInOriginalLayoutRestoresAnchorAndCanFollowBookAgain()',
              'bodyFontPreferenceAndCapabilityCannotSelectAnotherBookOrFile()']
BUILD, TEST, CASE, TOTAL = 900, 240, 180, 2700
require = dev.require


def load(path):
    return json.loads(path.read_bytes())


def read_cases():
    plan = load(PLAN)
    require((plan['scope'], plan['branch']) == (SCOPE, native.BRANCH), 'Scope/branch drift')
    require([plan[k + '_timeout_seconds'] for k in ('build', 'test', 'case', 'total')]
            == [BUILD, TEST, CASE, TOTAL], 'Timeout drift')
    project = (ROOT/'project.yml').read_text(encoding='utf-8')
    for k, v in [('MARKETING_VERSION', '0.2.25'), ('CURRENT_PROJECT_VERSION', '27')]:
        require(re.findall(r'^\s*' + k + r': "([^"]+)"$', project, re.M) == [v], 'Version drift: ' + k)
    cases = plan['cases']
    require([c['file'] for c in cases] == [DOMAIN]*4 + [HOST]*2 and
            all(set(c) == {'file', 'name'} for c in cases), 'Expected four Domain and two Host declarations')
    for rel in (DOMAIN, HOST):
        text = (ROOT/'Tests'/rel).read_text(encoding='utf-8')
        require(re.search(r'^struct ' + Path(rel).stem + r'\b', text, re.M), 'Wrong suite: ' + rel)
        names = re.findall(r'^\s*@Test\s+func (\w+\(\))', text, re.M)
        selected = [c['name'] for c in cases if c['file'] == rel]
        if rel == DOMAIN:
            require(len(re.findall(r'^\s*@Test\b', text, re.M)) == 4 and Counter(names) == Counter(selected),
                    'Domain suite drift')
        else:
            require(selected == HOST_NAMES, 'Host scope drift')
        require(all(names.count(n) == 1 for n in selected), 'Missing/duplicate test declaration')
    return cases


def identity():
    env = os.environ
    head = dev.git(ROOT, 'rev-parse', 'HEAD')
    digest = dev.sha(PLAN)
    require(env.get('VALIDATION_SCOPE') == SCOPE and env.get('GITHUB_REF') == 'refs/heads/' + native.BRANCH
            and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1'
            and re.fullmatch(r'[1-9][0-9]*', env.get('GITHUB_RUN_ID', '')), 'Event/ref/scope/run/attempt mismatch')
    require(re.fullmatch('[a-f0-9]{40}', head) and head == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA')
            and digest == env.get('DEVELOPMENT_PLAN_SHA256'), 'Source or plan mismatch')
    require(not dev.git(ROOT, 'status', '--porcelain', '--untracked-files=all'), 'Clean checkout required')
    return dict(scope=SCOPE, branch=native.BRANCH, event=env['GITHUB_EVENT_NAME'], source_commit=head,
                development_source_sha=head, plan_sha256=digest, run_id=env['GITHUB_RUN_ID'],
                run_attempt=env['GITHUB_RUN_ATTEMPT'], job=env['GITHUB_JOB'], qualification='DEVELOPMENT_ONLY',
                release_qualified=False, selected_declarations=6, planned_executions=6)


def destination(requested):
    sim = load(ROOT/'artifacts/task3/simulator-selection.json')
    dest = 'platform=iOS Simulator,id=' + sim['udid']
    require(re.fullmatch(r'[\da-fA-F]{8}(?:-[\da-fA-F]{4}){3}-[\da-fA-F]{12}', sim['udid']) and
            sim['physical_device'] is False and sim['architecture'] == 'arm64' and requested in (None, dest),
            'Simulator destination mismatch')
    return dest


def verify_command(text, cmd):
    headers = re.findall(r'^Command line invocation:\n[ \t]+([^\n]+)$', text, re.M)
    require(len(headers) == 1, 'Missing or duplicate Xcode invocation')
    require(shlex.split(headers[0]) == ['/Applications/Xcode_16.4.app/Contents/Developer/usr/bin/xcodebuild', *cmd[1:]],
            'Raw Xcode invocation differs from expected command')


def verify_log(case, text):
    # Swift Testing emits a separate "Test run started." before the case starts.
    # Strip only presentation prefixes; never strip characters inside a selector.
    suite, sig = Path(case['file']).stem, case['name']
    seconds = r'(\d+(?:\.\d+)?) seconds?\.'
    patterns = [r'Test run started\.', re.escape(f'Suite {suite} started.'), re.escape(f'Test {sig} started.'),
                re.escape(f'Test {sig} passed after ') + seconds, re.escape(f'Suite {suite} passed after ') + seconds,
                r'Test run with 1 test (?:in 1 suite )?passed after ' + seconds, r'\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*']
    index = 0
    for line in text.splitlines():
        line = line.lstrip(' \t\ufeff\u200b')
        require(not re.match(r'[✘↷]|\*\* .*FAILED \*\*|Test Case |Executed [1-9]', line) and
                'exceeded execution time allowance' not in line, 'Failure, skip or unexpected XCTest execution')
        line = re.sub(r'^[◇✔][\ufe0f\u200b \t]*', '', line)
        if line == 'Test session results, code coverage, and logs:':
            continue
        if line.startswith("Test Suite '"):
            require(re.fullmatch(r"Test Suite '[^']+' (started|passed) at .+\.", line), 'Nonpassing XCTest suite')
            continue
        if line.startswith(('Test ', 'Suite ', 'Passing ', '** TEST ')):
            match = index < len(patterns) and re.fullmatch(patterns[index], line)
            require(match, 'Missing/foreign/out-of-order event: ' + line)
            if index == 3:
                require(float(match[1]) <= CASE, 'Case time allowance exceeded')
            index += 1
    require(index == len(patterns), 'Incomplete native log: ' + sig)


def jobs(cases, dest):
    for rel in (DOMAIN, HOST):
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
    verify_command(text, cmd)
    if case is None:
        require((folder/'build.xcresult/Info.plist').is_file() and
                re.findall(r'^\*\* TEST BUILD .* \*\*$', text, re.M) == ['** TEST BUILD SUCCEEDED **'], 'Missing successful build')
        return
    verify_log(case, text)
    # Replay queries go to a fresh scratch folder, never overwriting original JSON or raw xcresult.
    with tempfile.TemporaryDirectory(dir=os.environ.get('RUNNER_TEMP') or os.environ.get('PI_SCRATCH_DIR')) as temp:
        out = Path(temp) if replay else folder
        dev.export_results(out, folder/'test.xcresult', deadline=deadline, root=ROOT, runner=run_logged)
        tests, summary = (load(out/f'xcresult-{section}.json') for section in ('tests', 'summary'))
        native.verify_result(case, tests, summary)
        require(summary['result'] == 'Passed' and summary['expectedFailures'] == 0 and summary['testFailures'] == []
                and row['started_at'] - 1 <= summary['startTime'] <= summary['finishTime'] <= row['ended_at'] + 1,
                'Unexpected xcresult outcome or invocation time')
        devices = tests['devices']
        require(len(devices) == 1 and (devices[0]['platform'], devices[0]['architecture'], devices[0]['deviceId']) ==
                ('iOS Simulator', 'arm64', dest.split('id=')[1]), 'XCResult simulator mismatch')
        if replay:
            require(tests == load(folder/'xcresult-tests.json') and summary == load(folder/'xcresult-summary.json'),
                    'Saved exports differ from raw xcresult')


def execute(cases, dest, source):
    OUTPUT.mkdir(parents=True, exist_ok=False)
    result = dict(source, destination=dest, builds=[], cases=[], started=time.monotonic())
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
            except (ValueError, KeyError, OSError, TypeError, subprocess.SubprocessError) as exc:
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
        result.update(status='passed' if passed == 6 else 'failed', observed_passed_executions=passed,
                      native_executions=6 if passed == 6 else None)
        dev.write_json(OUTPUT/'development-summary.json', result)
    return result['status'] == 'passed'


def verify(cases, dest, source):
    result = load(OUTPUT/'development-summary.json')
    expected = dict(source, destination=dest, status='passed', native_executions=6, observed_passed_executions=6)
    require(all(result[k] == v for k, v in expected.items()), 'Summary identity/count/status mismatch')
    require(len(result['builds']) == 2 and len(result['cases']) == 6, 'Expected two builds and six cases')
    require(0 <= time.monotonic() - result['started'] < TOTAL, 'Not a current same-job execution')
    deadline = result['started'] + TOTAL
    rows = {k: iter(result[k]) for k in ('builds', 'cases')}
    for kind, scheme, _, folder, cmd, case in jobs(cases, dest):
        row = next(rows[kind])
        require(row['scheme'] == scheme and row['command'] == cmd and row['status'] == 'passed' and
                type(row['exit_code']) is int and row['exit_code'] == 0 and row['timed_out'] is False and
                0 < row['timeout_seconds'] <= (TEST if case else BUILD), 'Invocation mismatch: ' + folder.name)
        if case:
            require(row['selector'] == native.selector(case) and row['executions'] == 1, 'Wrong test receipt')
        check_evidence(folder, cmd, case, dest, row, deadline, replay=True)
    print('Verified same-run raw xcresult and logs for all six user-font declarations.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preflight', 'prepare-runtime', 'run', 'verify'))
    parser.add_argument('--destination')
    args = parser.parse_args()
    cases, source = read_cases(), identity()
    if args.action == 'preflight':
        print(json.dumps(dict(source, selectors=list(map(native.selector, cases))), indent=2))
    elif args.action == 'prepare-runtime':
        dev.prepare_runtime()
    elif args.action == 'run':
        return int(not execute(cases, destination(args.destination), source))
    else:
        verify(cases, destination(args.destination), source)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
