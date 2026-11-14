"""Bounded Task3 development execution. Never a release qualification source."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import subprocess
import time

import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
SCOPE = 'development-targeted'
PLAN = 'scripts/development_scope.json'
SCHEMES = {'ReaderDomainTests': 'ReaderDomain', 'YueJingHostTests': 'YueJingHost',
           'YueJingEPUBUITests': 'YueJingEPUBUI'}
PACKAGE_TARGETS = {'GRDB', 'GRDB_GRDB', 'CSQLite', 'ZIPFoundation', 'ZIPFoundation_ZIPFoundation'}
DEPENDENCIES = {'ReaderDomain': {'TXTCore', 'ReaderDomain', 'ReaderDomainTests'} | PACKAGE_TARGETS,
                'YueJingHost': {'TXTCore', 'ReaderDomain', 'YueJing', 'YueJingHostTests'} | PACKAGE_TARGETS,
                'YueJingEPUBUI': {'TXTCore', 'ReaderDomain', 'YueJing', 'YueJingEPUBUITests'} | PACKAGE_TARGETS}

class BudgetExhausted(RuntimeError):
    """Must stop scheduling; not an ordinary per-group I/O failure."""

def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    with Path(path).open('x', encoding='utf-8') as out:
        json.dump(value, out, indent=2, ensure_ascii=False)
        out.write('\n')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode('utf-8').strip()


def select(plan):
    require(set(plan) == {'schema', 'scope', 'branch', 'cases', 'build_timeout_seconds',
                         'test_timeout_seconds', 'case_timeout_seconds', 'total_timeout_seconds'}, 'Plan fields differ')
    require(plan['schema'] == 1 and plan['scope'] == SCOPE, 'Unknown development scope/schema')
    require(re.fullmatch(r'dev/[A-Za-z0-9][A-Za-z0-9_/-]{0,79}', plan['branch']) is not None
            and '..' not in plan['branch'] and '//' not in plan['branch'], 'Unapproved development branch')
    for key, upper in [('build_timeout_seconds', 900), ('test_timeout_seconds', 480),
                       ('case_timeout_seconds', 180), ('total_timeout_seconds', 3000)]:
        require(type(plan[key]) is int and 0 < plan[key] <= upper, 'Invalid budget: ' + key)
    require(plan['case_timeout_seconds'] <= plan['test_timeout_seconds'] <= plan['total_timeout_seconds']
            and plan['build_timeout_seconds'] <= plan['total_timeout_seconds'], 'Inconsistent budgets')
    require(isinstance(plan['cases'], list) and 0 < len(plan['cases']) <= 24, 'Select 1..24 exact declarations')
    specs, seen = [], set()
    for row in plan['cases']:
        require(isinstance(row, dict) and set(row) == {'file', 'name'}, 'Malformed case')
        rel, name = row['file'], row['name']
        require(isinstance(rel, str) and isinstance(name, str) and rel in inventory.FILES
                and name in inventory.FILES[rel].split(), 'Unknown declaration')
        target = rel.split('/')[0]
        require(target in SCHEMES and (rel, name) not in seen, 'Unsupported/duplicate declaration')
        seen.add((rel, name))
        kind = 'ui' if target == 'YueJingEPUBUITests' else ('host' if target == 'YueJingHostTests' else 'domain')
        specs.append(dict(target=target, scheme=SCHEMES[target], kind=kind, pairs=[(rel, name)], cases=[name]))
    return specs


def selection_summary(plan):
    specs = select(plan)
    return dict(qualification='DEVELOPMENT_ONLY', release_qualified=False, selected_declarations=len(specs),
                planned_executions=sum(len(inventory.PARAMETERIZED.get(s['cases'][0], {}).get('values', [None])) for s in specs),
                native_executions=None, selected=plan['cases'],
                not_selected_declarations=inventory.TOTAL-len(specs))


def check_identity(plan, env, head, clean, digest):
    select(plan)
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1', 'Development event/attempt differs')
    require(env.get('GITHUB_REF') == 'refs/heads/' + plan['branch'], 'Unapproved branch')
    require(re.fullmatch('[0-9a-f]{40}', head) is not None and head == env.get('GITHUB_SHA')
            == env.get('DEVELOPMENT_SOURCE_SHA'), 'Source identity drift')
    require(re.fullmatch('[0-9a-f]{64}', digest) is not None and digest == env.get('DEVELOPMENT_PLAN_SHA256'), 'Selection/plan digest drift')
    require(env.get('VALIDATION_SCOPE') == SCOPE and env.get('BUILD_IPA', 'false') == 'false'
            and env.get('ALLOW_UNQUALIFIED_IPA', 'false') == 'false'
            and not env.get('PRIOR_VALIDATION_RUN', ''), 'Development cannot package or reuse release evidence')
    require(clean and re.fullmatch('[1-9][0-9]*', env.get('GITHUB_RUN_ID', '')) is not None, 'Dirty checkout/run identity')


def preflight(root=ROOT):
    path = root / PLAN
    require(path.is_file() and not path.is_symlink(), 'Missing regular plan')
    plan = json.loads(path.read_text(encoding='utf-8'))
    inventory.validate_source(root)
    check_identity(plan, os.environ, git(root, 'rev-parse', 'HEAD'),
                   not git(root, 'status', '--porcelain', '--untracked-files=all'), sha(path))
    return plan


def tracked_fingerprints(root):
    result = {}
    for name in git(root, 'ls-files', '-z').split('\0'):
        if name:
            path = root / name
            require(path.is_file() and not path.is_symlink(), 'Nonregular source: ' + name)
            result[name] = sha(path)
    return result


def tree_fingerprints(folder):
    require(folder.is_dir() and not folder.is_symlink(), 'Missing products')
    result = {}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():
            require(path.resolve().is_relative_to(folder.resolve()), 'Escaping product symlink')
            result[path.relative_to(folder).as_posix()] = {'link': os.readlink(path)}
        elif path.is_file():
            result[path.relative_to(folder).as_posix()] = sha(path)
    require(result, 'Empty products')
    return result


def dependency_link_identity(folder, path):
    relative = path.relative_to(folder).as_posix()
    rows = [row for row in git(folder, 'ls-tree', '-z', 'HEAD', '--', relative).split('\0') if row]
    require(len(rows) == 1, 'Dependency link is not uniquely tracked: '+relative)
    meta, recorded_path = rows[0].split('\t', 1)
    fields = meta.split()
    require(len(fields) == 3 and fields[:2] == ['120000', 'blob'] and recorded_path == relative
            and re.fullmatch('[0-9a-f]{40}', fields[2]), 'Dependency link mode/identity differs: '+relative)
    raw = subprocess.check_output(['git', '-C', str(folder), 'cat-file', 'blob', fields[2]], timeout=30)
    require(len(raw) <= 4096 and hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest() == fields[2],
            'Dependency link blob differs: '+relative)
    target = os.readlink(path)
    require(target.encode('utf-8') == raw and not Path(target).is_absolute(), 'Dependency link target differs: '+relative)
    resolved = (path.parent/target).resolve(strict=True)
    base = folder.resolve(strict=True)
    require(resolved.is_relative_to(base) and '.git' not in resolved.relative_to(base).parts,
            'Dependency link escapes source: '+relative)
    require(resolved.is_file() or resolved.is_dir(), 'Invalid dependency link destination')
    return dict(link=target, git_blob=fields[2], resolved=resolved.relative_to(base).as_posix())


def dependency_entries(folder):
    # GRDB's official Tests/CustomSQLite/GRDB points to ../.. . Never follow it.
    stack = [folder]
    while stack:
        parent = stack.pop()
        require(not parent.is_symlink() and not getattr(parent, 'is_junction', lambda: False)(),
                'Linked dependency directory during traversal')
        for path in sorted(parent.iterdir()):
            if path.name == '.git':
                continue
            require(not getattr(path, 'is_junction', lambda: False)(), 'Dependency junction refused')
            if path.is_symlink():
                yield path
            elif path.is_dir():
                stack.append(path)
            else:
                require(path.is_file(), 'Nonregular dependency input: '+str(path))
                yield path


def dependency_fingerprints(root):
    checkouts = root/'build/SourcePackages/checkouts'
    require(checkouts.is_dir() and not checkouts.is_symlink(), 'Missing dependency checkouts')
    folders = sorted(checkouts.iterdir())
    require({p.name.lower() for p in folders} == {'grdb.swift', 'zipfoundation'}, 'Unexpected dependency closure')
    result = {}
    for folder in folders:
        require(folder.is_dir() and not folder.is_symlink(), 'Nonregular dependency checkout')
        files = {}
        for path in dependency_entries(folder):
            rel = path.relative_to(folder).as_posix()
            files[rel] = dependency_link_identity(folder, path) if path.is_symlink() else sha(path)
        require(files, 'Empty dependency checkout')
        result[folder.name.lower()] = dict(head=git(folder,'rev-parse','HEAD'),files=files)
    return result


def build_identity(root, plan, destination, scheme, tools):
    require(re.fullmatch(r'platform=iOS Simulator,id=[0-9a-fA-F-]{36}', destination) is not None, 'Invalid simulator destination')
    resolved = root / 'YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    project = root / 'YueJing.xcodeproj/project.pbxproj'
    generated_scheme = root/'YueJing.xcodeproj/xcshareddata/xcschemes'/f'{scheme}.xcscheme'
    return dict(source=tracked_fingerprints(root), source_commit=git(root,'rev-parse','HEAD'),
                dependencies=dependency_fingerprints(root), plan=plan, destination=destination, scheme=scheme,
                configuration='Debug', architecture='arm64', tools=tools,
                resolved_sha256=sha(resolved), generated_project_sha256=sha(project),
                generated_scheme_sha256=sha(generated_scheme))


def validate_build(receipt, identity, products):
    require(receipt.get('status') == 'passed' and receipt.get('identity') == identity, 'Build identity invalidated')
    require(receipt.get('products') == tree_fingerprints(products), 'Build product bytes drift')


def build_command(scheme, destination, derived, bundle):
    return ['xcodebuild', 'build-for-testing', '-project', 'YueJing.xcodeproj', '-scheme', scheme,
            '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', destination,
            '-derivedDataPath', str(derived), '-clonedSourcePackagesDirPath', 'build/SourcePackages',
            '-disableAutomaticPackageResolution', '-skipPackageUpdates', '-onlyUsePackageVersionsFromResolvedFile',
            '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle),
            'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES']


def test_command(spec, destination, derived, bundle, case_timeout):
    rel, name = spec['pairs'][0]
    selector = rel.removesuffix('.swift') + '/' + name
    if spec['kind'] != 'ui':
        selector += inventory.PARAMETERIZED.get(name, {}).get('signature', '()')
    return ['xcodebuild', 'test-without-building', '-project', 'YueJing.xcodeproj', '-scheme', spec['scheme'],
            '-configuration', 'Debug', '-destination', destination, '-derivedDataPath', str(derived),
            '-clonedSourcePackagesDirPath', 'build/SourcePackages', '-disableAutomaticPackageResolution',
            '-skipPackageUpdates', '-onlyUsePackageVersionsFromResolvedFile', '-only-testing:' + selector,
            '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle), '-test-timeouts-enabled', 'YES',
            '-default-test-execution-time-allowance', str(case_timeout),
            '-maximum-test-execution-time-allowance', str(case_timeout), 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64']


def failed_targets(text, scheme):
    # Only target-bearing actual error lines justify blocking another scheme.
    targets = set(re.findall(r"[^\n]*\berror: [^\n]*\(in target '([^']+)' from project", text))
    return targets & DEPENDENCIES[scheme]


def export_results(folder, bundle, *, deadline, root, runner):
    """Copy raw xcresult before queries; one deadline and the shared process tree owner."""
    def remaining():
        value = deadline-time.monotonic()
        if value <= 0:
            raise BudgetExhausted('No total budget remains for xcresult export')
        return value
    remaining()
    temporary_root = os.environ.get('PI_SCRATCH_DIR') or os.environ.get('RUNNER_TEMP')
    require(temporary_root, 'A dedicated scratch directory is required for xcresult copies')
    with tempfile.TemporaryDirectory(prefix='development-xcresult-',dir=temporary_root) as temp:
        working = Path(temp)/bundle.name
        def copy_bounded(src,dst):
            require(not Path(src).is_symlink(), 'Unexpected xcresult symlink')
            remaining()
            with open(src,'rb') as source, open(dst,'xb') as target:
                while True:
                    remaining()
                    chunk=source.read(1024*1024)
                    if not chunk:break
                    target.write(chunk)
            return dst
        require(bundle.is_dir() and not bundle.is_symlink()
                and not getattr(bundle, 'is_junction', lambda: False)(), 'Invalid raw xcresult bundle')
        for path in bundle.rglob('*'):
            remaining()
            require(not path.is_symlink() and not getattr(path, 'is_junction', lambda: False)(),
                    'Linked xcresult input refused')
        shutil.copytree(bundle,working,copy_function=copy_bounded)
        failures = []
        for section in ('tests','summary'):
            budget=min(60,remaining())
            path=folder/f'xcresult-{section}.json'
            try:
                code,timed_out=runner(['xcrun','xcresulttool','get','test-results',section,'--path',str(working)],path,budget,cwd=root)
                require(code == 0 and not timed_out, 'xcresult export failed: '+section)
                json.loads(path.read_text(encoding='utf-8'))
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                failures.append(section+': '+str(error))
            remaining()
        require(not failures, '; '.join(failures))


def execute(plan, destination, output, *, root=ROOT, runner=None, identity_factory=None, parser=None, exporter=None):
    from workflow_process import run_logged, ProcessCleanupError
    from workflow_failure_details import failure_details
    import run_epub_freeze_validation as freeze
    runner = runner or run_logged
    parser = parser or freeze.parse_log_for_spec
    exporter = exporter or export_results
    specs = select(plan)
    output.mkdir(parents=True, exist_ok=False)
    result = dict(**selection_summary(plan), builds=[], cases=[], timing={'queue_seconds': None,
                  'runner_startup_seconds': None, 'upload_seconds': None}, platform=os.name,
                  provenance={key: os.environ.get(env, 'unknown') for key, env in
                              [('source_commit','GITHUB_SHA'), ('run_id','GITHUB_RUN_ID'), ('run_attempt','GITHUB_RUN_ATTEMPT')]},
                  approved_plan_sha256=os.environ.get('DEVELOPMENT_PLAN_SHA256','unknown'),
                  plan_canonical_sha256=hashlib.sha256(json.dumps(plan,sort_keys=True).encode()).hexdigest())
    start = time.monotonic()
    builds, broken = {}, set()
    current = active_record = None
    frozen_identities = {}
    def identity_for(scheme):
        current_identity = identity_factory(scheme)
        if current_identity != frozen_identities[scheme]:
            raise RuntimeError('Execution-wide input identity drift: '+scheme)
        return current_identity
    def stop_record(record, status, error=None):
        if record is None:
            return
        if record['status'] not in ('failed', 'timed_out'):
            record['status'] = status
        if error is not None:
            message = str(error) or type(error).__name__
            if 'error' not in record:
                record['error'] = message
            elif record['error'] != message and message not in record.get('secondary_errors', []):
                record.setdefault('secondary_errors', []).append(message)

    def invoke(cmd, log, budget, record):
        nonlocal active_record
        remaining = plan['total_timeout_seconds'] - (time.monotonic() - start)
        if remaining <= 0:
            raise BudgetExhausted('Development total budget exhausted')
        active_record = record
        before = time.monotonic()
        record.update(command=cmd, invocation_started=True, status='running',
                      timeout_seconds_used=min(budget, remaining))
        try:
            code, timeout = runner(cmd, log, min(budget, remaining), cwd=root)
            record.update(exit_code=code, timed_out=timeout,
                          status='timed_out' if timeout else ('failed' if code else 'passed'))
            return dict(exit_code=code, timed_out=timeout, command=cmd)
        except BaseException as error:
            stop_record(record, 'cancelled' if isinstance(error, (KeyboardInterrupt, SystemExit)) else 'failed', error)
            raise
        finally:
            record['elapsed_seconds'] = time.monotonic()-before
    try:
        source_anchor = tracked_fingerprints(root) if identity_factory is None else None
        if identity_factory is None:
            from workflow_tools import inspect_toolchain
            tools = inspect_toolchain(root, output/'tools')
            identity_factory = lambda scheme: build_identity(root,plan,destination,scheme,tools)
        frozen_identities.update({s:copy.deepcopy(identity_factory(s)) for s in dict.fromkeys(x['scheme'] for x in specs)})
        if source_anchor is not None and any(v['source'] != source_anchor for v in frozen_identities.values()):
            raise RuntimeError('Source changed during execution preparation')
        write_json(output/'frozen-inputs.json', frozen_identities)
        for index, spec in enumerate(specs):
            active_record = None
            current = dict(index=index, name=spec['cases'][0], target=spec['target'], status='not_run')
            result['cases'].append(current)
            scheme = spec['scheme']
            blocked = sorted(DEPENDENCIES[scheme] & broken)
            if blocked:
                current.update(status='blocked', blocked_by=blocked)
                continue
            derived = root / 'build/development' / scheme
            products = derived / 'Build/Products'
            folder = output / f'case-{index+1:02d}'
            folder.mkdir()
            if scheme not in builds:
                build = dict(scheme=scheme, status='not_run')
                builds[scheme] = build
                result['builds'].append(build)
                active_record = build
                build_folder = output / ('build-' + scheme)
                build_folder.mkdir()
                try:
                    require(not derived.exists(), 'Refuse stale DerivedData; use a fresh checkout')
                    identity = identity_for(scheme)
                    build.update(invoke(build_command(scheme, destination, derived, build_folder/'build.xcresult'),
                                        build_folder/'native.log', plan['build_timeout_seconds'], build))
                    identity_for(scheme)
                    if build['exit_code'] != 0 or build['timed_out']:
                        build['status'] = 'timed_out' if build['timed_out'] else 'failed'
                        broken.update(failed_targets((build_folder/'native.log').read_text(encoding='utf-8', errors='replace'), scheme))
                    else:
                        identity_for(scheme)
                        build.update(status='passed', identity=identity, products=tree_fingerprints(products))
                except (ValueError, OSError, subprocess.SubprocessError) as exc:
                    stop_record(build, 'failed', exc)
                write_json(build_folder/'receipt.json', build)
                if build['status'] != 'passed':
                    build['failure_details'] = failure_details('build-'+scheme, logs=[build_folder/'native.log'],
                        receipts=[build_folder/'receipt.json'], provenance=result['provenance'])
            if builds[scheme]['status'] != 'passed':
                current.update(status='blocked', blocked_by=['build-' + scheme])
                continue
            try:
                active_record = current
                validate_build(builds[scheme], identity_for(scheme), products)
                command = test_command(spec, destination, derived, folder/'test.xcresult', plan['case_timeout_seconds'])
                current['status'] = 'running'
                current.update(invoke(command, folder/'native.log', plan['test_timeout_seconds'], current))
                raw = (folder/'native.log').read_bytes()
                text = raw.decode('utf-8', errors='replace')
                current['case_timed_out'] = 'exceeded execution time allowance' in text
                current['status'] = 'timed_out' if current['timed_out'] or current['case_timed_out'] else ('failed' if current['exit_code'] else 'passed')
                identity_for(scheme)
                if (folder/'test.xcresult').is_dir():
                    before_export = time.monotonic()
                    exporter(folder, folder/'test.xcresult', deadline=start+plan['total_timeout_seconds'], root=root, runner=runner)
                    current['export_seconds'] = time.monotonic()-before_export
                if current['status'] == 'passed':
                    validate_build(builds[scheme], identity_for(scheme), products)
                    counts = parser(str(index), spec, raw, current['exit_code'], current['timed_out'])
                    require((folder/'test.xcresult').is_dir(), 'Missing native xcresult')
                    if spec['cases'][0] in inventory.PARAMETERIZED:
                        freeze.parameter_result(json.loads((folder/'xcresult-tests.json').read_text(encoding='utf-8')))
                    current['executions'] = counts['executions']
                    current['test_body_seconds'] = sum(float(v) for v in re.findall(r'(?:passed after |passed \()([0-9.]+) seconds?', text))
                    write_json(folder/'counts.json', counts)
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                current.update(status='timed_out' if current.get('timed_out') or current.get('case_timed_out') else 'failed', error=str(exc))
            write_json(folder/'execution.json', current)
            if current['status'] != 'passed':
                current['failure_details'] = failure_details(current['name'], logs=[folder/'native.log'],
                    receipts=[folder/'execution.json'], summaries=[folder/'xcresult-summary.json'] if (folder/'xcresult-summary.json').is_file() else [],
                    provenance=result['provenance'])
    except (KeyboardInterrupt, SystemExit):
        stop_record(active_record, 'cancelled')
        stop_record(current, 'cancelled')
        result['stopped_reason'] = 'cancelled'
        raise
    except BudgetExhausted as exc:
        stop_record(active_record, 'blocked', exc)
        if current is not None and current['status'] not in ('failed', 'timed_out', 'cancelled'):
            current.update(status='blocked' if current.get('invocation_started') else 'not_run', error=str(exc))
        result['stopped_reason'] = 'budget_exhausted'
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        result['stopped_reason'] = 'preparation_or_evidence_error'
        result['error'] = str(exc)
        stop_record(current, 'failed', exc)
    except (RuntimeError, ProcessCleanupError) as exc:
        stop_record(active_record, 'failed' if isinstance(exc, ProcessCleanupError) else 'blocked', exc)
        stop_record(current, 'blocked', exc)
        result['stopped_reason'] = 'fatal_environment_or_cleanup'
        raise
    finally:
        for index in range(len(result['cases']), len(specs)):
            result['cases'].append(dict(index=index, name=specs[index]['cases'][0], status='not_run',
                                        reason=result.get('stopped_reason', 'execution_stopped')))
        # Interrupted/blocked selections still get immutable per-item receipts.
        for row in result['builds']:
            if row['status'] == 'running':
                row.update(status='failed', error='execution aborted without a terminal result')
            receipt = output/('build-'+row['scheme'])/'receipt.json'
            if not receipt.exists():
                write_json(receipt, row)
        for row in result['cases']:
            if row['status'] == 'running':
                row.update(status='failed', error='execution aborted without a terminal result')
            folder = output/f'case-{row["index"]+1:02d}'
            folder.mkdir(exist_ok=True)
            if not (folder/'execution.json').exists():
                write_json(folder/'execution.json', row)
        result['timing']['execution_total_seconds'] = time.monotonic()-start
        result['native_executions'] = sum(r.get('executions', 0) for r in result['cases']) if all(r['status']=='passed' for r in result['cases']) else None
        result['observed_passed_executions'] = sum(r.get('executions', 0) for r in result['cases'] if r['status']=='passed')
        result['status'] = 'passed' if all(r['status']=='passed' for r in result['cases']) else 'failed'
        write_json(output/'development-summary.json', result)
    return result

def prepare_runtime(root=ROOT):
    from workflow_process import run_logged
    import validate_task3 as validation
    output = root/'artifacts/development/runtime'
    output.mkdir(parents=True, exist_ok=False)
    (root/'artifacts/task3').mkdir(parents=True, exist_ok=True)
    times = {}
    def run(label, command, budget):
        started = time.monotonic()
        code, timeout = run_logged(command, output/(label+'.log'), budget, cwd=root)
        times[label] = dict(elapsed_seconds=time.monotonic()-started, exit_code=code, timed_out=timeout)
        require(code == 0 and not timeout, 'Runtime preparation failed: '+label)
    try:
        run('dependencies', ['xcodebuild', '-resolvePackageDependencies', '-project', 'YueJing.xcodeproj',
                             '-scheme', 'YueJing', '-clonedSourcePackagesDirPath', 'build/SourcePackages'], 300)
        validation.resolved()
        for kind in ('devices', 'runtimes'):
            command = ['xcrun', 'simctl', 'list', kind] + (['available'] if kind == 'devices' else []) + ['-j']
            run(kind, command, 30)
            (root/'artifacts/task3'/f'{kind}.json').write_bytes((output/(kind+'.log')).read_bytes())
        validation.select_simulator()
        selected = json.loads((root/'artifacts/task3/simulator-selection.json').read_text())
        udid = selected['udid']
        devices = json.loads((output/'devices.log').read_text())['devices']
        state = next(d['state'] for group in devices.values() for d in group if d['udid'] == udid)
        if state != 'Booted':
            run('simulator-boot', ['xcrun', 'simctl', 'boot', udid], 30)
        run('simulator-ready', ['xcrun', 'simctl', 'bootstatus', udid, '-b'], 120)
    finally:
        write_json(output/'timing.json', times)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('action', choices=['preflight', 'run', 'selection', 'prepare-runtime'])
    ap.add_argument('--destination')
    ap.add_argument('--output', type=Path, default=ROOT/'artifacts/development/execution')
    args = ap.parse_args()
    if args.action == 'selection':
        inventory.validate_source(ROOT)
        print(json.dumps(selection_summary(json.loads((ROOT/PLAN).read_text())), indent=2))
        return
    plan = preflight()
    if args.action == 'preflight':
        print(json.dumps(selection_summary(plan), indent=2))
        return
    if args.action == 'prepare-runtime':
        prepare_runtime()
        return
    result = execute(plan, args.destination, args.output)
    raise SystemExit(0 if result['status']=='passed' else 1)

if __name__ == '__main__':
    main()
