import Foundation

/// Local aggregate diagnostics. Contains no title, path, text, document hash, or private error.
public struct TXTDecodeMetrics: Sendable {
    public internal(set) var encoding: TXTEncoding?
    public let requestedEncoding: TXTEncoding?
    public internal(set) var processorSeconds = 0.0
    public internal(set) var scanConversionSeconds = 0.0
    public internal(set) var normalizationIndexSeconds = 0.0
    public internal(set) var unicodeScanBuildSeconds = 0.0
    public internal(set) var rawHashSeconds = 0.0
    public internal(set) var versionHashSeconds = 0.0
    public internal(set) var candidateScans = 0
    public internal(set) var unicodeScans = 0
    public internal(set) var gbScans = 0
    public internal(set) var batchConversions = 0
    public internal(set) var scalarConversions = 0
    public internal(set) var roundTrips = 0
    public internal(set) var fallbackBlocks = 0
    public internal(set) var largestGBInputBlock = 0
    public internal(set) var largestGBConversionBuffer = 0
    let enabled: Bool

    init(requestedEncoding: TXTEncoding?, enabled: Bool) {
        self.requestedEncoding = requestedEncoding; encoding = requestedEncoding; self.enabled = enabled
    }

    func start() -> ContinuousClock.Instant? { enabled ? ContinuousClock().now : nil }
    static func elapsed(_ start: ContinuousClock.Instant?) -> Double {
        guard let start else { return 0 }
        let value = start.duration(to: ContinuousClock().now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

public typealias TXTDecodeObserver = @Sendable (TXTDecodeMetrics) -> Void
