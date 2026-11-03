"""Six-path repair checks and explicitly qualified device-reproduction gate. No native test execution."""
import argparse
import ast
from collections import Counter
import copy
import difflib
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '1b2117b6717004dcd8ecabfbd8a9f4a2b55651ee'
REPO = 'wan780839395-cyber/YueJing'
SCOPE = 'c-dock-failure-1b2117-exact6'
DOCK = 'App/Reading/ReaderFloatingToolsView.swift'
UI = 'Tests/YueJingUITests/ReadingFlowUITests.swift'
DEVICE = '.github/workflows/ios-build.yml'
ALLOWED = [DOCK, UI, DEVICE, 'scripts/audit_native_case_events.py',
           'scripts/check_c_dock_failure_repair.py', 'docs/C_DOCK_FAILURE_REPAIR.md']
REVISION = '4de97e6903d29697caae1179cdef8479c64c2639'
PACKAGE_HASH = '8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def fingerprint(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1048576), b''):
            h.update(block)
    return dict(bytes=path.stat().st_size, sha256=h.hexdigest())


def git(*args):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, timeout=90,
                            env={**os.environ, 'GIT_OPTIONAL_LOCKS':'0'})
    require(result.returncode == 0, 'Git failed: '+repr(args)+': '+result.stderr.decode('utf-8','replace'))
    return result.stdout


def tree(revision):
    result = {}
    for row in git('ls-tree','-rz','--full-tree',revision).split(b'\0'):
        if row:
            meta, path = row.split(b'\t',1)
            result[path.decode()] = meta.decode().split()
    return result


def source_gate(env, state):
    require(env['PACKAGE_SCOPE'] == SCOPE and env['GITHUB_REPOSITORY'] == REPO, 'Scope/repository differs')
    require(env['GITHUB_RUN_ATTEMPT'] == '1' and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Manual attempt1 only')
    require(env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_WORKFLOW_REF'] == REPO+'/'+DEVICE+'@refs/heads/main', 'Main/workflow differs')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}',head) and head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'], 'Source/workflow SHA differs')
    require(state['parents'] == [head,BASE] and not state['dirty'], 'Unique parent/clean checkout differs')
    before, after = state['before'], state['after']
    require(len(before) == 189 and len(after) == 192 and set(after) == set(before)|set(ALLOWED[3:]), 'Tracked path set differs')
    changed = {n for n in after if before.get(n) != after[n]}
    require(changed == set(ALLOWED), 'Exactly six paths must change')
    require(set(after) == set(state['working']) == set(state['index']), 'Complete working/index set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644','blob'] and state['working'][n] == dict(regular=True,blob=entry[2]) and
                state['index'][n] == [entry[0],entry[2],'0'], 'Regular committed working/index object differs: '+n)
    run_id = env['HOST_VALIDATION_RUN_ID']
    require(re.fullmatch(r'[1-9][0-9]*',run_id) and run_id != env['GITHUB_RUN_ID'], 'A distinct completed full native run is required')
    require(state['inputs'] == dict(package_scope=SCOPE,host_validation_run_id=run_id), 'Dispatch inputs differ')
    return dict(source_commit=head,parent=BASE,approved_changed_files=ALLOWED,other_entries_equal=186,index_and_working_equal_commit=True)


