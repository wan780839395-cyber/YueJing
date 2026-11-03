"""Fixed-parent package continuation: reuse audited146, run zero new native tests."""
import argparse
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
BASE = '66d129183498b7ccfa675bffb6af3548c79a33d0'
RUN = 41611708463
ARTIFACT = 13221452735
ARCHIVE_SHA = '8ef7900f009fd47746f502a177805e71ff0c9a0fad84948ef603b1fea5506a1a'
SCOPE = 'full146-package-66d1291-exact3'
DEVICE = '.github/workflows/ios-build.yml'
ALLOWED = [DEVICE, 'scripts/check_full146_package_resume.py', 'docs/FULL146_DEVICE_PACKAGE.md']
TOTALS = dict(passed=146, failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0)
require, git, tree = prior.require, prior.git, prior.tree
sha = lambda b: hashlib.sha256(b).hexdigest()


def source_gate(env, state):
    require(env['PACKAGE_SCOPE'] == SCOPE and env['GITHUB_REPOSITORY'] == prior.REPO, 'Scope/repository differs')
    require(env['GITHUB_RUN_ATTEMPT'] == '1' and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Manual attempt1 only')
    require(env['GITHUB_REF'] == 'refs/heads/main' and env['GITHUB_WORKFLOW_REF'] == prior.REPO+'/'+DEVICE+'@refs/heads/main', 'Workflow/ref differs')
    head = state['head']
    require(re.fullmatch(r'[0-9a-f]{40}', head) and head == env['GITHUB_SHA'] == env['GITHUB_WORKFLOW_SHA'], 'SHA differs')
    require(state['parents'] == [head, BASE] and not state['dirty'], 'Unique parent/clean checkout differs')
    before, after = state['before'], state['after']
    require(len(before) == 201 and len(after) == 203 and set(after) == set(before)|set(ALLOWED[1:]), 'Complete tree differs')
    require({n for n in after if before.get(n) != after[n]} == set(ALLOWED), 'Exactly three packaging paths must change')
    require(set(after) == set(state['working']) == set(state['index']), 'Working/index path set differs')
    for n, entry in after.items():
        require(entry[:2] == ['100644', 'blob'] and state['working'][n] == dict(regular=True, blob=entry[2]) and
                state['index'][n] == [entry[0], entry[2], '0'], 'Working/index/commit differs: '+n)
    require(env['HOST_VALIDATION_RUN_ID'] == str(RUN) and env['GITHUB_RUN_ID'] != str(RUN), 'Fixed prior run required')
    require(state['inputs'] == dict(package_scope=SCOPE, host_validation_run_id=str(RUN)), 'Inputs differ')
    return dict(source_commit=head, parent=BASE, approved_changed_files=ALLOWED, other_entries_equal=200,
                product_test_source_commit=BASE, production_and_test_bytes_equal_parent=True,
                index_and_working_equal_commit=True)


def upstream_gate(run, jobs, annotations):
    require(all(run.get(k) == v for k, v in dict(id=RUN, head_sha=BASE, head_branch='main', event='workflow_dispatch',
        run_attempt=1, workflow_id=398234793, path='.github/workflows/task3-validate.yml', status='completed', conclusion='cancelled').items()), 'Fixed prior run identity differs')
    require(jobs['total_count'] == len(jobs['jobs']) == 1, 'Prior jobs differ')
    j = jobs['jobs'][0]
    require(j['id'] == 125834957000 and j['run_id'] == RUN and j['run_attempt'] == 1 and j['conclusion'] == 'cancelled', 'Prior job binding differs')
    steps = {s['number']:s['conclusion'] for s in j['steps']}
    require(all(steps[n] == 'success' for n in list(range(1,13))+[14,16,17,18,21]), 'Prior native146/source/evidence gate failed')
    require(steps[19] == 'cancelled' and all(steps[n] == 'skipped' for n in (13,15,20,22)) and
            all(v in ('success','skipped','cancelled') for v in steps.values()) and
            [n for n,v in steps.items() if v == 'cancelled'] == [19], 'Only device19 cancellation accepted')
    require(any(a.get('message') == 'The job has exceeded the maximum execution time of 35m0s' and a.get('annotation_level') == 'failure' for a in annotations), 'Explicit prior35min timeout annotation required')
    return dict(run_id=RUN, attempt=1, source_commit=BASE, workflow_conclusion='cancelled',
                full146_passed=True, package_cancelled_by_job35min=True, url=run['html_url'])


def zip_members(raw):
    """CRC-read every original member; retain non-xcresult evidence, never export results."""
    seen, files, expanded = set(), {}, 0
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        for item in z.infolist():
            n = item.orig_filename
            p = PurePosixPath(n)
            key = n.rstrip('/').casefold()
            require(n == item.filename and n and '\0' not in n and '\\' not in n and ':' not in n and
                    not p.is_absolute() and '..' not in p.parts and p.as_posix() == n.rstrip('/') and key not in seen, 'Unsafe/duplicate evidence ZIP path')
            seen.add(key)
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(not item.flag_bits & 1 and kind in (0, stat.S_IFREG, stat.S_IFDIR) and
                    ((item.is_dir() and kind in (0, stat.S_IFDIR)) or (not item.is_dir() and kind in (0, stat.S_IFREG))), 'Encrypted/special evidence ZIP member')
            expanded += item.file_size
            require(expanded <= 1024*1024*1024 and item.file_size <= 256*1024*1024, 'Evidence ZIP exceeds bounded limit')
            body = z.read(item)
            require(len(body) == item.file_size, 'ZIP member size differs')
            if not item.is_dir() and '.xcresult/' not in n:
                files[n] = body
    return files


def parent_sources():
    return {n:sha(git('show', BASE+':'+n)) for n in sorted(tree(BASE))
            if n == 'project.yml' or (n.split('/')[0] in ('App','Sources','Tests','scripts','.github') and
               Path(n).suffix in ('.swift','.py','.yml','.txt'))}


def evidence_gate(files, expected_sources):
    def receipt(n):
        v = json.loads(files[n])
        require(v['source_commit'] == BASE and str(v['run_id']) == str(RUN) and str(v['run_attempt']) == '1', 'Receipt provenance differs: '+n)
        return v
    frozen = receipt('task3/candidate-sources.json')
    require(frozen['files'] == expected_sources and frozen['inventory'] == inventory.validate_source(), 'Parent source/inventory differs')
    groups = []
    for target, count in inventory.COUNTS.items():
        folder = 'reading-ui-native/' if target in ('YueJingHostTests','YueJingUITests') else 'task3/'
        raw = files[folder+target+'.log']
        parsed = audit.parse_events(raw, inventory.expected_names(target), target == 'YueJingUITests')
        require(parsed['parser_complete'] and parsed['totals']['passed'] == count and
                all(not v for k,v in parsed['totals'].items() if k != 'passed'), 'Actual native events not all passed: '+target)
        require(files[folder+target+'-exit-code.txt'].strip() == b'0', 'Native exit differs: '+target)
        counts = receipt(folder+target+'-counts.json')
        require(counts['log_sha256'] == sha(raw) and len(counts['passed']) == count and
                set(counts['passed']) == set(inventory.expected_names(target)), 'Count/raw identity differs: '+target)
        if target in ('YueJingHostTests','YueJingUITests'):
            ex = receipt(folder+target+'-execution.json')
            require(ex['native_exit'] == 0 and ex['timed_out'] is False and ex['timeout_seconds'] == (480 if target == 'YueJingHostTests' else 900)
                    and ex['declared'] == inventory.expected_names(target) and ex['expected'] == count, 'Execution selection/budget differs')
            src = json.loads(files[folder+target+'-source-hashes.json'])
            require(src['source_commit'] == BASE and src['files'] and all(expected_sources.get(n) == h for n,h in src['files'].items()), 'Test source hashes differ')
        groups.append(dict(target=target, totals=parsed['totals'], raw_sha256=sha(raw)))
    totals = {k:sum(g['totals'][k] for g in groups) for k in TOTALS}
    require(totals == TOTALS, 'Actual146 totals differ')
    gate = receipt('task3/native-test-gate.json')
    require(gate['native_passed'] == 146 and gate['failed'] == gate['skipped'] == gate['unexecuted'] == 0 and
            gate['inventory_sha256'] == sha((ROOT/'scripts/task3_test_inventory.py').read_bytes()), 'Original full gate differs')
    u = 'reading-ui-native/'
    export = receipt(u+'attachment-export.json')
    require(export['native_exit'] == export['export_exit'] == 0 and export['timed_out'] is False, 'Attachment export failed')
    ci = receipt(u+'case-evidence-index.json')
    require(ci['native_exit'] == 0 and set(ci['cases']) == set(inventory.expected_names('YueJingUITests')), 'UI evidence identities differ')
    actual, ax, png = {}, {n:[] for n in ci['cases']}, {n:[] for n in ci['cases']}
    for n,b in sorted(files.items()):
        if not n.startswith(u+'YueJingUITests-attachments/'):
            continue
        name = PurePosixPath(n).name
        require(name not in actual, 'Duplicate attachment name')
        item = dict(path=n[len(u):], bytes=len(b), sha256=sha(b))
        actual[name] = dict(**item, png=b.startswith(b'\x89PNG\r\n\x1a\n'))
        if b.startswith(b'YueJing UI evidence\n'):
            text = b.decode('utf-8')
            case = re.search(r'^case: (test\w+)$', text, re.M)
            stage = re.search(r'^stage: ([\w-]+)$', text, re.M)
            if case and case[1] in ax:
                ax[case[1]].append(dict(**item, stage=stage[1] if stage else None,
                    full_app_available='fullAppDebugDescription:\n' in text and 'App is not running;' not in text))
    def walk(value, owner=None):
        if isinstance(value, dict):
            strings = [v for v in value.values() if isinstance(v,str)]
            matched = [n for n in png if any(n in s for s in strings)]
            owner = matched[0] if len(matched) == 1 else owner
            if owner:
                for s in strings:
                    item = actual.get(PurePosixPath(s).name)
                    if item and item['png'] and item not in png[owner]:
                        png[owner].append(item)
            for child in value.values(): walk(child, owner)
        elif isinstance(value, list):
            for child in value: walk(child, owner)
    walk(json.loads(files[u+ci['native_manifest']]))
    for n,row in ci['cases'].items():
        require(row == dict(png=png[n], ax=ax[n]) and png[n] and any(a['stage'] == 'open' and a['full_app_available'] for a in ax[n]), 'Actual PNG/full App AX/open missing: '+n)
    require(ci['exported_files'] == list(actual.values()), 'Exported evidence index differs')
    return dict(full146_passed=True, totals=totals, groups=groups, attachment_gate_passed=True,
                parent_cloud_source_count=len(expected_sources), new_native_test_executions=0)


def fixed_dependency():
    v = json.loads((ROOT/'artifacts/task3/dependency-resolution.json').read_bytes())
    require(v['package']['location'] == 'https://github.com/groue/GRDB.swift.git' and v['package']['state'] == dict(revision=prior.REVISION, version='7.0.0') and
            v['checkout_revision'] == prior.REVISION and v['package_manifest_sha256'] == prior.PACKAGE_HASH, 'Official fixed GRDB differs')
    save(ROOT/'artifacts/task3/full146-fixed-dependency.json', dict(source_commit=os.environ['GITHUB_SHA'], revision=prior.REVISION, package_manifest_sha256=prior.PACKAGE_HASH, passed=True))


def save(p,v):
    with p.open('x', encoding='utf-8') as f:json.dump(v,f,ensure_ascii=False,indent=2);f.write('\n')


def device_gate():
    env = os.environ
    after, working, index, hashes = tree('HEAD'), {}, {}, {}
    for n in after:
        p = ROOT/n
        regular = p.is_file() and not any(x.is_symlink() for x in (p,*p.parents))
        b = p.read_bytes() if regular else b''
        working[n] = dict(regular=regular, blob=hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest())
        hashes[n] = sha(b)
    for row in git('ls-files','--stage','-z').split(b'\0'):
        if row:
            meta,n = row.split(b'\t',1)
            require(n.decode() not in index, 'Conflicted index')
            index[n.decode()] = meta.decode().split()
    state = dict(head=git('rev-parse','HEAD').decode().strip(), parents=git('rev-list','--parents','-n','1','HEAD').decode().split(),
        dirty=git('status','--porcelain=v1','--untracked-files=all'), before=tree(BASE), after=after, working=working, index=index,
        inputs=json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes()).get('inputs'))
    receipt = source_gate(env,state)
    token = env.get('NATIVE_READ_TOKEN','')
    require(token, 'Existing read token unavailable; no credential fallback')
    run = prior.api_read('/actions/runs/'+str(RUN),token)
    jobs = prior.api_read('/actions/runs/'+str(RUN)+'/attempts/1/jobs?per_page=100',token)
    annotations = prior.api_read('/check-runs/125834957000/annotations?per_page=100',token)
    upstream = upstream_gate(run,jobs,annotations)
    listing = prior.api_read('/actions/runs/'+str(RUN)+'/artifacts?per_page=100',token)
    require(listing['total_count'] == len(listing['artifacts']) == 1, 'Unique prior artifact required')
    art = listing['artifacts'][0]
    require(art['id'] == ARTIFACT and art['name'] == 'task3-evidence-'+str(RUN)+'-'+BASE and not art['expired'] and
            art['workflow_run']['id'] == RUN and art['workflow_run']['head_sha'] == BASE, 'Prior artifact binding differs')
    raw = prior.api_read('/actions/artifacts/'+str(ARTIFACT)+'/zip',token,binary=True)
    require(len(raw) == art['size_in_bytes'] == 16855288 and sha(raw) == ARCHIVE_SHA and art['digest'] == 'sha256:'+ARCHIVE_SHA, 'Prior artifact size/digest differs')
    upstream.update(evidence_gate(zip_members(raw),parent_sources()))
    receipt.update(run_id=env['GITHUB_RUN_ID'],run_attempt='1',files=hashes,upstream_full_validation=upstream,
                   prior_artifact_id=ARTIFACT,prior_artifact_sha256=ARCHIVE_SHA,cloud_prior_evidence_GETs=5)
    out = ROOT/'artifacts/task3'
    out.mkdir(parents=True,exist_ok=True)
    save(out/'full146-package-exact3-gate.json',receipt)
    save(out/'prior-full146-run.json',run);save(out/'prior-full146-jobs.json',jobs);save(out/'prior-full146-annotations.json',annotations)
    status = dict(source_commit=receipt['source_commit'], purpose='Package-only continuation of audited146 parent; not a new full run',
        qualification='TESTS NOT RUN', tests_run=False, full_regression_passed=False,
        full_test_gate='NOT RUN THIS BUILD; prior146 passed on identical App/Tests bytes',
        approved_changed_files=ALLOWED, app_candidate=BASE, product_test_source_commit=BASE,
        production_and_test_bytes_equal_parent=True, prior_full146_passed=True, prior_validation_run=RUN,
        prior_validation_attempt=1, prior_validation_source_commit=BASE, prior_validation_totals=TOTALS,
        prior_workflow_conclusion='cancelled', prior_package_blocker='JOB_35_MINUTE_TIMEOUT',
        native_tests_this_run=dict(status='not run',executions=0,selection=[]),native_execution=[],
        physical_device_acceptance='not performed',formal_release_approved=False,exact3_gate=receipt)
    save(ROOT/'artifacts/verification-status.json',status)
    print('::warning::TESTS NOT RUN in this build; audited prior146 passed; parent workflow cancelled at device build; physical acceptance not performed')
    print(json.dumps(dict(source_commit=receipt['source_commit'],product_test_source_commit=BASE,prior_full146_passed=True,native_tests_this_run=0),indent=2))


