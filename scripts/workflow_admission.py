"""Cheap Task3 dispatch admission, before native tool preparation."""
import os
import task3_test_inventory as inventory
from workflow_development import preflight

HISTORICAL = {'host-natural-root-5c88543-exact3', 'reuse-native-205-d2110a9', 'epub-compat-33',
              'epub-paging-6', 'epub-reading-15', 'epub-diagnostic-a0fbb60',
              'epub-opening-followup-3', 'epub-author-layout'}


def admit(scope, acknowledgement):
    if scope not in HISTORICAL | {'full', 'development-targeted'}:
        raise ValueError('Choose an explicit scope; no native work is authorized by the default')
    if scope != 'development-targeted' and acknowledgement != scope:
        raise ValueError('Explicit scope acknowledgement required; historical frozen gates still apply')
    return scope


def main():
    scope = admit(os.environ.get('VALIDATION_SCOPE', ''), os.environ.get('SCOPE_ACKNOWLEDGEMENT', ''))
    if scope == 'development-targeted':
        preflight()
    else:
        if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
            raise ValueError('Explicit first-attempt dispatch required')
    print('Admitted scope:', scope, '(not a release qualification)')

if __name__ == '__main__':
    main()
