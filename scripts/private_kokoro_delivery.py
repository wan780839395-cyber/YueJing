"""Task3 build40: classify the checked-out product before native jobs, then seal artifacts."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

from device_registry import DEVICE_SCOPES, dispatch_batch
from package_ipa import expected_project_identity

CERT = Path('Config/kokoro-test-recipient.pem')
PRIVATE = ('0.2.38', '40')
KINDS = ('device-delivery', 'device-evidence', 'development-evidence')
RECEIPTS = ('manifest.json', 'SHA256SUMS', 'task3/app-dependency-gate.json',
            'task3/ipa-verification.json', 'task3/epub-diagnostic-scope.json')


def policy(version, build, scope):
    # Scope/key is not the privacy boundary. In particular, 'full' on the new
    # checkout would otherwise start a different job with an always() upload.
    if scope in DEVICE_SCOPES:
        batch = dispatch_batch(scope)
        if (version, build) != (batch.version, batch.build):
            raise ValueError('Device registry and checked-out product disagree')
    if (version, build) in (PRIVATE, ('0.2.39', '41'), ('0.2.40', '42'), ('0.2.41', '43'), ('0.2.42', '44')) and scope in ('development-targeted', 'device-active'):
        return 'cms40'
    if tuple(map(int, version.split('.'))) < (0, 2, 38) and int(build) < 40:
        return 'legacy'
    raise ValueError('No approved delivery policy for this product and scope')


def recipient():
    if CERT.is_symlink() or not re.fullmatch(
            rb'-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*',
            CERT.read_bytes()):
        raise ValueError('Expected one public recipient certificate')
    subprocess.run(['openssl', 'x509', '-in', CERT, '-noout', '-checkend', '0'], check=True)


def members(kind, root):
    if kind == 'device-delivery':
        ipa, = root.glob('*.ipa')
        for file in [ipa, *(root / name for name in RECEIPTS)]:
            yield file, file.relative_to(root)
    else:
        # Mirror the old artifact roots (including raw xcresults), never build/.
        # Skip hidden entries, as upload-artifact did. Don't follow links.
        dirs = ('development', 'task3') if kind == 'development-evidence' else ('task3',)
        base = root if kind == 'development-evidence' else root / 'task3'
        def visit(folder):
            for file in sorted(folder.iterdir()):
                if file.name.startswith('.') or file.is_symlink():
                    continue
                if file.is_dir():
                    yield from visit(file)
                else:
                    yield file, file.relative_to(base)
        for name in dirs:
            folder = root / name
            if not folder.is_symlink() and folder.is_dir():
                yield from visit(folder)


def seal(kind):
    if kind not in KINDS:
        raise ValueError('Unknown artifact kind')
    recipient()
    root = Path('artifacts')
    temp = Path(os.environ['RUNNER_TEMP'])
    final_dir = temp / ('kokoro-' + kind)
    final_dir.mkdir(mode=0o700)  # fresh, outside all plaintext upload roots
    with tempfile.TemporaryDirectory(dir=temp) as work:
        plain = Path(work) / 'payload.zip'
        with zipfile.ZipFile(plain, 'x', zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
            for file, name in members(kind, root):
                if not file.is_file() or any(p.is_symlink() for p in (file, *file.parents)):
                    raise ValueError('Expected regular non-linked artifact member')
                archive.write(file, name.as_posix())
            if not archive.namelist():
                raise ValueError('No artifact members; refusing empty envelope')
        # macOS ships LibreSSL on some runners. Use already installed Homebrew
        # OpenSSL 3 there (no install), not a tool which might lack CMS support.
        openssl = 'openssl'
        if sys.platform == 'darwin':
            prefix = subprocess.check_output(['brew', '--prefix', 'openssl@3'], text=True).strip()
            openssl = str(Path(prefix) / 'bin/openssl')
        cipher = Path(work) / 'cipher.der'
        subprocess.run([openssl, 'cms', '-encrypt', '-binary', '-aes-256-cbc', '-outform', 'DER',
                        '-in', plain, '-out', cipher, CERT], check=True)
        if cipher.stat().st_size <= plain.stat().st_size:
            raise ValueError('Incomplete CMS envelope')
        cipher.rename(final_dir / (kind + '.cms'))


if __name__ == '__main__':
    cmd, = sys.argv[1:]
    if cmd == 'policy':
        product = expected_project_identity()
        mode = policy(product['version'], product['build'], os.environ['VALIDATION_SCOPE'])
        if mode == 'cms40':
            recipient()
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as out:
            print('delivery_mode=' + mode, file=out)
    else:
        seal(cmd)
