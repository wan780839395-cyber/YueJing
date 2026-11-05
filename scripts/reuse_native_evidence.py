"""Reuse one reviewed native baseline for unchanged product inputs; never runs tests."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import unicodedata
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/task3'
EVIDENCE = ROOT / 'build/reused-native'
ARCHIVE = ROOT / 'build/reused-native.zip'
BASE = 'd2110a99f689d11f4afb2fb34a4cbecf54c7d0ae'
RUN = 41843348986
ARTIFACT = 13331969479
ARCHIVE_BYTES = 58796132
ARCHIVE_SHA256 = 'a9890310c8f31c1e726766da3829c3414e19d5f0d36b91a5568210d89d299ab3'
REPO = 'wan780839395-cyber/YueJing'
SCOPE = 'reuse-native-205-d2110a9'
# Only build-validation plumbing/documentation may differ. Product, tests,
# inventory, parser, build specification and both dependency pins remain exact.
ALLOWED = frozenset({
    '.github/workflows/task3-validate.yml', 'scripts/validate_task3.py',
    'scripts/check_task3_validation.py', 'docs/WEBKIT_STARTUP_REPAIR.md',
    'scripts/reuse_native_evidence.py', 'scripts/check_reuse_native_evidence.py',
    'docs/INCREMENTAL_IPA.md',
})


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    return json.loads(path.read_bytes())


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def command(args):
    return subprocess.check_output(args, cwd=ROOT, timeout=180)


def git(*args):
    return command(['git', *args])


def tree(revision):
    result = {}
    for row in git('ls-tree', '-r', '-z', revision).split(b'\0'):
        if row:
            metadata, name = row.split(b'\t', 1)
            result[name.decode('utf-8')] = metadata.decode('ascii').split()
    return result


def validate_scope(previous, current):
    changed = {p for p in previous.keys() | current.keys() if previous.get(p) != current.get(p)}
    require(changed <= ALLOWED, 'Uncovered product/test/build input change: ' + repr(sorted(changed - ALLOWED)))
    require(all(v[:2] == ['100644', 'blob'] for v in current.values()), 'Nonregular tracked input')
    return sorted(changed)


def validate_run(run, artifact):
    require(run['id'] == RUN and run['head_sha'] == BASE and run['run_attempt'] == 1
            and run['workflow_id'] == 398234793 and run['event'] == 'workflow_dispatch'
            and run['head_branch'] == 'main' and run['status'] == 'completed'
            and run['conclusion'] == 'failure', 'Unexpected baseline run identity')
    # The baseline's native groups passed; its later package gate failed.
    require(artifact['id'] == ARTIFACT and not artifact['expired']
            and artifact['name'] == f'task3-evidence-{RUN}-{BASE}'
            and artifact['workflow_run']['id'] == RUN
            and artifact['workflow_run']['head_sha'] == BASE
            and artifact['size_in_bytes'] == ARCHIVE_BYTES
            and artifact['digest'] == 'sha256:' + ARCHIVE_SHA256, 'Baseline artifact provenance mismatch')


def zip_members(archive):
    seen = set()
    files = {}
    with zipfile.ZipFile(archive) as source:
        require(sum(i.file_size for i in source.infolist()) < 4 * 1024**3, 'Expanded evidence exceeds bound')
        for info in source.infolist():
            name = info.filename
            parts = name.rstrip('/').split('/')
            alias = unicodedata.normalize('NFC', name.rstrip('/')).casefold()
            require(name == info.orig_filename and name and not name.startswith('/')
                    and '\\' not in name and ':' not in name
                    and all(p not in ('', '.', '..') for p in parts)
                    and not any(ord(c) < 32 for c in name)
                    and alias not in seen and not info.flag_bits & 1, 'Unsafe evidence ZIP member')
            seen.add(alias)
            require(stat.S_IFMT(info.external_attr >> 16) in
                    (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG), 'Evidence symlink/nonregular file')
            if not info.is_dir():
                data = source.read(info)
                files[name] = dict(bytes=len(data), sha256=digest(data))
        require(source.testzip() is None, 'Corrupt evidence ZIP')
    return files


def download():
    require(not EVIDENCE.exists() and not ARCHIVE.exists(), 'Evidence already exists; never replace')
    OUT.mkdir(parents=True, exist_ok=True)
    api = lambda suffix: json.loads(command(['gh', 'api', 'repos/' + REPO + suffix]))
    run = api(f'/actions/runs/{RUN}')
    artifact = api(f'/actions/artifacts/{ARTIFACT}')
    validate_run(run, artifact)
    save(OUT / 'reused-run.json', run)
    save(OUT / 'reused-artifact.json', artifact)
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    with ARCHIVE.open('xb') as target:
        subprocess.run(['gh', 'api', f'repos/{REPO}/actions/artifacts/{ARTIFACT}/zip'],
                       cwd=ROOT, stdout=target, check=True, timeout=600)
    require(ARCHIVE.stat().st_size == ARCHIVE_BYTES and digest(ARCHIVE.read_bytes()) == ARCHIVE_SHA256,
            'Downloaded baseline archive hash/size mismatch')
    members = zip_members(ARCHIVE)
    EVIDENCE.mkdir()
    with zipfile.ZipFile(ARCHIVE) as source:
        source.extractall(EVIDENCE)
    save(OUT / 'reused-members.json', members)


def validate_native(raw, receipt):
    require(raw['full_selected_passed'] and raw['selected'] == 205 and len(raw['groups']) == 8
            and raw['totals'] == dict(passed=205, failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0),
            'Baseline does not contain all 205 real passed cases')
    require(receipt['source_commit'] == BASE and str(receipt['run_id']) == str(RUN)
            and str(receipt['run_attempt']) == '1' and receipt['passed']
            and receipt['native_passed'] == receipt['verified_passed'] == 205
            and all(receipt[k] == 0 for k in ('failed', 'skipped', 'unexecuted', 'unverified')),
            'Baseline native receipt mismatch')
    require(len(receipt['groups']) == 8, 'Native receipt group count')
    for group in raw['groups']:
        recorded = next(g for g in receipt['groups'] if g['target'] == group['target'])
        require(set(recorded['passed']) == {c['name'] for c in group['cases']}
                and recorded['log_sha256'] == group['raw_sha256'], 'Baseline case/log receipt mismatch')


def verify(evidence=EVIDENCE, *, require_download=True, require_dependencies=False):
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and os.environ.get('GITHUB_REF') == 'refs/heads/main'
            and os.environ.get('VALIDATION_SCOPE') == SCOPE, 'Unapproved reuse invocation')
    sha = os.environ['GITHUB_SHA']
    require(git('rev-parse', 'HEAD').decode().strip() == sha, 'Checkout identity')
    git('merge-base', '--is-ancestor', BASE, 'HEAD')
    previous, current = tree(BASE), tree('HEAD')
    changes = validate_scope(previous, current)
    for name, metadata in current.items():
        path = ROOT / name
        require(path.is_file() and not path.is_symlink(), 'Nonregular worktree input')
        data = path.read_bytes()
        require(hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == metadata[2],
                'Worktree differs from committed blob: ' + name)
    if require_download:
        validate_run(load(OUT / 'reused-run.json'), load(OUT / 'reused-artifact.json'))
        require(ARCHIVE.stat().st_size == ARCHIVE_BYTES and digest(ARCHIVE.read_bytes()) == ARCHIVE_SHA256,
                'Retained archive drift')
        expected = load(OUT / 'reused-members.json')
        actual = {p.relative_to(evidence).as_posix(): dict(bytes=p.stat().st_size, sha256=digest(p.read_bytes()))
                  for p in evidence.rglob('*') if p.is_file()}
        require(actual == expected, 'Extracted baseline drift')
    source = load(evidence / 'task3/candidate-sources.json')
    require(source['source_commit'] == BASE and str(source['run_id']) == str(RUN)
            and str(source['run_attempt']) == '1', 'Baseline source provenance')
    for name, expected in source['files'].items():
        if name not in ALLOWED:
            require(digest((ROOT / name).read_bytes()) == expected, 'Tested input drift: ' + name)
    import audit_native_case_events
    raw = audit_native_case_events.audit_evidence(evidence, BASE, RUN)
    validate_native(raw, load(evidence / 'task3/native-test-gate.json'))
    for name in ('decoder-comparison.json', 'processing-measurements.json'):
        require(load(evidence / 'task3' / name)['source_commit'] == BASE, 'Baseline measurement provenance')
    tool = (evidence / 'task3/toolchain.log').read_text(encoding='utf-8')
    require(all(t in tool for t in ('Xcode 16.4', 'Build version 16F6', 'Apple Swift version 6.1.2', 'arm64'))
            and (evidence / 'task3/xcodegen.log').read_text().strip() == 'Version: 2.46.0', 'Baseline toolchain')
    packages = load(evidence / 'task3/dependency-resolution.json')['packages']
    if require_dependencies:
        require(load(OUT / 'dependency-resolution.json')['packages'] == packages, 'Resolved dependency drift')
    return dict(qualification='REUSED_NATIVE_205_DEVICE_BUILD_ONLY', source_commit=sha,
                run_id=os.environ['GITHUB_RUN_ID'], run_attempt='1', native_tests_executed_this_run=0,
                reused_native_passed=205, tested_source_commit=BASE, tested_run_id=str(RUN), tested_run_attempt='1',
                baseline_workflow_conclusion='failure_after_native_success', artifact_id=ARTIFACT,
                artifact_sha256=ARCHIVE_SHA256, changed_paths=changes, native_totals=raw['totals'],
                packages=packages, prior_incomplete_run='41943152123: 204 passed, final TXT UI case unfinished at 1200s group deadline; not erased or claimed passed in that run',
                rationale='Product/resources/tests/project/dependency definitions and test parser/inventory unchanged; changes restricted to package validation plumbing/docs')


def validate_saved():
    receipt = verify(require_dependencies=True)
    require(load(OUT / 'reused-native-gate.json') == receipt, 'Reuse gate receipt drift')
    return receipt


def qualify():
    receipt = verify(require_dependencies=True)
    save(OUT / 'reused-native-gate.json', receipt)
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    try:
        {'download': download, 'qualify': qualify}[sys.argv[1]]()
    except (ValueError, OSError, KeyError, StopIteration, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print('Native evidence reuse stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
