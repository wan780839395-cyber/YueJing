import CoreFoundation
import XCTest
import UIKit

/// Non-gate diagnostics for the first open of each synthetic fixture, not additional test cases.
@MainActor
enum ReadingEntryEvidence {
    private struct Identity {
        let pid: Int
        let route: String
        let window: String
    }
    private static var sessions: [String: String] = [:]
    private static var started: Set<String> = []
    private static var failed: Set<String> = []
    private static var identities: [String: Identity] = [:]

    static func prepare(_ app: XCUIApplication, key: String, session: String) {
        sessions[key] = session
        started.remove(key); failed.remove(key); identities.removeValue(forKey: key)
        app.launchEnvironment["YUEJING_READER_ENTRY_PROBE"] = "1"
    }

    static func beforeSettings(_ app: XCUIApplication, key: String, sharedDeadline: Date) -> Bool {
        guard sessions[key] != nil, started.insert(key).inserted else { return false }
        capture(app, key: key, phase: "initial", sharedDeadline: sharedDeadline)
        return true
    }

    static func settingsFailed(_ app: XCUIApplication, key: String) {
        guard started.contains(key), failed.insert(key).inserted else { return }
        // The functional waiter has already returned a failure. Never restart it or click.
        capture(app, key: key, phase: "failure", sharedDeadline: nil)
    }

