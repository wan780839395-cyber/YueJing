"""Fixed-parent diagnostic IPA eligibility, not native acceptance. No tests/builds are launched."""
import argparse
import copy
import io
import json
import os
from pathlib import Path
import re
import sys
import zipfile

# Import pure helpers only; never invoke the historical entrypoints or scope gates.
sys.dont_write_bytecode = True
import audit_native_case_events as audit
import check_bookmark_dock_recovery as helper
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
BASE = 'c77853a46d2d536a431944cca6f2b1af5454855a'
SCOPE = 'bookmark-ui-locator-c77853a-exact3'
REPO = 'wan780839395-cyber/YueJing'
RUN = 41749976876
ARTIFACT = 13286472309
ARCHIVE_BYTES = 163905336
ARCHIVE_SHA = '2c6bfb9203b94a2251b347cf41fb99056060ffaf8327ddaf3ee5270eb862ba85'
WORKFLOW = '.github/workflows/ios-build.yml'
SELF = 'scripts/check_bookmark_ui_locator_package.py'
DOC = 'docs/BOOKMARK_UI_LOCATOR_PACKAGE.md'
ALLOWED = [WORKFLOW, SELF, DOC]
COUNTS = dict(TXTCoreTests=25, ReaderDomainTests=107, TXTBlockDecoderTests=6,
              ProcessingReuseMeasurementTests=1, YueJingHostTests=13, YueJingUITests=11, YueJingCanvasTests=3)
FAILED = ['testBookmarksAccessibilityCloseAndConfirmedDeletion', 'testBookmarksPersistIsolateAndJumpAfterRelaunch']
TOTALS = dict(passed=161, failed=2, skipped=0, unexecuted=3, unfinished=0, ambiguous=0)
UI_LOG = 'reading-ui-native/YueJingUITests.log'
AX_LIST = 'reading-ui-native/YueJingUITests-attachments/AA3F1983-0C90-483B-8998-0C3CDAADE872.txt'
# The second original attachment has NO filename extension.
AX_NAME = 'reading-ui-native/YueJingUITests-attachments/F952DE2E-E385-4B7F-B5F0-345940CFB29A'
CANDIDATE = 'task3/candidate-sources.json'
PINS = {
    UI_LOG: (244872, '95c1c93df2d59aa7eb71efc22bcbcb4549b8522b717357cc51b4ef2377edde4f'),
    AX_LIST: (19143, 'a3f0ed0a2f33a370c6ffacc88d3f10ea6ccda3001195051730c1454d1ef432e3'),
    AX_NAME: (35479, 'f354d2f29a501586878a7002da6e42e9c36280f5c8175f713a89c3724433b903'),
    CANDIDATE: (31508, 'b4315d26ca105a7dbc998d35fa0695dfc46bdaae76c67ed64371e61389f17100'),
}
require, sha, blob = helper.require, helper.sha, helper.blob


def source_gate(env, state):
    """Pure exact-three source identity gate, independently usable with synthetic state."""
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
    require(len(before) == 215 and len(after) == 217 and
            set(after) == set(before) | {SELF, DOC}, '215 to 217 tracked path set differs')
    require({n for n in after if before.get(n) != after[n]} == set(ALLOWED), 'Exactly two additions and one modification required')
    require({n: v for n, v in before.items() if n != WORKFLOW} ==
            {n: v for n, v in after.items() if n not in ALLOWED}, '214 parent modes/blobs differ')
    require(set(after) == set(state['working']) == set(state['index']), 'Working/index path set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Committed/index/working entry differs: '+n)
    return dict(scope=SCOPE, source_commit=head, parent=BASE, approved_changed_files=ALLOWED,
                tracked_before=215, tracked_after=217, other_entries_equal=214,
                index_and_working_equal_commit=True, production_and_tests_unchanged=True)


def workflow_blocks():
    gate = '''      # BEGIN BOOKMARK UI LOCATOR PACKAGE GATE
      - name: Require the fixed bookmark UI locator evidence and exact three-file package scope
        if: ${{ inputs.package_scope == 'SCOPE' }}
        env:
          PACKAGE_SCOPE: ${{ inputs.package_scope }}
          HOST_VALIDATION_RUN_ID: ${{ inputs.host_validation_run_id }}
          NATIVE_READ_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          python3 -B scripts/check_bookmark_ui_locator_package.py --package-gate
      # END BOOKMARK UI LOCATOR PACKAGE GATE

'''.replace("'SCOPE'", "'"+SCOPE+"'")
    dependency = '''      # BEGIN BOOKMARK UI LOCATOR PACKAGE DEPENDENCY
      - name: Require fixed official GRDB for the bookmark UI locator diagnostic package
        if: ${{ inputs.package_scope == 'SCOPE' }}
        run: |
          set -euo pipefail
          python3 -B scripts/check_bookmark_ui_locator_package.py --fixed-dependency
      # END BOOKMARK UI LOCATOR PACKAGE DEPENDENCY

'''.replace("'SCOPE'", "'"+SCOPE+"'")
    return gate, dependency


