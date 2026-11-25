"""Build host only. Materialize the matching static libraries and their own C header."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

URL = ('https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.20/'
       'sherpa-onnx-v1.12.20-ios.tar.bz2')
SHA256 = '1afdc4175326411522c575b6774a62b8fd37201cdb8a9850af2faff459b9b145'
SLICE = {'iphoneos': 'ios-arm64', 'iphonesimulator': 'ios-arm64_x86_64-simulator'}


def prepare(platform, output, local_archive):
    identifier = SLICE[platform]
    sherpa = f'./build-ios/sherpa-onnx.xcframework/{identifier}'
    ort = f'./build-ios/ios-onnxruntime/1.17.1/onnxruntime.xcframework/{identifier}'
    header = 'sherpa-onnx/c-api/c-api.h'
    members = {f'{sherpa}/libsherpa-onnx.a': 'libsherpa-onnx.a',
               f'{sherpa}/Headers/{header}': header, f'{ort}/onnxruntime.a': 'onnxruntime.a'}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as work:
        stage = Path(work)
        archive = local_archive
        if not archive:
            archive = stage / 'download.tar.bz2'
            subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--retry', '2',
                            '--output', str(archive), URL], check=True)
        with open(archive, 'rb') as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
            if digest.hexdigest() != SHA256:
                raise ValueError('sherpa-onnx iOS archive checksum mismatch')
            stream.seek(0)
            seen = set()
            with tarfile.open(fileobj=stream, mode='r|bz2') as tar:
                for entry in tar:
                    if entry.name not in members:
                        continue
                    if not entry.isreg() or entry.name in seen:
                        raise ValueError('unexpected archive entry type or duplicate')
                    seen.add(entry.name)
                    dest = stage / members[entry.name]
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with dest.open('xb') as file:
                        shutil.copyfileobj(tar.extractfile(entry), file)
            if seen != members.keys():
                raise ValueError('missing pinned iOS libraries or header')
        for path in members.values():
            (output / path).parent.mkdir(parents=True, exist_ok=True)
            os.replace(stage / path, output / path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=SLICE)
    parser.add_argument('output', type=Path)
    parser.add_argument('--archive', default=os.environ.get('KOKORO_IOS_ARCHIVE'))
    args = parser.parse_args()
    prepare(args.platform, args.output, args.archive)
