"""Fixed fe09e95 diagnostic package eligibility; never launches native tests or builds."""
import argparse
import copy
import io
import json
import os
from pathlib import Path
import re
import sys
import zipfile

# Pure helpers only: no historical entrypoint, scope gate, or mutated module globals.
sys.dont_write_bytecode = True
import audit_native_case_events as audit
import check_bookmark_dock_recovery as helper
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
BASE = 'fe09e95cd30a6326179d740cc0b9248a0a532735'
SCOPE = 'bookmark-timeout-fe09e95-exact3'
REPO = 'wan780839395-cyber/YueJing'
RUN = 41767851984
ARTIFACT = 13295545933
ARCHIVE_BYTES = 164537177
ARCHIVE_SHA = '3354263403f81ed253fc0ef3c796982a1ae5bcdb31a6fb4c9759eb06d18d4d45'
WORKFLOW = '.github/workflows/ios-build.yml'
SELF = 'scripts/check_bookmark_timeout_package.py'
DOC = 'docs/BOOKMARK_TIMEOUT_PACKAGE.md'
ALLOWED = [WORKFLOW, SELF, DOC]
COUNTS = dict(TXTCoreTests=25, ReaderDomainTests=107, TXTBlockDecoderTests=6,
              ProcessingReuseMeasurementTests=1, YueJingHostTests=13, YueJingUITests=11, YueJingCanvasTests=3)
FAILED = ['testBookmarksPersistIsolateAndJumpAfterRelaunch']
TOTALS = dict(passed=162, failed=0, skipped=0, unexecuted=3, unfinished=1, ambiguous=0)
CLASSIFIED = dict(passed=162, failed=1, timed_out_cases=1, skipped=0, unexecuted=3, ambiguous=0)
UI_LOG = 'reading-ui-native/YueJingUITests.log'
CANDIDATE = 'task3/candidate-sources.json'
PINS = {
    UI_LOG: (328858, '7413dbed3c9ae6d58d33630e2f9b980e01f0811b688e1e1e595950117f43308e'),
    CANDIDATE: (31628, 'aa365be5735455ca2d40b3b966d8192267dc604aede7d721b075190a2ec13298'),
}
TIMEOUT = ("Test Case '-[YueJingUITests.ReadingFlowUITests "+FAILED[0]+"]' exceeded execution time allowance of 3 minutes. "
           "The test may have hung; check Xcode's test report for additional diagnostics. If the test requires additional time, "
           "use -[XCTestCase executionTimeAllowance] or one of xcodebuild's command-line overrides.")
REVISION = '4de97e6903d29697caae1179cdef8479c64c2639'
MANIFEST_SHA = '8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a'
require, sha, blob = helper.require, helper.sha, helper.blob


def source_gate(env, state):
    """Exact3, unique fixed parent, committed/index/working identity; synthetic-state testable."""
    require(env['PACKAGE_SCOPE'] == SCOPE and env['GITHUB_REPOSITORY'] == REPO, 'Scope/repository differs')
    require(env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_REF_NAME'] == 'main' and
            env['GITHUB_WORKFLOW_REF'] == REPO+'/'+WORKFLOW+'@refs/heads/main', 'Main/workflow differs')
    require(env['GITHUB_EVENT_NAME'] == 'workflow_dispatch' and env['GITHUB_RUN_ATTEMPT'] == '1', 'Manual attempt1 only')
    require(re.fullmatch(r'[1-9][0-9]*', env['GITHUB_RUN_ID']) and env['GITHUB_RUN_ID'] != str(RUN), 'New run required')
    require(env['HOST_VALIDATION_RUN_ID'] == str(RUN) and
            state['inputs'] == dict(package_scope=SCOPE, host_validation_run_id=str(RUN)), 'Fixed inputs differ')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}', head) and head != BASE and
            head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'], 'Source/workflow SHA differs')
    require(state['parents'] == [head, BASE] and not state['dirty'], 'Unique fixed parent/clean checkout differs')
    before, after = state['before'], state['after']
    require(len(before) == 217 and len(after) == 219 and
            set(after) == set(before) | {SELF, DOC}, '217 to 219 tracked path set differs')
    require({n for n in after if before.get(n) != after[n]} == set(ALLOWED), 'Exactly two additions and one modification required')
    require({n: v for n, v in before.items() if n != WORKFLOW} ==
            {n: v for n, v in after.items() if n not in ALLOWED}, '216 parent modes/blobs differ')
    require(set(after) == set(state['working']) == set(state['index']), 'Working/index path set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Committed/index/working entry differs: '+n)
    return dict(scope=SCOPE, source_commit=head, parent=BASE, approved_changed_files=ALLOWED,
                tracked_before=217, tracked_after=219, other_entries_equal=216,
                index_and_working_equal_commit=True, production_and_tests_unchanged=True)


