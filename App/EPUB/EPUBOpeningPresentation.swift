import Foundation
import ReaderDomain
import SwiftUI
import UIKit

/// Fixed-size local observation. Display-link callbacks are frame opportunities, not pixel proof.
struct EPUBOpeningObservation {
    let intentAt: ContinuousClock.Instant?
    let processOpenOrdinal: Int?
    let rendererTaken: Bool?
    private(set) var loadAt: ContinuousClock.Instant?
    private(set) var readyAt: ContinuousClock.Instant?
    private(set) var frameAt: ContinuousClock.Instant?
    private var readyToken: EPUBNavigationToken?
    enum Interruption: String { case retry = "经历重试", background = "进入后台" }
    private(set) var interruption: Interruption?

    init(intentAt: ContinuousClock.Instant?, processOpenOrdinal: Int?, rendererTaken: Bool?) {
        self.intentAt = intentAt
        self.processOpenOrdinal = processOpenOrdinal
        self.rendererTaken = rendererTaken
    }

    mutating func interrupt(_ reason: Interruption) {
        guard frameAt == nil else { return } // Later reading activity cannot invalidate a completed opening.
        interruption = reason
    }

    mutating func beganLoading(at now: ContinuousClock.Instant = .now) {
        if loadAt == nil { loadAt = now }
    }

    mutating func becameReady(_ token: EPUBNavigationToken, at now: ContinuousClock.Instant = .now) {
        guard readyAt == nil, loadAt != nil else { return }
        readyAt = now
        readyToken = token
    }

    @discardableResult
    mutating func observedFrame(_ token: EPUBNavigationToken, at now: ContinuousClock.Instant = .now) -> Bool {
        guard interruption == nil, token == readyToken, let readyAt, now >= readyAt, frameAt == nil else { return false }
        frameAt = now
        return true
    }

    private func interval(_ start: ContinuousClock.Instant?, _ end: ContinuousClock.Instant?) -> String {
        guard let start, let end, end >= start else { return "未取得" }
        let parts = start.duration(to: end).components
        return String(format: "%.3fs", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    var summary: String {
        let process = processOpenOrdinal.map {
            $0 == 1 ? "本进程首次 EPUB 开书（不等于设备文件缓存冷态）" : "本进程第 \($0) 次 EPUB 开书"
        } ?? "非书架点击入口；进程序号未记录"
        let renderer = rendererTaken.map { $0 ? "取出已停放页面；实际DOM复用仍需验证" : "未取出已停放页面" }
            ?? "未配置页面缓存"
        return "打开呈现：opening-presentation-v1\n\(process)\n\(renderer)\n" +
            "点击→加载开始 \(interval(intentAt, loadAt))\n" +
            (interruption.map { "本次\($0.rawValue)，不纳入正常开书耗时样本。\n" } ?? "") +
            "点击→章节就绪 \(interval(intentAt, readyAt))\n" +
            "点击→正文揭示后的显示帧机会 \(interval(intentAt, frameAt))\n" +
            "章节就绪→显示帧机会 \(interval(readyAt, frameAt))\n" +
            "显示帧机会：当前路由可交互且前台挂载后两次CADisplayLink回调；不是像素首绘/屏幕扫描完成证明。"
    }
}

enum EPUBOpeningFeedback: Equatable {
    case quiet, compact, detailed
    static let compactDelay = Duration.milliseconds(280)
    static let detailedDelay = Duration.seconds(1)

    static func phase(elapsedSeconds: Double) -> Self {
        if elapsedSeconds >= 1 { return .detailed }
        if elapsedSeconds >= 0.280 { return .compact }
        return .quiet
    }
}

/// Presentation hint only: never supplies saved preferences, positions or publication authority.
@MainActor
enum EPUBPresentationThemeHint {
    static let key = "dev.yuejing.epub.presentation-theme.v1"
    static func read(from defaults: UserDefaults = .standard) -> ReaderTheme {
        ReaderTheme(rawValue: defaults.string(forKey: key) ?? "") ?? .paper
    }
    static func remember(_ theme: ReaderTheme, in defaults: UserDefaults = .standard) {
        if defaults.string(forKey: key) != theme.rawValue { defaults.set(theme.rawValue, forKey: key) }
    }
}

/// Observes after SwiftUI removes its opaque paper cover. Does not gate or delay interaction.
@MainActor
struct EPUBPresentationProbe: UIViewRepresentable {
    let token: EPUBNavigationToken?
    let observed: @MainActor (EPUBNavigationToken) -> Void

    func makeUIView(context: Context) -> EPUBPresentationProbeView { EPUBPresentationProbeView() }
    func updateUIView(_ view: EPUBPresentationProbeView, context: Context) {
        view.observe(token, completion: observed)
    }
    static func dismantleUIView(_ view: EPUBPresentationProbeView, coordinator: ()) { view.stop() }
}

@MainActor
final class EPUBPresentationProbeView: UIView {
    private var token: EPUBNavigationToken?
    private var completedToken: EPUBNavigationToken?
    private var completion: (@MainActor (EPUBNavigationToken) -> Void)?
    private var displayLink: CADisplayLink?
    private var frames = 0

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func observe(_ value: EPUBNavigationToken?, completion: @escaping @MainActor (EPUBNavigationToken) -> Void) {
        if token != value { stop(); frames = 0; token = value }
        self.completion = completion
        startIfMounted()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop(); frames = 0 } else { startIfMounted() }
    }
    private func startIfMounted() {
        guard let token, token != completedToken, window != nil, displayLink == nil,
              UIApplication.shared.applicationState == .active else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameOpportunity))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func frameOpportunity() {
        guard let token, window != nil, UIApplication.shared.applicationState == .active else { stop(); frames = 0; return }
        frames += 1
        guard frames >= 2 else { return }
        stop()
        completedToken = token
        completion?(token)
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
