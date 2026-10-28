import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct DecodeTimingSummaryTests {
    @Test func fixedEncodingAndNestedTimingsDoNotClaimSeparateUnicodeCostsOrExposeText() async throws {
        let pair = AsyncStream<ProcessingMeasurement>.makeStream(bufferingPolicy: .bufferingOldest(16))
        defer { pair.continuation.finish() }
        let task = Task {
            var values: [ProcessingMeasurement] = []
            for await value in pair.stream { values.append(value) }
            return values
        }
        _ = try await TXTProcessor().decode(Data("PRIVATE_TEXT_SENTINEL\r\n中😀e\u{301}\r".utf8), using: .utf8,
            observe: { metrics in ProcessingMeasurement.decoder(metrics, observe: { _ = pair.continuation.yield($0) }) })
        pair.continuation.finish()
        let values = await task.value
        let total = try #require(values.first { $0.phase == .decoderTotal })
        #expect(total.encoding == .utf8 && total.requestedEncoding == .utf8)
        #expect(values.contains { $0.phase == .unicodeScanBuild })
        #expect(!values.contains { $0.phase == .scanConversion || $0.phase == .normalizationIndex })
        let summary = ProcessingMeasurement.summary(values)
        #expect(summary.contains("UTF-8") && summary.contains("固定编码"))
        #expect(summary.contains("未拆分") && summary.contains("不重复相加"))
        #expect(!summary.contains("PRIVATE_TEXT_SENTINEL"))
    }
}