def workflow_blocks():
    gate = '''      # BEGIN BOOKMARK TIMEOUT PACKAGE GATE
      - name: Require the fixed bookmark timeout evidence and exact three-file package scope
        if: ${{ inputs.package_scope == 'SCOPE' }}
        env:
          PACKAGE_SCOPE: ${{ inputs.package_scope }}
          HOST_VALIDATION_RUN_ID: ${{ inputs.host_validation_run_id }}
          NATIVE_READ_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          python3 -B scripts/check_bookmark_timeout_package.py --package-gate --source "$GITHUB_SHA" --run-id "$HOST_VALIDATION_RUN_ID"
      # END BOOKMARK TIMEOUT PACKAGE GATE

'''.replace("'SCOPE'", "'"+SCOPE+"'")
    dependency = '''      # BEGIN BOOKMARK TIMEOUT PACKAGE DEPENDENCY
      - name: Require fixed official GRDB for the bookmark timeout diagnostic package
        if: ${{ inputs.package_scope == 'SCOPE' }}
        run: |
          set -euo pipefail
          python3 -B scripts/check_bookmark_timeout_package.py --fixed-dependency --source "$GITHUB_SHA"
      # END BOOKMARK TIMEOUT PACKAGE DEPENDENCY

'''.replace("'SCOPE'", "'"+SCOPE+"'")
    return gate, dependency


def strip_workflow(current):
    gate, dependency = workflow_blocks()
    option, case = '          - '+SCOPE+'\n', '|'+SCOPE+') ;;'
    for part in (gate, dependency, option, case):
        require(current.count(part) == 1, 'Missing/changed/duplicate workflow insertion')
    require(current.index(gate) < current.index('      - name: Verify the selected native toolchain') and
            current.index('python3 scripts/validate_task3.py resolved') < current.index(dependency) <
            current.index('      - name: Verify Release settings'), 'Diagnostic gate ordering differs')
    return current.replace(gate, '').replace(dependency, '').replace(option, '').replace(case, ') ;;')


def workflow_gate(current, parent):
    require(strip_workflow(current) == parent, 'Legacy scope/public build/package chain changed')
    return dict(public_chain_unchanged=True, added_scope_only_steps=2)


def upstream_gate(run, jobs):
    result = helper.upstream_gate(run, jobs, BASE, str(RUN))
    require(run['html_url'] == 'https://github.com/'+REPO+'/actions/runs/'+str(RUN), 'Upstream URL differs')
    job = jobs['jobs'][0]
    steps = {s['number']: s for s in job['steps']}
    require(set(steps) == set(range(1, 23)) | {44, 45}, 'Unexpected upstream step set')
    for n, name in ((1, 'Set up job'), (44, 'Post Check out this source revision'), (45, 'Complete job')):
        require(steps[n]['name'] == name and steps[n]['status'] == 'completed' and
                steps[n]['conclusion'] == 'success', 'Setup/cleanup differs')
    require(job['head_branch'] == 'main', 'Upstream job branch differs')
    return result


def artifact_metadata(listing):
    require(listing['total_count'] == len(listing['artifacts']) == 1, 'Unique evidence artifact required; no IPA')
    item = listing['artifacts'][0]
    require(item['id'] == ARTIFACT and item['name'] == 'task3-evidence-'+str(RUN)+'-'+BASE and
            item['size_in_bytes'] == ARCHIVE_BYTES and item['digest'] == 'sha256:'+ARCHIVE_SHA and
            item['expired'] is False, 'Fixed artifact identity/size/digest differs')
    require(item['workflow_run'] == dict(id=RUN, repository_id=1435377188, head_repository_id=1435377188,
                                      head_branch='main', head_sha=BASE), 'Artifact source differs')
    return item


def pinned_bytes(raw, size, digest, label):
    require(len(raw) == size and sha(raw) == digest, 'Fixed bytes/hash differ: '+label)


def archive_gate(listing, raw):
    artifact_metadata(listing)
    pinned_bytes(raw, ARCHIVE_BYTES, ARCHIVE_SHA, 'original ZIP')
    files = helper.zip_members(raw)  # Bounded, CRC-read every member, no extraction.
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        names = {i.filename for i in archive.infolist() if not i.is_dir()}
    absent_downstream(names)
    return files, names


def absent_downstream(names):
    require(not any(n.lower().endswith('.ipa') or 'YueJingCanvasTests' in n or
                    n in ('task3/native-test-gate.json', 'task3/host-only-scope.json') for n in names),
            'Unexpected Canvas/full gate/Host-only/IPA evidence')


def native_events(raw, target):
    parsed = audit.parse_events(raw, inventory.expected_names(target), ui=target == 'YueJingUITests')
    wanted = dict(passed=COUNTS[target], failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0)
    if target == 'YueJingUITests':
        wanted.update(passed=10, unfinished=1)
        require(parsed['parser_complete'] is False and not parsed['unexpected'] and not parsed['derived_starts'] and
                parsed['unknown_test_lines'] == [dict(line=1706, text=TIMEOUT)], 'Only pinned timeout may be unknown')
        cases = {c['name']: c for c in parsed['cases']}
        failed = cases[FAILED[0]]
        require(failed['status'] == 'unfinished' and len(failed['starts']) == 1 and
                failed['starts'][0]['line'] == 779 and not failed['finishes'] and not failed['skips'],
                'Timeout raw case must remain unfinished; no synthesized finish')
        intervals = []
        for c in parsed['cases']:
            require(len(c['starts']) == 1 and not c['skips'], 'Missing/duplicate/skipped UI start')
            if c['name'] == FAILED[0]:
                end = 1706  # Supplemental boundary only; raw parser records are untouched.
            else:
                require(c['status'] == 'passed' and len(c['finishes']) == 1, 'Additional UI failure/unfinished')
                end = c['finishes'][0]['line']
            intervals.append((c['starts'][0]['line'], end))
        intervals.sort()
        require(all(a < b for a, b in intervals) and all(a[1] < b[0] for a, b in zip(intervals, intervals[1:])),
                'Overlapping UI cases')
    else:
        require(parsed['parser_complete'], 'Incomplete/unknown/ambiguous native events: '+target)
        if target == 'YueJingCanvasTests':
            wanted.update(passed=0, unexecuted=3)
            require(not raw, 'Canvas executed')
    require(parsed['totals'] == wanted, 'Native event totals differ: '+target)
    return parsed


