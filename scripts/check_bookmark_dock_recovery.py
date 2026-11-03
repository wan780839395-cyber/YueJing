"""Exact-eight bookmark dock recovery: local contracts and independent UI-only diagnostic gate.
No native tests are launched. Default mode is offline; network reads require --device-repro-gate.
"""
import argparse
import ast
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import audit_native_case_events as audit
import check_c_dock_failure_repair as common
import check_c_only_ui_repair as scanner
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
BASE = 'da2f05aa6816cad1a600c687133fffc626de0e0e'
SCOPE = 'bookmark-dock-da2f05a-exact8'
OLD_RUN = '41639270133'
UI = 'Tests/YueJingUITests/ReadingFlowUITests.swift'
RUNNER = 'scripts/run_reading_ui_tests.py'
AGGREGATE = 'scripts/check_task3_validation.py'
TASK3 = '.github/workflows/task3-validate.yml'
DEVICE = '.github/workflows/ios-build.yml'
SELF = 'scripts/check_bookmark_dock_recovery.py'
DOC = 'docs/BOOKMARK_DOCK_RECOVERY.md'
LAUNCH = 'scripts/check_reading_launch_diagnostics.py'
ALLOWED = [UI, RUNNER, AGGREGATE, TASK3, DEVICE, LAUNCH, SELF, DOC]
COUNTS = dict(TXTCoreTests=25, ReaderDomainTests=107, TXTBlockDecoderTests=6,
              ProcessingReuseMeasurementTests=1, YueJingHostTests=13, YueJingUITests=11, YueJingCanvasTests=3)
require, git, tree = common.require, common.git, common.tree
sha = lambda data: hashlib.sha256(data).hexdigest()
MAX_ARCHIVE = 256 * 1024 * 1024


def source_gate(env, state):
    require(env['PACKAGE_SCOPE'] == SCOPE and env['GITHUB_REPOSITORY'] == common.REPO, 'Scope/repository differs')
    require(env['GITHUB_RUN_ATTEMPT'] == '1' and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Manual attempt1 only')
    require(env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_WORKFLOW_REF'] == common.REPO+'/'+DEVICE+'@refs/heads/main', 'Main/workflow differs')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}', head) and head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'], 'Source/workflow SHA differs')
    require(state['parents'] == [head, BASE] and not state['dirty'], 'Unique parent/clean checkout differs')
    before, after = state['before'], state['after']
    require(len(before) == 213 and len(after) == 215 and set(after) == set(before)|{SELF, DOC}, 'Tracked path set differs')
    require({n for n in after if before.get(n) != after[n]} == set(ALLOWED), 'Exactly eight paths must change')
    require(set(after) == set(state['working']) == set(state['index']), 'Complete working/index set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Regular committed working/index object differs: '+n)
    run_id = env['HOST_VALIDATION_RUN_ID']
    require(re.fullmatch(r'[1-9][0-9]*', run_id) and run_id not in (OLD_RUN, env['GITHUB_RUN_ID']), 'Distinct NEW completed full run required')
    require(state['inputs'] == dict(package_scope=SCOPE, host_validation_run_id=run_id), 'Dispatch inputs differ')
    return dict(source_commit=head, parent=BASE, approved_changed_files=ALLOWED,
                other_entries_equal=207, index_and_working_equal_commit=True)


def upstream_gate(run, jobs, head, run_id):
    require(str(run_id) != OLD_RUN, 'Old failed run is not eligible')
    require(all(run.get(k) == v for k, v in dict(id=int(run_id), head_sha=head, head_branch='main',
        event='workflow_dispatch', run_attempt=1, workflow_id=398234793, path=TASK3,
        status='completed', conclusion='failure').items()), 'Same-source completed failed full attempt1 required')
    require(run['repository']['full_name'] == common.REPO and run['head_repository']['full_name'] == common.REPO,
            'Upstream repository differs')
    require(jobs['total_count'] == len(jobs['jobs']) == 1, 'Unique full job required')
    job = jobs['jobs'][0]
    require(job['run_id'] == int(run_id) and job['run_attempt'] == 1 and job['head_sha'] == head and
            job['status'] == 'completed' and job['conclusion'] == 'failure' and job['name'] == 'validate', 'Upstream job differs')
    steps = {s['number']: s for s in job['steps']}
    require(len(steps) == len(job['steps']), 'Duplicate step number')
    names = re.findall(r'^      - name: (.+)$', (ROOT/TASK3).read_text(encoding='utf-8'), re.M)
    require(len(names) == 21 and names[12] == 'Run the 13 real App-host UIKit tests once' and
            names[14] == 'Run 11 real App UI flows including 2 bookmark flows', 'Current workflow identities differ')
    # Actions adds Set up job at number1. Full execution is distinguished from Host-only by
    # all four data steps succeeding and both Host-only steps being skipped.
    for number, name in enumerate(names, 2):
        require(steps[number]['name'] == name and steps[number]['status'] == 'completed', 'Step identity/status differs: '+str(number))
        expected = ('failure' if number == 16 else 'skipped' if number in (13, 15, 17, 18, 19, 20, 22) else 'success')
        require(steps[number]['conclusion'] == expected, 'Non-UI failure or wrong full selection: '+str(number))
    require([s['number'] for s in job['steps'] if s['conclusion'] == 'failure'] == [16] and
            all(s['conclusion'] in ('success', 'skipped', 'failure') for s in job['steps']), 'Additional failure/cancellation')
    return dict(run_id=int(run_id), attempt=1, source_commit=head, conclusion='failure', failed_step=16,
                selection='full', url=run['html_url'])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_read(suffix, token, binary=False):
    """Bounded GET; 600-second artifact allowance, never forward credentials to CDN."""
    require(suffix.startswith('/actions/'), 'Unexpected API route')
    opener = urllib.request.build_opener(NoRedirect)
    headers = {'Authorization': 'Bearer '+token, 'Accept': 'application/vnd.github+json',
               'User-Agent': 'YueJing-bookmark-dock-gate'}
    url = 'https://api.github.com/repos/'+common.REPO+suffix
    limit = MAX_ARCHIVE if binary else 8*1024*1024
    for hop in range(4):
        try:
            with opener.open(urllib.request.Request(url, headers=headers), timeout=600 if binary else 120) as response:
                raw = response.read(limit+1)
            require(len(raw) <= limit, 'API body exceeds bounded limit')
            return raw if binary else json.loads(raw)
        except urllib.error.HTTPError as error:
            if not binary or error.code not in (301, 302, 303, 307, 308):
                raise
            location = error.headers.get('Location', '')
            parsed = urllib.parse.urlparse(location)
            require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password and
                    parsed.port in (None, 443) and parsed.hostname.endswith(('.blob.core.windows.net', '.githubusercontent.com')),
                    'Unsafe artifact redirect')
            url, headers = location, {'User-Agent': 'YueJing-bookmark-dock-gate'}
    raise ValueError('Too many artifact redirects')


def zip_members(raw):
    """CRC-read ALL members without extraction, with bounded compressed/expanded/retained sizes."""
    require(len(raw) <= MAX_ARCHIVE, 'Archive too large')
    seen, files, expanded, retained = set(), {}, 0, 0
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        require(len(archive.infolist()) <= 20000, 'Too many ZIP members')
        for item in archive.infolist():
            n, p = item.orig_filename, PurePosixPath(item.orig_filename)
            key = n.rstrip('/').casefold()
            require(n == item.filename and n and '\0' not in n and '\\' not in n and ':' not in n and
                    not p.is_absolute() and '..' not in p.parts and p.as_posix() == n.rstrip('/') and key not in seen,
                    'Unsafe/duplicate ZIP path')
            seen.add(key)
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(not item.flag_bits & 1 and kind in (0, stat.S_IFREG, stat.S_IFDIR) and
                    ((item.is_dir() and kind in (0, stat.S_IFDIR)) or (not item.is_dir() and kind in (0, stat.S_IFREG))),
                    'Encrypted/special ZIP member')
            expanded += item.file_size
            require(expanded <= 1024*1024*1024 and item.file_size <= MAX_ARCHIVE, 'Expanded ZIP limit')
            keep = not item.is_dir() and '.xcresult/' not in n and '-attachments/' not in n and n.endswith(('.json', '.log', '-exit-code.txt'))
            if keep:
                retained += item.file_size
                require(item.file_size <= 64*1024*1024 and retained <= 128*1024*1024, 'Retained evidence limit')
            chunks, size = [], 0
            with archive.open(item) as stream:
                while True:
                    block = stream.read(1024*1024)
                    if not block:
                        break
                    size += len(block)
                    require(size <= item.file_size, 'Expanded member size differs')
                    if keep:
                        chunks.append(block)
            require(size == item.file_size, 'Member size differs')
            if keep:
                files[n] = b''.join(chunks)
    return files


def artifact_gate(artifact, raw, head, run_id):
    require(type(artifact['id']) is int and artifact['id'] > 0 and artifact['name'] == 'task3-evidence-'+str(run_id)+'-'+head and
            artifact['expired'] is False and artifact['workflow_run']['id'] == int(run_id) and
            artifact['workflow_run']['head_sha'] == head and artifact['workflow_run']['head_branch'] == 'main', 'Artifact identity differs')
    require(0 < artifact['size_in_bytes'] <= MAX_ARCHIVE and len(raw) == artifact['size_in_bytes'] and
            artifact['digest'] == 'sha256:'+sha(raw), 'API artifact size/digest differs')
    return zip_members(raw)