def upstream_gate(run, jobs, head, run_id):
    require(run['id'] == int(run_id) and run['head_sha'] == head and run['head_branch'] == 'main' and
            run['event'] == 'workflow_dispatch' and run['run_attempt'] == 1 and run['workflow_id'] == 398234793 and
            run['path'] == '.github/workflows/task3-validate.yml' and run['status'] == 'completed' and run['conclusion'] == 'failure', 'Upstream must be a same-source failed full attempt1')
    require(jobs['total_count'] == len(jobs['jobs']) == 1, 'Upstream job set differs')
    job = jobs['jobs'][0]
    require(job['run_id'] == int(run_id) and job['run_attempt'] == 1 and job['conclusion'] == 'failure', 'Upstream job identity differs')
    steps = {s['number']:s for s in job['steps']}
    require(all(steps[n]['conclusion'] == 'success' for n in (2,3,4,5,6,7,8,9,10,11,12,14)), 'An upstream preparation/build/core/Host gate did not pass')
    require([s['number'] for s in job['steps'] if s['conclusion'] == 'failure'] == [16] and
            steps[16]['name'] == 'Run 8 real App UI flows (original 6 plus 2 typography and relaunch cases)', 'Only UI step16 failure is allowed')
    require(all(steps[n]['conclusion'] == 'skipped' for n in (17,18,19,20,22)), 'Full-gate downstream steps differ')
    return dict(run_id=int(run_id),attempt=1,url=run['html_url'],source_commit=head,conclusion='failure',failed_step=16)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_read(suffix, token, binary=False):
    url = 'https://api.github.com/repos/'+REPO+suffix
    req = urllib.request.Request(url, headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json','User-Agent':'YueJing-fixed-repro-gate'})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        if not binary or error.code not in (301,302,303,307,308):
            raise
        location = error.headers.get('Location','')
        parsed = urllib.parse.urlparse(location)
        require(parsed.scheme == 'https' and parsed.hostname and parsed.hostname.endswith(('.blob.core.windows.net','.githubusercontent.com')),
                'Unexpected log redirect; do not forward token')
        # The signed CDN request deliberately has NO Authorization header.
        with urllib.request.urlopen(urllib.request.Request(location,headers={'User-Agent':'YueJing-fixed-repro-gate'}),timeout=120) as response:
            raw = response.read()
    return raw if binary else json.loads(raw)


def ui_assertion_failures(text, result):
    """Every error must be a sourced assertion inside its own failed case interval."""
    errors = {i:line for i,line in enumerate(text.splitlines(),1) if re.search(r'\berror:',line)}
    pattern = re.compile(r"/Tests/YueJingUITests/ReadingFlowUITests\.swift:\d+(?::\d+)?: error: "
                         r"-\[(?:\w+\.)?ReadingFlowUITests (test\w+)\] : "
                         r"(XCT(?:Assert\w*|Fail) failed)(?::.*)?$")
    claimed, reasons = set(), []
    for case in result['cases']:
        start, end = case['starts'][0]['line'], case['finishes'][0]['line']
        rows = [(i,line) for i,line in errors.items() if start < i < end]
        if case['status'] == 'passed':
            require(not rows, 'Error inside passed UI case: '+case['name'])
            continue
        require(rows, 'Failed UI case has no classified assertion: '+case['name'])
        for i,line in rows:
            match = pattern.search(line)
            require(match and match[1] == case['name'], 'Non-assertion or unclassified UI error at line '+str(i))
            claimed.add(i)
            reasons.append(dict(name=case['name'],line=i,kind=match[2],raw_line_sha256=hashlib.sha256(line.encode()).hexdigest()))
    require(claimed == set(errors), 'Unattributed error outside UI cases')
    return reasons


def verify_ui_log_archive(raw):
    import audit_native_case_events as audit
    import task3_test_inventory as inventory
    seen, selected = set(), []
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        for item in archive.infolist():
            n = item.orig_filename
            path = PurePosixPath(n)
            canonical = n.rstrip('/').casefold()
            require(n == item.filename and n and '\\' not in n and '\0' not in n and ':' not in n and not path.is_absolute() and '..' not in path.parts and canonical not in seen, 'Unsafe/duplicate upstream log path')
            seen.add(canonical)
            mode = item.external_attr >> 16
            require(not item.flag_bits & 1 and stat.S_IFMT(mode) in (0,stat.S_IFREG,stat.S_IFDIR), 'Special/encrypted upstream log')
            body = archive.read(item)
            if '/16_Run 8 real App UI flows' in n and n.endswith('.txt'):
                selected.append(body)
    require(len(selected) == 1, 'Unique UI step16 log required')
    body = selected[0]
    text = body.decode('utf-8-sig')
    result = audit.parse_events(body,inventory.expected_names('YueJingUITests'),ui=True)
    t = result['totals']
    require(result['parser_complete'] and t['passed']+t['failed'] == 9 and t['failed'] > 0 and
            not any(t[k] for k in ('skipped','unexecuted','unfinished','ambiguous')), 'All nine UI identities must have finished; assertion failure required')
    require('XCTAssert' in text and 'failed' in text and '** TEST FAILED **' in text and
            'Native target timed out' not in text and not re.search(r'\.swift:\d+:\d+: error:|error: emit-module',text), 'Not an eligible UI-assertion-only failure')
    reasons = ui_assertion_failures(text, result)
    return dict(log_archive_sha256=hashlib.sha256(raw).hexdigest(),ui_step_log_sha256=hashlib.sha256(body).hexdigest(),totals=t,finished_UI_cases=9,assertion_failures=reasons)


def assertion_gate_self_check():
    import task3_test_inventory as inventory
    names = inventory.expected_names('YueJingUITests')
    blocks = []
    for name in names:
        blocks.append("Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' started.\n"
                      "/Tests/YueJingUITests/ReadingFlowUITests.swift:1: error: -[YueJingUITests.ReadingFlowUITests "+name+"] : XCTAssertTrue failed\n"
                      "Test Case '-[YueJingUITests.ReadingFlowUITests "+name+"]' failed (0.1 seconds).\n")
    good = ''.join(blocks) + '** TEST FAILED **\n'
    def archive(text):
        out = io.BytesIO()
        with zipfile.ZipFile(out,'w') as z:
            z.writestr('validate/16_Run 8 real App UI flows.txt',text)
        return out.getvalue()
    require(verify_ui_log_archive(archive(good))['totals']['failed'] == 9,'All-assertions positive failed')
    mixed_pass = blocks[0] + ''.join(b.splitlines()[0]+'\n'+b.splitlines()[2].replace('failed','passed')+'\n' for b in blocks[1:]) + '** TEST FAILED **\n'
    require(verify_ui_log_archive(archive(mixed_pass))['totals']['passed'] == 8,'One assertion/eight passes positive failed')
    reason = blocks[1].splitlines()[1]
    variants = {
        'mixed-automation-error': good.replace(reason,reason.replace('XCTAssertTrue failed','Failed to get matching snapshot: UI automation failure')),
        'missing-reason': good.replace(reason+'\n',''),
        'wrong-case-reason': good.replace(reason,reason.replace(names[1],names[0])),
        'outside-error': good+'xcodebuild: error: simulator unavailable\n',
        'mixed-second-error': good.replace(reason,reason+'\nerror: UI automation disconnected'),
        'compiler-error': good+'x.swift:1:1: error: cannot find symbol\n',
        'unknown-event': good+"Test Case '-[OtherTests testAlien]' started.\n",
        'malformed-event': good+'Test Case incomplete started.\n',
        'unfinished-case': good.replace(blocks[1].splitlines()[2]+'\n',''),
        'skipped-case': good.replace(blocks[1].splitlines()[2],blocks[1].splitlines()[2].replace('failed','skipped')),
        'no-test-failed-marker': good.replace('** TEST FAILED **',''),
        'timed-out': good+'Native target timed out\n',
        'passed-case-error': mixed_pass.replace(blocks[1].splitlines()[0],blocks[1].splitlines()[0]+'\n'+reason),
    }
    for label,text in variants.items():
        try:
            verify_ui_log_archive(archive(text))
        except ValueError:
            continue
        raise ValueError('Unsafe diagnostic log accepted: '+label)
    return dict(passed=True,positive_controls=2,negative_controls=len(variants),native_executions=0)


def device_repro_gate():
    env = os.environ
    after = tree('HEAD')
    working, index, hashes = {}, {}, {}
    for n in after:
        p = ROOT/n
        regular = p.is_file() and not any(x.is_symlink() for x in (p,*p.parents))
        data = p.read_bytes() if regular else b''
        working[n] = dict(regular=regular,blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest())
        hashes[n] = hashlib.sha256(data).hexdigest()
    for row in git('ls-files','--stage','-z').split(b'\0'):
        if row:
            meta,n = row.split(b'\t',1)
            require(n.decode() not in index,'Unmerged index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse','HEAD').decode().strip(),parents=git('rev-list','--parents','-n','1','HEAD').decode().split(),
                 dirty=git('status','--porcelain=v1','--untracked-files=all'),before=tree(BASE),after=after,working=working,index=index,
                 inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = source_gate(env,state)
    run_id = env['HOST_VALIDATION_RUN_ID']
    token = env.get('NATIVE_READ_TOKEN','')
    require(token,'Existing read token unavailable; no credential installation or fallback')
    run = api_read('/actions/runs/'+run_id,token)
    jobs = api_read('/actions/runs/'+run_id+'/attempts/1/jobs?per_page=100',token)
    upstream = upstream_gate(run,jobs,receipt['source_commit'],run_id)
    raw = api_read('/actions/runs/'+run_id+'/attempts/1/logs',token,binary=True)
    upstream.update(verify_ui_log_archive(raw))
    receipt.update(run_id=env['GITHUB_RUN_ID'],run_attempt='1',files=hashes,upstream_full_validation=upstream)
    out = ROOT/'artifacts/task3'
    out.mkdir(parents=True,exist_ok=True)
    (out/'c-dock-repair-exact6-gate.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    status = dict(source_commit=receipt['source_commit'],purpose='C dock repair device reproduction after same-source UI assertions failed',
                  qualification='TESTS NOT RUN',tests_run=False,full_regression_passed=False,full_test_gate='NOT PASSED: same-source full native run failed UI assertions',
                  approved_changed_files=ALLOWED,app_candidate=receipt['source_commit'],previous_candidate=BASE,
                  native_tests_this_run=dict(status='not run',executions=0,selection=[]),native_execution=[],
                  prior_validation_run=int(run_id),prior_validation_attempt=1,prior_validation_source_commit=receipt['source_commit'],
                  prior_validation_url=upstream['url'],prior_UI_totals=upstream['totals'],original_task3_gate='unchanged; failure retained',
                  physical_device_acceptance='not performed',exact6_gate=receipt)
    (ROOT/'artifacts/verification-status.json').write_text(json.dumps(status,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('::warning::TESTS NOT RUN in this attempt; full regression NOT PASSED; device reproduction only')
    print(json.dumps(dict(source_commit=receipt['source_commit'],upstream=upstream,tracked_files=len(hashes)),indent=2))


def fixed_dependency():
    receipt = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    require(receipt['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and
            receipt['package']['state'] == dict(revision=REVISION,version='7.0.0') and
            receipt['checkout_revision'] == REVISION and receipt['package_manifest_sha256'] == PACKAGE_HASH, 'Fixed official GRDB differs')
    out = dict(source_commit=os.environ['GITHUB_SHA'],revision=REVISION,package_manifest_sha256=PACKAGE_HASH,passed=True)
    (ROOT/'artifacts/task3/c-dock-repair-fixed-dependency.json').write_text(json.dumps(out,indent=2)+'\n',encoding='utf-8')


def allowed_delta(previous, current, lines, insert_before):
    matcher = difflib.SequenceMatcher(None,previous.splitlines(),current.splitlines(),autojunk=False)
    for kind,a,b,_,_ in matcher.get_opcodes():
        if kind == 'equal':
            continue
        require((kind == 'insert' and (a+1 in insert_before or a+1 in lines or a in lines)) or (kind != 'insert' and set(range(a+1,b+1)) <= lines), 'Unapproved old-line delta: '+repr((kind,a+1,b)))

def contracts(src, old):
    import check_navigation_panel_layout as lexical
    checks=[]
    def need(ok,name):
        require(ok,name)
        checks.append(name)
    for n in (DOCK,UI):
        lexical.check_balanced_delimiters(n,lexical.strip_swift_comments_and_strings(src[n]))
        checks.append('lexical-balanced:'+n)
    allowed_delta(old[DOCK],src[DOCK],set(range(21,85)),set())
    allowed_delta(old[UI],src[UI],{175,550,556,561,562,578},{393,560,565,573,589})
    checks.append('only-reviewed-Swift-regions-changed')
    d,t=src[DOCK],src[UI]
    need(d[d.index('    private var collapseButton:'):]==old[DOCK][old[DOCK].index('    private var collapseButton:'):], 'dock-existing-actions-guards-labels-focus-byte-identical')
    need('if visible {' in d and 'if trayExpanded {' in d and 'expandedDock' in d and 'expandButton' in d and '.opacity(trayExpanded' not in d, 'only-current-control-tree-mounted')
    need('@State private var trayExpanded = false' in d and '.allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)' in d, 'stable-state-and-existing-input-gates')
    need('ViewThatFits(in: .horizontal)' in d and 'ScrollView(.vertical)' in d and 'metrics.controlHeight * 3 + 8' in d and '.accessibilityIdentifier("reader.tools.scroll")' in d,'adaptive-scrolling-size-and-unique-tool-viewport')
    need('reduceMotion ? nil : ReaderMotion.toolVisibility' in d and '.offset(y: ReaderMotion.hiddenTravel)' in d and '.transition(.opacity)' in d, 'scoped-motion-no-reader-size-animation')
    need(d.count('guard visible, state.canInteract, !exitSaveFailed else { return }') == 2, 'both-dock-action-admission-guards-retained')
    scanner=ROOT/'scripts/check_c_only_ui_repair.py'
    nodes=[n for n in ast.parse(scanner.read_text(encoding='utf-8')).body if isinstance(n,ast.FunctionDef) and n.name=='assertions']
    ns=dict(re=re,Counter=Counter,require=require)
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(scanner),'exec'),ns)
    previous,current=ns['assertions'](old[UI]),ns['assertions'](t)
    need(not (previous-current), 'all-original-assertions-retained')
    marker='    @MainActor func testOtherAppRoundTripRestoresCentralTapAndWindowUpdates() {'
    end='    @MainActor private func sceneRoundTripPID'
    need(t[t.index(marker):t.index(end)]==old[UI][old[UI].index(marker):old[UI].index(end)],'strict-App-return-one-central-tap-PID-anchors-unchanged')
    need('collapse.exists && !expand.exists' in t and 'XCTAssertFalse(collapse.isHittable)' in t and 'XCTAssertFalse(expand.isHittable)' in t,'expansion-proof-without-offscreen-hittable-or-weakening-mutual-exclusion')
    helper=t[t.index('    @MainActor private func revealDockControl'):t.index('    @MainActor private func viewport')]
    need('app.scrollViews["reader.tools.scroll"]' in helper and 'for _ in 0..<3' in helper and 'deadline.timeIntervalSinceNow > 0' in helper and 'bounds.contains(CGPoint' in helper,'tool-local-bounded-scroll-and-center-admission')
    need('viewport(app)' not in helper and '.tap()' not in helper and 'sleep' not in helper and 'waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow))' in helper,'no-body-tap-retry-or-new-wait-budget')
    need('openSettings(app, sharedDeadline: dockDeadline)' in t and 'collapse.tap()' in t and 'XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)' in t,'large-text-real-collapse-and-reexpand-shared-budget')
    need(not any(x in d+t for x in ('XCTSkip','withKnownIssue','XCTExpectFailure','Timer(', 'asyncAfter(', 'drawingGroup(', 'compositingGroup(')), 'no-skip-known-failure-timer-or-raster-workaround')
    return dict(checks=checks,count=len(checks),old_assertions=sum(previous.values()),final_assertions=sum(current.values()))


def local_check(base):
    import yaml
    import task3_test_inventory as inventory
    require(base.resolve().is_relative_to(ROOT/'artifacts'),'Baseline outside project artifacts')
    state=json.loads((base/'baseline.json').read_bytes())
    require(state['head']==BASE and state['allowed']==ALLOWED,'Baseline scope differs')
    old={n:(base/'preimage'/n).read_text(encoding='utf-8') for n in ALLOWED[:3]}
    for n in ALLOWED[:3]:require(fingerprint(base/'preimage'/n)==state['preimage'][n],'Preimage hash differs '+n)
    src={n:(ROOT/n).read_text(encoding='utf-8') for n in ALLOWED[:3]}
    result=contracts(src,old)
    old_spec=yaml.load(old[DEVICE],Loader=yaml.BaseLoader)
    new_spec=yaml.load(src[DEVICE],Loader=yaml.BaseLoader)
    normalized=copy.deepcopy(new_spec)
    normalized['on']['workflow_dispatch']['inputs']['package_scope']['options'].remove(SCOPE)
    normalized['on']['workflow_dispatch']['inputs']['host_validation_run_id']['description']=old_spec['on']['workflow_dispatch']['inputs']['host_validation_run_id']['description']
    steps=normalized['jobs']['build']['steps']
    extra=[s for s in steps if s.get('if')=="${{ inputs.package_scope == '"+SCOPE+"' }}"]
    require(len(extra)==2,'Exactly two scope-specific device steps required')
    normalized['jobs']['build']['steps']=[s for s in steps if s not in extra]
    normalized['jobs']['build']['steps'][0]['run']=normalized['jobs']['build']['steps'][0]['run'].replace('|'+SCOPE,'')
    require(normalized==old_spec,'Original workflow properties/steps/conditions changed')
    python_blocks=0
    for step in new_spec['jobs']['build']['steps']:
        for body in re.findall(r"python3(?: -B)? - <<'PY'\n(.*?)\nPY",step.get('run',''),re.S):
            ast.parse(body)
            python_blocks+=1
    reviewed=inventory.validate_source()
    require(reviewed['selected']==146 and reviewed['all_declared']==147,'Inventory changed')
    require(git('rev-parse','HEAD').decode().strip()==BASE and fingerprint(ROOT/'.git/index')==state['index'],'HEAD/index drift')
    require(not git('diff','--cached','--name-only') and not git('diff','--check'),'Staging/whitespace differs')
    require(set(git('diff','--name-only').decode().splitlines())==set(ALLOWED[:3]),'Tracked changed paths differ')
    require(set(git('ls-files','--others','--exclude-standard','-z').decode().split('\0'))-{''}==set(ALLOWED[3:])|{'.architect_memory.json','PROJECT_STATE.md','ask_architect.py'},'Untracked paths differ')
    protected=json.loads((base/'protection-baseline.json').read_bytes())
    drift=[n for n,v in protected.items() if not Path(n).is_file() or fingerprint(Path(n))!=v]
    require(not drift,'Protected bytes changed: '+repr(drift))
    return dict(passed=True,**result,assertion_gate=assertion_gate_self_check(),python_blocks=python_blocks,inventory=reviewed,protected=len(protected),drift=[],candidate={n:fingerprint(ROOT/n) for n in ALLOWED},native_executions=0,FPS_measured=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path)
    parser.add_argument('--device-repro-gate',action='store_true')
    parser.add_argument('--fixed-dependency',action='store_true')
    args=parser.parse_args()
    require(sum((bool(args.baseline),args.device_repro_gate,args.fixed_dependency))==1,'Select one explicit mode')
    if args.device_repro_gate:
        device_repro_gate()
    elif args.fixed_dependency:
        fixed_dependency()
    else:
        print(json.dumps(local_check(args.baseline),ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