def timeout_gate(files):
    for n, (size, digest) in PINS.items():
        pinned_bytes(files[n], size, digest, n)
    lines = files[UI_LOG].decode('utf-8').splitlines()
    require(len(lines) == 4847 and lines[1705] == TIMEOUT and
            lines[778] == "Test Case '-[YueJingUITests.ReadingFlowUITests "+FAILED[0]+"]' started." and
            lines[777] == "Test Case '-[YueJingUITests.ReadingFlowUITests testBookmarksAccessibilityCloseAndConfirmedDeletion]' passed (97.148 seconds)." and
            lines[4841] == 'Failing tests:' and lines[4842] == '\tReadingFlowUITests.'+FAILED[0]+'()',
            'Original timeout/start/passed-case/failing-summary differs')
    require(lines[1834] == 'Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.',
            'Original XCTest restart differs')
    return dict(case=FAILED[0], original_start_line=779, original_timeout_line=1706, xcode_failing_summary_line=4843,
                case_timeout_seconds=180, native_exit=65, overall_timed_out=False, raw_parser_status='unfinished',
                raw_parser_complete=False, raw_unknown_test_lines=[dict(line=1706, text=TIMEOUT)],
                supplemental_classification='XCTest single-case timeout failure', raw_logs_modified=False,
                synthetic_finish_created=False, framework_restart_line=1835, agent_manual_rerun=False,
                qualification='The template may-have-hung text does not establish an App hang or completed long flow')


def execution_gate(selection, execution, target, exit_raw):
    for value in (selection, execution):
        helper.provenance(value, BASE, RUN)
        helper.selection_gate(value, target)
    require(all(execution.get(k) == v for k, v in selection.items()), 'Execution/selection differs')
    expected = 65 if target == 'YueJingUITests' else 0
    require(type(execution['native_exit']) is int and execution['native_exit'] == expected and
            execution['timed_out'] is False and exit_raw.strip() == str(expected).encode(), 'Native exit/overall timeout differs')


def evidence_gate(files, expected_sources):
    require(inventory.COUNTS == COUNTS and inventory.TOTAL == 166, 'Frozen166 inventory differs')
    def receipt(n):
        value = json.loads(files[n])
        helper.provenance(value, BASE, RUN)
        return value
    timeout = timeout_gate(files)
    frozen = receipt(CANDIDATE)
    require(len(expected_sources) == 160 and frozen['files'] == expected_sources and
            frozen['inventory'] == inventory.validate_source(), 'Complete parent160 source/inventory differs')
    absent_downstream(files)
    groups = []
    for target in COUNTS:
        folder = 'reading-ui-native/' if target in ('YueJingHostTests', 'YueJingUITests') else 'task3/'
        raw = b'' if target == 'YueJingCanvasTests' else files[folder+target+'.log']
        parsed = native_events(raw, target)
        groups.append(dict(target=target, native_exit=None, **parsed))
        if target == 'YueJingCanvasTests':
            continue
        expected_exit = 65 if target == 'YueJingUITests' else 0
        exit_raw = files[folder+target+'-exit-code.txt']
        require(exit_raw.strip() == str(expected_exit).encode(), 'Native exit differs: '+target)
        groups[-1]['native_exit'] = expected_exit
        if target in ('YueJingHostTests', 'YueJingUITests'):
            selection = receipt(folder+target+'-selection.json')
            execution = receipt(folder+target+'-execution.json')
            execution_gate(selection, execution, target, exit_raw)
            source = json.loads(files[folder+target+'-source-hashes.json'])
            require(source['source_commit'] == BASE and source['files'] == helper.app_source_subset(expected_sources), 'App source map differs')
        if target == 'YueJingUITests':
            require(folder+target+'-counts.json' not in files, 'Unexpected passing UI count receipt')
            continue
        counts = receipt(folder+target+'-counts.json')
        require(counts['expected'] == COUNTS[target] and counts['native_exit'] == 0 and counts['log_sha256'] == sha(raw) and
                counts['declared'] == inventory.expected_names(target) and
                len(counts['passed']) == COUNTS[target] and set(counts['passed']) == set(inventory.expected_names(target)), 'Native counts differ')
        if target == 'YueJingHostTests':
            from run_reading_ui_tests import count_log
            native = count_log(target, raw.decode('utf-8'), 0)
            require(all(counts.get(k) == v for k, v in selection.items()), 'Host counts selection differs')
        else:
            require(counts['inventory_sha256'] == sha((ROOT/'scripts/task3_test_inventory.py').read_bytes()) and
                    counts['selection'] == inventory.selection(target) and
                    counts['source_files'] == ['Tests/'+p for p in sorted(inventory.FILES) if inventory.group_for(p) == target], 'Data selection differs')
            native = inventory.parse_swift_log(target, raw.decode('utf-8'), 0)
        require(all(counts.get(k) == json.loads(json.dumps(v)) for k, v in native.items()), 'Original counts/raw schema differs')
    totals = {k: sum(g['totals'][k] for g in groups) for k in TOTALS}
    require(totals == TOTALS, 'Full166 raw totals differ')
    return dict(selected=166, totals=totals, raw_parser_totals=totals, classified_totals=CLASSIFIED,
                failed_cases=FAILED, groups=groups, timeout_evidence=timeout,
                original_evidence_sha256={n: digest for n, (_, digest) in PINS.items()},
                full_regression_passed=False, native_tests_this_run=0, prior_packaging='not executed')