def provenance(receipt, head, run_id):
    require(receipt['source_commit'] == head and str(receipt['run_id']) == str(run_id) and
            str(receipt['run_attempt']) == '1', 'Evidence provenance differs')


def selection_gate(record, target):
    require(record['target'] == target and record['scheme'] == 'YueJingUI' and record['configuration'] == 'Debug' and
            record['expected'] == COUNTS[target] and record['declared'] == inventory.expected_names(target) and
            record['timeout_seconds'] == (480 if target == 'YueJingHostTests' else 1200), 'App selection/budget differs')
    args = record['command']
    require(isinstance(args, list) and args[:2] == ['xcodebuild', 'test'] and
            [a for a in args if a.startswith(('-only-testing', '-skip-testing'))] == ['-only-testing:'+target], 'App command filtering differs')
    for flag, value in (('-scheme', 'YueJingUI'), ('-configuration', 'Debug'), ('-parallel-testing-enabled', 'NO'),
                        ('-test-timeouts-enabled', 'YES'), ('-default-test-execution-time-allowance', '180'),
                        ('-maximum-test-execution-time-allowance', '180')):
        require(args.count(flag) == 1 and args[args.index(flag)+1] == value, 'App command option differs: '+flag)
    require(not any(a.startswith(('-retry-tests', '-test-iterations', '-run-tests-until-failure')) for a in args), 'Native retries forbidden')


def ui_failure(raw, execution, export):
    selection_gate(execution, 'YueJingUITests')
    result = audit.parse_events(raw, inventory.expected_names('YueJingUITests'), ui=True)
    totals = result['totals']
    require(not result['unexpected'] and not result['unknown_test_lines'] and not totals['ambiguous'] and
            not totals['skipped'] and totals['unfinished'] <= 1 and any(c['starts'] for c in result['cases']), 'Unknown/skipped/ambiguous/unstarted UI run')
    intervals = sorted((c['starts'][0]['line'], c['finishes'][0]['line'] if c['finishes'] else len(raw.splitlines())+1)
                       for c in result['cases'] if c['starts'])
    require(all(a[1] < b[0] for a, b in zip(intervals, intervals[1:])), 'Overlapping UI cases')
    text = raw.decode('utf-8')
    require(not re.search(r'\bTest \w+\(\) (?:started|passed|failed|skipped)\b', text), 'Unexpected Swift Testing execution in UI selection')
    require(not re.search(r'\*\* (?:TEST )?BUILD FAILED \*\*|error: emit-module|fatal error:|Testing failed:', text), 'UI build/tool failure')
    require(not re.search(r'\bError Domain=|\b(?:lost|failed to establish) connection (?:to|with) (?:the )?(?:test|runner)|'
                          r'\b(?:test runner|testmanagerd|automation (?:session|connection)).{0,100}\b(?:disconnect|invalidat|crash)|'
                          r'Failed to get matching snapshot|Failed to establish communication|Early unexpected exit|'
                          r'Test runner exited|Restarting after unexpected', text, re.I), 'UI transport/runner failure')
    errors = {i: line for i, line in enumerate(text.splitlines(), 1) if re.search(r'\berror\s*[:=]', line, re.I)}
    pattern = re.compile(r'/Tests/YueJingUITests/ReadingFlowUITests\.swift:(\d+)(?::\d+)?: error: '
                         r'-\[(?:\w+\.)?ReadingFlowUITests (test\w+)\] : (XCT(?:Assert\w*|Fail) failed)(?::.*)?$')
    source_lines = (ROOT/UI).read_text(encoding='utf-8').splitlines()
    claimed, reasons = set(), []
    for case in result['cases']:
        if not case['starts']:
            continue
        start = case['starts'][0]['line']
        end = case['finishes'][0]['line'] if case['finishes'] else len(text.splitlines())+1
        rows = [(i, line) for i, line in errors.items() if start < i < end]
        require(case['status'] != 'passed' or not rows, 'Error inside passed UI case')
        require(case['status'] != 'failed' or rows, 'Failed case without sourced assertion')
        for i, line in rows:
            match = pattern.search(line)
            require(match and match[2] == case['name'], 'Unclassified/misattributed UI error: '+str(i))
            source_line = int(match[1])
            require(1 <= source_line <= len(source_lines) and re.search(r'\bXCT(?:Assert\w*|Fail)\s*\(', source_lines[source_line-1]), 'Assertion source line differs')
            claimed.add(i)
            reasons.append(dict(name=case['name'], line=i, source_line=source_line, kind=match[3], raw_line_sha256=sha(line.encode())))
    require(claimed == set(errors), 'Unattributed UI error')
    timeout = execution['timed_out'] is True and execution['native_exit'] == -9
    complete = result['parser_complete'] and totals['passed']+totals['failed'] == 11
    assertions = execution['timed_out'] is False and execution['native_exit'] == 65 and complete and totals['failed'] > 0 and '** TEST FAILED **' in text
    attachment = execution['timed_out'] is False and execution['native_exit'] == 0 and complete and totals['passed'] == 11 and export is not None and export['export_exit'] != 0
    require(timeout or assertions or attachment, 'Only sourced assertions, native1200 timeout or attachment export failure eligible')
    return dict(totals=totals, audit_complete=result['parser_complete'], cases=result['cases'],
                ui_log_sha256=sha(raw), native_exit=execution['native_exit'], timed_out=execution['timed_out'],
                qualification='full regression NOT PASSED', reason='UI_TIMEOUT' if timeout else 'UI_ASSERTIONS' if assertions else 'ATTACHMENT_EXPORT',
                assertion_failures=reasons, export_exit=export['export_exit'] if export else None)


def app_source_subset(expected_sources):
    return {n: h for n, h in expected_sources.items() if n == 'project.yml' or
            (n.startswith('App/') and n.endswith('.swift')) or
            (n.startswith(('Tests/YueJingHostTests/', 'Tests/YueJingUITests/')) and n.endswith('.swift') and len(PurePosixPath(n).parts) == 3)}


def evidence_gate(files, head, run_id, expected_sources):
    require(inventory.COUNTS == COUNTS and inventory.TOTAL == 166, 'Frozen166 counts differ')
    def receipt(n):
        value = json.loads(files[n])
        provenance(value, head, run_id)
        return value
    frozen = receipt('task3/candidate-sources.json')
    require(frozen['files'] == expected_sources and frozen['inventory'] == inventory.validate_source(), 'Candidate source/hash map/inventory differs')
    require('task3/host-only-scope.json' not in files, 'Host-only execution is ineligible')
    groups = []
    for target in COUNTS:
        if target in ('YueJingUITests', 'YueJingCanvasTests'):
            continue
        folder = 'reading-ui-native/' if target == 'YueJingHostTests' else 'task3/'
        raw = files[folder+target+'.log']
        parsed = audit.parse_events(raw, inventory.expected_names(target))
        require(parsed['parser_complete'] and parsed['totals']['passed'] == COUNTS[target] and
                all(not v for k, v in parsed['totals'].items() if k != 'passed'), 'Upstream native cases not all passed: '+target)
        require(files[folder+target+'-exit-code.txt'].strip() == b'0', 'Upstream native exit failed: '+target)
        counts = receipt(folder+target+'-counts.json')
        require(counts['expected'] == COUNTS[target] and counts['log_sha256'] == sha(raw) and
                len(counts['passed']) == COUNTS[target] and set(counts['passed']) == set(inventory.expected_names(target)), 'Upstream count receipt differs: '+target)
        if target != 'YueJingHostTests':
            require(counts['inventory_sha256'] == sha((ROOT/'scripts/task3_test_inventory.py').read_bytes()) and
                    counts['selection'] == inventory.selection(target) and
                    counts['source_files'] == ['Tests/'+p for p in sorted(inventory.FILES) if inventory.group_for(p) == target], 'Data selection differs')
            native_counts = inventory.parse_swift_log(target, raw.decode('utf-8'), 0)
        else:
            from run_reading_ui_tests import count_log
            native_counts = count_log(target, raw.decode('utf-8'), 0)
        require(all(counts.get(k) == json.loads(json.dumps(v)) for k, v in native_counts.items()), 'Raw/native count schema differs: '+target)
        groups.append(dict(target=target, **parsed))
    folder = 'reading-ui-native/'
    executions = {}
    for target in ('YueJingHostTests', 'YueJingUITests'):
        selection = receipt(folder+target+'-selection.json')
        execution = receipt(folder+target+'-execution.json')
        selection_gate(selection, target)
        selection_gate(execution, target)
        require(all(execution.get(k) == v for k, v in selection.items()), 'Execution/selection differs')
        require(type(execution['native_exit']) is int and type(execution['timed_out']) is bool and
                int(files[folder+target+'-exit-code.txt'].strip()) == execution['native_exit'], 'Native exit receipt differs')
        src = json.loads(files[folder+target+'-source-hashes.json'])
        require(src['source_commit'] == head and src['files'] == app_source_subset(expected_sources), 'Complete Host/UI source subset differs')
        if target == 'YueJingHostTests':
            require(execution['native_exit'] == 0 and execution['timed_out'] is False, 'Host execution failed')
            counts = receipt(folder+target+'-counts.json')
            require(all(counts.get(k) == v for k, v in selection.items()) and counts['native_exit'] == 0, 'Host counts selection differs')
        executions[target] = execution
    execution = executions['YueJingUITests']
    export = receipt(folder+'attachment-export.json') if folder+'attachment-export.json' in files else None
    if export:
        require(all(export.get(k) == v for k, v in execution.items() if k not in ('command', 'timed_out')) and
                type(export['export_exit']) is int and type(export['timed_out']) is bool, 'Attachment provenance/native exit differs')
        command = export['command']
        require(len(command) == 8 and command[:5] == ['xcrun', 'xcresulttool', 'export', 'attachments', '--path'] and
                command[6] == '--output-path' and PurePosixPath(command[5]).name == 'YueJingUITests.xcresult' and
                PurePosixPath(command[7]).name == 'YueJingUITests-attachments', 'Only attachment export failure eligible')
        require(folder+'attachment-export.log' in files and (export['export_exit'] == 0 or files[folder+'attachment-export.log']), 'Original export log missing')
        help_receipt = json.loads(files[folder+'attachment-export-help.json'])
        require(help_receipt == dict(command=['xcrun', 'xcresulttool', 'export', 'attachments', '--help'], exit=0, timed_out=False) and
                all(flag in files[folder+'attachment-export-help.log'] for flag in (b'--path', b'--output-path')), 'Export tool unavailable')
    result = ui_failure(files[folder+'YueJingUITests.log'], execution, export)
    # UI failed before Canvas/full union/device; never manufacture the missing three passes.
    require(not any(n.startswith('task3/YueJingCanvasTests') or n == 'task3/native-test-gate.json' for n in files), 'Unexpected downstream execution/gate')
    canvas = audit.parse_events(b'', inventory.expected_names('YueJingCanvasTests'))
    result.update(upstream_groups=groups, canvas=canvas, full_regression_passed=False)
    return result


def blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()


def local_contracts():
    """Text/blob contracts only: not Swift compilation, hit testing or native acceptance."""
    before = tree(BASE)
    require(len(before) == 213, 'Base tracked count differs')
    frozen = [n for n in before if n.startswith(('App/', 'Sources/', 'Tests/')) and n != UI]
    actual = {p.relative_to(ROOT).as_posix() for folder in ('App', 'Sources', 'Tests') for p in (ROOT/folder).rglob('*') if p.is_file()}
    require(actual == {n for n in before if n.startswith(('App/', 'Sources/', 'Tests/'))}, 'Product/test path set changed')
    for n in frozen:
        require(not (ROOT/n).is_symlink() and blob((ROOT/n).read_bytes()) == before[n][2], 'Frozen product/test bytes differ: '+n)
    old = {n: git('show', BASE+':'+n).decode('utf-8') for n in ALLOWED[:6]}
    now = {n: (ROOT/n).read_text(encoding='utf-8') for n in ALLOWED[:6]}
    start = '    @MainActor private func showTools('
    new_start = '    @MainActor private func hasVisibleDockControl('
    end = '    @MainActor private func endMarker('
    require(now[UI].split(new_start)[0] == old[UI].split(start)[0] and
            now[UI].split(end)[1] == old[UI].split(end)[1], 'All test bodies and other helpers must stay byte-identical')
    require(scanner.assertions(now[UI]) == scanner.assertions(old[UI]), 'Assertions changed')
    helper = now[UI].split(new_start)[1].split(start)[0]
    expected_helper = '''_ app: XCUIApplication) -> Bool {
        let screen = app.windows.firstMatch.frame
        guard !screen.isNull, screen.width > 0, screen.height > 0 else { return false }
        let scroll = app.scrollViews["reader.tools.scroll"]
        let trayBounds = scroll.exists ? scroll.frame.intersection(screen) : screen
        for identifier in ["reader.tools.expand", "reader.tools.directory", "reader.tools.settings", "reader.tools.collapse"] {
            let button = app.buttons[identifier]
            guard button.exists, button.isHittable else { continue }
            let frame = button.frame
            let bounds = identifier == "reader.tools.expand" ? screen : trayBounds
            if !frame.isNull, frame.width > 0, frame.height > 0,
               !bounds.isNull, bounds.width > 0, bounds.height > 0,
               bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) { return true }
        }
        return false
    }

'''
    require(helper == expected_helper, 'Visible dock predicate must prove actual center/hittability')
    previous = old[UI].split(start)[1].split(end)[0]
    previous = previous.replace('        let expand = app.buttons["reader.tools.expand"], collapse = app.buttons["reader.tools.collapse"]\n', '')
    previous = previous.replace('!((expand.exists && expand.isHittable) || (collapse.exists && collapse.isHittable))', '!self.hasVisibleDockControl(app)')
    previous = previous.replace('(expand.exists && expand.isHittable) || (collapse.exists && collapse.isHittable)', 'self.hasVisibleDockControl(app)')
    previous = previous.replace('waitHittable(app.buttons["reader.tools.settings"], timeout: max(0, deadline.timeIntervalSinceNow))',
                                'revealDockControl(app.buttons["reader.tools.settings"], app, deadline: deadline)')
    require(now[UI].split(start)[1].split(end)[0] == previous, 'Only approved showTools readiness changes allowed')
    require(now[RUNNER] == old[RUNNER].replace('480 if target == "YueJingHostTests" else 900', '480 if target == "YueJingHostTests" else 1200'), 'Only aggregate UI budget may change')
    require(now[TASK3] == old[TASK3].replace('timeout-minutes: 18', 'timeout-minutes: 23') and
            re.findall(r'timeout-minutes: (\d+)', now[TASK3]) == ['60', '12', '23'], 'Task3 timeout contract differs')
    require('480 if target == "YueJingHostTests" else 1200' in now[AGGREGATE] and
            '["60", "12", "23"]' in now[AGGREGATE] and '180' in now[AGGREGATE], 'Aggregate checker must retain case180 and new outer budgets')
    # Supplemental approval permits precisely the existing line466 budget assertion/label.
    launch_old = old[LAUNCH].splitlines(keepends=True)
    launch_line = '''        check('timeout_seconds = 480 if target == "YueJingHostTests" else 900' in text, "host-480-ui-900-budgets-preserved")\n'''
    require(launch_old[465] == launch_line, 'Frozen launch self-check line466 differs')
    launch_old[465] = launch_line.replace('else 900', 'else 1200').replace('host-480-ui-900-budgets-preserved', 'host-480-ui-1200-approved-budgets')
    require((ROOT/LAUNCH).read_bytes() == ''.join(launch_old).encode('utf-8'), 'Only approved launch self-check line466 may change')
    device = now[DEVICE]
    device = device.replace('          - '+SCOPE+'\n', '').replace('|'+SCOPE+') ;;', ') ;;')
    device = re.sub(r'      - name: Require exact eight-path bookmark dock recovery and same-source full UI-only failure\n.*?(?=      - name:)', '', device, flags=re.S)
    device = re.sub(r'      - name: Require fixed official GRDB for the bookmark dock diagnostic package\n.*?(?=      - name:)', '', device, flags=re.S)
    require(device == old[DEVICE], 'Legacy scopes/common build/package changed')
    require(now[DEVICE].index('--device-repro-gate', now[DEVICE].index('Require exact eight-path')) < now[DEVICE].index('      - name: Verify the selected native toolchain'), 'Source/evidence gate must precede toolchain')
    require(inventory.COUNTS == COUNTS and inventory.validate_source()['selected'] == 166, 'Reviewed166 inventory differs')
    for n in (SELF, RUNNER, AGGREGATE, LAUNCH):
        ast.parse((ROOT/n).read_text(encoding='utf-8'), filename=n)
    return dict(passed=True, frozen_product_and_test_files=len(frozen), test_bodies_and_assertions_unchanged=True,
                native_executions=0, limits=dict(host=480, ui=1200, case=180, show_tools=20, body_taps=2))


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8') as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write('\n')