def strip_workflow(current):
    """Only these exact scope-only steps/choice/case additions may be removed."""
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
    # This helper checks the explicit supplied source/run, not its old source/scope gate.
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
    # 256MiB compressed, 1GiB expanded, CRC-read EVERY entry; no extraction.
    files = helper.zip_members(raw)
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        names = {i.filename for i in archive.infolist() if not i.is_dir()}
        require(not any(n.lower().endswith('.ipa') or 'YueJingCanvasTests' in n or
                        n in ('task3/native-test-gate.json', 'task3/host-only-scope.json') for n in names),
                'Unexpected Canvas/full gate/Host-only/IPA evidence')
        for n in (AX_LIST, AX_NAME):
            require(archive.getinfo(n).file_size == PINS[n][0], 'Attachment size differs')
            files[n] = archive.read(n)
    return files, names


def native_events(raw, target):
    parsed = audit.parse_events(raw, inventory.expected_names(target), ui=target == 'YueJingUITests')
    require(parsed['parser_complete'], 'Incomplete/unknown/ambiguous native events: '+target)
    wanted = dict(passed=COUNTS[target], failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0)
    if target == 'YueJingUITests':
        wanted.update(passed=9, failed=2)
        require(sorted(c['name'] for c in parsed['cases'] if c['status'] == 'failed') == FAILED, 'UI failure identities differ')
        intervals = sorted((c['starts'][0]['line'], c['finishes'][0]['line']) for c in parsed['cases']) if parsed['totals'] == wanted else []
        require(len(intervals) == 11 and all(a[1] < b[0] for a, b in zip(intervals, intervals[1:])), 'UI events overlap/are unfinished')
    elif target == 'YueJingCanvasTests':
        wanted.update(passed=0, unexecuted=3)
        require(not raw, 'Canvas executed')
    require(parsed['totals'] == wanted, 'Native event totals differ: '+target)
    return parsed


def locator_gate(files):
    for n, (size, digest) in PINS.items():
        pinned_bytes(files[n], size, digest, n)
    log = files[UI_LOG].decode('utf-8').splitlines()
    rows = ((437, 'Tap "reader.bookmarks.add" Button'), (448, 'Swipe up "reader.bookmarks.list" Table'),
            (454, 'ReadingFlowUITests.swift:872: error:'), (454, FAILED[0]),
            (454, 'No matches found for Elements matching predicate'), (464, "' failed (32.854 seconds)."),
            (564, 'Tap "reader.bookmarks.add" Button'), (578, 'Tap "reader.bookmarks.rename.'),
            (584, '"reader.bookmarks.name" TextField'), (593, 'ReadingFlowUITests.swift:882: error:'),
            (593, FAILED[1]), (593, 'XCTAssertEqual failed:'), (601, "' failed (42.104 seconds)."))
    for line, text in rows:
        require(text in log[line-1], 'Original locator error/action order differs: '+str(line))
    require([i for i, line in enumerate(log, 1) if re.search(r'\berror\s*[:=]', line, re.I)] == [454, 593], 'Additional UI error')
    large, normal = files[AX_LIST].decode('utf-8').splitlines(), files[AX_NAME].decode('utf-8').splitlines()
    for line, tokens in ((89, ('CollectionView,', "identifier: 'reader.bookmarks.list'")),
                         (98, ('此位置已有书签', 'Disabled')), (108, ('reader.bookmarks.notice', '书签已保存。')),
                         (121, ('reader.bookmarks.rename.', '{{16.0, 736.0}'))):
        require(all(t in large[line-1] for t in tokens), 'Large-font AX differs')
    require('Alert,' in normal[301] and '重命名书签' in normal[301] and
            all(t in normal[324] for t in ('TextField,', "placeholderValue: '书签名称'", 'Keyboard Focused')) and
            'identifier:' not in normal[324], 'Rename Alert/TextField AX differs')
    return dict(large_font=dict(log_lines=[437, 448, 454, 464], ax_lines=[89, 98, 108, 121],
                               finding='Added bookmark; Table locator does not match CollectionView; rename below viewport'),
                ordinary=dict(log_lines=[564, 578, 584, 593, 601], ax_lines=[302, 325],
                              finding='Rename tapped; Alert contains focused placeholder TextField without requested identifier'),
                qualification='Observed locator failures only; no claim of persistence/jump/deletion completion or physical acceptance')


