"""Device-only provenance; the separate development run is never a packaging credential."""
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

from device_registry import BATCHES, HOSTS, REGISTRY_PATH, dispatch_batch, load_registry
from package_ipa import expected_project_identity
import validate_task3 as v

SCOPE = 'bookmark-device-028'  # Historical CLI/API aliases, not release configuration.
COMMANDS = {'verify-download': SCOPE, 'verify-search-download': 'search-device-029',
            'verify-search-return-download': 'search-return-device-030'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=v.ROOT, timeout=30)


def check_freeze(batch, source):
    if batch.legacy_source:
        v.require(source == batch.legacy_source, 'Not the reviewed legacy release commit')
        return
    # The freeze commit cannot contain its own SHA. Instead pin its sole parent,
    # allow ONLY an ordinary registry edit, and match its active contract exactly.
    v.require(git('rev-list', '--parents', '-n1', source).decode().split() == [source, batch.product],
              'Expected one direct child of the approved device product')
    raw = git('diff-tree', '--no-commit-id', '--raw', '-r', '-z', '--no-renames', batch.product, source)
    v.require(re.fullmatch(rb':100644 100644 [a-f0-9]+ [a-f0-9]+ M\x00' +
                           re.escape(REGISTRY_PATH.encode()) + rb'\x00', raw), 'Expected registry-only freeze')
    rows, active = load_registry(json.loads(git('show', source + ':' + REGISTRY_PATH)))
    v.require(active == batch.key and rows[active] == batch, 'Candidate did not activate this frozen contract')
    previous, _ = load_registry(json.loads(git('show', batch.product + ':' + REGISTRY_PATH)))
    v.require(active not in previous and rows == {**previous, active: batch},
              'Freeze must append one new batch without rewriting earlier contracts')
    batch.check_plan(git('show', batch.product + ':' + batch.plan_path))


def identity(source, run_id, scope=SCOPE):
    batch = BATCHES[scope]
    v.require(re.fullmatch('[0-9a-f]{40}', source) and re.fullmatch('[1-9][0-9]*', run_id),
              'Expected full commit and positive device run ID')
    check_freeze(batch, source)
    return dict(scope=scope, version=batch.version, build=batch.build, source_commit=source, base_commit=batch.product,
                ref=batch.ref, plan_sha256=batch.plan_sha256, run_id=run_id, run_attempt='1', job='epub_diagnostic',
                qualification='DEVICE_DIAGNOSTIC_ONLY', coverage='UI_NOT_QUALIFIED',
                native_tests_executed_this_job=0, full_regression_passed=False, release_qualified=False,
                build_ipa=True, allow_unqualified_ipa=True, validation_reference=None,
                physical_acceptance='not performed', **({} if batch.legacy_source else {'device_route': batch.route()}))


def check_host(batch, system, architecture):
    v.require(system == 'Darwin' and architecture == HOSTS[batch.runner], 'Wrong physical device build host')


def scope_receipt():
    env = os.environ
    scope = env.get('VALIDATION_SCOPE')
    batch = dispatch_batch(scope)
    v.require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
              and env.get('GITHUB_REPOSITORY') == 'wan780839395-cyber/YueJing' and env.get('GITHUB_REF') == batch.ref
              and env.get('GITHUB_RUN_ATTEMPT') == '1' and env.get('GITHUB_JOB') in ('admission', 'epub_diagnostic')
              and env.get('BUILD_IPA') == env.get('ALLOW_UNQUALIFIED_IPA') == 'true', 'Device dispatch identity differs')
    if env['GITHUB_JOB'] == 'epub_diagnostic':
        check_host(batch, platform.system(), platform.machine())
    source = env['GITHUB_SHA']
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    v.require(inputs.get('validation_scope') == inputs.get('scope_acknowledgement') == scope
              and inputs.get('development_source_sha') == source and inputs.get('development_plan_sha256') == batch.plan_sha256
              and str(inputs.get('build_ipa')).lower() == str(inputs.get('allow_unqualified_ipa')).lower() == 'true'
              and not inputs.get('prior_validation_run'), 'Device dispatch inputs differ')
    v.require(git('rev-parse', 'HEAD').decode().strip() == source and not git('status', '--porcelain', '--untracked-files=all'),
              'Expected a clean checkout of the approved candidate')
    if batch.legacy_source:
        v.require(git('rev-list', '--parents', '-n1', 'HEAD').decode().split() == [batch.legacy_source, batch.product],
                  'Unexpected historical release or product source')
    batch.check_plan((v.ROOT / batch.plan_path).read_bytes())
    project = expected_project_identity()
    v.require((project['version'], project['build']) == (batch.version, batch.build), 'Version or build drift')
    return identity(source, env['GITHUB_RUN_ID'], batch.key)


def check_gate(scope, hashes):
    from userfont_package import check_release_gate
    gate = v.OUT / 'app-dependency-gate.json'
    check_release_gate(gate, {'device_scope': scope}, dict(source_commit=scope['source_commit'], signing='unsigned'), hashes)
    return v.digest(gate)


if __name__ == '__main__':
    from epub_diagnostic_package import verify_download
    if len(sys.argv) == 7 and sys.argv[1] == 'verify-batch-download':
        verify_download(*sys.argv[3:], device_scope=sys.argv[2])
    elif len(sys.argv) == 6 and sys.argv[1] in COMMANDS:
        verify_download(*sys.argv[2:], device_scope=COMMANDS[sys.argv[1]])
    else:
        sys.exit('usage: bookmark_device_package.py {verify-batch-download BATCH | ' + '|'.join(COMMANDS) +
                 '} EXTRACTED_DIR SOURCE_SHA DEVICE_RUN_ID IPA_SHA256')