def device_repro_gate():
    import validate_task3
    env = os.environ
    after, working, index, hashes = tree('HEAD'), {}, {}, {}
    for n in after:
        path = ROOT/n
        regular = path.is_file() and not any(p.is_symlink() for p in (path, *path.parents))
        data = path.read_bytes() if regular else b''
        working[n], hashes[n] = dict(regular=regular, blob=blob(data)), sha(data)
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if row:
            meta, n = row.split(b'\t', 1)
            require(n.decode() not in index, 'Unmerged index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse', 'HEAD').decode().strip(), parents=git('rev-list', '--parents', '-n', '1', 'HEAD').decode().split(),
                 dirty=git('status', '--porcelain=v1', '--untracked-files=all'), before=tree(BASE), after=after, working=working, index=index,
                 inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = source_gate(env, state)
    receipt['local_contracts'] = local_contracts()
    run_id, token = env['HOST_VALIDATION_RUN_ID'], env.get('NATIVE_READ_TOKEN', '')
    require(token, 'Existing read token unavailable; no credential fallback')
    run = api_read('/actions/runs/'+run_id, token)
    jobs = api_read('/actions/runs/'+run_id+'/attempts/1/jobs?per_page=100', token)
    upstream = upstream_gate(run, jobs, receipt['source_commit'], run_id)
    listing = api_read('/actions/runs/'+run_id+'/artifacts?per_page=100', token)
    require(listing['total_count'] == len(listing['artifacts']) == 1, 'Unique full evidence artifact required')
    artifact = listing['artifacts'][0]
    require(type(artifact['id']) is int and 0 < artifact['size_in_bytes'] <= MAX_ARCHIVE, 'Artifact API metadata invalid')
    raw = api_read('/actions/artifacts/'+str(artifact['id'])+'/zip', token, binary=True)
    files = artifact_gate(artifact, raw, receipt['source_commit'], run_id)
    upstream.update(evidence_gate(files, receipt['source_commit'], run_id, validate_task3.candidate_files()))
    upstream.update(artifact_id=artifact['id'], artifact_sha256=sha(raw), artifact_bytes=len(raw))
    receipt.update(run_id=env['GITHUB_RUN_ID'], run_attempt='1', files=hashes, upstream_full_validation=upstream)
    status = dict(source_commit=receipt['source_commit'], purpose='Bookmark dock same-source UI-only failure diagnostic reproduction',
                  qualification='TESTS NOT RUN', tests_run=False, full_regression_passed=False,
                  full_test_gate='NOT PASSED: '+upstream['reason'], approved_changed_files=ALLOWED,
                  native_tests_this_run=dict(status='not run', executions=0, selection=[]), native_execution=[],
                  prior_validation_run=int(run_id), prior_validation_attempt=1, prior_validation_source_commit=receipt['source_commit'],
                  prior_validation_url=upstream['url'], prior_UI_totals=upstream['totals'], original_task3_gate='failure retained; no rerun',
                  physical_device_acceptance='not performed', exact8_gate=receipt)
    save(ROOT/'artifacts/task3/bookmark-dock-exact8-gate.json', receipt)
    save(ROOT/'artifacts/verification-status.json', status)
    print('::warning::TESTS NOT RUN; full regression NOT PASSED; same-source diagnostic IPA only')
    print(json.dumps(dict(source_commit=receipt['source_commit'], reason=upstream['reason'], totals=upstream['totals']), indent=2))