def execution_gate(selection, execution, target, exit_raw):
    for value in (selection, execution):
        helper.provenance(value, BASE, RUN)
        helper.selection_gate(value, target)
    require(all(execution.get(k) == v for k, v in selection.items()), 'Execution/selection differs')
    expected = 65 if target == 'YueJingUITests' else 0
    require(type(execution['native_exit']) is int and execution['native_exit'] == expected and
            execution['timed_out'] is False and exit_raw.strip() == str(expected).encode(), 'Native exit/timeout differs')


def evidence_gate(files, expected_sources):
    require(inventory.COUNTS == COUNTS and inventory.TOTAL == 166, 'Frozen166 inventory differs')
    def receipt(n):
        value = json.loads(files[n])
        helper.provenance(value, BASE, RUN)
        return value
    locator = locator_gate(files)
    frozen = receipt(CANDIDATE)
    require(len(expected_sources) == 159 and frozen['files'] == expected_sources and
            frozen['inventory'] == inventory.validate_source(), 'Complete parent159 source/inventory differs')
    require(not any('YueJingCanvasTests' in n or n.lower().endswith('.ipa') or
                    n in ('task3/native-test-gate.json', 'task3/host-only-scope.json') for n in files), 'Downstream evidence exists')
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
    require(totals == TOTALS, 'Full166 totals differ')
    return dict(selected=166, totals=totals, failed_cases=FAILED, groups=groups, locator_evidence=locator,
                original_evidence_sha256={n: digest for n, (_, digest) in PINS.items()},
                full_regression_passed=False, native_tests_this_run=0, prior_packaging='not executed')


def validate_evidence(run, jobs, listing, raw, expected_sources=None):
    upstream = upstream_gate(run, jobs)
    files, names = archive_gate(listing, raw)
    # Offline can trust the pinned raw candidate receipt, but cannot assert a cloud commit/index gate.
    if expected_sources is None:
        pinned_bytes(files[CANDIDATE], *PINS[CANDIDATE], CANDIDATE)
        expected_sources = json.loads(files[CANDIDATE])['files']
    upstream.update(evidence_gate(files, expected_sources), artifact_id=ARTIFACT,
                    artifact_sha256=ARCHIVE_SHA, artifact_bytes=ARCHIVE_BYTES)
    return upstream, files, names


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
    # Read-only current source comparison, excluding the approved new files. No Git invocation.
    frozen = json.loads(files[CANDIDATE])['files']
    require(local_candidate_names() == set(frozen) | {SELF}, 'Local complete candidate path set differs')
    for n, digest in frozen.items():
        data = (ROOT/n).read_bytes()
        if n == WORKFLOW and SCOPE.encode() in data:
            data = strip_workflow(data.decode('utf-8')).encode('utf-8')
        require(sha(data) == digest, 'Local parent candidate bytes differ: '+n)
    return dict(passed=True, mode='offline-evidence', source_gate='not evaluated: cloud committed checkout required',
                selected=result['selected'], totals=result['totals'], failed_cases=FAILED,
                parent_candidate_files=159, archive_members=len(names), raw_hashes_verified=PINS,
                full_regression_passed=False, native_executions=0, network_requests=0)


def candidate_path(n):
    return n == 'project.yml' or (n.startswith(('App/', 'Sources/', 'Tests/', 'scripts/', '.github/workflows/')) and
                                Path(n).suffix in ('.swift', '.py', '.yml', '.txt'))


def local_candidate_names():
    return {'project.yml'} | {p.relative_to(ROOT).as_posix()
        for folder in ('App', 'Sources', 'Tests', 'scripts', '.github/workflows')
        for p in (ROOT/folder).rglob('*') if p.is_file() and candidate_path(p.relative_to(ROOT).as_posix())}


def cloud_state(env):
    # Read-only Git is used ONLY by the explicit cloud package-gate mode.
    git, tree = helper.git, helper.tree
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
    require(len(parent_sources) == 159, 'Parent159 candidate set differs')
    receipt.update(files=hashes, parent_candidate_sha256=parent_sources,
                   candidate_sha256={n: h for n, h in hashes.items() if candidate_path(n)})
    return receipt, parent_sources


