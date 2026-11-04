import Foundation
import ReaderDomain
import SwiftUI
import UIKit
import WebKit

/// One controlled chapter/epoch load or reflow request for EPUBWebViewController.
struct EPUBNavigationRequest: Equatable {
    let id: UUID
    let token: EPUBNavigationToken
    let publication: EPUBPublication
    let targetPosition: EPUBReadingPosition?
    let fragment: String?
    let preferences: ReaderPreferences
    let preserveTargetAnchor: Bool
    let reloadDocument: Bool

    static func == (lhs: EPUBNavigationRequest, rhs: EPUBNavigationRequest) -> Bool {
        lhs.id == rhs.id &&
            lhs.token == rhs.token &&
            lhs.publication.package == rhs.publication.package &&
            lhs.publication.resourceRoot == rhs.publication.resourceRoot &&
            lhs.targetPosition == rhs.targetPosition &&
            lhs.fragment == rhs.fragment &&
            lhs.preferences == rhs.preferences &&
            lhs.preserveTargetAnchor == rhs.preserveTargetAnchor &&
            lhs.reloadDocument == rhs.reloadDocument
    }
}

/// Handle bridging EPUBReaderViewModel and the live EPUBWebViewController.
@MainActor
final class EPUBWebViewHandle {
    weak var controller: EPUBWebViewController?
    private(set) var latestPayload: EPUBLocatorPayload?

    func attach(_ value: EPUBWebViewController) {
        if let old = controller, old !== value {
            old.detachCallbacks()
        }
        controller = value
    }

    func detach(_ value: EPUBWebViewController) {
        guard controller === value else { return }
        value.detachCallbacks()
        controller = nil
    }

    func recordPayload(_ payload: EPUBLocatorPayload) {
        latestPayload = payload
    }

    func clearPayload() {
        latestPayload = nil
    }

    func sampleNow() async -> EPUBLocatorPayload? {
        guard let controller else { return latestPayload }
        if let fresh = await controller.sampleVisibleNow() {
            latestPayload = fresh
            return fresh
        }
        return latestPayload
    }
}

@MainActor
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: EPUBWebViewController?

    init(target: EPUBWebViewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleScriptMessage(message)
    }
}