def fixed_dependency():
    value = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    require(value['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            value['package']['state'] == dict(revision=common.REVISION, version='7.0.0') and
            value['checkout_revision'] == common.REVISION and value['package_manifest_sha256'] == common.PACKAGE_HASH,
            'Fixed official GRDB differs')
    status = json.loads((ROOT/'artifacts/verification-status.json').read_bytes())
    require(status['source_commit'] == os.environ['GITHUB_SHA'] and status['exact8_gate']['parent'] == BASE and
            status['qualification'] == 'TESTS NOT RUN' and status['full_regression_passed'] is False, 'Missing exact8 diagnostic gate')
    save(ROOT/'artifacts/task3/bookmark-dock-fixed-dependency.json', dict(source_commit=os.environ['GITHUB_SHA'],
         revision=common.REVISION, package_manifest_sha256=common.PACKAGE_HASH, passed=True))


def self_check():
    """Synthetic adversarial checks; never represents an XCTest or device execution."""
    negatives = []
    def reject(label, fn):
        try:
            fn()
        except (ValueError, KeyError, IndexError, zipfile.BadZipFile):
            negatives.append(label)
            return
        raise ValueError('Unsafe gate accepted: '+label)
    head, run_id = 'a'*40, '50000000000'
    before = {n: ['100644', 'blob', 'b'*40] for n in ALLOWED[:6]}
    before.update({'frozen/'+str(i): ['100644', 'blob', 'b'*40] for i in range(207)})
    after = copy.deepcopy(before)
    after.update({n: ['100644', 'blob', 'c'*40] for n in ALLOWED})
    state = dict(head=head, parents=[head, BASE], dirty=b'', before=before, after=after,
                 working={n: dict(regular=True, blob=e[2]) for n, e in after.items()},
                 index={n: [e[0], e[2], '0'] for n, e in after.items()}, inputs=dict(package_scope=SCOPE, host_validation_run_id=run_id))
    env = dict(PACKAGE_SCOPE=SCOPE, GITHUB_REPOSITORY=common.REPO, GITHUB_RUN_ATTEMPT='1', GITHUB_EVENT_NAME='workflow_dispatch',
               GITHUB_REF='refs/heads/main', GITHUB_WORKFLOW_REF=common.REPO+'/'+DEVICE+'@refs/heads/main',
               GITHUB_SHA=head, GITHUB_WORKFLOW_SHA=head, HOST_VALIDATION_RUN_ID=run_id, GITHUB_RUN_ID='50000000001')
    source_gate(env, state)
    for key, value in [('GITHUB_SHA', 'd'*40), ('GITHUB_RUN_ATTEMPT', '2'), ('HOST_VALIDATION_RUN_ID', OLD_RUN),
                       ('PACKAGE_SCOPE', 'c-exit-recovery-2f962b6-exact5'), ('GITHUB_REF', 'refs/heads/other')]:
        reject(key, lambda k=key, v=value: source_gate({**env, k: v}, state))
    for key, value in [('parents', [head, 'd'*40]), ('dirty', b'M file'), ('inputs', {}), ('index', {}), ('working', {})]:
        reject(key, lambda k=key, v=value: source_gate(env, {**state, k: v}))
    names = re.findall(r'^      - name: (.+)$', (ROOT/TASK3).read_text(encoding='utf-8'), re.M)
    steps = [dict(number=1, name='Set up job', status='completed', conclusion='success')]
    steps += [dict(number=i, name=n, status='completed', conclusion='failure' if i == 16 else 'skipped' if i in (13,15,17,18,19,20,22) else 'success') for i, n in enumerate(names, 2)]
    run = dict(id=int(run_id), head_sha=head, head_branch='main', event='workflow_dispatch', run_attempt=1,
               workflow_id=398234793, path=TASK3, status='completed', conclusion='failure', html_url='synthetic',
               repository=dict(full_name=common.REPO), head_repository=dict(full_name=common.REPO))
    jobs = dict(total_count=1, jobs=[dict(run_id=int(run_id), run_attempt=1, head_sha=head, status='completed', conclusion='failure', name='validate', steps=steps)])
    upstream_gate(run, jobs, head, run_id)
    for step in (4, 9, 10, 11, 12, 14, 21):
        bad = copy.deepcopy(jobs)
        bad['jobs'][0]['steps'][step-1]['conclusion'] = 'failure'
        reject('preUI-or-evidence-step-'+str(step), lambda b=bad: upstream_gate(run, b, head, run_id))
    reject('upstream-attempt2', lambda: upstream_gate({**run, 'run_attempt': 2}, jobs, head, run_id))
    reject('upstream-wrong-source', lambda: upstream_gate({**run, 'head_sha': BASE}, jobs, head, run_id))
    reject('upstream-old-run', lambda: upstream_gate(run, jobs, head, OLD_RUN))
    target = 'YueJingUITests'
    cmd = ['xcodebuild', 'test', '-only-testing:'+target, '-scheme', 'YueJingUI', '-configuration', 'Debug',
           '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
           '-maximum-test-execution-time-allowance', '180']
    execution = dict(target=target, scheme='YueJingUI', configuration='Debug', expected=11,
                     declared=inventory.expected_names(target), timeout_seconds=1200, command=cmd, timed_out=False, native_exit=65)
    source_line = next(i for i, s in enumerate((ROOT/UI).read_text(encoding='utf-8').splitlines(), 1) if 'XCTAssertTrue(' in s)
    blocks = []
    for name in execution['declared']:
        blocks.append("Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' started.\n"+
                      '/Tests/YueJingUITests/ReadingFlowUITests.swift:'+str(source_line)+': error: -[YueJingUITests.ReadingFlowUITests '+name+'] : XCTAssertTrue failed\n'+
                      "Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' failed (0.1 seconds).\n")
    raw = (''.join(blocks)+'** TEST FAILED **\n').encode()
    require(ui_failure(raw, execution, None)['totals']['failed'] == 11, 'Assertion positive')
    timeout = {**execution, 'timed_out': True, 'native_exit': -9}
    partial = (blocks[0]+blocks[1].splitlines()[0]+'\n').encode()
    require(ui_failure(partial, timeout, None)['totals']['unfinished'] == 1, 'Timeout partial ledger positive')
    passed = ''.join(b.splitlines()[0]+'\n'+b.splitlines()[2].replace('failed', 'passed')+'\n' for b in blocks).encode()
    require(ui_failure(passed, {**execution, 'native_exit': 0}, dict(export_exit=64))['reason'] == 'ATTACHMENT_EXPORT', 'Attachment positive')
    for key, value in [('timeout_seconds', 900), ('expected', 9), ('declared', []), ('command', cmd+['-skip-testing:Other'])]:
        reject('UI-'+key, lambda k=key, v=value: ui_failure(raw, {**execution, k:v}, None))
    for label, data in [('compile', raw+b'error: emit-module failed\n'), ('transport', raw+b'Error Domain=TestManager Code=1\n'),
                        ('unknown-event', raw+b"Test Case '-[OtherTests testOther]' started.\n"),
                        ('missing-assertion', raw.replace(b'XCTAssertTrue failed', b'not an assertion')),
                        ('wrong-source-line', raw.replace(('swift:'+str(source_line)+':').encode(), b'swift:1:'))]:
        reject(label, lambda d=data: ui_failure(d, execution, None))
    reject('false-timeout', lambda: ui_failure(partial, {**timeout, 'native_exit': 65}, None))
    reject('old-timeout', lambda: ui_failure(partial, {**timeout, 'timeout_seconds': 900}, None))
    reject('allpassed-not-export-failure', lambda: ui_failure(passed, {**execution, 'native_exit': 0}, None))
    def archive(name):
        out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            info = zipfile.ZipInfo('fixture')
            info.filename = info.orig_filename = name  # Do not let Windows normalize the attack fixture.
            z.writestr(info, b'evidence')
        return out.getvalue()
    good = archive('task3/example.log')
    require(zip_members(good) == {'task3/example.log': b'evidence'}, 'Safe ZIP positive')
    for name in ('../unsafe.log', '/absolute.log', 'a\\b.log', 'a/./b.log', 'a//b.log', 'C:drive.log'):
        reject('unsafezip-'+name, lambda n=name: zip_members(archive(n)))
    reject('bad-CRC', lambda: zip_members(good.replace(b'evidence', b'EVIdence', 1)))
    artifact = dict(id=123, name='task3-evidence-'+run_id+'-'+head, expired=False,
                    workflow_run=dict(id=int(run_id), head_sha=head, head_branch='main'), size_in_bytes=len(good), digest='sha256:'+sha(good))
    artifact_gate(artifact, good, head, run_id)
    for key, value in [('digest', 'sha256:'+'0'*64), ('size_in_bytes', len(good)+1), ('name', 'wrong-source'), ('expired', True)]:
        reject('artifact-'+key, lambda k=key, v=value: artifact_gate({**artifact, k:v}, good, head, run_id))
    reject('receipt-source', lambda: provenance(dict(source_commit=BASE, run_id=run_id, run_attempt='1'), head, run_id))
    # Exercise the complete evidence join in memory, including actual reviewed selection/hash shapes.
    import validate_task3
    expected_sources = validate_task3.candidate_files()
    files = {}
    prov = dict(source_commit=head, run_id=run_id, run_attempt='1')
    def put(name, value):
        files[name] = json.dumps(value).encode()
    put('task3/candidate-sources.json', dict(prov, files=expected_sources, inventory=inventory.validate_source()))
    for group in COUNTS:
        if group in ('YueJingUITests', 'YueJingCanvasTests'):
            continue
        folder = 'reading-ui-native/' if group == 'YueJingHostTests' else 'task3/'
        names = inventory.expected_names(group)
        data = ''.join('Test '+n+'() started.\nTest '+n+'() passed after 0.1 seconds.\n' for n in names).encode()
        data += ('Test run with '+str(COUNTS[group])+' tests passed after 1 seconds.\n** TEST SUCCEEDED **\n').encode()
        files[folder+group+'.log'] = data
        files[folder+group+'-exit-code.txt'] = b'0'
        from run_reading_ui_tests import count_log
        native_counts = count_log(group, data.decode(), 0) if group == 'YueJingHostTests' else inventory.parse_swift_log(group, data.decode(), 0)
        counts = dict(prov, expected=COUNTS[group], log_sha256=sha(data),
                      inventory_sha256=sha((ROOT/'scripts/task3_test_inventory.py').read_bytes()), selection=inventory.selection(group),
                      source_files=['Tests/'+p for p in sorted(inventory.FILES) if inventory.group_for(p) == group], **native_counts)
        put(folder+group+'-counts.json', counts)
    for group in ('YueJingHostTests', 'YueJingUITests'):
        record = {**execution, **prov, 'target': group, 'expected': COUNTS[group], 'declared': inventory.expected_names(group),
                  'timeout_seconds': 480 if group == 'YueJingHostTests' else 1200,
                  'command': [a.replace('YueJingUITests', group) for a in cmd]}
        del record['timed_out'], record['native_exit']
        put('reading-ui-native/'+group+'-selection.json', record)
        put('reading-ui-native/'+group+'-execution.json', dict(record, timed_out=False, native_exit=0 if group == 'YueJingHostTests' else 65))
        put('reading-ui-native/'+group+'-source-hashes.json', dict(source_commit=head, files=app_source_subset(expected_sources)))
        if group == 'YueJingHostTests':
            key = 'reading-ui-native/'+group+'-counts.json'
            put(key, {**json.loads(files[key]), **record, 'native_exit': 0})
    files['reading-ui-native/YueJingUITests.log'] = raw
    files['reading-ui-native/YueJingUITests-exit-code.txt'] = b'65'
    require(evidence_gate(files, head, run_id, expected_sources)['totals']['failed'] == 11, 'Complete evidence positive')
    for key, field, value in [
        ('task3/candidate-sources.json', 'files', {}),
        ('reading-ui-native/YueJingUITests-source-hashes.json', 'files', {}),
        ('task3/TXTCoreTests-counts.json', 'log_sha256', '0'*64),
        ('task3/ReaderDomainTests-counts.json', 'run_attempt', '2'),
        ('reading-ui-native/YueJingHostTests-execution.json', 'native_exit', 65),
        ('reading-ui-native/YueJingUITests-selection.json', 'command', cmd+['-skip-testing:Other'])]:
        bad = dict(files)
        bad[key] = json.dumps({**json.loads(bad[key]), field: value}).encode()
        reject('evidence-'+key+'-'+field, lambda b=bad: evidence_gate(b, head, run_id, expected_sources))
    for group in ('TXTCoreTests', 'ReaderDomainTests', 'TXTBlockDecoderTests', 'ProcessingReuseMeasurementTests', 'YueJingHostTests'):
        folder = 'reading-ui-native/' if group == 'YueJingHostTests' else 'task3/'
        bad = dict(files)
        key = folder+group+'.log'
        bad[key] = bad[key].replace(b'() passed', b'() failed', 1)
        reject('data-Host-native-failure-'+group, lambda b=bad: evidence_gate(b, head, run_id, expected_sources))
    timed_files = dict(files)
    timed_files['reading-ui-native/YueJingUITests.log'] = partial
    timed_files['reading-ui-native/YueJingUITests-exit-code.txt'] = b'-9'
    key = 'reading-ui-native/YueJingUITests-execution.json'
    timed_files[key] = json.dumps({**json.loads(files[key]), 'native_exit': -9, 'timed_out': True}).encode()
    require(evidence_gate(timed_files, head, run_id, expected_sources)['totals']['unexecuted'] == 9, 'Complete timeout evidence positive')
    exported_files = dict(files)
    exported_files['reading-ui-native/YueJingUITests.log'] = passed
    exported_files['reading-ui-native/YueJingUITests-exit-code.txt'] = b'0'
    exported_files[key] = json.dumps({**json.loads(files[key]), 'native_exit': 0}).encode()
    export = {**json.loads(exported_files[key]), 'command': ['xcrun', 'xcresulttool', 'export', 'attachments', '--path',
              '/synthetic/YueJingUITests.xcresult', '--output-path', '/synthetic/YueJingUITests-attachments'], 'export_exit': 64}
    exported_files['reading-ui-native/attachment-export.json'] = json.dumps(export).encode()
    exported_files['reading-ui-native/attachment-export.log'] = b'Synthetic result bundle metadata export failure, NOT native evidence'
    exported_files['reading-ui-native/attachment-export-help.json'] = json.dumps(dict(command=['xcrun', 'xcresulttool', 'export', 'attachments', '--help'], exit=0, timed_out=False)).encode()
    exported_files['reading-ui-native/attachment-export-help.log'] = b'--path --output-path'
    require(evidence_gate(exported_files, head, run_id, expected_sources)['reason'] == 'ATTACHMENT_EXPORT', 'Complete export evidence positive')
    bad_export = dict(exported_files)
    bad_export['reading-ui-native/attachment-export.json'] = json.dumps({**export, 'command': ['xcodebuild', 'build']}).encode()
    reject('not-attachment-export', lambda: evidence_gate(bad_export, head, run_id, expected_sources))
    reject('extra-Swift-Testing', lambda: ui_failure(raw+b'Test alien() passed after 1 seconds.\n', execution, None))
    for label, entries in [('duplicate', [('a.log', 0), ('A.log', 0)]), ('symlink', [('a.log', stat.S_IFLNK | 0o777)])]:
        out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            for name, mode in entries:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, b'synthetic')
        reject('unsafezip-'+label, lambda b=out.getvalue(): zip_members(b))
    return dict(passed=True, negative_controls=len(negatives), rejected=negatives, native_executions=0, synthetic_only=True)


