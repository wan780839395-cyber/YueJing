"""Exact-five exit/query repair checks; qualified same-source diagnostic IPA, never test acceptance."""
import argparse
import ast
from collections import Counter
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

import audit_native_case_events as audit
import check_c_dock_failure_repair as prior
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
BASE = '2f962b60c4837ed6d226a518971495699f1c81f8'
SCOPE = 'c-exit-recovery-2f962b6-exact5'
SCREEN = 'App/Reading/ReaderScreen.swift'
UI = prior.UI
DEVICE = prior.DEVICE
ALLOWED = [SCREEN, UI, DEVICE, 'scripts/check_c_exit_recovery.py', 'docs/C_EXIT_RECOVERY.md']
require, fingerprint, git, tree = prior.require, prior.fingerprint, prior.git, prior.tree
sha = lambda data: hashlib.sha256(data).hexdigest()


def source_gate(env, state):
    require(env['PACKAGE_SCOPE'] == SCOPE and env['GITHUB_REPOSITORY'] == prior.REPO, 'Scope/repository differs')
    require(env['GITHUB_RUN_ATTEMPT'] == '1' and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Manual attempt1 only')
    require(env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_WORKFLOW_REF'] == prior.REPO+'/'+DEVICE+'@refs/heads/main', 'Main/workflow differs')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}', head) and head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'], 'Source/workflow SHA differs')
    require(state['parents'] == [head, BASE] and not state['dirty'], 'Unique parent/clean checkout differs')
    before, after = state['before'], state['after']
    require(len(before) == 192 and len(after) == 194 and set(after) == set(before)|set(ALLOWED[3:]), 'Tracked path set differs')
    require({n for n in after if before.get(n) != after[n]} == set(ALLOWED), 'Exactly five paths must change')
    require(set(after) == set(state['working']) == set(state['index']), 'Complete working/index set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Regular committed working/index object differs: '+n)
    run_id = env['HOST_VALIDATION_RUN_ID']
    require(re.fullmatch(r'[1-9][0-9]*', run_id) and run_id != env['GITHUB_RUN_ID'], 'Distinct completed full run required')
    require(state['inputs'] == dict(package_scope=SCOPE, host_validation_run_id=run_id), 'Dispatch inputs differ')
    return dict(source_commit=head, parent=BASE, approved_changed_files=ALLOWED, other_entries_equal=189,
                index_and_working_equal_commit=True)


def zip_members(raw):
    """Read and CRC-check every original member, retain only small logs/JSON/exit receipts."""
    seen, selected = set(), {}
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        for item in z.infolist():
            n = item.orig_filename
            p = PurePosixPath(n)
            key = n.rstrip('/').casefold()
            require(n == item.filename and n and '\\' not in n and '\0' not in n and ':' not in n and
                    not p.is_absolute() and '..' not in p.parts and key not in seen, 'Unsafe/duplicate archive member')
            seen.add(key)
            require(not item.flag_bits & 1 and stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR), 'Special/encrypted archive member')
            body = z.read(item)
            if n.endswith(('.json', '.log', '-exit-code.txt')) and '.xcresult/' not in n and '-attachments/' not in n:
                selected[n] = body
    return selected


def provenance(receipt, head, run_id):
    require(receipt['source_commit'] == head and str(receipt['run_id']) == str(run_id) and
            str(receipt['run_attempt']) == '1', 'Evidence provenance differs')


