import Foundation

/// Fixed local reason codes and numeric costs only; never publication identifiers or error text.
struct EPUBReopenDiagnostics: Sendable {
    enum Reason: String, Sendable {
        case takeHit, takeMiss, takeInvalid
        case closeStarted, closeNotReady, leaseUnavailable, controllerMissing, saveFailed, abandoned
        case parkNotReady, parkContentMismatch, parkJavaScriptFailure, parkMalformedReply
        case parkTimeout, parkInvalidated, parkCancelled, parkInvalidState, parked
        case retained, rejectBudget, rejectDisabled, rejectNotParked, rejectInactiveRoute
        case evictedCount, evictedBytes, evictedInvalid, memoryWarning, explicitDiscard
        case processTerminated, leftEPUB
    }
    struct Sample: Sendable {
        let reason: Reason
        var estimatedBytes: Int = 0
        var imageBytes: Int = 0
        var xhtmlBytes: Int = 0
        var limitBytes: Int = 0
    }
    private(set) var samples: [Sample] = []
    mutating func record(_ reason: Reason) { append(Sample(reason: reason)) }
    mutating func append(_ sample: Sample) {
        if samples.count == 16 { samples.removeFirst() }
        samples.append(sample)
    }
    var summary: String {
        let rows = samples.map { sample in
            var row = sample.reason.rawValue
            if sample.estimatedBytes > 0 || sample.limitBytes > 0 {
                row += " estimate=\(sample.estimatedBytes)B xhtml=\(sample.xhtmlBytes)B images=\(sample.imageBytes)B limit=\(sample.limitBytes)B"
            }
            return row
        }
        return "复用原因：reopen-reasons-v1（本进程同书最近16项，旧记录可能已淘汰；估算非RSS）\n" +
            (rows.isEmpty ? "无保留记录" : rows.joined(separator: " → "))
    }
}

/// Preserve the existing conservative estimate, including whole-publication metadata allowance.
/// This is not a measurement of DOM residency or RSS, and does not change admission limits.
struct EPUBRendererCost: Sendable {
    let xhtmlBytes: Int
    let imageBytes: Int
    var total: Int { 16 * 1024 * 1024 + imageBytes + xhtmlBytes * 2 }
}
