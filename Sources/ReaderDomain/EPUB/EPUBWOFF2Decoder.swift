import Foundation
@_implementationOnly import CWOFF2

/// In-memory reconstruction only. EPUBFontPreparation validates the returned SFNT before use.
internal enum EPUBWOFF2Decoder {
    // Do not reserve an 8 MiB destination for each concurrent import. No suspension,
    // IO or dispatch while holding this lock; the C cancellation callback is synchronous.
    private static let gate = NSLock()

    static func decode(_ data: Data, inputRemaining: Int, outputRemaining: Int) throws -> Data {
        try Task.checkCancellation()
        let bookCap = EPUBAuthorStyles.maxTotalFontBytes
        guard (0...bookCap).contains(inputRemaining), (1...bookCap).contains(outputRemaining),
              data.count <= inputRemaining, data.count <= EPUBAuthorStyles.maxFontBytes else {
            throw EPUBError.limitExceeded
        }
        guard data.count >= 48 else { throw EPUBError.corruptResource }
        gate.lock()
        defer { gate.unlock() }
        try Task.checkCancellation()
        let capacity = min(outputRemaining, EPUBAuthorStyles.maxFontBytes)
        var output = Data(count: capacity)
        var options = yj_options(input_remaining: inputRemaining, output_remaining: outputRemaining,
                                 cancelled: { _ in Task.isCancelled ? 1 : 0 }, opaque: nil)
        var written = 0
        let status = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                yj_woff2_decode(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                                destination.bindMemory(to: UInt8.self).baseAddress, destination.count,
                                &options, &written)
            }
        }
        try Task.checkCancellation()
        switch status {
        case YJ_OK:
            guard written > 0, written <= capacity else { throw EPUBError.corruptResource }
            output.count = written
            return output
        case YJ_INVALID: throw EPUBError.corruptResource
        case YJ_UNSUPPORTED: throw EPUBError.unsupportedContent
        case YJ_LIMIT: throw EPUBError.limitExceeded
        case YJ_CANCELLED: throw CancellationError()
        // Transient runtime errors must not persist an omitted font or a partially updated book.
        case YJ_ALLOC_FAILED: throw POSIXError(.ENOMEM)
        case YJ_BUSY: throw POSIXError(.EBUSY)
        default: throw POSIXError(.EIO)
        }
    }
}