/// Hosts WKWebView with custom yjepub: scheme, content rules, disabled page JS, and isolated locator world.
@MainActor
final class EPUBWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private static let contentRulesIdentifier = "dev.yuejing.epub.contentrules.v1"
    private static let contentRulesJSON = """
    [
      {
        "trigger": { "url-filter": "^https?://.*" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://.*" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^file://.*" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^ftp://.*" },
        "action": { "type": "block" }
      }
    ]
    """
    private static var cachedRuleList: WKContentRuleList?

    let resourceHandler = EPUBResourceHandler()
    private(set) var webView: WKWebView!
    private let canvasAccessibilityView = UIView(frame: .zero)
    private var messageProxy: WeakScriptMessageProxy?
    private(set) var activeRequest: EPUBNavigationRequest?
    private var loadedDocumentToken: EPUBNavigationToken?
    private var loadedDocumentPath: String?
    private var loadTask: Task<Void, Never>?
    private var loadingNavigation: WKNavigation?
    private var beganTapDuringDeceleration = false
    private(set) var deniedNavigations: [String] = []

    var onLocatorEvent: (@MainActor (EPUBLocatorPayload) -> Void)?
    var onLoadFailure: (@MainActor (Error, EPUBNavigationToken) -> Void)?
    var onInternalLink: (@MainActor (String, String?) -> Void)?
    var toolIntent: (@MainActor () -> UUID)?
    var onToolsInteraction: (@MainActor (ReadingToolsInteraction) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebViewIfNeeded()
    }

    func setupWebViewIfNeeded() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(resourceHandler, forURLScheme: EPUBResourceHandler.scheme)
        config.userContentController.addUserScript(EPUBLocationScript.makeUserScript())
        let proxy = WeakScriptMessageProxy(target: self)
        messageProxy = proxy
        config.userContentController.add(
            proxy,
            contentWorld: EPUBLocationScript.world,
            name: EPUBLocationScript.handlerName
        )

        let created = WKWebView(frame: view.bounds, configuration: config)
        created.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        created.navigationDelegate = self
        created.uiDelegate = self
        created.scrollView.delegate = self
        created.scrollView.contentInsetAdjustmentBehavior = .never
        created.isOpaque = false
        created.allowsBackForwardNavigationGestures = false
        created.allowsLinkPreview = false
        created.accessibilityIdentifier = "reader.viewport"
        webView = created
        view.addSubview(created)

        canvasAccessibilityView.backgroundColor = .clear
        canvasAccessibilityView.isUserInteractionEnabled = false
        canvasAccessibilityView.isAccessibilityElement = false
        canvasAccessibilityView.accessibilityTraits = .staticText
        canvasAccessibilityView.accessibilityIdentifier = "reader.text.canvas"
        view.addSubview(canvasAccessibilityView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleViewportTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        created.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView?.frame = view.bounds
        let insetBounds = view.bounds.inset(by: UIEdgeInsets(top: 56, left: 16, bottom: 56, right: 16))
        if insetBounds.width > 0 && insetBounds.height > 0 {
            canvasAccessibilityView.frame = insetBounds
        } else {
            canvasAccessibilityView.frame = view.bounds
        }
    }

    func applyTheme(_ theme: ReaderTheme) {
        setupWebViewIfNeeded()
        view.backgroundColor = theme.background
        webView.backgroundColor = theme.background
        webView.scrollView.backgroundColor = theme.background
    }

    func apply(_ request: EPUBNavigationRequest) {
        setupWebViewIfNeeded()
        applyTheme(request.preferences.theme)
        guard activeRequest != request else { return }
        loadingNavigation = nil
        webView.stopLoading()

        activeRequest = request
        let capability = EPUBResourceCapability(
            token: request.token,
            publication: request.publication,
            preferences: request.preferences
        )
        resourceHandler.activate(capability)


        clearAccessibilityCanvas()
        loadedDocumentPath = nil
        loadedDocumentToken = nil
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.installContentRulesIfNeeded(on: self.webView.configuration.userContentController)
                guard !Task.isCancelled, self.activeRequest == request else { return }
                guard let url = EPUBResourceCapability.url(for: request.token) else { throw EPUBError.invalidPackage }
                self.loadingNavigation = self.webView.load(URLRequest(url: url))
            } catch {
                guard !Task.isCancelled, self.activeRequest == request else { return }
                self.onLoadFailure?(error, request.token)
            }
        }
    }

    func detachCallbacks() {
        loadTask?.cancel()
        loadTask = nil
        activeRequest = nil
        loadedDocumentPath = nil
        loadedDocumentToken = nil
        loadingNavigation = nil
        onLocatorEvent = nil
        onLoadFailure = nil
        onInternalLink = nil
        toolIntent = nil
        onToolsInteraction = nil
        resourceHandler.invalidate()
        clearAccessibilityCanvas()
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.scrollView.delegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: EPUBLocationScript.handlerName,
                contentWorld: EPUBLocationScript.world
            )
        }
    }

    private static func installContentRulesIfNeeded(on controller: WKUserContentController) async throws {
        if let cached = cachedRuleList {
            controller.add(cached)
            return
        }
        guard let store = WKContentRuleListStore.default() else { throw EPUBError.unsupportedContent }
        guard let list = try await store.compileContentRuleList(
            forIdentifier: contentRulesIdentifier, encodedContentRuleList: contentRulesJSON
        ) else { throw EPUBError.unsupportedContent }
        cachedRuleList = list
        controller.add(list)
    }

    private func configureLoadedDOM(for request: EPUBNavigationRequest) {
        do {
            let invoke = try EPUBLocationScript.configurationInvokeScript(
                token: request.token,
                package: request.publication.package,
                targetPosition: request.targetPosition,
                fragment: request.fragment,
                preferences: request.preferences,
                preserveTargetAnchor: request.preserveTargetAnchor
            )
            let combined = EPUBLocationScript.bootstrapSource + "\n" + invoke
            // Use the public NS_REFINED_FOR_SWIFT ObjC entry point, not libswiftWebKit.
            webView.__evaluateJavaScript(combined, inFrame: nil, in: EPUBLocationScript.world) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.activeRequest?.token == request.token else { return }
                    self.onLoadFailure?(error, request.token)
                }
            }
        } catch {
            onLoadFailure?(error, request.token)
        }
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == EPUBLocationScript.handlerName,
              let payload = EPUBLocationScript.parseMessage(message.body),
              let current = activeRequest,
              payload.sessionID == current.token.sessionID,
              payload.epoch == current.token.epoch,
              payload.path == current.token.path else {
            return
        }
        if payload.kind == .ready || payload.kind == .scroll {
            updateAccessibilityCanvas(with: payload, preferences: current.preferences)
        }
        onLocatorEvent?(payload)
    }

    func sampleVisibleNow() async -> EPUBLocatorPayload? {
        guard let current = activeRequest, webView != nil else { return nil }
        return await withCheckedContinuation { continuation in
            webView.__evaluateJavaScript(
                "window.__yjEpub && window.__yjEpub.sampleNow ? window.__yjEpub.sampleNow() : null;",
                inFrame: nil,
                in: EPUBLocationScript.world
            ) { [weak self] raw, error in
                guard error == nil, let raw,
                      let self, let payload = EPUBLocationScript.parseMessage(raw),
                      self.activeRequest?.token == current.token,
                      payload.sessionID == current.token.sessionID,
                      payload.epoch == current.token.epoch,
                      payload.path == current.token.path else {
                    continuation.resume(returning: nil)
                    return
                }
                self.updateAccessibilityCanvas(with: payload, preferences: current.preferences)
                continuation.resume(returning: payload)
            }
        }
    }

    #if DEBUG
    func evaluatePageJavaScriptForTesting(_ script: String) async throws -> Any? {
        try await evaluateJSONForTesting(script, world: .page)
    }

    func evaluateLocatorJavaScriptForTesting(_ script: String) async throws -> Any? {
        try await evaluateJSONForTesting(script, world: EPUBLocationScript.world)
    }

    private func evaluateJSONForTesting(_ script: String, world: WKContentWorld) async throws -> Any? {
        setupWebViewIfNeeded()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.__evaluateJavaScript(script, inFrame: nil, in: world) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed]))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    #endif

    private func updateAccessibilityCanvas(with payload: EPUBLocatorPayload, preferences: ReaderPreferences) {
        let text = payload.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearAccessibilityCanvas()
            return
        }
        let validated = preferences.validated
        let node = payload.kind == .ready ? payload.restoredNode : payload.node
        let offset = payload.kind == .ready ? payload.restoredOffset : payload.utf16Offset
        canvasAccessibilityView.isAccessibilityElement = true
        canvasAccessibilityView.accessibilityLabel = text
        canvasAccessibilityView.accessibilityValue =
            "path=\(payload.path)|node=\(node)|offset=\(offset)|scrollY=\(Int(payload.scrollY.rounded()))|" +
            "font=\(Int(validated.fontSize.rounded()))|spacing=\(Int(validated.lineSpacing.rounded()))|" +
            "theme=\(validated.theme.rawValue)"
    }

    private func clearAccessibilityCanvas() {
        canvasAccessibilityView.isAccessibilityElement = false
        canvasAccessibilityView.accessibilityLabel = nil
        canvasAccessibilityView.accessibilityValue = nil
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = false
        guard let url = navigationAction.request.url else {
            deniedNavigations.append("<nil>")
            decisionHandler(.cancel, preferences)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame == true,
              navigationAction.navigationType != .formSubmitted,
              navigationAction.navigationType != .formResubmitted,
              (navigationAction.request.httpMethod?.uppercased() ?? "GET") == "GET",
              let current = activeRequest,
              url.scheme?.lowercased() == EPUBResourceHandler.scheme,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.host?.lowercased() == EPUBResourceCapability.host(for: current.token) else {
            deniedNavigations.append(url.absoluteString)
            decisionHandler(.cancel, preferences)
            return
        }
        let rawPath = String(url.path.drop(while: { $0 == "/" }))
        guard let canonical = try? EPUBResourcePath.canonical(rawPath),
              canonical == rawPath else {
            deniedNavigations.append(url.absoluteString)
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            if current.publication.package.spine.contains(canonical) {
                onInternalLink?(canonical, url.fragment)
            } else {
                deniedNavigations.append(url.absoluteString)
            }
            decisionHandler(.cancel, preferences)
            return
        }
        guard canonical == current.token.path else {
            deniedNavigations.append(url.absoluteString)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              navigationResponse.canShowMIMEType,
              navigationResponse.response.url?.scheme?.lowercased() == EPUBResourceHandler.scheme,
              navigationResponse.response.mimeType?.lowercased() == "application/xhtml+xml" else {
            if let badURL = navigationResponse.response.url?.absoluteString {
                deniedNavigations.append(badURL)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, let loadingNavigation, let current = activeRequest, navigation === loadingNavigation,
              webView.url == EPUBResourceCapability.url(for: current.token) else { return }
        loadedDocumentPath = current.token.path
        loadedDocumentToken = current.token
        configureLoadedDOM(for: current)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, let loadingNavigation, navigation === loadingNavigation else { return }
        handleWebKitNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, let loadingNavigation, navigation === loadingNavigation else { return }
        handleWebKitNavigationFailure(error)
    }

    private func handleWebKitNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        guard let current = activeRequest else { return }
        onLoadFailure?(error, current.token)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString {
            deniedNavigations.append(url)
        }
        return nil
    }

    // MARK: - UIScrollViewDelegate & Tap Gesture

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onToolsInteraction?(.scrollingBegan)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            Task { [weak self] in
                guard let self, let payload = await self.sampleVisibleNow() else { return }
                self.onLocatorEvent?(payload)
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        Task { [weak self] in
            guard let self, let payload = await self.sampleVisibleNow() else { return }
            self.onLocatorEvent?(payload)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        beganTapDuringDeceleration = webView?.scrollView.isDecelerating ?? false
        return true
    }

    @objc private func handleViewportTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let webView else { return }
        let location = recognizer.location(in: view)
        guard ReadingToolsGesturePolicy.central(
            x: location.x,
            y: location.y,
            width: view.bounds.width,
            height: view.bounds.height
        ) else {
            return
        }
        let scrollView = webView.scrollView
        let decision = ReadingToolsGesturePolicy.tap(
            beganDuringDeceleration: beganTapDuringDeceleration,
            dragging: scrollView.isDragging,
            decelerating: scrollView.isDecelerating,
            voiceOver: UIAccessibility.isVoiceOverRunning
        )
        beganTapDuringDeceleration = false
        guard let expected = toolIntent?() else { return }
        onToolsInteraction?(.tap(expected, decision))
    }
}

/// SwiftUI bridge for EPUBWebViewController.
@MainActor
struct EPUBWebView: UIViewControllerRepresentable {
    @MainActor
    final class Coordinator {
        let handle: EPUBWebViewHandle
        init(handle: EPUBWebViewHandle) {
            self.handle = handle
        }
    }

    let request: EPUBNavigationRequest?
    let preferences: ReaderPreferences
    let handle: EPUBWebViewHandle
    let onLocatorEvent: @MainActor (EPUBLocatorPayload) -> Void
    let onLoadFailure: @MainActor (Error, EPUBNavigationToken) -> Void
    let onInternalLink: @MainActor (String, String?) -> Void
    let toolIntent: @MainActor () -> UUID
    let onToolsInteraction: @MainActor (ReadingToolsInteraction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeUIViewController(context: Context) -> EPUBWebViewController {
        let controller = EPUBWebViewController()
        handle.attach(controller)
        controller.onLocatorEvent = onLocatorEvent
        controller.onLoadFailure = onLoadFailure
        controller.onInternalLink = onInternalLink
        controller.toolIntent = toolIntent
        controller.onToolsInteraction = onToolsInteraction
        controller.applyTheme(preferences.theme)
        return controller
    }

    func updateUIViewController(_ controller: EPUBWebViewController, context: Context) {
        guard handle.controller === controller else { return }
        controller.onLocatorEvent = onLocatorEvent
        controller.onLoadFailure = onLoadFailure
        controller.onInternalLink = onInternalLink
        controller.toolIntent = toolIntent
        controller.onToolsInteraction = onToolsInteraction
        controller.applyTheme(preferences.theme)
        if let request {
            controller.apply(request)
        }
    }

    static func dismantleUIViewController(_ controller: EPUBWebViewController, coordinator: Coordinator) {
        coordinator.handle.detach(controller)
    }
}