def status_record(head, receipt, upstream):
    return dict(source_commit=head, app_candidate=BASE, qualification='TESTS NOT RUN', tests_run=False,
                native_tests_this_run=dict(status='not run', executions=0, selection=[]), native_execution=[],
                physical_device_acceptance='not performed', full_regression_passed=False, formal_release=False,
                prior_validation_run=RUN, prior_validation_attempt=1, prior_validation_source_commit=BASE,
                prior_validation_url=upstream['url'], prior_counts=upstream['totals'], prior_failed_cases=FAILED,
                prior_validation_selected=166, prior_validation_passed=161, prior_validation_failed=2,
                prior_validation_unexecuted=3, prior_validation_skipped=0, prior_task3_tests_rerun=False,
                full_test_gate='NOT PASSED: two fixed bookmark UI locator failures; Canvas3 unexecuted',
                original_task3_gate='failure retained; no rerun', approved_changed_files=ALLOWED, package_scope=SCOPE,
                candidate_sha256=receipt['candidate_sha256'], parent_candidate_sha256=receipt['parent_candidate_sha256'],
                bookmark_ui_locator_exact3_gate=receipt,
                purpose='Separately approved diagnostic IPA only; not a fix, full acceptance, or formal release')


def summary(message):
    print('::warning::'+message)
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a', encoding='utf-8') as output:
        output.write('## Bookmark UI locator diagnostic — TESTS NOT RUN\n\n'+message+'\n\n')


def package_gate():
    env = os.environ
    require(env.get('GITHUB_ACTIONS') == 'true', '--package-gate is cloud-only')
    receipt, expected_sources = cloud_state(env)
    token = env.get('NATIVE_READ_TOKEN', '')
    require(token, 'Existing read-only token required; no fallback credentials')
    # Bounded HTTPS GET only; helper strips authorization on signed-blob redirects.
    run = helper.api_read('/actions/runs/'+str(RUN), token)
    jobs = helper.api_read('/actions/runs/'+str(RUN)+'/attempts/1/jobs?per_page=100', token)
    upstream_gate(run, jobs)
    listing = helper.api_read('/actions/runs/'+str(RUN)+'/artifacts?per_page=100', token)
    artifact_metadata(listing)
    raw = helper.api_read('/actions/artifacts/'+str(ARTIFACT)+'/zip', token, binary=True)
    upstream, files, _ = validate_evidence(run, jobs, listing, raw, expected_sources)
    receipt.update(run_id=env['GITHUB_RUN_ID'], run_attempt=1, upstream_full_validation=upstream)
    out = ROOT/'artifacts/task3'
    helper.save(out/'bookmark-ui-locator-exact3-gate.json', receipt)
    helper.save(out/'bookmark-ui-locator-candidate-sources.json', dict(source_commit=env['GITHUB_SHA'],
                parent=BASE, parent_files=expected_sources, files=receipt['candidate_sha256'], tracked_files=receipt['files']))
    for n, value in (('run', run), ('jobs', jobs), ('artifacts', listing)):
        helper.save(out/('bookmark-ui-locator-upstream-'+n+'.json'), value)
    # Preserve only parsed logs/receipts and two original AX attachments, never the ZIP/xcresult.
    for n, data in files.items():
        if n in PINS or (n.startswith(('task3/', 'reading-ui-native/')) and
                         Path(n).name.startswith(tuple(COUNTS)) and
                         (n.endswith('.log') or n.endswith(('-counts.json', '-selection.json', '-execution.json', '-source-hashes.json', '-exit-code.txt')))):
            p = out/'bookmark-ui-locator-prior'/n
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open('xb') as output:
                output.write(data)
    helper.save(ROOT/'artifacts/verification-status.json', status_record(env['GITHUB_SHA'], receipt, upstream))
    summary('Diagnostic eligibility passed, not test acceptance. Current native executions: 0; physical acceptance: not performed; formal release: false. '
            'Fixed parent '+BASE+' / run '+str(RUN)+' attempt1 remains FAILURE: 166 selected, 161 passed, 2 failed, 3 unexecuted; '
            'UI11 finished 9 passed / 2 locator failures, exit65, no timeout; Canvas and upstream packaging never executed.')


