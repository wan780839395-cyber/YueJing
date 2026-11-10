"""Source contracts only. Does not execute Swift, SQLite, iOS or measure phone performance."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding='utf-8')

def main():
    service = read('Sources/ReaderDomain/LibraryService.swift')
    store = read('Sources/ReaderDomain/LibraryStore.swift')
    pool = read('Sources/ReaderDomain/EPUB/EPUBContentPool.swift')
    assert 'storedEPUBSnapshot(bookID: id, reusing: decoded)' in service, 'reopen must carry one decoded metadata snapshot into session confirmation'
    snapshot = read('Sources/ReaderDomain/EPUB/EPUBMetadataSnapshot.swift')
    assert 'private let metadata: Data' in snapshot and 'metadata == current' in snapshot
    assert 'metadataSHA256 = EPUBResourceStore.digest(metadata)' in snapshot
    assert snapshot.count('JSONDecoder().decode(EPUBPackage.self, from: metadata)') == 1
    assert '[String: String]' in snapshot and 'maximumEntries = 64' in snapshot
    assert 'cached[snapshot.metadataSHA256]' in snapshot and 'encoder.outputFormatting = [.sortedKeys]' in snapshot
    assert 'cached.removeValue(forKey: order.removeFirst())' in snapshot
    begin = store.split('func beginEPUB(', 1)[1].split('func beginEPUBNavigation', 1)[0]
    assert 'snapshot.matches(metadata)' in begin and 'JSONDecoder().decode(EPUBPackage.self' not in begin
    assert 'readerOpens[permit.bookID] == permit.id' in begin and 'book.versionID == package.versionID' in begin
    assert 'snapshot: snapshot' in service and 'packageFingerprint' in pool
    assert 'EPUBResourceStore.sourceDigest(archive)' in pool
    assert 'EPUBPublicationCache.verifyResources(publication)' in pool
    assert 'EPUBMetadataFingerprintCache.canonical(expected)' in pool
    build = pool.split('private func build(', 1)[1].split('private func grant(', 1)[0]
    assert 'canonical(' not in build and 'fingerprint(' not in build
    assert 'package == expected' in build
    timing = read('Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift')
    assert 'metadata-snapshot-v1' in timing and 'packageFingerprintReused' in timing
    tests = read('Tests/ReaderDomainTests/EPUBContentPoolTests.swift')
    for token in ('verifyMetadataSnapshotReuse', 'verifyMetadataMutationRejectsSession',
                  'firstByteSnapshot.matches', 'fingerprints.count == 64',
                  'openingTimings.packageFingerprintReused', 'snapshot: snapshot'):
        assert token in tests, token
    assert len(re.findall(r'@Test\s+func\s+', tests)) == 6, 'existing selected identities must remain six'
    print('PASS: single metadata decode path; exact-byte session recheck; bounded SHA-keyed canonical fingerprints; full source/resource integrity retained; diagnostics and native regression declarations present.')
    print('STATIC ONLY: Swift compilation, native regressions and phone speed NOT verified.')

if __name__ == '__main__':
    main()
