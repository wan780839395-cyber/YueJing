"""Fresh, bounded simulator tests only. No full-inventory, reuse, or IPA gate."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import time

import workflow_development as dev
from workflow_process import run_logged

ROOT = dev.ROOT
PLAN = ROOT / 'scripts/woff2_native_plan.json'
OUTPUT = ROOT / 'artifacts/development/execution'
SCOPE = 'woff2-native-024'
BRANCH = 'dev/workflow-optimization'
PARAM = 'refreshRejectsDamageAndRollsBack(_:)'
ALL = {'ReaderDomainTests/EPUBWOFF2ResourceTests.swift',
       'ReaderDomainTests/EPUBWOFF2ReadyMigrationTests.swift'}
SINGLE = {'ReaderDomainTests/EPUBFontCompletionTests.swift': 'packageFontOmissionsDiagnoseWOFF2LocalMissingAndSubsetWithoutCapabilities()',
          'ReaderDomainTests/EPUBAuthorStylesTests.swift': 'authorStylesRejectsCorruptOversizedAndInvalidSFNTFontsAndDRM()',
          'YueJingHostTests/EPUBFontLoadingHostTests.swift': 'epubWebKitLoadsReconstructedWOFF2ThroughFontCapability()'}
require = dev.require


def selector(case):
    return case['file'].removesuffix('.swift') + '/' + case['name']


def read_plan():
    plan = json.loads(PLAN.read_text(encoding='utf-8'))
    require((plan['scope'], plan['branch']) == (SCOPE, BRANCH), 'Scope/branch drift')
    for key, maximum in [('build', 900), ('test', 480), ('case', 180), ('total', 2700)]:
        limit = plan[key + '_timeout_seconds']
        require(type(limit) is int and 0 < limit <= maximum, 'Invalid budget: ' + key)
    cases = plan['cases']
    require(len(cases) == len(set(map(selector, cases))) == 12, 'Expected 12 unique declarations')
    require({c['file'] for c in cases} == ALL | SINGLE.keys(), 'Selected file drift')
    for rel in sorted(ALL | SINGLE.keys()):
        text = (ROOT / 'Tests' / rel).read_text(encoding='utf-8')
        require(re.search(r'^struct ' + Path(rel).stem + r'\b', text, re.M), 'Wrong suite: ' + rel)
        found = re.findall(r'^\s*@Test(?:\((arguments: Failure\.allCases)\))?\s+func (\w+)\(([^)]*)\)', text, re.M)
        declared = []
        for attribute, name, params in found:
            if attribute:
                require(name + '(_:)' == PARAM and params == '_ failure: Failure', 'Unexpected parameter declaration')
            else:
                require(not params, 'Unsupported parameter signature: ' + name)
            declared.append(name + ('(_:)' if attribute else '()'))
        selected = [c for c in cases if c['file'] == rel]
        require(Counter(c['name'] for c in selected) == Counter(declared if rel in ALL else [SINGLE[rel]]), 'Selection differs: ' + rel)
        if rel in ALL:
            require(len(declared) == len(re.findall(r'^\s*@Test\b', text, re.M)), 'Unsupported @Test in ' + rel)
        for case in selected:
            require(declared.count(case['name']) == 1, 'Missing/duplicate declaration: ' + selector(case))
            if case['name'] == PARAM:
                enum = re.search(r'enum Failure: CaseIterable, Sendable\s*\{\s*case ([\w,\s]+)\}', text)
                require(enum and [v.strip() for v in enum[1].split(',')] == case['arguments'] and
                        len(set(case['arguments'])) == len(case['arguments']) == 8, 'Failure.allCases drift')
            else:
                require('arguments' not in case, 'Unexpected parameter expansion')
    require(sum(len(c.get('arguments', [])) or 1 for c in cases) == 19, 'Expected 19 execution leaves')
    return plan


def preflight():
    plan = read_plan()
    env = os.environ
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1'
            and env.get('GITHUB_REF') == 'refs/heads/' + BRANCH and env.get('VALIDATION_SCOPE') == SCOPE,
            'Unapproved event/attempt/ref/scope')
    head = dev.git(ROOT, 'rev-parse', 'HEAD')
    require(re.fullmatch('[0-9a-f]{40}', head) and head == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA'), 'Source SHA mismatch')
    require(dev.sha(PLAN) == env.get('DEVELOPMENT_PLAN_SHA256'), 'Plan digest mismatch')
    require(not dev.git(ROOT, 'status', '--porcelain', '--untracked-files=all'), 'Clean checkout required')
    return plan


def argument_value(label):
    # Xcode may include the internal parameter label, parentheses or enum type.
    value = label.strip().removeprefix('(').removesuffix(')') if label.startswith('(') and label.endswith(')') else label.strip()
    enum = r'(?:(?:ReaderDomainTests\.)?EPUBWOFF2ReadyMigrationTests\.)?Failure'
    m = re.fullmatch(r'(?:(?:_ )?failure\s*(?::|→)\s*)?(?:(?:' + enum + r')?\.)?(\w+)(?: \(' + enum + r'\))?', value)
    require(m, 'Unrecognized Failure argument: ' + label)
    return m[1]


def verify_log(case, text, allowance):
    sig = case['name']
    events, arguments = [], []
    for line in text.splitlines():
        line = line.lstrip('\u200b')
        m = re.fullmatch(r'(?:◇ )?Test (\S+) started\.', line)
        if m:
            events.append(('start', m[1]))
        m = re.fullmatch(r'(?:✔ )?Test (\S+) passed after ([\d.]+) seconds?\.', line)
        if m:
            require(float(m[2]) <= allowance, 'Test exceeded case allowance')
            events.append(('pass', m[1]))
        if re.match(r'(?:◇ )?Passing ', line):
            m = re.fullmatch(r'(?:◇ )?Passing 1 argument (?:failure → )?(.+) to ' + re.escape(sig) + r'\.?', line)
            require(m and events == [('start', sig)], 'Foreign/out-of-order argument event')
            arguments.append(argument_value(m[1]))
        require(not re.search(r'^(?:✘|↷) (?:Test|Suite) |\*\* TEST (?:EXECUTE )?FAILED \*\*|exceeded execution time allowance', line), 'Failed/skipped native event')
    require(events == [('start', sig), ('pass', sig)] and Counter(arguments) == Counter(case.get('arguments', [])), 'Test/argument events differ: ' + sig)
    require(re.search(r'^\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*$', text, re.M) and
            re.search(r'Test run with 1 tests? (?:in \d+ suites? )?passed after ', text), 'Missing single-test success summary')


def verify_result(case, tests, summary):
    target, suite, sig = selector(case).split('/')
    values = case.get('arguments', [])
    count = len(values) or 1
    for k in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests'):
        require(type(summary.get(k)) is int, 'Missing summary count: ' + k)
    require(summary['totalTestCount'] == summary['passedTests'] in {1, count} and
            summary['failedTests'] == summary['skippedTests'] == summary.get('expectedFailures', 0) == 0 and
            summary.get('result', 'Passed') == 'Passed', 'xcresult summary mismatch')
    seen = []
    def visit(n, bundle=None, parent_suite=None):
        kind, label = n['nodeType'], n['name']
        require(n.get('result', 'Passed') == 'Passed', 'Nonpassing xcresult node: ' + label)
        children = n.get('children', [])
        if kind == 'Unit test bundle':
            bundle = label.removesuffix('.xctest')
        if kind == 'Test Suite':
            parent_suite = label
        if kind == 'Test Case':
            require((bundle, parent_suite, label, n.get('result')) == (target, suite, sig, 'Passed'), 'Unexpected test identity: ' + str((bundle, parent_suite, label)))
            seen.append(sig)
            leaves = []
            for leaf in children:
                require(leaf.get('nodeType') == 'Arguments' and leaf.get('result') == 'Passed' and not leaf.get('children'), 'Unexpected/nonpassing case child')
                leaves.append(argument_value(leaf['name']))
            require(Counter(leaves) == Counter(values), 'xcresult parameter leaves differ: ' + str(leaves))
        else:
            require(kind != 'Arguments', 'Argument outside selected declaration')
            for child in children:
                visit(child, bundle, parent_suite)
    for root in tests['testNodes']:
        visit(root)
    require(seen == [sig], 'Missing or duplicate xcresult declaration')


def test_command(case, scheme, dest, derived, bundle, seconds):
    return ['xcodebuild', 'test-without-building', '-project', 'YueJing.xcodeproj', '-scheme', scheme,
            '-configuration', 'Debug', '-destination', dest, '-derivedDataPath', str(derived),
            '-clonedSourcePackagesDirPath', 'build/SourcePackages', '-disableAutomaticPackageResolution',
            '-skipPackageUpdates', '-onlyUsePackageVersionsFromResolvedFile', '-only-testing:' + selector(case),
            '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle), '-test-timeouts-enabled', 'YES',
            '-default-test-execution-time-allowance', str(seconds), '-maximum-test-execution-time-allowance', str(seconds),
            'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64']


def selection(plan):
    return dict(scope=SCOPE, qualification='DEVELOPMENT_ONLY', release_qualified=False, native_executions=None,
                plan_sha256=dev.sha(PLAN), selected_declarations=len(plan['cases']), planned_executions=19,
                cases=[dict(selector=selector(c), arguments=c.get('arguments'), status='not_run') for c in plan['cases']])


def execute(plan, destination, *, output=OUTPUT, root=ROOT, runner=run_logged, exporter=dev.export_results):
    end = time.monotonic() + plan['total_timeout_seconds']
    output.mkdir(parents=True, exist_ok=False)
    result = dict(**selection(plan), source_commit=os.environ['GITHUB_SHA'], run_id=os.environ['GITHUB_RUN_ID'],
                  run_attempt=os.environ['GITHUB_RUN_ATTEMPT'], destination=destination, builds=[])
    def invoke(row, cmd, folder, budget):
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise dev.BudgetExhausted('Total budget exhausted')
        row.update(command=cmd, status='running', timeout_seconds=min(budget, remaining))
        code, timeout = runner(cmd, folder/'native.log', row['timeout_seconds'], cwd=root)
        row.update(exit_code=code, timed_out=timeout)
        require(code == 0 and not timeout, f'Native exit={code}, timed_out={timeout}')
    errors = (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError)
    try:
        for target in ('ReaderDomainTests', 'YueJingHostTests'):
            scheme = dev.SCHEMES[target]
            build = dict(scheme=scheme, status='not_run')
            result['builds'].append(build)
            folder = output / ('build-' + scheme)
            folder.mkdir()
            derived = root / 'build/woff2-native' / scheme
            try:
                require(not derived.exists(), 'Refuse stale DerivedData')
                invoke(build, dev.build_command(scheme, destination, derived, folder/'build.xcresult'), folder, plan['build_timeout_seconds'])
                require((folder/'build.xcresult/Info.plist').is_file(), 'Missing build result bundle')
                build['status'] = 'passed'
            except errors as exc:
                build.update(status='timed_out' if build.get('timed_out') else 'failed', error=str(exc))
            for index, (row, case) in enumerate(zip(result['cases'], plan['cases'])):
                if not case['file'].startswith(target + '/'):
                    continue
                if build['status'] != 'passed':
                    row.update(status='blocked', blocked_by=scheme)
                    continue
                folder = output / f'case-{index+1:02}'
                folder.mkdir()
                bundle = folder/'test.xcresult'
                try:
                    cmd = test_command(case, scheme, destination, derived, bundle, plan['case_timeout_seconds'])
                    invoke(row, cmd, folder, plan['test_timeout_seconds'])
                    exporter(folder, bundle, deadline=end, root=root, runner=runner)
                    verify_result(case, *(json.loads((folder/f'xcresult-{section}.json').read_bytes()) for section in ('tests', 'summary')))
                    verify_log(case, (folder/'native.log').read_text(encoding='utf-8'), plan['case_timeout_seconds'])
                    row.update(status='passed', executions=len(case.get('arguments', [])) or 1)
                except errors as exc:
                    row.update(status='timed_out' if row.get('timed_out') else 'failed', error=str(exc))
    except dev.BudgetExhausted as exc:
        result['stopped_reason'] = str(exc)
    finally:
        for row in result['cases'] + result['builds']:
            if row['status'] == 'running':
                row.update(status='incomplete')
        passed = sum(c.get('executions', 0) for c in result['cases'] if c['status'] == 'passed')
        result.update(status='passed' if passed == 19 else 'failed', observed_passed_executions=passed,
                      native_executions=passed if passed == 19 else None)
        dev.write_json(output/'development-summary.json', result)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=['selection', 'preflight', 'prepare-runtime', 'run'])
    ap.add_argument('--destination')
    args = ap.parse_args()
    plan = read_plan() if args.action == 'selection' else preflight()
    if args.action == 'prepare-runtime':
        dev.prepare_runtime()
    elif args.action == 'run':
        sim = json.loads((ROOT/'artifacts/task3/simulator-selection.json').read_bytes())
        dest = 'platform=iOS Simulator,id=' + sim['udid']
        require(re.fullmatch(r'[a-fA-F0-9-]{36}', sim['udid']) and sim['physical_device'] is False and
                sim['architecture'] == 'arm64' and args.destination in (None, dest), 'Simulator destination mismatch')
        return int(execute(plan, dest)['status'] != 'passed')
    else:
        print(json.dumps(selection(plan), indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
