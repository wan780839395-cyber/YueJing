"""Cheap Task3 dispatch admission, before native tool preparation."""
import os
import subprocess
import task3_test_inventory as inventory
from workflow_development import preflight

HISTORICAL = {'host-natural-root-5c88543-exact3', 'reuse-native-205-d2110a9', 'epub-compat-33',
              'epub-paging-6', 'epub-reading-15', 'epub-diagnostic-a0fbb60',
              'epub-opening-followup-3', 'epub-author-layout', 'neon-device-022', 'neon-device-023'}


def admit(scope, acknowledgement):
    if scope not in HISTORICAL | {'full', 'development-targeted', 'woff2-native-024', 'userfont-native-025'}:
        raise ValueError('Choose an explicit scope; no native work is authorized by the default')
    if scope != 'development-targeted' and acknowledgement != scope:
        raise ValueError('Explicit scope acknowledgement required; historical frozen gates still apply')
    return scope


def main():
    scope = admit(os.environ.get('VALIDATION_SCOPE', ''), os.environ.get('SCOPE_ACKNOWLEDGEMENT', ''))
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
    elif scope == 'userfont-native-025':
        env = os.environ
        if not (env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('GITHUB_RUN_ATTEMPT') == '1'
                and env.get('GITHUB_REPOSITORY') == 'wan780839395-cyber/YueJing'
                and env.get('GITHUB_REF') == 'refs/heads/dev/workflow-optimization'
                and subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip() == env.get('GITHUB_SHA') == env.get('DEVELOPMENT_SOURCE_SHA')
                and env.get('BUILD_IPA') == 'true' and env.get('ALLOW_UNQUALIFIED_IPA') == 'false'
                and not env.get('PRIOR_VALIDATION_RUN')):
            raise ValueError('Custom font qualified delivery identity mismatch')
        from run_userfont_native import identity, read_cases
        identity()
        read_cases()
    elif scope == 'development-targeted':
        preflight()
    else:
        if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
            raise ValueError('Explicit first-attempt dispatch required')
    print('Admitted scope:', scope, '(not a release qualification)')

if __name__ == '__main__':
    main()