def validate_evidence(run, jobs, listing, raw, expected_sources=None):
    upstream = upstream_gate(run, jobs)
    files, names = archive_gate(listing, raw)
    if expected_sources is None:
        pinned_bytes(files[CANDIDATE], *PINS[CANDIDATE], CANDIDATE)
        expected_sources = json.loads(files[CANDIDATE])['files']
    upstream.update(evidence_gate(files, expected_sources), artifact_id=ARTIFACT,
                    artifact_sha256=ARCHIVE_SHA, artifact_bytes=ARCHIVE_BYTES)
    return upstream, files, names


def candidate_path(n):
    return n == 'project.yml' or (n.startswith(('App/', 'Sources/', 'Tests/', 'scripts/', '.github/workflows/')) and
                                Path(n).suffix in ('.swift', '.py', '.yml', '.txt'))


def local_candidate_names():
    return {'project.yml'} | {p.relative_to(ROOT).as_posix()
        for folder in ('App', 'Sources', 'Tests', 'scripts', '.github/workflows')
        for p in (ROOT/folder).rglob('*') if p.is_file() and candidate_path(p.relative_to(ROOT).as_posix())}


def offline_evidence(path):
    run, jobs, listing = [json.loads((path/n).read_bytes()) for n in
                          ('terminal-run.json', 'terminal-jobs.json', 'terminal-artifacts.json')]
    result, files, names = validate_evidence(run, jobs, listing, (path/(str(ARTIFACT)+'.zip')).read_bytes())
    evidence = path/'evidence'
    disk = {p.relative_to(evidence).as_posix() for p in evidence.rglob('*') if p.is_file()}
    require(disk == names, 'Extracted evidence path set differs from original ZIP')
    for n, data in files.items():
        p = evidence/n
        require(not any(q.is_symlink() for q in (p, *p.parents)) and p.read_bytes() == data, 'Extracted original bytes differ: '+n)
    frozen = json.loads(files[CANDIDATE])['files']
    require(local_candidate_names() == set(frozen) | {SELF}, 'Local complete candidate path set differs')
    for n, digest in frozen.items():
        p = ROOT/n
        require(not any(q.is_symlink() for q in (p, *p.parents)), 'Local candidate symlink: '+n)
        data = p.read_bytes()
        if n == WORKFLOW and SCOPE.encode() in data:
            data = strip_workflow(data.decode('utf-8')).encode('utf-8')
        require(sha(data) == digest, 'Local parent candidate bytes differ: '+n)
    return dict(passed=True, mode='offline-evidence', source_gate='not evaluated: cloud committed checkout required',
                selected=result['selected'], totals=result['totals'], raw_parser_totals=result['raw_parser_totals'],
                classified_totals=result['classified_totals'], failed_cases=FAILED, parent_candidate_files=160,
                archive_members=len(names), raw_hashes_verified=PINS, raw_logs_modified=False,
                full_regression_passed=False, native_executions=0, network_requests=0, git_invocations=0)


def cloud_state(env):
    git, tree = helper.git, helper.tree  # Read-only Git, cloud package-gate only.
    before, after, working, index, hashes = tree(BASE), tree('HEAD'), {}, {}, {}
    for n in after:
        p = ROOT/n
        regular = p.is_file() and not any(q.is_symlink() for q in (p, *p.parents))
        data = p.read_bytes() if regular else b''
        working[n], hashes[n] = dict(regular=regular, blob=blob(data)), sha(data)
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if row:
            meta, n = row.split(b'\t', 1)
            require(n.decode() not in index, 'Unmerged index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse', 'HEAD').decode().strip(),
                 parents=git('rev-list', '--parents', '-n', '1', 'HEAD').decode().split(),
                 dirty=git('status', '--porcelain=v1', '--untracked-files=all'), before=before, after=after,
                 working=working, index=index, inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = source_gate(env, state)
    require(local_candidate_names() == {n for n in after if candidate_path(n)}, 'Ignored/untracked candidate source exists')
    product_files = {p.relative_to(ROOT).as_posix() for folder in ('App', 'Sources', 'Tests')
                     for p in (ROOT/folder).rglob('*') if p.is_file()}
    require(product_files == {n for n in after if n.startswith(('App/', 'Sources/', 'Tests/'))},
            'Complete product/test resource path set differs')
    parent_workflow = git('show', BASE+':'+WORKFLOW).decode('utf-8')
    receipt['workflow_contract'] = workflow_gate((ROOT/WORKFLOW).read_bytes().decode('utf-8'), parent_workflow)
    parent_sources = {n: sha(git('show', BASE+':'+n)) for n in sorted(before) if candidate_path(n)}
    require(len(parent_sources) == 160, 'Parent160 candidate set differs')
    receipt.update(files=hashes, parent_candidate_sha256=parent_sources,
                   candidate_sha256={n: h for n, h in hashes.items() if candidate_path(n)})
    return receipt, parent_sources


