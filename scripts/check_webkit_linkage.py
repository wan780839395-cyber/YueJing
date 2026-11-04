"""Fail closed on the unavailable Swift WebKit overlay; does not launch/build tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

OVERLAY = '/usr/lib/swift/libswiftWebKit.dylib'
LOADS = {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20}
WEAK_LOAD = 0x80000018
MAGIC = b'\xcf\xfa\xed\xfe'
MACH_MAGICS = {MAGIC, b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
               b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def inspect_macho(data):
    require(len(data) >= 32 and data[:4] == MAGIC, 'Expected thin little-endian Mach-O 64')
    _, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', data)
    require(cpu == 0x0100000C, 'Expected arm64')
    end = 32 + size
    require(end <= len(data) and count <= size // 8, 'Invalid load command bounds')
    pos, libraries, symtab = 32, [], None
    for _ in range(count):
        require(pos + 8 <= end, 'Truncated command')
        cmd, length = struct.unpack_from('<II', data, pos)
        require(length >= 8 and length % 8 == 0 and pos + length <= end, 'Invalid command size')
        if cmd in LOADS:
            require(length >= 24, 'Short dylib command')
            offset = struct.unpack_from('<I', data, pos + 8)[0]
            require(24 <= offset < length, 'Invalid dylib name offset')
            terminator = data.find(b'\0', pos + offset, pos + length)
            require(terminator >= 0, 'Unterminated dylib name')
            libraries.append(dict(ordinal=len(libraries) + 1, command=hex(cmd),
                                  name=data[pos + offset:terminator].decode('utf-8'), weak=cmd == WEAK_LOAD))
        if cmd == 2:  # LC_SYMTAB; n_desc high byte indexes dylib load-command order.
            require(length == 24 and symtab is None, 'Invalid/duplicate symbol table')
            symtab = struct.unpack_from('<4I', data, pos + 8)
        pos += length
    require(pos == end and symtab is not None, 'Incomplete commands or no symbol table')
    symoff, nsyms, stroff, strsize = symtab
    require(symoff + nsyms * 16 <= len(data) and stroff + strsize <= len(data), 'Invalid symbols bounds')
    overlay = [lib for lib in libraries if lib['name'].endswith('/libswiftWebKit.dylib')]
    ordinals = {lib['ordinal'] for lib in overlay}
    imports = []
    for i in range(nsyms):
        string_index, kind, _, desc, _ = struct.unpack_from('<IBBHQ', data, symoff + i * 16)
        if not kind & 0xE0 and kind & 0x0E == 0 and desc >> 8 in ordinals:
            require(string_index < strsize, 'Invalid imported symbol string')
            stop = data.find(b'\0', stroff + string_index, stroff + strsize)
            require(stop >= 0, 'Unterminated imported symbol')
            imports.append(data[stroff + string_index:stop].decode('utf-8'))
    return dict(overlay_loads=overlay, overlay_imports=imports,
                passed=all(lib['weak'] for lib in overlay) and not imports)


def synthetic(cmd=WEAK_LOAD, symbol=False, ordinal=1, name=OVERLAY):
    raw = name.encode() + b'\0'
    length = (24 + len(raw) + 7) // 8 * 8
    load = struct.pack('<6I', cmd, length, 24, 0, 0, 0) + raw + bytes(length - 24 - len(raw))
    strings = b'\0_overlaySymbol\0'
    symoff = 32 + length + 24
    entry = struct.pack('<IBBHQ', 1, 1, 0, ordinal << 8, 0) if symbol else b''
    table = struct.pack('<6I', 2, 24, symoff, int(symbol), symoff + len(entry), len(strings))
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 6, 2, length + 24, 0, 0)
    return header + load + table + entry + strings


def self_check():
    require(inspect_macho(synthetic())['passed'], 'Weak unused overlay must pass')
    require(not inspect_macho(synthetic(0xC))['passed'], 'Strong overlay must fail')
    require(not inspect_macho(synthetic(symbol=True))['passed'], 'Used weak overlay must fail')
    require(inspect_macho(synthetic(name='/usr/lib/libSystem.B.dylib', symbol=True))['passed'], 'Unrelated import')
    require(inspect_macho(synthetic(symbol=True, ordinal=0xFE))['passed'], 'Dynamic lookup is not ordinal1')
    for bad in (b'', synthetic()[:40], synthetic()[:-5], synthetic().replace(MAGIC, b'BAD!', 1)):
        try:
            inspect_macho(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Malformed Mach-O accepted')
    print(json.dumps(dict(self_check='passed', synthetic_cases=9, native_invocations=0)))


def inspect_apps(apps, out):
    require(sys.platform == 'darwin', 'Native binary evidence requires macOS')
    out.mkdir(parents=True, exist_ok=False)
    result = dict(source_commit=os.environ['GITHUB_SHA'], run_id=os.environ['GITHUB_RUN_ID'],
                  run_attempt=os.environ['GITHUB_RUN_ATTEMPT'], passed=False, binaries=[], errors=[])
    for index, app in enumerate(apps):
        try:
            require(app.is_dir() and (app / 'YueJing').is_file(), 'Missing built App: ' + str(app))
            found = 0
            for path in sorted(app.rglob('*')):
                if not path.is_file() or path.is_symlink():
                    continue
                with path.open('rb') as stream:
                    magic = stream.read(4)
                if magic not in MACH_MAGICS:
                    continue
                found += 1
                relative = Path(str(index)) / path.relative_to(app)
                evidence = out / 'binaries' / relative
                evidence.parent.mkdir(parents=True, exist_ok=True)
                data = path.read_bytes()
                evidence.write_bytes(data)  # Preserve exact bytes, even when inspection fails.
                record = dict(app=str(app), path=path.relative_to(app).as_posix(),
                              evidence=evidence.relative_to(out).as_posix(), bytes=len(data),
                              sha256=hashlib.sha256(data).hexdigest(), passed=False)
                result['binaries'].append(record)
                try:
                    record.update(inspect_macho(data))
                    command = ['xcrun', 'nm', '-m', '-u', str(path)]
                    native = subprocess.run(command, capture_output=True, text=True, timeout=60)
                    log = out / ('nm-' + str(len(result['binaries'])) + '.log')
                    log.write_text(native.stdout + native.stderr, encoding='utf-8')
                    record['nm_exit'] = native.returncode
                    record['nm_log'] = log.name
                    require(native.returncode == 0, 'nm failed')
                    require(not any('libswiftWebKit' in line for line in native.stdout.splitlines()), 'nm found overlay symbol import')
                    require(record['passed'], 'Strong overlay load or imported overlay symbols')
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    record['passed'] = False
                    result['errors'].append(dict(path=str(path), error=str(error)))
            require(found > 0, 'No Mach-O files: ' + str(app))
        except (OSError, ValueError) as error:
            result['errors'].append(dict(path=str(app), error=str(error)))
    result['passed'] = bool(result['binaries']) and not result['errors']
    (out / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--app', type=Path, action='append')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return 0
    require(args.app and args.output, '--app and --output required')
    return inspect_apps(args.app, args.output)


if __name__ == '__main__':
    raise SystemExit(main())
