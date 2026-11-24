"""Cheap Task3 dispatch admission, before native tool preparation."""
import json
import os
import subprocess
from device_registry import BATCHES, DEVICE_SCOPES, dispatch_batch
from workflow_development import preflight

HISTORICAL = {'host-natural-root-5c88543-exact3', 'reuse-native-205-d2110a9', 'epub-compat-33',
              'epub-paging-6', 'epub-reading-15', 'epub-diagnostic-a0fbb60',
              'epub-opening-followup-3', 'epub-author-layout', 'neon-device-022', 'neon-device-023'}


def admit(scope, acknowledgement):
    if scope not in HISTORICAL | DEVICE_SCOPES | {'full', 'development-targeted', 'woff2-native-024', 'userfont-native-025', 'fontpicker-native-026', 'fontcopy-native-027'}:
        raise ValueError('Choose an explicit scope; no native work is authorized by the default')
    if scope != 'development-targeted' and acknowledgement != scope:
        raise ValueError('Explicit scope acknowledgement required; historical frozen gates still apply')
    return scope


def main():
    scope = admit(os.environ.get('VALIDATION_SCOPE', ''), os.environ.get('SCOPE_ACKNOWLEDGEMENT', ''))
    if scope == 'full':
        from bookmark_device_package import SCOPE
        parents = subprocess.check_output(['git', 'rev-list', '--parents', '-n1', 'HEAD'], text=True).split()[1:]
        if BATCHES[SCOPE].product in parents:
            raise ValueError('This bookmark batch permits targeted development and device-only packaging, not full')
    if scope == 'woff2-native-024':
        env = os.environ
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        parent = subprocess.check_output(['git', 'rev-parse', 'HEAD^'], text=True).strip()
        if not (env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1'
                and env.get('GITHUB_REF') == 'refs/heads/dev/workflow-optimization'
                and head == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA')
                and parent == '9007f22fce86a9f6b125bbb14fe0c8d676294803'
                and env.get('BUILD_IPA') == 'false' and env.get('ALLOW_UNQUALIFIED_IPA') == 'false'
                and not env.get('PRIOR_VALIDATION_RUN')):
            raise ValueError('WOFF2 candidate, branch, package consent or run identity mismatch')
        from run_woff2_native import preflight as native_preflight
        native_preflight()
    elif scope in DEVICE_SCOPES:
        from bookmark_device_package import scope_receipt
        scope_receipt()
    elif scope in ('userfont-native-025', 'fontpicker-native-026', 'fontcopy-native-027'):
        env = os.environ
        if not (env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1'
                and env.get('GITHUB_REPOSITORY') == 'wan780839395-cyber/YueJing'
                and env.get('GITHUB_REF') == 'refs/heads/dev/workflow-optimization'
                and subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip() == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA')
                and env.get('BUILD_IPA') == 'true' and env.get('ALLOW_UNQUALIFIED_IPA') == 'false'
                and not env.get('PRIOR_VALIDATION_RUN')):
            raise ValueError('Custom font qualified delivery identity mismatch')
        if scope in ('fontpicker-native-026', 'fontcopy-native-027'):
            for path, blob in {'App/EPUB/EPUBUserFontCard.swift': 'c541095379ba29e28a66873ae9cfa319dcc02207', 'App/EPUB/EPUBSettingsView.swift': '97a7c6a34acc0b35bad042b3d39082bcb63f4ad4', 'App/EPUB/EPUBUserFontPicker.swift': 'a6854b7a6d4f64446068749bbb006f1849b7113f', 'App/EPUB/EPUBFontFilePicker.swift': ('b374be2fbb4f847de51ae86fcef35067a1459eea' if scope == 'fontcopy-native-027' else 'f14158742e31d0364aadc4e9de5e4f1300ee7f61')}.items():
                if subprocess.check_output(['git', 'rev-parse', 'HEAD:' + path], text=True).strip() != blob:
                    raise ValueError('Frozen picker or Gemini UI drift: ' + path)
            from run_fontpicker_native import read_cases
            from hashlib import sha256
            from pathlib import Path
            if sha256(Path('scripts/fontcopy_native_plan.json' if scope == 'fontcopy-native-027' else 'scripts/fontpicker_native_plan.json').read_bytes()).hexdigest() != env.get('DEVELOPMENT_PLAN_SHA256'):
                raise ValueError('Font picker plan drift')
            read_cases()
        else:
            from run_userfont_native import identity, read_cases
            identity()
            read_cases()
    elif scope == 'development-targeted':
        preflight()
    else:
        if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
            raise ValueError('Explicit first-attempt dispatch required')
    if 'GITHUB_OUTPUT' in os.environ:
        # Older, non-registry diagnostic jobs keep their original hosting contract.
        route = (dispatch_batch(scope).route() if scope in DEVICE_SCOPES else
                 dict(batch='', runner='macos-15', architecture='arm64', job_minutes=30, prepare_minutes=5))
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
            print('device_route=' + json.dumps(route, separators=(',', ':')), file=output)
    print('Admitted scope:', scope, '(not a release qualification)')

if __name__ == '__main__':
    main()
