"""Offline registry routes, freeze rejection, and optional real 030 artifact replay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from unittest.mock import patch

import bookmark_device_package as device
import device_registry as registry
from epub_diagnostic_package import verify_download
import workflow_admission as admission

OLD = 'search-return-device-030'
SOURCE = 'f50c2ff934de04526f2bc576002e1e03495b0f36'
RUN = '45231684790'
SHA = 'a31a1ce0f057457fa20a8c43cf821e5d72f279159ba451461e01dbacf7f6cbd5'


def rejects(message, operation, *args, **kwargs):
    try:
        operation(*args, **kwargs)
    except ValueError as error:
        if message in str(error):
            return
        raise
    raise AssertionError('Expected refusal: ' + message)


def future_fixture():
    # Model SCM responses only; do not create a commit or approve any real batch.
    previous = (registry.ROOT / registry.REGISTRY_PATH).read_bytes()
    data = json.loads(previous)
    key, product, source = 'offline-only', 'a' * 40, 'b' * 40
    plan = (registry.ROOT / 'scripts/development_scope.json').read_bytes()
    data['active'] = key
    data['batches'][key] = dict(version='1.0.1', build='999', product=product, runner='macos-15-intel',
                                plan_sha256=hashlib.sha256(plan).hexdigest(), job_minutes=17, prepare_minutes=3)
    rows, active = registry.load_registry(data)
    batch = rows[active]
    raw = b':100644 100644 a b M\0scripts/device_batches.json\0'
    with patch.object(registry, 'BATCHES', rows), patch.object(registry, 'ACTIVE', active):
        assert registry.dispatch_batch('device-active').route() == dict(batch=key, runner='macos-15-intel',
                                        architecture='x86_64', job_minutes=17, prepare_minutes=3)
    replies = [(source + ' ' + product).encode(), raw, json.dumps(data).encode(), previous, plan]
    with patch.object(device, 'git', side_effect=replies):
        device.check_freeze(batch, source)
    for index, value, message in [(0, source.encode(), 'direct child'), (1, raw + b'App/File.swift\0', 'registry-only'),
                                  (3, replies[2], 'rewriting'), (4, plan + b' ', 'digest differs')]:
        altered = list(replies)
        altered[index] = value
        with patch.object(device, 'git', side_effect=altered):
            rejects(message, device.check_freeze, batch, source)


def admission_replay(tmp):
    batch = registry.BATCHES[OLD]
    raw = device.git('show', batch.product + ':' + batch.plan_path)
    batch.check_plan(raw)
    assert len(json.loads(raw)['cases']) == 2
    changed = json.loads(raw)
    changed['cases'] += [{'file': 'Example.swift', 'name': 'extra1'}, {'file': 'Example.swift', 'name': 'extra2'}]
    rejects('digest differs', batch.check_plan, json.dumps(changed).encode())
    event = tmp / 'event.json'
    output = tmp / 'github-output'
    inputs = dict(validation_scope=OLD, scope_acknowledgement=OLD, development_source_sha=SOURCE,
                  development_plan_sha256=batch.plan_sha256, build_ipa=True, allow_unqualified_ipa=True)
    event.write_text(json.dumps({'inputs': inputs}))
    env = dict(VALIDATION_SCOPE=OLD, SCOPE_ACKNOWLEDGEMENT=OLD, GITHUB_EVENT_NAME='workflow_dispatch',
               GITHUB_REPOSITORY='wan780839395-cyber/YueJing', GITHUB_REF=batch.ref, GITHUB_RUN_ATTEMPT='1',
               GITHUB_JOB='admission', BUILD_IPA='true', ALLOW_UNQUALIFIED_IPA='true', GITHUB_SHA=SOURCE,
               GITHUB_RUN_ID=RUN, GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
    path = tmp / batch.plan_path
    path.parent.mkdir()
    path.write_bytes(raw)
    # Simulate only the clean checkout and actual host; use the real admission,
    # event parser, project identity parser, registry, device and plan checks.
    spec = tmp / 'project.yml'
    spec.write_bytes(device.git('show', SOURCE + ':project.yml'))
    project = device.expected_project_identity(spec)
    lineage = device.git('rev-list', '--parents', '-n1', SOURCE)
    replies = {('rev-parse', 'HEAD'): SOURCE.encode(), ('status', '--porcelain', '--untracked-files=all'): b'',
               ('rev-list', '--parents', '-n1', 'HEAD'): lineage}
    with patch.dict(os.environ, env), patch.object(device.v, 'ROOT', tmp), patch.object(device, 'git', lambda *a: replies[a]), \
         patch.object(device, 'expected_project_identity', return_value=project):
        admission.main()
        assert json.loads(output.read_text().split('=', 1)[1]) == batch.route()
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/heads/not-approved'}):
            rejects('dispatch identity', admission.main)
        with patch.dict(os.environ, {'GITHUB_JOB': 'epub_diagnostic'}), patch.object(device.platform, 'system', return_value='Darwin'):
            with patch.object(device.platform, 'machine', return_value='arm64'):
                rejects('Wrong physical', device.scope_receipt)
            with patch.object(device.platform, 'machine', return_value='x86_64'):
                assert device.scope_receipt() == device.identity(SOURCE, RUN, OLD)
        event.write_text(json.dumps({'inputs': {**inputs, 'development_plan_sha256': ''}}))
        rejects('inputs differ', admission.main)
        event.write_text(json.dumps({'inputs': inputs}))
        path.write_bytes(raw + b' ')
        rejects('digest differs', admission.main)
        with patch.object(registry, 'ACTIVE', None), patch.dict(os.environ, {'VALIDATION_SCOPE': 'device-active',
                                                                             'SCOPE_ACKNOWLEDGEMENT': 'device-active'}):
            rejects('No frozen batch', admission.main)


def archive_replay(archive, tmp):
    verify_download(archive, SOURCE, RUN, SHA, device_scope=OLD)
    rejects('legacy release commit', verify_download, archive, '0' * 40, RUN, SHA, device_scope=OLD)
    copy_dir = tmp / 'download'
    shutil.copytree(archive, copy_dir)
    proof = copy_dir / 'task3/ipa-verification.json'
    altered = json.loads(proof.read_bytes())
    altered['release_files_sha256']['Payload/YueJing.app/YueJing'] = '0' * 64
    proof.write_text(json.dumps(altered))
    rejects('verified device Release', verify_download, copy_dir, SOURCE, RUN, SHA, device_scope=OLD)
    with next(copy_dir.glob('*.ipa')).open('ab') as out:
        out.write(b'!')
    rejects('IPA or SHA256SUMS mismatch', verify_download, copy_dir, SOURCE, RUN, SHA, device_scope=OLD)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-030', type=Path, help='original extracted task3-unsigned-ipa artifact')
    args = parser.parse_args()
    future_fixture()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        admission_replay(root)
        if args.artifact_030:
            archive_replay(args.artifact_030, root)
    print('Device registry checks passed' + (' (including archived 030 IPA)' if args.artifact_030 else ' (without archive)'))
