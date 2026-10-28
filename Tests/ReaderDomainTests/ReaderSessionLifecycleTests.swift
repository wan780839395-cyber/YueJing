import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct ReaderSessionLifecycleTests {
    @Test func supersededOpensAtEachSuspensionCannotRevokeTheLatestSessionOrLease() async throws {
        for step in [ReaderOpenStep.sourceReady, .sessionStarted, .preferencesLoaded] {
            let f = try await DerivedBookFixture()
            defer { f.remove() }
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let gate = ReaderTestGate()
            let old = Task {
                try await f.service.openReader(id: f.book.id, budget: f.budget,
                    inject: { if $0 == step { await gate.pause() } })
            }
            do { try await gate.wait() } catch { old.cancel(); await gate.release(); _ = try? await old.value; throw error }
            let settings = ReaderPreferences(fontSize: 29, lineSpacing: 12, theme: .dark)
            try await f.store.savePreferences(settings)
            let latest = try await f.service.openReader(id: f.book.id, budget: f.budget)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await old.value }
            #expect(latest.preferences == settings)
            #expect(await f.store.activeDerivedLeaseCount() == 1)
            let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0, lineFraction: 0.7)
            #expect(try await latest.saveProgress(anchor, sequence: 3))
            #expect(try await latest.savePreferences(settings, sequence: 3))
            try await latest.close()
            #expect(await f.store.activeDerivedLeaseCount() == 0)
        }
    }

    @Test func cancellationAfterSourceSessionOrPreferencesClosesOnlyItsOwnResources() async throws {
        for step in [ReaderOpenStep.sourceReady, .sessionStarted, .preferencesLoaded] {
            let f = try await DerivedBookFixture()
            defer { f.remove() }
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let gate = ReaderTestGate()
            let cancelled = Task {
                try await f.service.openReader(id: f.book.id, budget: f.budget,
                    inject: { if $0 == step { await gate.pause() } })
            }
            do { try await gate.wait() } catch { cancelled.cancel(); await gate.release(); _ = try? await cancelled.value; throw error }
            cancelled.cancel()
            let current = try await f.service.openReader(id: f.book.id, budget: f.budget)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(await f.store.activeDerivedLeaseCount() == 1)
            let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0, lineFraction: 0.4)
            try await current.close(anchor: anchor, sequence: 5)
            let reopened = try await f.service.openReader(id: f.book.id, budget: f.budget)
            #expect(reopened.reading.anchor == anchor)
            try await reopened.close()
            #expect(await f.store.activeDerivedLeaseCount() == 0)
        }
    }

    @Test func concurrentClosesJoinOneFinalSaveInsteadOfFinishingEarlyWithNil() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let gate = ReaderTestGate(), joined = ReaderTestGate()
        let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0, lineFraction: 0.8)
        let settings = ReaderPreferences(fontSize: 27, lineSpacing: 10, theme: .dark)
        let first = Task {
            try await reader.close(anchor: anchor, sequence: 9, preferences: settings, preferencesSequence: 9,
                inject: { if $0 == .started { await gate.pause() } })
        }
        do { try await gate.wait() } catch { await gate.release(); _ = try? await first.value; throw error }
        let second = Task { try await reader.close(inject: { if $0 == .joined { await joined.signal() } }) }
        do { try await joined.wait() } catch { await gate.release(); _ = try? await first.value; _ = try? await second.value; throw error }
        #expect(await f.store.activeDerivedLeaseCount() == 1)
        #expect(try await reader.saveProgress(anchor, sequence: 10) == false)
        await gate.release()
        try await first.value; try await second.value
        #expect(await f.store.activeDerivedLeaseCount() == 0)
        #expect(await reader.source.statistics().retainedLogicalBytes == 0)
        let next = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(next.reading.anchor == anchor && next.preferences == settings)
        try await next.close()
    }

    @Test func failedFinalSaveRollsBackAndRevokesWritesWithoutClearingANewerSession() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let saved = try await f.savedAnchor()
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let settings = ReaderPreferences(fontSize: 35, lineSpacing: 19, theme: .dark)
        let invalid = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: f.book.byteCount + 1)
        await #expect(throws: LibraryError.invalidAnchor) {
            try await reader.close(anchor: invalid, sequence: 10, preferences: settings, preferencesSequence: 10)
        }
        #expect(await f.store.activeDerivedLeaseCount() == 0)
        #expect(try await reader.saveProgress(saved, sequence: 11) == false)
        #expect(try await reader.savePreferences(settings, sequence: 11) == false)
        // Bypass the handle too: Store revoked the failed session before the failed transaction.
        #expect(try await f.store.saveProgress(session: reader.reading.session, anchor: saved, sequence: 12) == false)
        let next = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(next.reading.anchor == saved && next.preferences == ReaderPreferences())
        try await reader.close() // Old retry must not clear the newer active session.
        #expect(try await next.saveProgress(saved, sequence: 13))
        try await next.close()
    }

    @Test func closedAndSupersededCallbacksCannotOverwriteNewerProgressOrSettings() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let old = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0, lineFraction: 0.6)
        let latestSettings = ReaderPreferences(fontSize: 30, lineSpacing: 10, theme: .dark)
        let new = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(try await new.saveProgress(anchor, sequence: 4))
        #expect(try await new.savePreferences(latestSettings, sequence: 4))
        #expect(try await new.savePreferences(ReaderPreferences(), sequence: 3) == false)
        #expect(try await old.saveProgress(anchor, sequence: 100) == false)
        #expect(try await old.savePreferences(ReaderPreferences(), sequence: 100) == false)
        try await old.close(anchor: anchor, sequence: 101, preferences: ReaderPreferences(), preferencesSequence: 101)
        #expect(await f.store.activeDerivedLeaseCount() == 1)
        // A lower final sequence must preserve the newer already-saved settings.
        try await new.close(anchor: anchor, sequence: 5, preferences: ReaderPreferences(), preferencesSequence: 2)
        let reopened = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(reopened.reading.anchor == anchor && reopened.preferences == latestSettings)
        try await reopened.close()
    }

    @Test func concurrentMissesShareOneProducerAndCancellingOneConsumerKeepsTheOtherAlive() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let started = ReaderTestGate(), joined = ReaderTestGate()
        let first = Task {
            try await f.service.openReader(id: f.book.id, budget: f.budget,
                inject: { if $0 == .buildStarted { await started.pause() } })
        }
        do { try await started.wait() } catch { first.cancel(); await started.release(); _ = try? await first.value; throw error }
        let second = Task {
            try await f.service.openReader(id: f.book.id, budget: f.budget,
                inject: { if $0 == .buildJoined { await joined.pause() } })
        }
        do { try await joined.wait() } catch { first.cancel(); second.cancel(); await started.release(); await joined.release(); _ = try? await first.value; _ = try? await second.value; throw error }
        first.cancel()
        await joined.release(); await started.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        let reader = try await second.value
        let stats = await f.service.readingRouteStatistics()
        #expect(stats.documentDecodes == 1 && stats.chapterBuilds == 1)
        #expect(await f.store.activeDerivedLeaseCount() == 1)
        _ = try await reader.chapterPage(start: 0, limit: 32)
        try await reader.close()
        #expect(await f.store.activeDerivedLeaseCount() == 0)
    }

    @Test func productSummariesReportMeasuredScopesAndLogicalBudgetWithoutPrivateValues() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let trace = ReaderMeasurementLog()
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget, measure: trace.observe)
        let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0)
        _ = try await reader.window(around: anchor, width: 320, preferences: reader.preferences, measure: trace.observe)
        let values = await trace.values(), summary = ProcessingMeasurement.summary(values)
        #expect(values.contains { $0.phase == .sourceVerification })
        #expect(values.contains { $0.phase == .diskHit })
        #expect(values.contains { $0.phase == .rangeRead && ($0.bytes ?? 0) > 0 && $0.budgetBytes == f.budget.maximumWorkingBytes })
        #expect(summary.contains("未拆分") && summary.contains("非RSS") && summary.contains("预算"))
        #expect(!summary.contains(f.book.id) && !summary.contains(f.book.title) && !summary.contains(f.root.path))
        #expect(!summary.contains("首绘") && !summary.contains("冷启动"))
        try await reader.close()
    }
}

/// The production observer is synchronous; this test collector contains only fixed measurements.
private struct ReaderMeasurementLog: Sendable {
    private let continuation: AsyncStream<ProcessingMeasurement>.Continuation
    private let consumer: Task<[ProcessingMeasurement], Never>
    init() {
        let pair = AsyncStream<ProcessingMeasurement>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        consumer = Task {
            var values: [ProcessingMeasurement] = []
            for await value in pair.stream { values.append(value) }
            return values
        }
    }
    var observe: ProcessingMeasurementObserver { let sink = continuation; return { _ = sink.yield($0) } }
    func values() async -> [ProcessingMeasurement] { continuation.finish(); return await consumer.value }
}