def self_check():
    before = tree(BASE)
    after = copy.deepcopy(before)
    for n in ALLOWED:after[n] = ['100644','blob','a'*40]
    head = 'b'*40
    env = dict(PACKAGE_SCOPE=SCOPE,GITHUB_REPOSITORY=prior.REPO,GITHUB_RUN_ATTEMPT='1',GITHUB_EVENT_NAME='workflow_dispatch',
        GITHUB_REF='refs/heads/main',GITHUB_WORKFLOW_REF=prior.REPO+'/'+DEVICE+'@refs/heads/main',GITHUB_SHA=head,
        GITHUB_WORKFLOW_SHA=head,HOST_VALIDATION_RUN_ID=str(RUN),GITHUB_RUN_ID='12345')
    state = dict(head=head,parents=[head,BASE],dirty=b'',before=before,after=after,
        working={n:dict(regular=True,blob=v[2]) for n,v in after.items()},index={n:[v[0],v[2],'0'] for n,v in after.items()},
        inputs=dict(package_scope=SCOPE,host_validation_run_id=str(RUN)))
    source_gate(env,state)
    mutations = [lambda e,s:e.update(GITHUB_RUN_ATTEMPT='2'),lambda e,s:e.update(HOST_VALIDATION_RUN_ID='1'),
        lambda e,s:e.update(GITHUB_WORKFLOW_SHA='c'*40),lambda e,s:e.update(PACKAGE_SCOPE='reader-dock-exact8'),
        lambda e,s:s.update(parents=[head,'c'*40]),lambda e,s:s.update(dirty=b'M App/x.swift'),
        lambda e,s:s['after']['App/ContentView.swift'].__setitem__(2,'c'*40),
        lambda e,s:s['index'][DEVICE].__setitem__(2,'1'),lambda e,s:s['working'][DEVICE].update(regular=False),
        lambda e,s:s['inputs'].update(host_validation_run_id='1')]
    rejected = 0
    for mutate in mutations:
        e,s = copy.deepcopy(env),copy.deepcopy(state)
        mutate(e,s)
        try:source_gate(e,s)
        except (ValueError,KeyError):rejected += 1
        else:raise AssertionError('Unsafe source mutation accepted')
    return dict(passed=True,source_positive=1,source_negative=rejected,native_tests_run=0)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    modes = p.add_mutually_exclusive_group(required=True)
    modes.add_argument('--self-check',action='store_true')
    modes.add_argument('--evidence-zip',type=Path)
    modes.add_argument('--device-package-gate',action='store_true')
    modes.add_argument('--fixed-dependency',action='store_true')
    a = p.parse_args()
    if a.self_check:print(json.dumps(self_check(),indent=2))
    elif a.evidence_zip:
        raw = a.evidence_zip.read_bytes()
        require(sha(raw) == ARCHIVE_SHA and len(raw) == 16855288,'Frozen local prior evidence differs')
        print(json.dumps(evidence_gate(zip_members(raw),parent_sources()),indent=2))
    elif a.device_package_gate:device_gate()
    else:fixed_dependency()


if __name__ == '__main__':main()
