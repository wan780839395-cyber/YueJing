import Foundation

/// No MainActor inheritance, detached tasks, stored CoreText objects, or mutable global state.
/// The caller awaits this actor; all returned data is immutable and Sendable.
public actor TXTProcessor {
    public init() {}

    public func decode(_ bytes: Data, using encoding: TXTEncoding? = nil,
                       chunkSize: Int = 4096, observe: TXTDecodeObserver? = nil) throws -> TXTDocument {
        var metrics = TXTDecodeMetrics(requestedEncoding: encoding, enabled: observe != nil)
        let started = metrics.start()
        defer { metrics.processorSeconds = TXTDecodeMetrics.elapsed(started); observe?(metrics) }
        try Task.checkCancellation()
        return try TXTDecoder.decode(bytes, using: encoding, chunkSize: chunkSize, metrics: &metrics)
    }

    public func chapters(in document: TXTDocument) throws -> [TXTChapter] {
        try TXTChapters.split(document)
    }

    public func paginate(_ document: TXTDocument, layout: TXTPageLayout) throws -> [TXTPage] {
        try TXTPaginator.paginate(document, layout: layout)
    }
}
