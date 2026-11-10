"""Source contracts, not Swift execution or a performance benchmark."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def main():
    snapshot = read('Sources/ReaderDomain/EPUB/EPUBMetadataSnapshot.swift')
    pool = read('Sources/ReaderDomain/EPUB/EPUBContentPool.swift')
    store = read('Sources/ReaderDomain/LibraryStore.swift')
    service = read('Sources/ReaderDomain/LibraryService.swift')
    resource = read('Sources/ReaderDomain/EPUB/EPUBResourceStore.swift')
    timings = read('Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift')
    tests = read('Tests/ReaderDomainTests/EPUBContentPoolTests.swift')
    assert 'final class Decoded: Sendable' in snapshot, 'lease-held decoded metadata proof required'
    assert 'fileprivate init(package: EPUBPackage, metadataSHA256: String)' in snapshot
    assert snapshot.index('metadataSHA256 = EPUBResourceStore.digest(metadata)') < snapshot.index('if let reusing')
    assert 'reusing.metadataSHA256 == metadataSHA256' in snapshot
    assert 'metadata == current' in snapshot and snapshot.count('JSONDecoder().decode(EPUBPackage.self, from: metadata)') == 1
    holder = pool.split('private struct Holder {')[1].split('private var entries:')[0]
    entry = pool.split('private struct Entry {')[1].split('private struct Holder {')[0]
    assert 'EPUBMetadataSnapshot.Decoded?' in holder and 'Decoded' not in entry
    reuse = pool.split('func reusableMetadata(')[1].split('private static func requireDirectory')[0]
    assert 'holders.values' in reuse and '!entry.retired' in reuse and 'entry.root == root' in reuse
    assert 'decoded: holder.decoded' in pool and 'holders.removeValue(forKey: token)' in pool
    assert pool.count('decoded: snapshot?.decoded') == 4
    assert 'EPUBResourceStore.sourceDigest(archive)' in pool and 'EPUBPublicationCache.verifyResources(publication)' in pool
    assert 'reusing: decoded' in service and 'timings.metadataDecodeReused = snapshot.decodeReused' in service
    assert 'EPUBMetadataSnapshot(metadata: metadata, reusing: reusing)' in store and 'snapshot.matches(metadata)' in store
    assert 'path.split(separator: "/").dropLast()' in resource
    assert '[.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]' in resource
    assert 'values.isSymbolicLink != true' in resource and 'digest(data) == resource.sha256' in resource
    assert 'values.fileSize == resource.byteCount' in resource and 'resource.byteCount + 1' in resource
    assert 'leased-metadata-v1' in timings and 'metadataDecodeReused' in timings
    for token in ('verifyLeaseHeldMetadataReuse', 'same.decoded === original.decoded',
                  'changedSnapshot.decodeReused == false', 'afterRelease == nil',
                  'reopened.openingTimings.metadataDecodeReused', 'verifyResourceAttributes'):
        assert token in tests, token
    print('PASS: full-byte SHA-gated lease-held decode reuse; no idle package cache; latest-state transaction retained; combined leaf attributes keep full integrity; native regressions declared.')
    print('STATIC ONLY: native execution0; Swift/SQLite/WKWebView/phone speed NOT verified.')
if __name__ == '__main__': main()
