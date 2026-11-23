"""Device-only scope. The separate development run is never a packaging credential."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from package_ipa import expected_project_identity
import validate_task3 as v

SCOPE, VERSION, BUILD = 'bookmark-device-028', '0.2.28', '30'
BASE = '765fc4e1f09b1d09554b60e2016b1b34bc9aabbb'
PLAN = '6a618ed99773c0f2ff626c633cefd08b60b1c3a9f60a5c4106a96ac82d780e2d'
REF = 'refs/heads/dev/workflow-optimization'


def identity(source, run_id):
    v.require(re.fullmatch('[0-9a-f]{40}', source) and re.fullmatch('[1-9][0-9]*', run_id),
              'Expected full commit and positive device run ID')
    return dict(scope=SCOPE, version=VERSION, build=BUILD, source_commit=source, base_commit=BASE,
                ref=REF, plan_sha256=PLAN, run_id=run_id, run_attempt='1', job='epub_diagnostic',
                qualification='DEVICE_DIAGNOSTIC_ONLY', coverage='UI_NOT_QUALIFIED',
                native_tests_executed_this_job=0, full_regression_passed=False, release_qualified=False,
                build_ipa=True, allow_unqualified_ipa=True, validation_reference=None,
                physical_acceptance='not performed')


def scope_receipt():
    env = os.environ
    v.require(env.get('VALIDATION_SCOPE') == SCOPE and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
              and env.get('GITHUB_REPOSITORY') == 'wan780839395-cyber/YueJing' and env.get('GITHUB_REF') == REF
              and env.get('GITHUB_RUN_ATTEMPT') == '1' and env.get('GITHUB_JOB') in ('admission', 'epub_diagnostic')
              and env.get('BUILD_IPA') == env.get('ALLOW_UNQUALIFIED_IPA') == 'true', 'Device dispatch identity differs')
    source = env['GITHUB_SHA']
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    v.require(inputs.get('validation_scope') == inputs.get('scope_acknowledgement') == SCOPE
              and inputs.get('development_source_sha') == source and inputs.get('development_plan_sha256') == PLAN
              and str(inputs.get('build_ipa')).lower() == str(inputs.get('allow_unqualified_ipa')).lower() == 'true'
              and not inputs.get('prior_validation_run'), 'Device dispatch inputs differ')

    def git(*args):
        return subprocess.check_output(['git', *args], cwd=v.ROOT, timeout=30).decode().strip()

    v.require(git('rev-list', '--parents', '-n1', 'HEAD').split() == [source, BASE]
              and not git('status', '--porcelain', '--untracked-files=all'), 'Expected clean, exact direct child of batch base')
    project = expected_project_identity()
    v.require((project['version'], project['build']) == (VERSION, BUILD)
              and v.digest(v.ROOT / 'scripts/development_scope.json') == PLAN, 'Version, build or Host plan drift')
    return identity(source, env['GITHUB_RUN_ID'])


def check_gate(scope, hashes):
    from userfont_package import check_release_gate
    gate = v.OUT / 'app-dependency-gate.json'
    check_release_gate(gate, {'device_scope': scope}, dict(source_commit=scope['source_commit'], signing='unsigned'), hashes)
    return v.digest(gate)


if __name__ == '__main__':
    if len(sys.argv) != 6 or sys.argv[1] != 'verify-download':
        sys.exit('usage: bookmark_device_package.py verify-download EXTRACTED_DIR SOURCE_SHA DEVICE_RUN_ID IPA_SHA256')
    from epub_diagnostic_package import verify_download
    verify_download(*sys.argv[2:], bookmark=True)