# Independent, separately approved package-only continuation. Legacy exact8 above is unchanged.
HOST_LOG_BASE = 'a657de20e21cec44bbc152e0db8217a634e3d052'
HOST_LOG_SCOPE = 'bookmark-host-log-a657de2-exact3'
HOST_LOG_ALLOWED = [DEVICE, SELF, DOC]
HOST_LOG_RUN = 41657258680
HOST_LOG_ARTIFACT = 13240429087
HOST_LOG_SIZE = 661864
HOST_LOG_ARCHIVE_SHA = 'c349bd14a88f1927f9383ab2d3beb75d6e0a746cac1ef58cb211401dc0d8f69a'
HOST_LOG_RAW_SHA = '84dc9d6f2b357d1d3c049f1e23b0df45322b306da6d3d6f8b14497ced948ae26'
HOST_LOG_SPAN_SHA = '8edf4a2348abbfb1280d4a0fb7aae932d7ffaffc73481144b5f116217ede43e3'
HOST_LOG_CASE = 'momentumAtTouchBeginStillStopsBeforeANewIdleTouchCanToggle'
HOST_LOG_WARNING = ('2026-11-03 15:00:22.810490+0000 YueJing[14184:52530] '
                    'Unbalanced calls to begin/end appearance transitions for <YueJing.ReaderViewController: 0x1041da000>.')
HOST_LOG_SPAN = ('✔ Test '+HOST_LOG_CASE+'()'+HOST_LOG_WARNING+'\n passed after 0.126 seconds.\n').encode('utf-8')
HOST_LOG_STEP = 'validate/14_Run the 13 real App-host UIKit tests once.txt'
HOST_LOG_WRAPPER = 'Reading UI checks stopped: Missing, duplicate, or unexpected native execution: YueJingHostTests'


def host_log_source_gate(env, state):
    require(env['PACKAGE_SCOPE'] == HOST_LOG_SCOPE and env['GITHUB_REPOSITORY'] == common.REPO, 'Host-log scope/repository differs')
    require(env['GITHUB_EVENT_NAME'] == 'workflow_dispatch' and env['GITHUB_RUN_ATTEMPT'] == '1' and
            env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_WORKFLOW_REF'] == common.REPO+'/'+DEVICE+'@refs/heads/main', 'Host-log manual main attempt1 required')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}', head) and head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'] and
            state['parents'] == [head, HOST_LOG_BASE] and not state['dirty'], 'Host-log source/parent/clean state differs')
    before, after = state['before'], state['after']
    require(len(before) == len(after) == 215 and set(before) == set(after) == set(state['working']) == set(state['index']), 'Host-log complete215 path sets differ')
    require({n for n in after if before[n] != after[n]} == set(HOST_LOG_ALLOWED), 'Host-log exactly three changes required')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Host-log working/index/commit differs: '+n)
    require(env['HOST_VALIDATION_RUN_ID'] == str(HOST_LOG_RUN) and env['GITHUB_RUN_ID'] != str(HOST_LOG_RUN) and
            state['inputs'] == dict(package_scope=HOST_LOG_SCOPE, host_validation_run_id=str(HOST_LOG_RUN)), 'Host-log fixed upstream/input differs')
    return dict(source_commit=head, parent=HOST_LOG_BASE, approved_changed_files=HOST_LOG_ALLOWED, other_entries_equal=212,
                production_and_test_bytes_equal_parent=True, index_and_working_equal_commit=True)


def host_log_upstream_gate(run, jobs):
    require(all(run.get(k) == v for k, v in dict(id=HOST_LOG_RUN, head_sha=HOST_LOG_BASE, head_branch='main', event='workflow_dispatch',
        run_attempt=1, workflow_id=398234793, path=TASK3, status='completed', conclusion='failure').items()), 'Fixed failed full Host-log run differs')
    require(run['repository']['full_name'] == run['head_repository']['full_name'] == common.REPO, 'Host-log upstream repository differs')
    require(jobs['total_count'] == len(jobs['jobs']) == 1, 'Host-log unique job required')
    job = jobs['jobs'][0]
    require(all(job.get(k) == v for k, v in dict(run_id=HOST_LOG_RUN, run_attempt=1, head_sha=HOST_LOG_BASE,
        status='completed', conclusion='failure', name='validate').items()), 'Host-log upstream job differs')
    names = re.findall(r'^      - name: (.+)$', git('show', HOST_LOG_BASE+':'+TASK3).decode('utf-8'), re.M)
    require(len(names) == 21 and names[12] == 'Run the 13 real App-host UIKit tests once' and
            names[14] == 'Run 11 real App UI flows including 2 bookmark flows', 'Frozen Task3 step identities differ')
    steps = {s['number']: s for s in job['steps']}
    require(len(steps) == len(job['steps']), 'Duplicate Host-log step number')
    for number, name in enumerate(names, 2):
        expected = 'failure' if number == 14 else 'skipped' if number in (13, 15, 16, 17, 18, 19, 20, 22) else 'success'
        require(steps[number]['name'] == name and steps[number]['status'] == 'completed' and steps[number]['conclusion'] == expected,
                'Host-log step differs: '+str(number))
    require([s['number'] for s in job['steps'] if s['conclusion'] == 'failure'] == [14] and
            all(s['conclusion'] in ('success', 'skipped', 'failure') for s in job['steps']), 'Additional upstream failure/cancellation')
    return dict(run_id=HOST_LOG_RUN, attempt=1, source_commit=HOST_LOG_BASE, selection='full', conclusion='failure',
                failed_step=14, url=run['html_url'], full_regression_passed=False)


def host_log_parent_sources():
    return {n: sha(git('show', HOST_LOG_BASE+':'+n)) for n in sorted(tree(HOST_LOG_BASE)) if n == 'project.yml' or
            (n.startswith(('App/', 'Sources/', 'Tests/', 'scripts/', '.github/workflows/')) and Path(n).suffix in ('.swift', '.py', '.yml', '.txt'))}


def host_log_derive(raw):
    """Fixed two-line supplemental event; never changes original bytes or the old parser."""
    require(len(raw) == 404000 and sha(raw) == HOST_LOG_RAW_SHA, 'Fixed original Host log hash/size differs')
    lines = raw.splitlines(keepends=True)
    require(len(lines) == 2344 and b''.join(lines[2283:2285]) == HOST_LOG_SPAN and raw.count(HOST_LOG_SPAN) == 1 and
            sha(HOST_LOG_SPAN) == HOST_LOG_SPAN_SHA, 'Exact unique two-line Host interleave differs')
    names = inventory.expected_names('YueJingHostTests')
    original = audit.parse_events(raw, names)
    require(original['totals'] == dict(passed=12, failed=0, skipped=0, unexecuted=0, unfinished=1, ambiguous=0) and
            not original['unexpected'] and len(original['unknown_test_lines']) == 1 and
            original['unknown_test_lines'][0]['line'] == 2284 and not original['parser_complete'], 'Original Host parser failure differs')
    # Keep both original line positions and retain the warning on the second line in this in-memory view.
    derived_line = ('✔ Test '+HOST_LOG_CASE+'() passed after 0.126 seconds.\n').encode('utf-8')
    view = b''.join(lines[:2283])+derived_line+(HOST_LOG_WARNING+'\n').encode('utf-8')+b''.join(lines[2285:])
    derived = audit.parse_events(view, names)
    require(derived['parser_complete'] and derived['totals'] == dict(passed=13, failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0), 'Derived Host identities not exactly thirteen passed')
    intervals = sorted((c['starts'][0]['line'], c['finishes'][0]['line']) for c in derived['cases'])
    require(all(a[1] < b[0] for a, b in zip(intervals, intervals[1:])), 'Overlapping Host identities')
    from run_reading_ui_tests import count_log
    require(len(count_log('YueJingHostTests', view.decode('utf-8'), 0)['passed']) == 13, 'Host summary/success differs')
    item = next(c for c in derived['cases'] if c['name'] == HOST_LOG_CASE)['finishes'][0]
    item.update(kind='supplemental-derived-pass-exact-two-original-lines', end_line=2285,
                raw_span_sha256=HOST_LOG_SPAN_SHA, original_lines=[2284, 2285], warning_retained=True)
    return dict(kind='SUPPLEMENTAL_READONLY_DERIVATION_NOT_OLD_GATE_REPAIR', original=original, derived=derived,
                raw_log_sha256=sha(raw), raw_span=HOST_LOG_SPAN.decode('utf-8'), raw_span_sha256=HOST_LOG_SPAN_SHA,
                original_lines=[2284, 2285], derived_passes=1, original_log_unchanged=True, warning_retained=True,
                original_parser_failure_retained=True, host_counts_receipt_created=False)


def host_log_actions_gate(raw):
    zip_members(raw)  # CRC and bounded safety checks on every member, including discarded files.
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        require(archive.namelist().count(HOST_LOG_STEP) == 1, 'Unique original Host14 Actions log required')
        item = archive.getinfo(HOST_LOG_STEP)
        require(item.file_size <= 2*1024*1024, 'Host Actions log too large')
        body = archive.read(item)
    lines = body.decode('utf-8').splitlines()
    matches = [i for i, line in enumerate(lines) if HOST_LOG_WRAPPER in line]
    require(len(matches) == 1 and matches[0] == len(lines)-2 and lines[-1].endswith('##[error]Process completed with exit code 1.') and
            '** TEST SUCCEEDED **' in body.decode('utf-8'), 'Original Host wrapper error/exit differs')
    require(len([line for line in lines if '##[error]' in line]) == 1, 'Additional Host Actions failure')
    return dict(archive_sha256=sha(raw), host_step_sha256=sha(body), wrapper_error=lines[matches[0]], wrapper_exit=1,
                workflow_conclusion='failure', original_parser_failure_retained=True)


