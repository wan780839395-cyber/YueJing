"""Bounded source checks for P0 observation only; no native or performance claim."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]

def main():
    timing = (ROOT/'Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift').read_text('utf-8')
    assert 'sessionBreakdown' in timing, 'opening diagnostics must expose session substage timings'
    trace = (ROOT/'Sources/ReaderDomain/EPUB/EPUBSessionBreakdown.swift').read_text('utf-8')
    store = (ROOT/'Sources/ReaderDomain/LibraryStore.swift').read_text('utf-8')
    service = (ROOT/'Sources/ReaderDomain/LibraryService.swift').read_text('utf-8')
    begin = store.split('func beginEPUBMeasured(', 1)[1].split('func beginEPUBNavigation(', 1)[0]
    assert 'samples.count < 24' in trace and 'session-breakdown-v1' in trace
    assert '不与外层重复相加' in trace and '非纯fsync' in trace
    for phase in ('actorAdmission', 'storeSetup', 'databaseEntry', 'bookRead', 'formatRead',
                  'metadataRead', 'metadataCompare', 'progressRead', 'progressDecode',
                  'positionValidation', 'rowUpdate', 'transactionReturn', 'storePublish'):
        assert '.' + phase in begin, phase
    for phase in ('preferencesCall', 'beginCall', 'confirmCall', 'releaseCall', 'returnResume'):
        assert '.' + phase in service, phase
    assert 'snapshot.matches(metadata)' in begin
    assert 'readerOpens[permit.bookID] == permit.id' in begin
    assert 'try? $0.validate(in: package)' in begin
    assert 'UPDATE books SET activeSession=?,lastReadAt=? WHERE id=?' in begin
    assert 'queue.write' in begin and 'await' not in begin
    assert 'beginEPUBMeasured(permit, snapshot: snapshot, requestedAt:' in service
    assert 'confirmReaderOpen(permit, session: start.session)' in service
    assert 'await store.endReaderOpen(permit)' in service
    assert 'sessionBreakdown.merge(measured.details)' in service
    tests = (ROOT/'Tests/ReaderDomainTests/EPUBContentPoolTests.swift').read_text('utf-8')
    assert 'verifySessionBreakdown' in tests and 'session-breakdown-v1' in tests
    assert 'sessionBreakdown.samples' in tests and 'metadataBytes > 0' in tests
    assert len(re.findall(r'@Test\s+func\s+', tests)) == 6
    print('PASS: bounded fixed-label P0 session observation; nested intervals labelled; SQL/permit/position checks retained; regression declarations present.')
    print('STATIC ONLY: Swift compilation, SQLite execution, native clocks and physical performance NOT verified.')

if __name__ == '__main__':
    main()