def status_record(head, receipt, upstream):
    return dict(source_commit=head, app_candidate=BASE, qualification='TESTS NOT RUN', tests_run=False,
                native_tests_this_run=dict(status='not run', executions=0, selection=[]), native_execution=[],
                physical_device_acceptance='not performed', full_regression_passed=False, formal_release=False,
                prior_validation_run=RUN, prior_validation_attempt=1, prior_validation_source_commit=BASE,
                prior_validation_url=upstream['url'], prior_counts=upstream['totals'], prior_raw_parser_totals=TOTALS,
                prior_classified_totals=CLASSIFIED, prior_failed_cases=FAILED, prior_timeout_evidence=upstream['timeout_evidence'],
                prior_validation_selected=166, prior_validation_passed=162, prior_validation_failed=1,
                prior_validation_unexecuted=3, prior_validation_skipped=0, prior_raw_unfinished=1, prior_task3_tests_rerun=False,
                full_test_gate='NOT PASSED: one XCTest180s bookmark UI timeout; Canvas3 unexecuted',
                original_task3_gate='failure retained; no rerun', approved_changed_files=ALLOWED, package_scope=SCOPE,
                candidate_sha256=receipt['candidate_sha256'], parent_candidate_sha256=receipt['parent_candidate_sha256'],
                bookmark_timeout_exact3_gate=receipt,
                purpose='Paused repair; separately approved diagnostic IPA only, not full acceptance or formal release')


def summary(message):
    print('::warning::'+message)
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a', encoding='utf-8') as output:
        output.write('## Bookmark timeout diagnostic — TESTS NOT RUN\n\n'+message+'\n\n')


def cli_identity(source, run_id=None):
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'Package/dependency modes are cloud-only')
    require(source == os.environ['GITHUB_SHA'] and re.fullmatch(r'[0-9a-f]{40}', source) and source != BASE,
            'Explicit source differs')
    if run_id is not None:
        require(run_id == str(RUN) == os.environ['HOST_VALIDATION_RUN_ID'], 'Explicit fixed upstream run differs')


def package_gate(source, run_id):
    cli_identity(source, run_id)
    env = os.environ
    receipt, expected_sources = cloud_state(env)
    token = env.get('NATIVE_READ_TOKEN', '')
    require(token, 'Existing read-only token required; no fallback credentials')
    run = helper.api_read('/actions/runs/'+str(RUN), token)
    jobs = helper.api_read('/actions/runs/'+str(RUN)+'/attempts/1/jobs?per_page=100', token)
    upstream_gate(run, jobs)
    listing = helper.api_read('/actions/runs/'+str(RUN)+'/artifacts?per_page=100', token)
    artifact_metadata(listing)
    raw = helper.api_read('/actions/artifacts/'+str(ARTIFACT)+'/zip', token, binary=True)
    upstream, files, _ = validate_evidence(run, jobs, listing, raw, expected_sources)
    receipt.update(run_id=env['GITHUB_RUN_ID'], run_attempt=1, upstream_full_validation=upstream)
    out = ROOT/'artifacts/task3'
    helper.save(out/'bookmark-timeout-exact3-gate.json', receipt)
    helper.save(out/'bookmark-timeout-candidate-sources.json', dict(source_commit=source, parent=BASE,
                parent_files=expected_sources, files=receipt['candidate_sha256'], tracked_files=receipt['files']))
    for n, value in (('run', run), ('jobs', jobs), ('artifacts', listing)):
        helper.save(out/('bookmark-timeout-upstream-'+n+'.json'), value)
    # Preserve original logs/receipts, not the 164MB ZIP, attachments, or xcresult.
    for n, data in files.items():
        if n in PINS or (n.startswith(('task3/', 'reading-ui-native/')) and Path(n).name.startswith(tuple(COUNTS)) and
                         (n.endswith('.log') or n.endswith(('-counts.json', '-selection.json', '-execution.json', '-source-hashes.json', '-exit-code.txt')))):
            p = out/'bookmark-timeout-prior'/n
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open('xb') as output:
                output.write(data)
    helper.save(ROOT/'artifacts/verification-status.json', status_record(source, receipt, upstream))
    summary('Diagnostic eligibility only. Current native executions: 0; physical acceptance: not performed; formal release: false. '
            'Parent '+BASE+' / run '+str(RUN)+' attempt1 remains FAILURE: 166 selected, 162 passed, 1 XCTest180s timeout failure, '
            '3 unexecuted. Original parser: 162 passed / 0 failed / 1 unfinished / 3 unexecuted; only unknown line1706. '
            'UI exit65, overall timed_out=false; no synthesized finish, rerun, Canvas, or prior device package.')