def host_log_artifact_gate(artifact, raw):
    require(artifact['id'] == HOST_LOG_ARTIFACT and artifact['size_in_bytes'] == HOST_LOG_SIZE and
            len(raw) == HOST_LOG_SIZE and sha(raw) == HOST_LOG_ARCHIVE_SHA, 'Fixed Host-log artifact ID/size/hash differs')
    return artifact_gate(artifact, raw, HOST_LOG_BASE, str(HOST_LOG_RUN))


def host_log_evidence_gate(files, expected_sources):
    require(inventory.COUNTS == COUNTS and inventory.TOTAL == 166, 'Host-log frozen166 selection differs')
    def receipt(name):
        value = json.loads(files[name])
        provenance(value, HOST_LOG_BASE, HOST_LOG_RUN)
        return value
    frozen = receipt('task3/candidate-sources.json')
    require(frozen['files'] == expected_sources and frozen['inventory'] == inventory.validate_source(), 'Frozen parent source map/inventory differs')
    require('task3/host-only-scope.json' not in files, 'Not full selection')
    groups = []
    for target in list(COUNTS)[:4]:
        prefix = 'task3/'+target
        raw = files[prefix+'.log']
        parsed = audit.parse_events(raw, inventory.expected_names(target))
        require(parsed['parser_complete'] and parsed['totals']['passed'] == COUNTS[target] and
                all(v == 0 for k, v in parsed['totals'].items() if k != 'passed'), 'Upstream native failure: '+target)
        require(files[prefix+'-exit-code.txt'].strip() == b'0', 'Upstream exit failure: '+target)
        counts = receipt(prefix+'-counts.json')
        native = inventory.parse_swift_log(target, raw.decode('utf-8'), 0)
        require(all(counts.get(k) == json.loads(json.dumps(v)) for k, v in native.items()) and
                counts['expected'] == COUNTS[target] and counts['log_sha256'] == sha(raw) and
                counts['inventory_sha256'] == expected_sources['scripts/task3_test_inventory.py'] and
                counts['selection'] == inventory.selection(target) and counts['source_files'] ==
                ['Tests/'+p for p in sorted(inventory.FILES) if inventory.group_for(p) == target], 'Data receipt/raw/selection differs: '+target)
        groups.append(dict(target=target, **parsed))
    prefix = 'reading-ui-native/YueJingHostTests'
    require(prefix+'-counts.json' not in files, 'Original Host counts receipt must remain absent')
    selection, execution = receipt(prefix+'-selection.json'), receipt(prefix+'-execution.json')
    selection_gate(selection, 'YueJingHostTests')
    selection_gate(execution, 'YueJingHostTests')
    require(all(execution.get(k) == v for k, v in selection.items()) and type(execution['native_exit']) is int and
            execution['native_exit'] == 0 and execution['timed_out'] is False and files[prefix+'-exit-code.txt'].strip() == b'0', 'Host native selection/exit/timeout differs')
    sources = json.loads(files[prefix+'-source-hashes.json'])
    require(sources['source_commit'] == HOST_LOG_BASE and sources['files'] == app_source_subset(expected_sources), 'Complete parent Host source subset differs')
    host = host_log_derive(files[prefix+'.log'])
    require(not any(n.startswith(('reading-ui-native/YueJingUITests', 'reading-ui-native/attachment-', 'task3/YueJingCanvasTests')) or
                    n == 'task3/native-test-gate.json' for n in files), 'Unexpected UI/Canvas/full gate evidence')
    unexecuted = {t: audit.parse_events(b'', inventory.expected_names(t), t == 'YueJingUITests') for t in ('YueJingUITests', 'YueJingCanvasTests')}
    return dict(groups=groups, host=host, unexecuted_groups=unexecuted, original_parser_totals=dict(passed=151, unfinished=1, unexecuted=14),
                supplemental_totals=dict(passed=152, derived_passes=1, failed=0, skipped=0, unfinished=0, unexecuted=14, ambiguous=0),
                UI_unexecuted=11, Canvas_unexecuted=3, full_regression_passed=False, original_Host_gate='FAILED: log parser',
                native_reexecutions=0)


def host_log_offline_gate(run, jobs, artifact, archive, actions_archive, expected_sources):
    """Same pure evidence join used by CI and offline review; does not authorize a different child."""
    result = host_log_upstream_gate(run, jobs)
    files = host_log_artifact_gate(artifact, archive)
    result.update(host_log_evidence_gate(files, expected_sources))
    result.update(actions_log=host_log_actions_gate(actions_archive), artifact_id=HOST_LOG_ARTIFACT,
                  artifact_sha256=sha(archive), artifact_bytes=len(archive))
    return result