def ui_failure(raw, execution, export):
    names = inventory.expected_names('YueJingUITests')
    require(execution['target'] == 'YueJingUITests' and execution['scheme'] == 'YueJingUI' and
            execution['configuration'] == 'Debug' and execution['expected'] == 9 and
            execution['declared'] == names and execution['timeout_seconds'] == 900, 'UI execution selection/budget differs')
    result = audit.parse_events(raw, names, ui=True)
    totals = result['totals']
    require(not result['unexpected'] and not result['unknown_test_lines'] and not totals['ambiguous'] and
            not totals['skipped'] and totals['unfinished'] <= 1 and any(c['starts'] for c in result['cases']), 'Unknown/skipped/ambiguous or unstarted UI run')
    # Serial XCTest cannot overlap cases, including the one genuinely unfinished timeout case.
    intervals = sorted((c['starts'][0]['line'], c['finishes'][0]['line'] if c['finishes'] else len(raw.splitlines())+1)
                       for c in result['cases'] if c['starts'])
    require(all(a[1] < b[0] for a, b in zip(intervals, intervals[1:])), 'Overlapping native UI identities')
    text = raw.decode('utf-8')
    require(not re.search(r'\*\* (?:TEST )?BUILD FAILED \*\*|error: emit-module|fatal error:|Testing failed:', text), 'UI compilation/tooling failure is not eligible')
    require(not re.search(r'\bError Domain=|\b(?:lost|failed to establish) connection (?:to|with) (?:the )?(?:test|runner)|'
                          r'\b(?:test runner|testmanagerd|automation (?:session|connection)).{0,100}\b(?:disconnect|invalidat|crash)|'
                          r'Failed to get matching snapshot', text, re.I), 'Structured runner/transport/automation error is not eligible')
    errors = {i: line for i, line in enumerate(text.splitlines(), 1) if re.search(r'\berror\s*[:=]', line, re.I)}
    pattern = re.compile(r'/Tests/YueJingUITests/ReadingFlowUITests\.swift:\d+(?::\d+)?: error: '
                         r'-\[(?:\w+\.)?ReadingFlowUITests (test\w+)\] : (XCT(?:Assert\w*|Fail) failed)(?::.*)?$')
    claimed, reasons = set(), []
    for case in result['cases']:
        if not case['starts']:
            continue
        start = case['starts'][0]['line']
        end = case['finishes'][0]['line'] if case['finishes'] else len(text.splitlines())+1
        rows = [(i, line) for i, line in errors.items() if start < i < end]
        require(case['status'] != 'passed' or not rows, 'Error inside a passed case')
        require(case['status'] != 'failed' or rows, 'Failed case has no sourced assertion')
        for i, line in rows:
            match = pattern.search(line)
            require(match and match[1] == case['name'], 'Unclassified/non-assertion UI error at '+str(i))
            claimed.add(i)
            reasons.append(dict(name=case['name'], line=i, kind=match[2], raw_line_sha256=sha(line.encode())))
    require(claimed == set(errors), 'Unattributed UI error')
    timeout = execution['timed_out'] is True and execution['native_exit'] == -9
    complete = result['parser_complete'] and totals['passed']+totals['failed'] == 9
    assertions = execution['timed_out'] is False and execution['native_exit'] == 65 and complete and totals['failed'] > 0 and '** TEST FAILED **' in text
    attachment = execution['timed_out'] is False and execution['native_exit'] == 0 and complete and totals['passed'] == 9 and export is not None and export['export_exit'] != 0
    require(timeout or assertions or attachment, 'Only verified UI assertions, UI900 timeout or attachment export failure eligible')
    return dict(totals=totals, audit_complete=result['parser_complete'], cases=result['cases'],
                ui_log_sha256=sha(raw), native_exit=execution['native_exit'], timed_out=execution['timed_out'],
                qualification='full regression NOT PASSED', reason='UI_TIMEOUT' if timeout else 'UI_ASSERTIONS' if assertions else 'ATTACHMENT_EXPORT',
                assertion_failures=reasons, export_exit=export['export_exit'] if export else None)


def evidence_gate(files, head, run_id, expected_sources=None):
    def receipt(n):
        r = json.loads(files[n])
        provenance(r, head, run_id)
        return r
    frozen = receipt('task3/candidate-sources.json')
    require(frozen['inventory'] == inventory.validate_source(), 'Frozen full selection differs')
    if expected_sources is not None:
        require(frozen['files'] == expected_sources, 'Cloud candidate source subset differs')
    for target in inventory.COUNTS:
        folder = 'reading-ui-native/' if target in ('YueJingHostTests', 'YueJingUITests') else 'task3/'
        if target in ('YueJingUITests', 'YueJingCanvasTests'):
            continue
        raw = files[folder+target+'.log']
        result = audit.parse_events(raw, inventory.expected_names(target))
        require(result['parser_complete'] and result['totals']['passed'] == inventory.COUNTS[target] and
                all(not v for k, v in result['totals'].items() if k != 'passed'), 'Upstream native cases did not all pass: '+target)
        require(int(files[folder+target+'-exit-code.txt'].strip()) == 0, 'Upstream native exit failed: '+target)
        counts = receipt(folder+target+'-counts.json')
        require(counts['log_sha256'] == sha(raw) and set(counts['passed']) == set(inventory.expected_names(target)), 'Upstream count receipt differs: '+target)
        if target == 'YueJingHostTests':
            execution = receipt(folder+target+'-execution.json')
            require(execution['native_exit'] == 0 and execution['timed_out'] is False and execution['timeout_seconds'] == 480, 'Host execution/budget differs')
    folder = 'reading-ui-native/'
    execution = receipt(folder+'YueJingUITests-execution.json')
    require(int(files[folder+'YueJingUITests-exit-code.txt'].strip()) == execution['native_exit'], 'UI native exit differs')
    export = receipt(folder+'attachment-export.json') if folder+'attachment-export.json' in files else None
    if export:
        require(export['target'] == 'YueJingUITests' and export['native_exit'] == execution['native_exit'], 'Attachment receipt differs')
    for target in ('YueJingHostTests', 'YueJingUITests'):
        r = json.loads(files[folder+target+'-source-hashes.json'])
        require(r['source_commit'] == head and r['files'] and all(frozen['files'].get(n) == h for n, h in r['files'].items()), 'Host/UI source hashes differ')
    return ui_failure(files[folder+'YueJingUITests.log'], execution, export)


