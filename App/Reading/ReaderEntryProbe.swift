#if DEBUG
import CoreFoundation
import ReaderDomain
import SwiftUI
import UIKit

/// Synthetic-fixture only. Darwin notifications request observations, never UI actions.
/// The AX getter below returns immutable cached JSON; automatic snapshots cannot spend samples.
@MainActor
final class ReaderEntryProbe {
    static let shared = ReaderEntryProbe()
    static var enabled: Bool {
        ReadingUITestFixture.isRequested
            && ProcessInfo.processInfo.environment["YUEJING_READER_ENTRY_PROBE"] == "1"
            && UUID(uuidString: ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] ?? "") != nil
    }
    private weak var store: ReaderHitProbeStore?
    private weak var endpoint: UIView?
    private var names: [String: String] = [:]
    private var consumed: Set<String> = []
    private var samples: [String: [String: Any]] = [:]
    private var firstRoute: String?
    private var firstWindow: String?
    private(set) var cachedValue = "{\"schema\":1,\"status\":\"unknown-not-attached\"}"

    private init() {}

    func attach(store: ReaderHitProbeStore, endpoint: UIView) {
        guard Self.enabled, names.isEmpty else { return }
        // Do not retarget a delayed request to a later reader route in this process.
        self.store = store; self.endpoint = endpoint
        let nonce = ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"]!
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for phase in ["initial", "failure"] {
            let name = "dev.yuejing.entry.\(nonce).\(phase)"
            names[name] = phase
            // Process-lifetime singleton, no unmanaged pointer or borrowed object crosses threads.
            CFNotificationCenterAddObserver(center, nil, { _, _, notification, _, _ in
                guard let notification else { return }
                let name = notification.rawValue as String
                Task { @MainActor in ReaderEntryProbe.shared.receive(name) }
            }, name as CFString, nil, .deliverImmediately)
        }
        publish()
    }

    private func receive(_ name: String) {
        guard Self.enabled, let phase = names[name], consumed.count < 2,
              consumed.insert(phase).inserted else { return }
        let received = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = ["request": name, "phase": phase, "receivedUptime": received,
            "status": "unknown", "nonGate": true, "predictionOnlyNoTouchSent": true,
            "observationMayPerturbComposition": true, "automaticAXReadsTriggerSampling": false]
        defer {
            record["completedUptime"] = ProcessInfo.processInfo.systemUptime
            samples[phase] = record
            publish()
        }
        if phase == "failure", samples["initial"] == nil {
            record["reason"] = "failure-before-initial-no-sample"; return
        }
        guard let store, let endpoint, endpoint.window != nil else {
            record["reason"] = "missing-live-endpoint-no-retry"; return
        }
        let raw = store.entryValue(endpoint: endpoint, requestSequence: phase == "initial" ? 1 : 2)
        guard raw.utf8.count <= 24576, let data = raw.data(using: .utf8),
              let sample = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            record["reason"] = "sample-unreadable-or-over-cap"; return
        }
        record["appSample"] = sample
        guard sample["status"] as? String == "observed",
              let route = sample["routeID"] as? String, let window = sample["windowToken"] as? String else {
            record["reason"] = "sample-reported-unknown"; return
        }
        if phase == "initial" {
            firstRoute = route; firstWindow = window
        } else if firstRoute != route || firstWindow != window {
            record["reason"] = "entry-route-or-window-unconfirmed"; return
        }
        record["status"] = "observed"
    }

    private func publish() {
        let envelope: [String: Any] = ["schema": 1, "bundle": "dev.yuejing.app",
            "nonce": ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] ?? "unknown",
            "appPID": ProcessInfo.processInfo.processIdentifier, "maximumSamples": 2,
            "automaticAXReadsTriggerSampling": false, "samples": samples]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
              data.count <= 65536, let value = String(data: data, encoding: .utf8) else {
            cachedValue = "{\"schema\":1,\"status\":\"unknown-envelope-over-cap-or-encoding\"}"; return
        }
        cachedValue = value
    }
}

@MainActor
struct ReaderEntryProbeEndpoint: UIViewRepresentable {
    let store: ReaderHitProbeStore
    let model: ReaderViewModel
    let routeID: UUID
    let tools: ReadingToolsPresentation

    func makeUIView(context: Context) -> ReaderEntryProbeValueView {
        let view = ReaderEntryProbeValueView(frame: .zero)
        view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true; view.accessibilityTraits = .staticText
        view.accessibilityIdentifier = "ui.fixture.reader.entryprobe"
        view.accessibilityLabel = "合成测试入口只读取证"
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: ReaderEntryProbeValueView, context: Context) {
        store.update(model: model, routeID: routeID, tools: tools)
        ReaderEntryProbe.shared.attach(store: store, endpoint: view)
    }
}

@MainActor
final class ReaderEntryProbeValueView: UIView {
    override var accessibilityValue: String? {
        get { ReaderEntryProbe.shared.cachedValue }
        set { /* Read-only. Only the two explicit fixture notifications request samples. */ }
    }
}
#endif
