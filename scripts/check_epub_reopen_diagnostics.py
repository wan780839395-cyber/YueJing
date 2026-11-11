"""Bounded reopen diagnostics contracts only. Not Swift compilation or native execution."""
from pathlib import Path
import sys

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
def read(name):
    return (ROOT / name).read_text(encoding='utf-8')

def main():
    diag = read('App/EPUB/EPUBReopenDiagnostics.swift')
    cache = read('App/EPUB/EPUBWarmRendererCache.swift')
    web = read('App/EPUB/EPUBWebView.swift')
    model = read('App/EPUB/EPUBReaderViewModel.swift')
    reply = read('App/EPUB/EPUBParkReply.swift')
    snapshot = read('Sources/ReaderDomain/EPUB/EPUBMetadataSnapshot.swift')
    timings = read('Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift')
    service = read('Sources/ReaderDomain/LibraryService.swift')
    host = read('Tests/YueJingHostTests/EPUBReaderHostTests.swift')
    domain = read('Tests/ReaderDomainTests/EPUBContentPoolTests.swift')
    assert 'samples.count == 16' in diag and 'diagnosticRecords.count == 64' in cache
    assert 'weak var service: LibraryService?' in cache
    sample = diag.split('struct Sample: Sendable {')[1].split('private(set) var samples')[0]
    assert 'String' not in sample and 'URL' not in sample and 'Error' not in sample
    assert not any(s in diag for s in ('bookID', 'localizedDescription', 'resourceRoot', 'print('))
    assert 'row.bookID == bookID && row.service === service' in cache
    close = cache.split('func recordClose(')[1].split('    init(')[0]
    assert close.index('diagnosticRoute?.generation == generation') < close.index('for sample in trace.samples')
    assert 'diagnosticRoute = (key, generation)' in cache and '.rejectInactiveRoute' in cache
    assert 'func recordInvalidation(' in cache and 'where sample.reason == .processTerminated || sample.reason == .parkInvalidated' in cache
    assert '.memoryWarning' in cache and 'recordActive(.leftEPUB)' in cache
    assert 'idleEstimatedBytes = 96 * 1024 * 1024' in cache and 'var totalRenderers = 3' in cache
    assert 'guard cost <= limits.idleEstimatedBytes, limits.totalRenderers > 0' in cache
    assert '16 * 1024 * 1024 + imageBytes + xhtmlBytes * 2' in diag
    for reason in ('takeMiss', 'takeHit', 'takeInvalid', 'rejectBudget', 'rejectDisabled', 'rejectNotParked',
                   'evictedCount', 'evictedBytes', 'evictedInvalid', 'explicitDiscard'):
        assert '.' + reason in cache, reason
    park = web.split('func parkForReopen(')[1].split('func restoreCallbacks(')[0]
    for token in ('parkNotReady', 'parkContentMismatch', 'parkJavaScriptFailure', 'parkMalformedReply',
                  'parkTimeout', 'parkCancelled', 'parkInvalidState', '.parked', 'parkingID == id',
                  'readyToken == request.token', 'Set(state.paths).isSubset(of: permitted)',
                  'state.paths.count <= EPUBChapterWindow.maximumChapters', 'json.utf8.count <= 32768',
                  'state.imageBytes <= 512 * 1024 * 1024', 'parkedEstimatedBytes = cost.total'):
        assert token in park, token
    assert 'if terminatedBeforePark { parkDiagnostics.record(.processTerminated) }' in park
    assert '.parkInvalidated' in web and '.processTerminated' in web
    assert 'Task.sleep(for: .seconds(2))' in reply
    assert 'self.continuation != nil' in reply and 'self.continuation = nil' in reply
    assert 'self.parkingID == id else { reply.finish(nil); return }' in park
    assert 'recordReopenTrace(controller.parkDiagnostics)' in model
    assert model.index('recordReopenTrace(controller.parkDiagnostics)', model.index('private func performClose')) < model.index('retainedRenderer = rendererCache.retain')
    for reason in ('closeStarted', 'closeNotReady', 'leaseUnavailable', 'controllerMissing', 'saveFailed', 'abandoned'):
        assert f'recordReopenReason(.{reason})' in model, reason
    assert 'reopen-reasons-v1' in model and '.diagnostics(bookID: self.bookID, service: self.service).summary' in model
    assert 'metadataSHA256 = EPUBResourceStore.digest(metadata)' in snapshot
    assert 'reusing.metadataSHA256 == metadataSHA256' in snapshot
    assert 'reuseReason = reusing == nil ? .noLeaseProof : .metadataChanged' in snapshot
    assert 'reuseReason = .reused' in snapshot and 'metadata == current' in snapshot
    assert 'timings.metadataReuseReason = snapshot.reuseReason' in service
    assert 'metadataReuseReason.rawValue' in timings
    for token in ('original.reuseReason == .noLeaseProof', 'same.reuseReason == .reused',
                  'changedSnapshot.reuseReason == .metadataChanged', 'coldAgain.reuseReason == .noLeaseProof'):
        assert token in domain, token
    for token in ('verifyReopenDiagnostics(fixture:', 'count: 1633', 'longBookCost.total >',
                  'ledger.diagnosticCount == 64', 'generation: old.generation', 'generation: current.generation',
                  'timeoutCount == 1', 'rejected.reason == .rejectBudget', 'rejected.limitBytes == 1',
                  'scenario == "invalid-state"', '.parkInvalidState', '.processTerminated', '.takeInvalid',
                  'openingTimings.metadataReuseReason == .reused'):
        assert token in host, token
    assert 'ledger.finish(current.generation)' in host and 'reason == .rejectInactiveRoute' in host
    assert 'next.samples.filter { $0.reason == .parked }.count == 1' in host
    print('PASS: bounded fixed-code diagnostics, weak service identity, generation guards, close/park/admission/eviction causes, unchanged budgets/full SHA, native regressions declared.')
    print('STATIC ONLY: native_executed=0; Swift/WKWebView and phone root cause NOT verified.')

if __name__ == '__main__':
    main()
