"""Generate deterministic synthetic EPUB acceptance samples into a NEW directory only."""
import argparse
import binascii
import csv
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile
import zlib


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)
    width, height = 96, 144
    rows = b''.join(b'\0' + bytes((40 + y // 2, 105, 98)) * width for y in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')


def epub(version=3, cover='valid', fixed=False, traversal=False):
    title = f'EPUB{version} synthetic {cover}'
    container = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    cover_item = '' if cover == 'none' else '<item id="cover" href="cover.png" media-type="image/png"' + (' properties="cover-image"' if version == 3 else '') + '/>'
    metadata_extra = '<meta property="rendition:layout">pre-paginated</meta>' if fixed else ''
    if version == 2 and cover != 'none':
        metadata_extra += '<meta name="cover" content="cover"/>'
    manifest = ''.join(f'<item id="c{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, 5))
    manifest += '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' if version == 3 else '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(1, 5))
    package = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:yuejing:synthetic:{version}:{cover}</dc:identifier><dc:title>{title}</dc:title><dc:language>zh</dc:language>{metadata_extra}</metadata><manifest>{manifest}{cover_item}</manifest><spine{(' toc="ncx"' if version == 2 else '')}>{spine}</spine></package>'''
    entries = [('mimetype', b'application/epub+zip'), ('META-INF/container.xml', container.encode()), ('OPS/book.opf', package.encode())]
    for chapter in range(1, 5):
        body = f'<h1 id="start">第{chapter}章 合成 EPUB 观察</h1>'
        body += ''.join(f'<p id="p{i}">E-C{chapter}-P{i:03d} 合成阅读段落，核对目录、滚动、字号变化和退出后位置。A😀é；此处没有私人小说或人物资料。</p>' for i in range(1, 81))
        body += f'<p id="end">EPUB-END-C{chapter}</p>'
        entries.append((f'OPS/chapter{chapter}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter {chapter}</title></head><body>{body}</body></html>'.encode()))
    if version == 3:
        links = ''.join(f'<li><a href="chapter{i}.xhtml#start">第{i}章</a><ol><li><a href="chapter{i}.xhtml#p40">中段 P040</a></li></ol></li>' for i in range(1, 5))
        entries.append(('OPS/nav.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>{links}</ol></nav></body></html>'.encode()))
    else:
        points = ''.join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>第{i}章</text></navLabel><content src="chapter{i}.xhtml#p40"/></navPoint>' for i in range(1, 5))
        entries.append(('OPS/toc.ncx', f'<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>{title}</text></docTitle><navMap>{points}</navMap></ncx>'.encode()))
    if cover != 'none':
        entries.append(('OPS/cover.png', png() if cover == 'valid' else b'Invalid optional image, not an archive error.'))
    if traversal:
        entries.append(('../outside.txt', b'MUST REJECT; never extract this entry'))
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return output.getvalue()


def generate(out):
    out.mkdir(parents=True, exist_ok=False)
    samples = {
        'EPUB3-cover.epub': (dict(), 'accept with embedded cover'),
        'EPUB2-cover.epub': (dict(version=2), 'accept with NCX navigation and cover'),
        'EPUB3-no-cover.epub': (dict(cover='none'), 'accept with placeholder'),
        'EPUB3-damaged-cover.epub': (dict(cover='damaged'), 'accept body with placeholder'),
        'Unsupported-fixed-layout.epub': (dict(fixed=True), 'reject unsupported fixed layout'),
        'Rejected-traversal.epub': (dict(traversal=True), 'reject unsafe archive'),
    }
    manifest = {}
    for name, (options, expected) in samples.items():
        data = epub(**options)
        if data != epub(**options):
            raise ValueError('Nondeterministic sample')
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if archive.testzip() is not None or archive.read('mimetype') != b'application/epub+zip':
                raise ValueError('Invalid generated ZIP')
        with (out / name).open('xb') as stream:
            stream.write(data)
        manifest[name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), expected=expected, synthetic=True)
    (out / 'SAMPLE_MANIFEST.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    with (out / 'EPUB_PHONE_OBSERVATIONS.csv').open('x', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['id', 'case', 'status', 'actual_result'])
        for number, case in enumerate(['EPUB3导入与封面', 'EPUB2与NCX目录', '跨章与章内跳转', '滚动后退出复开', '结束进程后复开', '字号行距主题重排', '无封面与坏封面回退', '返回TXT无串书', '固定版式明确拒绝', '路径穿越明确拒绝'], 1):
            writer.writerow([f'E{number:02d}', case, '未执行', ''])
    return dict(samples=manifest, native_executions=0, physical_acceptance='not performed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.out), ensure_ascii=False, indent=2))