def dependency_gate(value):
    require(value['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            value['package']['state'] == dict(revision=helper.common.REVISION, version='7.0.0') and
            value['checkout_revision'] == helper.common.REVISION and value['package_manifest_sha256'] == helper.common.PACKAGE_HASH,
            'Fixed official GRDB7.0.0 revision/manifest differs')


def fixed_dependency():
    require(os.environ.get('GITHUB_ACTIONS') == 'true', '--fixed-dependency is cloud-only')
    value = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    dependency_gate(value)
    status = json.loads((ROOT/'artifacts/verification-status.json').read_bytes())
    require(status['source_commit'] == os.environ['GITHUB_SHA'] and status['app_candidate'] == BASE and
            status['package_scope'] == SCOPE and status['bookmark_ui_locator_exact3_gate']['parent'] == BASE and
            status['qualification'] == 'TESTS NOT RUN' and status['tests_run'] is False and
            status['native_tests_this_run'] == dict(status='not run', executions=0, selection=[]) and
            status['full_regression_passed'] is False and status['formal_release'] is False and
            status['prior_counts'] == TOTALS and status.get('prior_full146_passed') is not True, 'Diagnostic status differs')
    helper.save(ROOT/'artifacts/task3/bookmark-ui-locator-fixed-dependency.json',
                dict(source_commit=os.environ['GITHUB_SHA'], scope=SCOPE, revision=helper.common.REVISION,
                     package_manifest_sha256=helper.common.PACKAGE_HASH, passed=True, qualification='TESTS NOT RUN'))
    summary('Fixed official GRDB7.0.0 dependency receipt verified. This permits only the unchanged public build/package chain; '
            'it is not native test, physical-device, full-regression, or formal-release acceptance.')


def self_check():
    """Synthetic pure-function controls: no network, Git, filesystem writes or native invocations."""
    negatives, positives = [], []
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
    before.update({'frozen/'+str(i): ['100644', 'blob', 'b'*40] for i in range(213)})
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
                        ('duplicate-block', current+gate), ('missing-block', current.replace(gate, ''))]:
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
    for key, value in dict(id=1, head_sha='a'*40, head_branch='other', event='push', run_attempt=2,
                          workflow_id=1, path=WORKFLOW, status='in_progress', conclusion='success',
                          repository=dict(full_name='x/y'), head_repository=dict(full_name='x/y')).items():
        bad('upstream-'+key, lambda k=key, v=value: upstream_gate(dict(run, **{k: v}), jobs))
    for step in steps:
        altered = copy.deepcopy(jobs)
        altered['jobs'][0]['steps'][steps.index(step)]['conclusion'] = 'failure' if step['conclusion'] != 'failure' else 'success'
        bad('step-'+str(step['number']), lambda j=altered: upstream_gate(run, j))
    for target in COUNTS:
        ui = target == 'YueJingUITests'
        lines = []
        for name in inventory.expected_names(target):
            status = 'failed' if name in FAILED else 'passed'
            prefix = "Test Case '-[ReadingFlowUITests "+name+"]' " if ui else 'Test '+name+'() '
            lines += [prefix+'started.', prefix+status+'.']
        raw = ('\n'.join(lines)+'\n').encode() if target != 'YueJingCanvasTests' else b''
        good('events-'+target, lambda r=raw, t=target: native_events(r, t))
        if target == 'YueJingCanvasTests':
            bad('canvas-executed', lambda: native_events(b'noise', 'YueJingCanvasTests'))
            continue
        for label, data in [('extra-failure', raw.replace(b'passed.', b'failed.', 1)),
                            ('unfinished', raw.replace(b'passed.', b'incomplete.', 1)),
                            ('skip', raw.replace(b'passed.', b'skipped.', 1)), ('duplicate', raw+raw), ('missing', b'')]:
            bad(target+'-'+label, lambda r=data, t=target: native_events(r, t))
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
                              expected=1, declared=[], command=['xcodebuild', 'test', '-only-testing:Other']).items():
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
        # ZipInfo normalizes Windows separators when writing; corrupt both raw headers instead.
        raw_zip = buf.getvalue().replace(name.replace('\\', '/').encode(), name.encode())
        bad('zip-path-'+name, lambda r=raw_zip: helper.zip_members(r))
    value = dict(package=dict(location='https://github.com/groue/GRDB.swift.git',
                             state=dict(revision=helper.common.REVISION, version='7.0.0')),
                 checkout_revision=helper.common.REVISION, package_manifest_sha256=helper.common.PACKAGE_HASH)
    good('fixed-GRDB', lambda: dependency_gate(value))
    for key in ('checkout_revision', 'package_manifest_sha256'):
        bad('dependency-'+key, lambda k=key: dependency_gate(dict(value, **{k: 'bad'})))
    for key in ('revision', 'version'):
        altered = copy.deepcopy(value)
        altered['package']['state'][key] = 'bad'
        bad('dependency-'+key, lambda v=altered: dependency_gate(v))
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
    args = parser.parse_args()
    if args.self_check:
        print(json.dumps(self_check(), ensure_ascii=False, indent=2))
    elif args.offline_evidence:
        print(json.dumps(offline_evidence(args.offline_evidence), ensure_ascii=False, indent=2))
    elif args.package_gate:
        package_gate()
    else:
        fixed_dependency()


if __name__ == '__main__':
    main()