    private static func capture(_ app: XCUIApplication, key: String, phase: String, sharedDeadline: Date?) {
        guard let nonce = sessions[key] else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let allowance = min(2.0, max(0, sharedDeadline?.timeIntervalSinceNow ?? 2.0))
        let deadline = startedAt + allowance
        let request = "dev.yuejing.entry.\(nonce).\(phase)"
        var record: [String: Any] = ["schema": 1, "kind": "reading-entry-diagnostic", "nonGate": true,
            "case": key, "phase": phase, "nonce": nonce, "request": request,
            "runnerPID": ProcessInfo.processInfo.processIdentifier, "startedUptime": startedAt,
            "cooperativeAllowanceSeconds": allowance, "cooperativeDeadlineUptime": deadline,
            "insideOriginalOpenBudget": sharedDeadline != nil, "functionalOutcomeAlreadyFailed": phase == "failure",
            "maximumCacheReads": 2, "sequentialNotAtomic": true, "observationMayChangeTiming": true,
            "hardWallClockBoundGuaranteed": false, "validation": "unknown", "unknownReasons": ["not-completed"]]
        if let sharedDeadline { record["sharedBudgetAtStartSeconds"] = sharedDeadline.timeIntervalSinceNow }
        persist(record, key: key, phase: phase, checkpoint: "started")
        var reasons: [String] = []
        defer {
            let ended = ProcessInfo.processInfo.systemUptime
            record["endedUptime"] = ended; record["elapsedSeconds"] = ended - startedAt
            record["deadlineOverrunSeconds"] = max(0, ended - deadline)
            if let sharedDeadline { record["sharedBudgetAtEndSeconds"] = sharedDeadline.timeIntervalSinceNow }
            if ended > deadline { reasons.append("cooperative-deadline-reached-or-overrun") }
            record["unknownReasons"] = reasons
            record["validation"] = reasons.isEmpty ? "observed-sequential-not-atomic" : "unknown"
            persist(record, key: key, phase: phase, checkpoint: "finished")
        }
        guard allowance > 0, ProcessInfo.processInfo.systemUptime < deadline else {
            reasons.append("original-or-diagnostic-budget-exhausted-no-request"); return
        }
        let posted = ProcessInfo.processInfo.systemUptime
        record["requestPostedUptime"] = posted
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: request as CFString), nil, nil, true)

        let endpoint = app.descendants(matching: .any).matching(identifier: "ui.fixture.reader.entryprobe").firstMatch
        var envelope: [String: Any]?
        var cacheReads = 0
        var readEnded = posted
        let cached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard cacheReads < 2, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            cacheReads += 1
            guard endpoint.exists, ProcessInfo.processInfo.systemUptime < deadline,
                  let raw = endpoint.value as? String else { return false }
            readEnded = ProcessInfo.processInfo.systemUptime
            guard raw.utf8.count <= 65536, let data = raw.data(using: .utf8),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            envelope = value
            return (value["samples"] as? [String: Any])?[phase] != nil
        }, object: nil)
        let cacheResult = XCTWaiter.wait(for: [cached], timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        record["cacheWaitResult"] = cacheResult.rawValue; record["cacheReads"] = cacheReads
        record["cacheReadEndedUptime"] = readEnded
        if let envelope { record["appEnvelope"] = envelope }
        // Preserve even a partial/unknown native cache before any further AX property access.
        persist(record, key: key, phase: phase, checkpoint: "app-cache")

        var observations: [String: Any] = [:]
        @MainActor func observe(_ label: String, _ read: @MainActor () -> Any) -> Any? {
            let from = ProcessInfo.processInfo.systemUptime
            guard from < deadline else {
                observations[label] = ["status": "unknown", "reason": "cooperative-deadline-before-query"]
                return nil
            }
            let value = read(), to = ProcessInfo.processInfo.systemUptime
            observations[label] = ["status": "observed", "startedUptime": from, "endedUptime": to, "value": value]
            return value
        }
        let settings = app.buttons["reader.tools.settings"], exit = app.buttons["reader.exit"]
        let settingsExists = observe("settings.exists") { settings.exists } as? Bool
        var settingsRect: CGRect?, exitRect: CGRect?
        if settingsExists == true {
            _ = observe("settings.enabled") { settings.isEnabled }
            _ = observe("settings.hittable") { settings.isHittable }
            _ = observe("settings.frame") { let frame = settings.frame; settingsRect = frame; return rectangle(frame) }
        } else { reasons.append("settings-not-found-or-unobserved") }
        if observe("exit.exists", { exit.exists }) as? Bool == true {
            _ = observe("exit.frame") { let frame = exit.frame; exitRect = frame; return rectangle(frame) }
        }
        record["observations"] = observations
        for label in ["settings.exists", "settings.enabled", "settings.hittable", "settings.frame", "exit.frame"] {
            if (observations[label] as? [String: Any])?["status"] as? String != "observed" {
                reasons.append("unobserved-\(label)")
            }
        }
        guard cacheResult == .completed, let envelope,
              let response = (envelope["samples"] as? [String: Any])?[phase] as? [String: Any],
              let sample = response["appSample"] as? [String: Any] else {
            reasons.append("native-cache-unavailable-or-incomplete-no-request-retry"); return
        }
        var stateReasons: [String] = []
        if envelope["schema"] as? Int != 1 || sample["schema"] as? Int != 1 {
            stateReasons.append("unsupported-schema")
        }
        if envelope["nonce"] as? String != nonce || sample["nonce"] as? String != nonce
            || envelope["bundle"] as? String != "dev.yuejing.app" || sample["bundle"] as? String != "dev.yuejing.app"
            || response["request"] as? String != request || response["phase"] as? String != phase {
            stateReasons.append("request-or-fixture-mismatch")
        }
        if response["status"] as? String != "observed" || sample["status"] as? String != "observed"
            || sample["sampleKind"] as? String != "explicit-entry-request"
            || sample["sequence"] as? Int != (phase == "initial" ? 1 : 2) {
            stateReasons.append("native-sample-unknown-or-wrong-sequence")
        }
        if let received = response["receivedUptime"] as? Double,
           let from = sample["startedUptime"] as? Double, let to = sample["endedUptime"] as? Double,
           let completed = response["completedUptime"] as? Double,
           [received, from, to, completed, readEnded].allSatisfy({ $0.isFinite }),
           posted <= received, received <= from, from <= to, to <= completed, completed <= readEnded,
           to - from <= 0.25 {
            record["sampleAgeAtReadSeconds"] = readEnded - to
        } else { stateReasons.append("unconfirmed-time-order-or-native-budget") }
        if let pid = sample["appPID"] as? Int, pid > 0, pid != Int(ProcessInfo.processInfo.processIdentifier),
           envelope["appPID"] as? Int == pid, let route = sample["routeID"] as? String,
           UUID(uuidString: route) != nil, let window = sample["windowToken"] as? String, !window.isEmpty {
            if phase == "initial", stateReasons.isEmpty {
                identities[key] = Identity(pid: pid, route: route, window: window)
            } else if phase == "failure" {
                if let first = identities[key], first.pid == pid, first.route == route, first.window == window {
                    record["sameEntryIdentity"] = true
                } else { stateReasons.append("entry-process-route-or-window-unconfirmed") }
            }
        } else { stateReasons.append("missing-native-identity") }
        record["stateValidation"] = stateReasons.isEmpty ? "observed-request-correlated-not-atomic" : "unknown"
        reasons += stateReasons
        if !matches(sample["exitScreenRect"], exitRect) { reasons.append("exit-marker-and-AX-geometry-unconfirmed") }
        let hit = sample["hit"] as? [String: Any], search = hit?["bottomAXSearch"] as? [String: Any]
        let bottomMatches = matches(hit?["bottomScreenRect"], settingsRect)
        record["settingsGeometryValidation"] = bottomMatches ? "matched-sequentially-not-atomic" : "unknown"
        if !bottomMatches { reasons.append("settings-native-and-AX-geometry-unconfirmed") }
        if hit?["status"] as? String != "observed" || hit?["bottomStatus"] as? String != "observed-public-AX-frame"
            || search?["truncated"] as? Bool != false || search?["matches"] as? Int != 1
            || (hit?["bottomHitChain"] as? [[String: Any]])?.isEmpty != false {
            reasons.append("settings-hit-chain-unavailable-or-truncated")
        }
        if sample["keyWindow"] as? Bool != true { reasons.append("native-window-not-confirmed-key") }
    }

    private static func rectangle(_ rect: CGRect) -> [Any] {
        [rect.minX, rect.minY, rect.width, rect.height].map { $0.isFinite ? Double($0) as Any : "nonfinite" as Any }
    }
    private static func matches(_ raw: Any?, _ expected: CGRect?) -> Bool {
        guard let actual = raw as? [Double], actual.count == 4, let expected,
              expected.width > 0, expected.height > 0 else { return false }
        let values = [Double(expected.minX), Double(expected.minY), Double(expected.width), Double(expected.height)]
        return zip(actual, values).allSatisfy { $0.0.isFinite && $0.1.isFinite && abs($0.0 - $0.1) <= 0.5 }
    }
    private static func persist(_ record: [String: Any], key: String, phase: String, checkpoint: String) {
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            ?? Data("{\"nonGate\":true,\"validation\":\"unknown-encoding\"}".utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.utf8-plain-text")
        let name = "YueJingUI--\(key)--entry-\(phase)-\(checkpoint).entryprobe.json"
        attachment.name = name; attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}