def host_log_contracts():
    before = tree(HOST_LOG_BASE)
    require(len(before) == 215, 'Host-log parent215 differs')
    changed = []
    for n, entry in before.items():
        path = ROOT/n
        require(path.is_file() and not any(p.is_symlink() for p in (path, *path.parents)), 'Nonregular source: '+n)
        if blob(path.read_bytes()) != entry[2]:
            changed.append(n)
    require(set(changed) == set(HOST_LOG_ALLOWED), 'Host-log local changes must be exact3; other212 frozen')
    # All old imports/constants/functions stay byte-identical; only new functions and CLI branches are added.
    old = git('show', HOST_LOG_BASE+':'+SELF).decode('utf-8')
    now = (ROOT/SELF).read_text(encoding='utf-8')
    old_tree, new_tree = ast.parse(old), ast.parse(now)
    new_nodes = {n.name: n for n in new_tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    for node in old_tree.body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name != 'main':
            require(ast.get_source_segment(old, node) == ast.get_source_segment(now, new_nodes[node.name]), 'Legacy definition changed: '+node.name)
    marker = '# Independent, separately approved package-only continuation.'
    require(now.split(marker)[0] == old.split('def main():')[0], 'Legacy pre-main bytes changed')
    device = (ROOT/DEVICE).read_text(encoding='utf-8')
    stripped = device.replace('          - '+HOST_LOG_SCOPE+'\n', '').replace('|'+HOST_LOG_SCOPE+') ;;', ') ;;')
    for title in ('Require exact three-path Host log diagnostic continuation from fixed a657de2 evidence',
                  'Require fixed official GRDB for the Host log diagnostic continuation'):
        stripped, count = re.subn(r'      - name: '+re.escape(title)+r'\n.*?(?=      - name:)', '', stripped, flags=re.S)
        require(count == 1, 'Unique new workflow branch required')
    require(stripped == git('show', HOST_LOG_BASE+':'+DEVICE).decode('utf-8'), 'Legacy/common workflow bytes changed')
    require(device.index('--host-log-package-gate') < device.index('      - name: Verify the selected native toolchain') and
            device.index('python3 scripts/validate_task3.py resolved') < device.index('--host-log-fixed-dependency') < device.index('      - name: Verify Release settings'), 'New branch ordering differs')
    require((ROOT/DOC).read_bytes().startswith(git('show', HOST_LOG_BASE+':'+DOC)), 'Historical document must remain intact')
    return dict(passed=True, changed_files=HOST_LOG_ALLOWED, frozen_entries=212, production_and_test_bytes_equal_parent=True,
                legacy_definitions_unchanged=True, native_executions=0)


def host_log_status(head, receipt, upstream):
    return dict(source_commit=head, app_candidate=HOST_LOG_BASE, prior_validation_source_commit=HOST_LOG_BASE,
                prior_validation_run=HOST_LOG_RUN, prior_validation_attempt=1, prior_validation_url=upstream['url'],
                qualification='TESTS NOT RUN', tests_run=False, full_regression_passed=False, formal_release=False,
                full_test_gate='NOT PASSED: fixed parent Host log parser failure; UI11 and Canvas3 not run',
                native_tests_this_run=dict(status='not run', executions=0, selection=[]), native_execution=[],
                physical_device_acceptance='not performed', production_and_test_bytes_equal_parent=True,
                approved_changed_files=HOST_LOG_ALLOWED, prior_counts=upstream['supplemental_totals'],
                original_parser_counts=upstream['original_parser_totals'], original_task3_gate='FAILED; unchanged; no test rerun',
                purpose='Separately approved diagnostic package after fixed Host log-parser failure', host_log_exact3_gate=receipt)


def host_log_package_gate():
    env = os.environ
    after, working, index, hashes = tree('HEAD'), {}, {}, {}
    for n in after:
        path = ROOT/n
        regular = path.is_file() and not any(p.is_symlink() for p in (path, *path.parents))
        data = path.read_bytes() if regular else b''
        working[n], hashes[n] = dict(regular=regular, blob=blob(data)), sha(data)
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if row:
            meta, n = row.split(b'\t', 1)
            require(n.decode() not in index, 'Unmerged index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse', 'HEAD').decode().strip(), parents=git('rev-list', '--parents', '-n', '1', 'HEAD').decode().split(),
                 dirty=git('status', '--porcelain=v1', '--untracked-files=all'), before=tree(HOST_LOG_BASE), after=after, working=working, index=index,
                 inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = host_log_source_gate(env, state)
    receipt['contracts'] = host_log_contracts()
    token = env.get('NATIVE_READ_TOKEN', '')
    require(token, 'Existing read token unavailable; no credential fallback')
    run = api_read('/actions/runs/'+str(HOST_LOG_RUN), token)
    jobs = api_read('/actions/runs/'+str(HOST_LOG_RUN)+'/attempts/1/jobs?per_page=100', token)
    host_log_upstream_gate(run, jobs)
    listing = api_read('/actions/runs/'+str(HOST_LOG_RUN)+'/artifacts?per_page=100', token)
    require(listing['total_count'] == len(listing['artifacts']) == 1, 'Unique fixed artifact required')
    artifact = listing['artifacts'][0]
    require(artifact['id'] == HOST_LOG_ARTIFACT and artifact['size_in_bytes'] == HOST_LOG_SIZE and
            artifact['digest'] == 'sha256:'+HOST_LOG_ARCHIVE_SHA, 'Fixed API artifact metadata differs')
    archive = api_read('/actions/artifacts/'+str(HOST_LOG_ARTIFACT)+'/zip', token, binary=True)
    actions_archive = api_read('/actions/runs/'+str(HOST_LOG_RUN)+'/attempts/1/logs', token, binary=True)
    upstream = host_log_offline_gate(run, jobs, artifact, archive, actions_archive, host_log_parent_sources())
    receipt.update(run_id=env['GITHUB_RUN_ID'], run_attempt='1', files=hashes, upstream_full_validation=upstream)
    save(ROOT/'artifacts/task3/bookmark-host-log-exact3-gate.json', receipt)
    save(ROOT/'artifacts/verification-status.json', host_log_status(receipt['source_commit'], receipt, upstream))
    print('::warning::TESTS NOT RUN; full regression NOT PASSED; Host parser failure retained; UI11/Canvas3 unexecuted')


def host_log_fixed_dependency():
    value = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    require(value['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            value['package']['state'] == dict(revision=common.REVISION, version='7.0.0') and value['checkout_revision'] == common.REVISION and
            value['package_manifest_sha256'] == common.PACKAGE_HASH, 'Host-log fixed official GRDB differs')
    status = json.loads((ROOT/'artifacts/verification-status.json').read_bytes())
    require(status['source_commit'] == os.environ['GITHUB_SHA'] and status['host_log_exact3_gate']['parent'] == HOST_LOG_BASE and
            status['app_candidate'] == HOST_LOG_BASE and status['tests_run'] is False and status['full_regression_passed'] is False and
            status['qualification'] == 'TESTS NOT RUN' and status['native_tests_this_run'] == dict(status='not run', executions=0, selection=[]) and
            status['physical_device_acceptance'] == 'not performed', 'Missing truthful Host-log exact3 status')
    save(ROOT/'artifacts/task3/bookmark-host-log-fixed-dependency.json', dict(source_commit=os.environ['GITHUB_SHA'],
         revision=common.REVISION, package_manifest_sha256=common.PACKAGE_HASH, passed=True))


def host_log_self_check():
    """Bounded synthetic gate controls only; original sealed evidence is checked separately."""
    rejected = []
    def reject(label, fn):
        try:
            fn()
        except (ValueError, KeyError, IndexError, zipfile.BadZipFile):
            rejected.append(label)
            return
        raise ValueError('Unsafe Host-log gate accepted: '+label)
    head = 'a'*40
    before = {n: ['100644', 'blob', 'b'*40] for n in HOST_LOG_ALLOWED}
    before.update({'App/frozen'+str(i): ['100644', 'blob', 'b'*40] for i in range(212)})
    after = copy.deepcopy(before)
    after.update({n: ['100644', 'blob', 'c'*40] for n in HOST_LOG_ALLOWED})
    state = dict(head=head, parents=[head, HOST_LOG_BASE], dirty=b'', before=before, after=after,
                 working={n: dict(regular=True, blob=e[2]) for n, e in after.items()}, index={n: [e[0], e[2], '0'] for n, e in after.items()},
                 inputs=dict(package_scope=HOST_LOG_SCOPE, host_validation_run_id=str(HOST_LOG_RUN)))
    env = dict(PACKAGE_SCOPE=HOST_LOG_SCOPE, GITHUB_REPOSITORY=common.REPO, GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_RUN_ATTEMPT='1',
               GITHUB_REF='refs/heads/main', GITHUB_WORKFLOW_REF=common.REPO+'/'+DEVICE+'@refs/heads/main', GITHUB_SHA=head,
               GITHUB_WORKFLOW_SHA=head, HOST_VALIDATION_RUN_ID=str(HOST_LOG_RUN), GITHUB_RUN_ID='50000000000')
    host_log_source_gate(env, state)
    for key, value in [('PACKAGE_SCOPE', SCOPE), ('HOST_VALIDATION_RUN_ID', OLD_RUN), ('GITHUB_SHA', HOST_LOG_BASE),
                       ('GITHUB_RUN_ATTEMPT', '2'), ('GITHUB_REF', 'refs/heads/other'), ('GITHUB_EVENT_NAME', 'push')]:
        reject(key, lambda k=key, v=value: host_log_source_gate({**env, k: v}, state))
    for key, value in [('parents', [head, BASE]), ('dirty', b'M file'), ('index', {}), ('working', {}), ('inputs', {})]:
        reject(key, lambda k=key, v=value: host_log_source_gate(env, {**state, k: v}))
    bad = copy.deepcopy(state)
    bad['after']['App/frozen0'][2] = 'd'*40
    reject('modified-App', lambda: host_log_source_gate(env, bad))
    names = re.findall(r'^      - name: (.+)$', git('show', HOST_LOG_BASE+':'+TASK3).decode(), re.M)
    steps = [dict(number=i, name=n, status='completed', conclusion='failure' if i == 14 else 'skipped' if i in (13,15,16,17,18,19,20,22) else 'success') for i, n in enumerate(names, 2)]
    run = dict(id=HOST_LOG_RUN, head_sha=HOST_LOG_BASE, head_branch='main', event='workflow_dispatch', run_attempt=1,
               workflow_id=398234793, path=TASK3, status='completed', conclusion='failure', repository=dict(full_name=common.REPO),
               head_repository=dict(full_name=common.REPO), html_url='synthetic')
    jobs = dict(total_count=1, jobs=[dict(run_id=HOST_LOG_RUN, run_attempt=1, head_sha=HOST_LOG_BASE, status='completed',
                                      conclusion='failure', name='validate', steps=steps)])
    host_log_upstream_gate(run, jobs)
    for key, value in [('id', int(OLD_RUN)), ('head_sha', head), ('run_attempt', 2), ('conclusion', 'success')]:
        reject('upstream-'+key, lambda k=key, v=value: host_log_upstream_gate({**run, k: v}, jobs))
    for number in (4,9,10,11,12,14,16,17,21):
        bad_jobs = copy.deepcopy(jobs)
        next(s for s in bad_jobs['jobs'][0]['steps'] if s['number'] == number)['conclusion'] = 'success' if number in (14,16,17) else 'failure'
        reject('step-'+str(number), lambda b=bad_jobs: host_log_upstream_gate(run, b))
    def archive(name, body):
        out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            info = zipfile.ZipInfo('fixture')
            info.filename = info.orig_filename = name
            z.writestr(info, body)
        return out.getvalue()
    wrapper = ('** TEST SUCCEEDED **\n'+HOST_LOG_WRAPPER+'\n##[error]Process completed with exit code 1.\n').encode()
    host_log_actions_gate(archive(HOST_LOG_STEP, wrapper))
    for label, data in [('missing-wrapper', wrapper.replace(HOST_LOG_WRAPPER.encode(), b'other')),
                        ('duplicate-wrapper', wrapper+wrapper), ('wrong-wrapper-exit', wrapper.replace(b'code 1.', b'code 65.'))]:
        reject(label, lambda d=data: host_log_actions_gate(archive(HOST_LOG_STEP, d)))
    for name in ('../unsafe.log', '/absolute.log', 'a\\b.log', 'a/./b.log', 'C:drive.log'):
        reject('unsafeZIP-'+name, lambda n=name: zip_members(archive(n, b'fixture')))
    reject('wrong-fixed-artifact', lambda: host_log_artifact_gate(dict(id=1), b''))
    reject('missing-interleave', lambda: host_log_derive(b''))
    reject('ambiguous-interleave', lambda: host_log_derive(HOST_LOG_SPAN*2))
    require(BASE != HOST_LOG_BASE and SCOPE != HOST_LOG_SCOPE and len(HOST_LOG_ALLOWED) == 3, 'Independent legacy/new constants')
    return dict(passed=True, synthetic_only=True, negative_controls=len(rejected), rejected=rejected, native_executions=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--device-repro-gate', action='store_true')
    mode.add_argument('--fixed-dependency', action='store_true')
    mode.add_argument('--host-log-package-gate', action='store_true')
    mode.add_argument('--host-log-fixed-dependency', action='store_true')
    mode.add_argument('--host-log-self-check', action='store_true')
    args = parser.parse_args()
    if args.host_log_package_gate:
        host_log_package_gate()
    elif args.host_log_fixed_dependency:
        host_log_fixed_dependency()
    elif args.host_log_self_check:
        print(json.dumps(dict(contracts=host_log_contracts(), self_checks=host_log_self_check()), indent=2))
    elif args.device_repro_gate:
        device_repro_gate()
    elif args.fixed_dependency:
        fixed_dependency()
    else:
        print(json.dumps(dict(contracts=local_contracts(), self_checks=self_check()), indent=2))


if __name__ == '__main__':
    main()