def dependency_gate(value):
    require(value['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            value['package']['state'] == dict(revision=REVISION, version='7.0.0') and
            value['checkout_revision'] == REVISION and value['package_manifest_sha256'] == MANIFEST_SHA,
            'Fixed official GRDB7.0.0 revision/manifest differs')


def status_gate(status, source):
    require(status['source_commit'] == source and status['app_candidate'] == BASE and
            status['package_scope'] == SCOPE and status['bookmark_timeout_exact3_gate']['parent'] == BASE and
            status['bookmark_timeout_exact3_gate']['source_commit'] == source and
            status['qualification'] == 'TESTS NOT RUN' and status['tests_run'] is False and
            status['native_tests_this_run'] == dict(status='not run', executions=0, selection=[]) and status['native_execution'] == [] and
            status['physical_device_acceptance'] == 'not performed' and status['full_regression_passed'] is False and status['formal_release'] is False and
            status['prior_counts'] == status['prior_raw_parser_totals'] == TOTALS and status['prior_classified_totals'] == CLASSIFIED and
            status['prior_validation_run'] == RUN and status['prior_validation_attempt'] == 1 and status['prior_validation_source_commit'] == BASE and
            status['prior_validation_selected'] == 166 and status['prior_validation_passed'] == 162 and status['prior_validation_failed'] == 1 and
            status['prior_validation_unexecuted'] == 3 and status['prior_raw_unfinished'] == 1 and status['prior_failed_cases'] == FAILED and
            status['prior_task3_tests_rerun'] is False and status.get('prior_full146_passed') is not True, 'Diagnostic status differs')


def fixed_dependency(source):
    cli_identity(source)
    value = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    dependency_gate(value)
    status = json.loads((ROOT/'artifacts/verification-status.json').read_bytes())
    status_gate(status, source)
    helper.save(ROOT/'artifacts/task3/bookmark-timeout-fixed-dependency.json',
                dict(source_commit=source, scope=SCOPE, revision=REVISION, package_manifest_sha256=MANIFEST_SHA,
                     passed=True, qualification='TESTS NOT RUN'))
    summary('Fixed official GRDB7.0.0 receipt verified; unchanged public build/package chain only. '
            'TESTS NOT RUN; no physical-device, full-regression, or formal-release acceptance.')


def self_check():
    """Synthetic controls; no network, Git, writes, historical entrypoints or native execution."""
    positives, negatives = [], []
    def good(label, fn):
        fn()
        positives.append(label)
    def bad(label, fn):
        try:
            fn()
        except (ValueError, KeyError, IndexError, zipfile.BadZipFile):
            negatives.append(label)
            return
        raise ValueError('Unsafe acceptance: '+label)
    head = 'a'*40
    before = {WORKFLOW: ['100644', 'blob', 'b'*40], 'App/Frozen.swift': ['100644', 'blob', 'b'*40]}
    before.update({'frozen/'+str(i): ['100644', 'blob', 'b'*40] for i in range(215)})
    after = copy.deepcopy(before)
    after.update({n: ['100644', 'blob', 'c'*40] for n in ALLOWED})
    env = dict(PACKAGE_SCOPE=SCOPE, GITHUB_REPOSITORY=REPO, GITHUB_REF='refs/heads/main', GITHUB_REF_NAME='main',
               GITHUB_WORKFLOW_REF=REPO+'/'+WORKFLOW+'@refs/heads/main', GITHUB_EVENT_NAME='workflow_dispatch',
               GITHUB_RUN_ATTEMPT='1', GITHUB_RUN_ID='50000000000', HOST_VALIDATION_RUN_ID=str(RUN),
               GITHUB_SHA=head, GITHUB_WORKFLOW_SHA=head)
    state = dict(head=head, parents=[head, BASE], dirty=b'', before=before, after=after,
                 working={n: dict(regular=True, blob=v[2]) for n, v in after.items()},
                 index={n: [v[0], v[2], '0'] for n, v in after.items()},
                 inputs=dict(package_scope=SCOPE, host_validation_run_id=str(RUN)))
    good('source-exact3', lambda: source_gate(env, state))
    for key, value in dict(PACKAGE_SCOPE='other', GITHUB_REPOSITORY='other/repo', GITHUB_REF='refs/heads/dev',
                          GITHUB_REF_NAME='dev', GITHUB_WORKFLOW_REF='other', GITHUB_EVENT_NAME='push',
                          GITHUB_RUN_ATTEMPT='2', GITHUB_RUN_ID=str(RUN), HOST_VALIDATION_RUN_ID='1',
                          GITHUB_SHA='b'*40, GITHUB_WORKFLOW_SHA='b'*40).items():
        bad('source-'+key, lambda k=key, v=value: source_gate(dict(env, **{k: v}), state))
    for key, value in [('parents', [head, BASE, 'b'*40]), ('parents', [head, 'b'*40]), ('dirty', b'M file'),
                       ('inputs', dict(state['inputs'], extra='x')), ('inputs', {}), ('head', BASE), ('index', {}), ('working', {})]:
        bad('state-'+key+str(len(negatives)), lambda k=key, v=value: source_gate(env, dict(state, **{k: v})))
    for label, mutate in [('production-drift', lambda s: s['after']['App/Frozen.swift'].__setitem__(2, 'd'*40)),
                          ('extra-path', lambda s: s['after'].__setitem__('extra', ['100644', 'blob', 'b'*40])),
                          ('missing-path', lambda s: s['after'].pop('App/Frozen.swift')),
                          ('mode-drift', lambda s: s['after']['App/Frozen.swift'].__setitem__(0, '100755')),
                          ('index-blob', lambda s: s['index'][SELF].__setitem__(1, 'd'*40)),
                          ('working-bytes', lambda s: s['working'][SELF].__setitem__('blob', 'd'*40)),
                          ('working-symlink', lambda s: s['working'][SELF].__setitem__('regular', False))]:
        altered = copy.deepcopy(state)
        mutate(altered)
        bad(label, lambda s=altered: source_gate(env, s))
    gate, dep = workflow_blocks()
    parent = 'options:\n          - old\nold) ;;\n      - name: Verify the selected native toolchain\npython3 scripts/validate_task3.py resolved\n      - name: Verify Release settings\n'
    current = parent.replace('          - old\n', '          - old\n          - '+SCOPE+'\n').replace('old) ;;', 'old|'+SCOPE+') ;;')
    current = current.replace('      - name: Verify the selected native toolchain', gate+'      - name: Verify the selected native toolchain').replace('      - name: Verify Release settings', dep+'      - name: Verify Release settings')
    good('workflow-public-chain', lambda: workflow_gate(current, parent))
    for label, text in [('common-chain', current+'x'), ('unsafe-marker-body', current.replace('set -euo pipefail', 'echo unsafe', 1)),
                        ('scope-condition', current.replace("== '"+SCOPE+"'", "!= '"+SCOPE+"'", 1)),
                        ('duplicate-block', current+gate), ('missing-block', current.replace(gate, '')),
                        ('missing-source', current.replace(' --source "$GITHUB_SHA"', '', 1))]:
        bad(label, lambda t=text: workflow_gate(t, parent))
    run = dict(id=RUN, head_sha=BASE, head_branch='main', event='workflow_dispatch', run_attempt=1,
               workflow_id=398234793, path='.github/workflows/task3-validate.yml', status='completed', conclusion='failure',
               repository=dict(full_name=REPO), head_repository=dict(full_name=REPO), html_url='https://github.com/'+REPO+'/actions/runs/'+str(RUN))
    names = re.findall(r'^      - name: (.+)$', (ROOT/'.github/workflows/task3-validate.yml').read_text(encoding='utf-8'), re.M)
    steps = [dict(number=i, name=n, status='completed', conclusion='failure' if i == 16 else
                  'skipped' if i in (13, 15, 17, 18, 19, 20, 22) else 'success') for i, n in enumerate(names, 2)]
    steps = [dict(number=1, name='Set up job', status='completed', conclusion='success')]+steps
    steps += [dict(number=i, name=n, status='completed', conclusion='success') for i, n in
              ((44, 'Post Check out this source revision'), (45, 'Complete job'))]
    jobs = dict(total_count=1, jobs=[dict(run_id=RUN, run_attempt=1, head_sha=BASE, head_branch='main',
                                       status='completed', conclusion='failure', name='validate', steps=steps)])
    good('upstream-full-failure', lambda: upstream_gate(run, jobs))
    for key, value in dict(id=1, head_sha=head, head_branch='other', event='push', run_attempt=2,
                          workflow_id=1, path=WORKFLOW, status='in_progress', conclusion='success', html_url='bad',
                          repository=dict(full_name='x/y'), head_repository=dict(full_name='x/y')).items():
        bad('upstream-'+key, lambda k=key, v=value: upstream_gate(dict(run, **{k: v}), jobs))
    for step in steps:
        altered = copy.deepcopy(jobs)
        altered['jobs'][0]['steps'][steps.index(step)]['conclusion'] = 'failure' if step['conclusion'] != 'failure' else 'success'
        bad('step-'+str(step['number']), lambda j=altered: upstream_gate(run, j))
    for target in COUNTS:
        ui = target == 'YueJingUITests'
        if ui:
            lines = ['']*1706
            lines[778] = "Test Case '-[YueJingUITests.ReadingFlowUITests "+FAILED[0]+"]' started."
            lines[1705] = TIMEOUT
            for name in inventory.expected_names(target):
                if name not in FAILED:
                    prefix = "Test Case '-[ReadingFlowUITests "+name+"]' "
                    lines += [prefix+'started.', prefix+'passed.']
        else:
            lines = [line for name in inventory.expected_names(target)
                     for line in ('Test '+name+'() started.', 'Test '+name+'() passed.')]
        raw = ('\n'.join(lines)+'\n').encode() if target != 'YueJingCanvasTests' else b''
        good('events-'+target, lambda r=raw, t=target: native_events(r, t))
        if target == 'YueJingCanvasTests':
            bad('canvas-executed', lambda: native_events(b'noise', 'YueJingCanvasTests'))
            continue
        for label, data in [('extra-failure', raw.replace(b'passed.', b'failed.', 1)),
                            ('unfinished', raw.replace(b'passed.', b'incomplete.', 1)),
                            ('skip', raw.replace(b'passed.', b'skipped.', 1)), ('duplicate', raw+raw), ('missing', b'')]:
            bad(target+'-'+label, lambda r=data, t=target: native_events(r, t))
        if ui:
            for label, data in [('timeout-budget', raw.replace(b'3 minutes', b'4 minutes')),
                                ('unknown-extra', raw+b'Test Case unknown event\n'),
                                ('timeout-shifted', b'\n'+raw), ('timeout-missing', raw.replace(TIMEOUT.encode(), b'')),
                                ('synthesized-finish', raw+("Test Case '-[ReadingFlowUITests "+FAILED[0]+"]' failed.\n").encode())]:
                bad(label, lambda r=data: native_events(r, 'YueJingUITests'))
    for target in ('YueJingHostTests', 'YueJingUITests'):
        selection = dict(source_commit=BASE, run_id=str(RUN), run_attempt='1', target=target, scheme='YueJingUI',
                         configuration='Debug', expected=COUNTS[target], declared=inventory.expected_names(target),
                         timeout_seconds=480 if target == 'YueJingHostTests' else 1200,
                         command=['xcodebuild', 'test', '-only-testing:'+target, '-scheme', 'YueJingUI', '-configuration', 'Debug',
                                  '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                                  '-default-test-execution-time-allowance', '180', '-maximum-test-execution-time-allowance', '180'])
        code = 65 if target == 'YueJingUITests' else 0
        execution = dict(selection, native_exit=code, timed_out=False)
        good('execution-'+target, lambda: execution_gate(selection, execution, target, str(code).encode()))
        for key, value in dict(native_exit=1, timed_out=True, source_commit=head, run_id='1', run_attempt='2',
                              expected=1, declared=[], timeout_seconds=180, command=['xcodebuild', 'test', '-only-testing:Other']).items():
            bad(target+'-execution-'+key, lambda k=key, v=value: execution_gate(selection, dict(execution, **{k: v}), target, str(code).encode()))
        bad(target+'-exit-file', lambda: execution_gate(selection, execution, target, b'1'))
    listing = dict(total_count=1, artifacts=[dict(id=ARTIFACT, name='task3-evidence-'+str(RUN)+'-'+BASE,
                   size_in_bytes=ARCHIVE_BYTES, digest='sha256:'+ARCHIVE_SHA, expired=False,
                   workflow_run=dict(id=RUN, repository_id=1435377188, head_repository_id=1435377188, head_branch='main', head_sha=BASE))])
    good('artifact-metadata', lambda: artifact_metadata(listing))
    for key, value in dict(id=1, name='other', size_in_bytes=1, digest='sha256:bad', expired=True, workflow_run={}).items():
        altered = copy.deepcopy(listing)
        altered['artifacts'][0][key] = value
        bad('artifact-'+key, lambda a=altered: artifact_metadata(a))
    bad('multiple-artifacts', lambda: artifact_metadata(dict(total_count=2, artifacts=listing['artifacts']*2)))
    good('byte-integrity-control', lambda: pinned_bytes(b'x', 1, sha(b'x'), 'control'))
    bad('evidence-byte-tamper', lambda: pinned_bytes(b'y', 1, sha(b'x'), 'tamper'))
    for n, (size, digest) in PINS.items():
        bad('pinned-evidence-'+n, lambda s=size, d=digest, label=n: pinned_bytes(b'', s, d, label))
    for name in ('../escape.log', '/absolute.log', 'a\\b.log', 'a:b.log'):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.writestr(name.replace('\\', '/'), b'x')
        raw_zip = buf.getvalue().replace(name.replace('\\', '/').encode(), name.encode())
        bad('zip-path-'+name, lambda r=raw_zip: helper.zip_members(r))
    value = dict(package=dict(location='https://github.com/groue/GRDB.swift.git', state=dict(revision=REVISION, version='7.0.0')),
                 checkout_revision=REVISION, package_manifest_sha256=MANIFEST_SHA)
    good('fixed-GRDB', lambda: dependency_gate(value))
    for key in ('checkout_revision', 'package_manifest_sha256'):
        bad('dependency-'+key, lambda k=key: dependency_gate(dict(value, **{k: 'bad'})))
    for key in ('revision', 'version'):
        altered = copy.deepcopy(value)
        altered['package']['state'][key] = 'bad'
        bad('dependency-'+key, lambda v=altered: dependency_gate(v))
    altered = copy.deepcopy(value)
    altered['package']['location'] = 'https://example.com/fork'
    bad('dependency-location', lambda: dependency_gate(altered))
    status = status_record(head, dict(parent=BASE, source_commit=head, candidate_sha256={}, parent_candidate_sha256={}),
                           dict(url=run['html_url'], totals=TOTALS, timeout_evidence={}))
    good('diagnostic-status', lambda: status_gate(status, head))
    for key, value in dict(qualification='PASSED', tests_run=True, native_tests_this_run={}, native_execution=[{}],
                          physical_device_acceptance='passed', full_regression_passed=True, formal_release=True,
                          prior_counts=CLASSIFIED, prior_raw_parser_totals={}, prior_classified_totals={}, prior_validation_failed=0,
                          prior_raw_unfinished=0, prior_task3_tests_rerun=True, prior_full146_passed=True).items():
        bad('status-'+key, lambda k=key, v=value: status_gate(dict(status, **{k: v}), head))
    return dict(passed=True, positive_controls=len(positives), negative_controls=len(negatives),
                controls=dict(positive=positives, negative=negatives), native_executions=0, network_requests=0,
                git_invocations=0, filesystem_writes=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--self-check', action='store_true')
    mode.add_argument('--offline-evidence', type=Path, metavar='COLLECTION')
    mode.add_argument('--package-gate', action='store_true')
    mode.add_argument('--fixed-dependency', action='store_true')
    parser.add_argument('--source')
    parser.add_argument('--run-id')
    args = parser.parse_args()
    if args.package_gate and (not args.source or not args.run_id):
        parser.error('--package-gate requires --source and --run-id')
    if args.fixed_dependency and (not args.source or args.run_id is not None):
        parser.error('--fixed-dependency requires --source only')
    if (args.self_check or args.offline_evidence) and (args.source is not None or args.run_id is not None):
        parser.error('Offline modes do not accept cloud identity arguments')
    if args.self_check:
        print(json.dumps(self_check(), ensure_ascii=False, indent=2))
    elif args.offline_evidence:
        print(json.dumps(offline_evidence(args.offline_evidence), ensure_ascii=False, indent=2))
    elif args.package_gate:
        package_gate(args.source, args.run_id)
    else:
        fixed_dependency(args.source)


if __name__ == '__main__':
    main()
