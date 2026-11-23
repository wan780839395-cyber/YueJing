"""Device-only scopes. The separate development run is never a packaging credential."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple

from package_ipa import expected_project_identity
import validate_task3 as v

SCOPE, VERSION, BUILD = 'bookmark-device-028', '0.2.28', '30'
BASE = '765fc4e1f09b1d09554b60e2016b1b34bc9aabbb'
PLAN = '6a618ed99773c0f2ff626c633cefd08b60b1c3a9f60a5c4106a96ac82d780e2d'
REF = 'refs/heads/dev/workflow-optimization'
SEARCH = 'search-device-029'
SEARCH_RETURN = 'search-return-device-030'


class Batch(NamedTuple):
    version: str
    build: str
    base: str
    plan: str


BATCHES = {SCOPE: Batch(VERSION, BUILD, BASE, PLAN),
           SEARCH: Batch('0.2.29', '31', '13bb9b05d6dac14a55e5f34b9f683b4b869331df',
                         '5ff8ec571ff8d613554103737af40096b4bc60eb9c4adbb6b9f7cb65d67d51f8'),
           SEARCH_RETURN: Batch('0.2.30', '32', '7f110bbeb257fea29ec3a7f165e68bcca961f179', '5fed7bbeec3d1432ad6a0ac1c928f7b34f997c35c6daf649ad887cbb1ce7774f')}
# Both search checkouts need MAX_SEARCH_COMMITS + 1 commits, including the base.
MAX_SEARCH_COMMITS = 8
SEARCH_PATHS = frozenset(('.github/workflows/task3-validate.yml', 'project.yml', 'scripts/workflow_tools.py',
                          'scripts/workflow_admission.py', 'scripts/bookmark_device_package.py',
                          'scripts/epub_diagnostic_package.py', 'scripts/package_ipa.py', 'scripts/validate_task3.py',
                          'scripts/workflow_development.py'))
RETURN_PATHS = frozenset(('.github/workflows/task3-validate.yml', 'project.yml', 'scripts/workflow_tools.py',
                          'scripts/workflow_admission.py', 'scripts/bookmark_device_package.py',
                          'scripts/epub_diagnostic_package.py', 'scripts/package_ipa.py'))


def identity(source, run_id, scope=SCOPE):
    batch = BATCHES[scope]
    v.require(re.fullmatch('[0-9a-f]{40}', batch.base) and re.fullmatch('[0-9a-f]{64}', batch.plan),
              'Device scope has no frozen product SHA and plan SHA256')
    v.require(re.fullmatch('[0-9a-f]{40}', source) and re.fullmatch('[1-9][0-9]*', run_id),
              'Expected full commit and positive device run ID')
    return dict(scope=scope, version=batch.version, build=batch.build, source_commit=source, base_commit=batch.base,
                ref=REF, plan_sha256=batch.plan, run_id=run_id, run_attempt='1', job='epub_diagnostic',
                qualification='DEVICE_DIAGNOSTIC_ONLY', coverage='UI_NOT_QUALIFIED',
                native_tests_executed_this_job=0, full_regression_passed=False, release_qualified=False,
                build_ipa=True, allow_unqualified_ipa=True, validation_reference=None,
                physical_acceptance='not performed')


def git(*args):
    return subprocess.check_output(['git', *args], cwd=v.ROOT, timeout=30).decode()


def check_search_chain(source, base, *, max_commits=MAX_SEARCH_COMMITS, paths=SEARCH_PATHS):
    current = source
    for _ in range(max_commits):
        lineage = git('rev-list', '--parents', '-n1', current).split()
        v.require(len(lineage) == 2 and lineage[0] == current, 'Missing search parent or unexpected merge')
        parent = lineage[1]
        # Check each edge, not just the endpoint diff: out-of-scope edits reverted later still fail.
        raw = git('diff-tree', '--no-commit-id', '--raw', '-r', '-z', '--no-renames', parent, current)
        entries = raw.split('\0')
        v.require(len(entries) >= 3 and len(entries) % 2 == 1 and entries[-1] == '', 'Empty or invalid search change')
        for meta, path in zip(entries[0:-1:2], entries[1:-1:2]):
            v.require(path in paths and meta.split()[:2] == [':100644', '100644'] and meta.endswith(' M'),
                      'Expected only edits of approved ordinary files in search candidate history')
        if parent == base:
            return
        current = parent
    raise ValueError('Frozen search base is outside permitted repair chain')


def scope_receipt():
    env = os.environ
    scope = env.get('VALIDATION_SCOPE')
    v.require(scope in BATCHES and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
              and env.get('GITHUB_REPOSITORY') == 'wan780839395-cyber/YueJing' and env.get('GITHUB_REF') == REF
              and env.get('GITHUB_RUN_ATTEMPT') == '1' and env.get('GITHUB_JOB') in ('admission', 'epub_diagnostic')
              and env.get('BUILD_IPA') == env.get('ALLOW_UNQUALIFIED_IPA') == 'true', 'Device dispatch identity differs')
    batch = BATCHES[scope]
    source = env['GITHUB_SHA']
    receipt = identity(source, env['GITHUB_RUN_ID'], scope)
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    v.require(inputs.get('validation_scope') == inputs.get('scope_acknowledgement') == scope
              and inputs.get('development_source_sha') == source and inputs.get('development_plan_sha256') == batch.plan
              and str(inputs.get('build_ipa')).lower() == str(inputs.get('allow_unqualified_ipa')).lower() == 'true'
              and not inputs.get('prior_validation_run'), 'Device dispatch inputs differ')
    v.require(git('rev-parse', 'HEAD').strip() == source and not git('status', '--porcelain', '--untracked-files=all'),
              'Expected a clean checkout of the approved candidate')
    if scope == SEARCH:
        check_search_chain(source, batch.base)
    elif scope == SEARCH_RETURN:
        check_search_chain(source, batch.base, max_commits=1, paths=RETURN_PATHS)
    else:
        v.require(git('rev-list', '--parents', '-n1', 'HEAD').split() == [source, batch.base],
                  'Expected exact direct child of bookmark base')
    project = expected_project_identity()
    v.require((project['version'], project['build']) == (batch.version, batch.build)
              and v.digest(v.ROOT / 'scripts/development_scope.json') == batch.plan, 'Version, build or plan drift')
    return receipt


def check_gate(scope, hashes):
    from userfont_package import check_release_gate
    gate = v.OUT / 'app-dependency-gate.json'
    check_release_gate(gate, {'device_scope': scope}, dict(source_commit=scope['source_commit'], signing='unsigned'), hashes)
    return v.digest(gate)


if __name__ == '__main__':
    commands = {'verify-download': SCOPE, 'verify-search-download': SEARCH,
                'verify-search-return-download': SEARCH_RETURN}
    if len(sys.argv) != 6 or sys.argv[1] not in commands:
        sys.exit('usage: bookmark_device_package.py {' + '|'.join(commands) + '} EXTRACTED_DIR SOURCE_SHA DEVICE_RUN_ID IPA_SHA256')
    from epub_diagnostic_package import verify_download
    verify_download(*sys.argv[2:], device_scope=commands[sys.argv[1]])