def device_repro_gate():
    import validate_task3
    env = os.environ
    after, working, index, hashes = tree('HEAD'), {}, {}, {}
    for n in after:
        p = ROOT/n
        regular = p.is_file() and not any(x.is_symlink() for x in (p, *p.parents))
        data = p.read_bytes() if regular else b''
        working[n] = dict(regular=regular, blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest())
        hashes[n] = sha(data)
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if row:
            meta, n = row.split(b'\t', 1)
            require(n.decode() not in index, 'Unmerged index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse', 'HEAD').decode().strip(), parents=git('rev-list', '--parents', '-n', '1', 'HEAD').decode().split(),
                 dirty=git('status', '--porcelain=v1', '--untracked-files=all'), before=tree(BASE), after=after, working=working, index=index,
                 inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = source_gate(env, state)
    run_id, token = env['HOST_VALIDATION_RUN_ID'], env.get('NATIVE_READ_TOKEN', '')
    require(token, 'Existing token unavailable; no credential fallback')
    run = prior.api_read('/actions/runs/'+run_id, token)
    jobs = prior.api_read('/actions/runs/'+run_id+'/attempts/1/jobs?per_page=100', token)
    upstream = prior.upstream_gate(run, jobs, receipt['source_commit'], run_id)
    listing = prior.api_read('/actions/runs/'+run_id+'/artifacts?per_page=100', token)
    require(listing['total_count'] == len(listing['artifacts']) == 1, 'Unique full evidence artifact required')
    artifact = listing['artifacts'][0]
    require(artifact['name'] == 'task3-evidence-'+run_id+'-'+receipt['source_commit'] and not artifact['expired'], 'Evidence artifact identity differs')
    raw = prior.api_read('/actions/artifacts/'+str(artifact['id'])+'/zip', token, binary=True)
    require(len(raw) == artifact['size_in_bytes'] and artifact['digest'] == 'sha256:'+sha(raw), 'Evidence API size/digest differs')
    upstream.update(evidence_gate(zip_members(raw), receipt['source_commit'], run_id, validate_task3.candidate_files()))
    upstream.update(artifact_id=artifact['id'], artifact_sha256=sha(raw))
    receipt.update(run_id=env['GITHUB_RUN_ID'], run_attempt='1', files=hashes, upstream_full_validation=upstream)
    out = ROOT/'artifacts/task3'
    out.mkdir(parents=True, exist_ok=True)
    (out/'c-exit-recovery-exact5-gate.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    status = dict(source_commit=receipt['source_commit'], purpose='C exit recovery diagnostic reproduction after same-source UI-only failure',
                  qualification='TESTS NOT RUN', tests_run=False, full_regression_passed=False, full_test_gate='NOT PASSED: '+upstream['reason'],
                  approved_changed_files=ALLOWED, app_candidate=receipt['source_commit'], previous_candidate=BASE,
                  native_tests_this_run=dict(status='not run', executions=0, selection=[]), native_execution=[],
                  prior_validation_run=int(run_id), prior_validation_attempt=1, prior_validation_source_commit=receipt['source_commit'],
                  prior_validation_url=upstream['url'], prior_UI_totals=upstream['totals'], original_task3_gate='unchanged; failure retained',
                  physical_device_acceptance='not performed', exact5_gate=receipt)
    (ROOT/'artifacts/verification-status.json').write_text(json.dumps(status, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('::warning::TESTS NOT RUN; full regression NOT PASSED; same-source device reproduction only')
    print(json.dumps(dict(source_commit=receipt['source_commit'], reason=upstream['reason'], totals=upstream['totals'], tracked_files=len(hashes)), indent=2))


def fixed_dependency():
    r = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    require(r['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            r['package']['state'] == dict(revision=prior.REVISION, version='7.0.0') and
            r['checkout_revision'] == prior.REVISION and r['package_manifest_sha256'] == prior.PACKAGE_HASH, 'Fixed official GRDB differs')
    (ROOT/'artifacts/task3/c-exit-recovery-fixed-dependency.json').write_text(json.dumps(dict(
        source_commit=os.environ['GITHUB_SHA'], revision=prior.REVISION, package_manifest_sha256=prior.PACKAGE_HASH, passed=True), indent=2)+'\n', encoding='utf-8')


def contracts(src, old):
    import check_navigation_panel_layout as lexical
    import check_c_only_ui_repair as scanner
    checks = []
    def need(ok, name):
        require(ok, name)
        checks.append(name)
    for n in (SCREEN, UI):
        lexical.check_balanced_delimiters(n, lexical.strip_swift_comments_and_strings(src[n]))
        need(not re.search(r'^(?:PUT|CUT) ', src[n], re.M), 'no-edit-protocol-text:'+n)
    prior.allowed_delta(old[SCREEN], src[SCREEN], {144, 172, 173}, set())
    prior.allowed_delta(old[UI], src[UI], {182, 556, 564, 570, 579, 581, 590, 600, 602, 609, 690}, set())
    checks.append('only-reviewed-Swift-lines')
    s, t = src[SCREEN], src[UI]
    original_content = old[SCREEN].split('        return HStack(spacing: 6) {', 1)[1].split('        .modifier(ReaderToolVisibility', 1)[0]
    current_content = s.split('        HStack(spacing: 6) {', 1)[1].split('        // Keep title/layout', 1)[0]
    need(original_content == current_content, 'title-actions-labels-focus-probe-size-and-layout-byte-identical')
    need('return ZStack {\n            if visible {' in s and 'titleBarContent(metrics: metrics, appearance: appearance)' in s,
         'only-visible-title-control-tree-mounted')
    need('.allowsHitTesting(visible && tools.canInteract).accessibilityHidden(!visible)' in s and
         '.transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -ReaderMotion.hiddenTravel)))' in s and
         '.animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: visible)' in s and
         '.transaction { transaction in transaction.animation = nil }' in s, 'existing-gates-scoped-motion-and-ReduceMotion')
    # Explicit mappings: three absent-tree checks are stronger, one is equivalent, one caches the same frame.
    mapped_lines = old[UI].splitlines(keepends=True)
    for line in (182, 556):
        mapped_lines[line-1] = mapped_lines[line-1].replace('collapse.isHittable', 'collapse.exists')
    mapped_lines[570-1] = mapped_lines[570-1].replace('expand.isHittable', 'expand.exists')
    mapped_lines[602-1] = mapped_lines[602-1].replace('app.buttons["reader.exit"].isHittable', 'exit.exists && exit.isHittable')
    mapped_lines[590-1] = mapped_lines[590-1].replace('button.frame.', 'targetFrame.')
    mapped = ''.join(mapped_lines)
    previous, current = scanner.assertions(mapped), scanner.assertions(t)
    need(previous == current and sum(current.values()) == 97, '97-assertions-preserved-with-explicit-equivalent-or-stronger-mapping')
    marker = '    @MainActor func testOtherAppRoundTripRestoresCentralTapAndWindowUpdates() {'
    end = '    @MainActor private func sceneRoundTripPID'
    need(t[t.index(marker):t.index(end)] == old[UI][old[UI].index(marker):old[UI].index(end)], 'strict-App-return-entire-case-byte-identical')
    for a, b in [('    @MainActor private func exitReader(', '    @MainActor private func showTools('),
                 ('    @MainActor private func showTools(', '    @MainActor private func endMarker(')]:
        need(t[t.index(a):t.index(b)] == old[UI][old[UI].index(a):old[UI].index(b)], 'strict-shared-budget-protocol-byte-identical:'+a.strip())
    h = t[t.index('    @MainActor private func revealDockControl'):t.index('    @MainActor private func viewport')]
    need('app.scrollViews["reader.tools.scroll"]' in h and 'for _ in 0..<3' in h and 'deadline.timeIntervalSinceNow > 0' in h and
         'button.isHittable' in h and 'bounds.contains(CGPoint' in h and 'waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow))' in h,
         'bounded-tool-local-scroll-real-target-readiness-and-center-proof')
    need('viewport(app)' not in h and '.tap()' not in h and 'if expand.exists && expand.isHittable { expand.tap() }' in t and
         'element.exists && element.isHittable' in t, 'short-circuit-missing-targets-without-new-taps')
    need('collapse.exists && !expand.exists' in t and 'openSettings(app, sharedDeadline: dockDeadline)' in t and
         'collapse.tap()' in t, 'real-collapse-reexpand-with-original-shared-ten-seconds')
    need(not any(x in s+t for x in ('XCTSkip', 'withKnownIssue', 'XCTExpectFailure', 'Timer(', 'asyncAfter(', '.zIndex(', 'safeAreaInset(')), 'no-skip-timer-global-geometry-workaround')
    return dict(checks=checks, count=len(checks), old_assertions=97, final_assertions=97)


def ui_gate_self_check():
    names = inventory.expected_names('YueJingUITests')
    def block(name, passed=True):
        return ("Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' started.\n" +
                ('' if passed else '/Tests/YueJingUITests/ReadingFlowUITests.swift:1: error: -[YueJingUITests.ReadingFlowUITests '+name+'] : XCTAssertTrue failed\n') +
                "Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' "+('passed' if passed else 'failed')+" (0.1 seconds).\n")
    execution = dict(target='YueJingUITests', scheme='YueJingUI', configuration='Debug', expected=9, declared=names, timeout_seconds=900, native_exit=65, timed_out=False)
    assertion = ''.join(block(n, i != 0) for i, n in enumerate(names))+'** TEST FAILED **\n'
    timeout = block(names[0])+"Test Case '-[YueJingUITests.ReadingFlowUITests "+names[1]+"]' started.\n"
    timed = {**execution, 'native_exit':-9, 'timed_out':True}
    ui_failure(assertion.encode(), execution, None)
    require(ui_failure(timeout.encode(), timed, None)['totals']['unfinished'] == 1, 'Timeout not retained')
    ui_failure(''.join(block(n) for n in names).encode(), {**execution, 'native_exit':0}, {'export_exit':64})
    variants = {
        'timeout-not-native': (timeout, execution, None),
        'wrong-budget': (timeout, {**timed, 'timeout_seconds':901}, None),
        'wrong-exit': (timeout, {**timed, 'native_exit':65}, None),
        'compiler-error': (timeout+'x.swift:1:1: error: cannot find symbol\n', timed, None),
        'automation-error': (assertion+'xcodebuild: error: automation disconnected\n', execution, None),
        'structured-runner-error': (timeout+'Error Domain=IDETestOperationsObserverErrorDomain Code=1 "Lost connection to test runner"\n', timed, None),
        'uppercase-error': (timeout+'ERROR: test transport failed\n', timed, None),
        'plain-runner-disconnect': (timeout+'Test runner disconnected unexpectedly\n', timed, None),
        'missing-assertion': (assertion.replace(' : XCTAssertTrue failed', ' : snapshot failed'), execution, None),
        'unknown-case': (timeout+"Test Case '-[Other testAlien]' started.\n", timed, None),
        'skipped-case': (assertion.replace("' failed (", "' skipped ("), execution, None),
        'all-pass-no-export-error': (''.join(block(n) for n in names), {**execution, 'native_exit':0}, {'export_exit':0}),
        'unstarted-timeout': ('compile still running\n', timed, None),
        'duplicate-start': (timeout+"Test Case '-[YueJingUITests.ReadingFlowUITests "+names[0]+"]' started.\n", timed, None),
        'wrong-reason-case': (assertion.replace('Tests '+names[0]+'] :', 'Tests '+names[1]+'] :'), execution, None),
        'outside-assertion': (assertion+'/Tests/YueJingUITests/ReadingFlowUITests.swift:1: error: -[YueJingUITests.ReadingFlowUITests '+names[0]+'] : XCTAssertTrue failed\n', execution, None),
    }
    for label, (text, e, export) in variants.items():
        try:
            ui_failure(text.encode(), e, export)
        except ValueError:
            continue
        raise ValueError('Unsafe UI diagnostic accepted: '+label)
    # UIKit cannot hit a nonexistent element: all physically admissible truth-table rows.
    for exists, hit in ((False, False), (True, False), (True, True)):
        require((not hit) == (not (exists and hit)), 'Equivalent absence predicate differs')
        require(exists or not hit, 'Stronger absent-tree assertion does not imply not-hittable')
    return dict(passed=True, positive_controls=3, negative_controls=len(variants), native_executions=0)


def local_check(base):
    import yaml
    require(base.resolve().is_relative_to(ROOT/'artifacts'), 'Baseline outside artifacts')
    state = json.loads((base/'baseline.json').read_bytes())
    require(state['head'] == BASE and state['allowed'] == ALLOWED, 'Baseline scope differs')
    old = {n:(base/'preimage'/n).read_text(encoding='utf-8') for n in ALLOWED[:3]}
    for n in ALLOWED[:3]:
        require(fingerprint(base/'preimage'/n) == state['preimage'][n], 'Preimage differs: '+n)
    src = {n:(ROOT/n).read_text(encoding='utf-8') for n in ALLOWED[:3]}
    result = contracts(src, old)
    before, after = (yaml.load(x[DEVICE], Loader=yaml.BaseLoader) for x in (old, src))
    normalized = copy.deepcopy(after)
    normalized['on']['workflow_dispatch']['inputs']['package_scope']['options'].remove(SCOPE)
    steps = normalized['jobs']['build']['steps']
    extra = [s for s in steps if s.get('if') == "${{ inputs.package_scope == '"+SCOPE+"' }}"]
    require(len(extra) == 2 and [s['run'].splitlines()[-1] for s in extra] ==
            ['python3 -B scripts/check_c_exit_recovery.py --device-repro-gate', 'python3 -B scripts/check_c_exit_recovery.py --fixed-dependency'], 'Exactly two fixed scope steps required')
    normalized['jobs']['build']['steps'] = [s for s in steps if s not in extra]
    normalized['jobs']['build']['steps'][0]['run'] = normalized['jobs']['build']['steps'][0]['run'].replace('|'+SCOPE, '')
    require(normalized == before, 'Original workflow properties/steps/conditions changed')
    python_blocks = 0
    for step in after['jobs']['build']['steps']:
        for body in re.findall(r"python3(?: -B)? - <<'PY'\n(.*?)\nPY", step.get('run', ''), re.S):
            ast.parse(body)
            python_blocks += 1
    reviewed = inventory.validate_source()
    require(reviewed['selected'] == 146 and reviewed['all_declared'] == 147, 'Inventory changed')
    require(git('rev-parse', 'HEAD').decode().strip() == BASE and fingerprint(ROOT/'.git/index') == state['index'], 'HEAD/index drift')
    require(not git('diff', '--cached', '--name-only') and not git('diff', '--check'), 'Staging/whitespace differs')
    require(set(git('diff', '--name-only').decode().splitlines()) == set(ALLOWED[:3]), 'Tracked changed paths differ')
    require(set(git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0'))-{''} ==
            set(ALLOWED[3:])|{'.architect_memory.json', 'PROJECT_STATE.md', 'ask_architect.py'}, 'Untracked paths differ')
    protected = json.loads((base/'protection-baseline.json').read_bytes())
    drift = [n for n, v in protected.items() if not Path(n).is_file() or fingerprint(Path(n)) != v]
    require(not drift, 'Protected byte drift: '+repr(drift))
    return dict(passed=True, **result, ui_gate=ui_gate_self_check(), python_blocks=python_blocks, inventory=reviewed,
                protected=len(protected), drift=[], candidate={n:fingerprint(ROOT/n) for n in ALLOWED},
                native_executions=0, network_requests=0, FPS_measured=False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline', type=Path)
    p.add_argument('--device-repro-gate', action='store_true')
    p.add_argument('--fixed-dependency', action='store_true')
    a = p.parse_args()
    require(sum((bool(a.baseline), a.device_repro_gate, a.fixed_dependency)) == 1, 'Choose one explicit mode')
    if a.device_repro_gate:
        device_repro_gate()
    elif a.fixed_dependency:
        fixed_dependency()
    else:
        print(json.dumps(local_check(a.baseline), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
