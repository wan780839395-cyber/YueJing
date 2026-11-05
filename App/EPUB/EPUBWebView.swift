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
    var startAtEnd: Bool = false
    var readingMode: EPUBReadingMode = .scroll
    var preserveViewport: Bool = false

    static func == (lhs: EPUBNavigationRequest, rhs: EPUBNavigationRequest) -> Bool {
        lhs.id == rhs.id &&
            lhs.token == rhs.token &&
            lhs.publication.package == rhs.publication.package &&
            lhs.publication.resourceRoot == rhs.publication.resourceRoot &&
            lhs.targetPosition == rhs.targetPosition &&
            lhs.fragment == rhs.fragment &&
            lhs.preferences == rhs.preferences &&
            lhs.preserveTargetAnchor == rhs.preserveTargetAnchor &&
            lhs.reloadDocument == rhs.reloadDocument && lhs.startAtEnd == rhs.startAtEnd &&
            lhs.readingMode == rhs.readingMode && lhs.preserveViewport == rhs.preserveViewport
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
    private var readyToken: EPUBNavigationToken?
    private var pageAnimationToken: EPUBNavigationToken?
    private var dragOrigin: (token: EPUBNavigationToken, offset: CGFloat)?
    private var pagePan: UIPanGestureRecognizer?
    private var pagePanToken: EPUBNavigationToken?
    private var interactionGeneration = UUID()
    private var scrollDirection: EPUBPageDirection?
    private var transitionSnapshot: UIView?
    private(set) var documentLoadCount = 0
    private(set) var renderedChapterPaths: Set<String> = []
    private var windowTask: Task<Void, Never>?
    private var windowInFlight = false
    private var windowChapterCount = EPUBChapterWindow.defaultChapters
    private var windowRequestedPaths: Set<String> = []
    private var windowFailedToken: EPUBNavigationToken?
    var onPreloadFailure: (@MainActor () -> Void)?
    var interactionEnabled = true {
        didSet {
            if oldValue != interactionEnabled {
                interactionGeneration = UUID()
                pagePanToken = nil
                dragOrigin = nil
                if interactionEnabled, activeRequest?.preserveViewport == true,
                   let token = readyToken { reportVisiblePosition(for: token) }
            }
        }
    }
    var onChapterBoundary: (@MainActor (EPUBPageDirection, EPUBNavigationToken) -> Bool)?

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

        // Accessing view here can synchronously reenter via viewDidLoad before
        // webView is assigned. Publish the instance before loading the root view.
        let created = WKWebView(frame: .zero, configuration: config)
        created.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        created.navigationDelegate = self
        created.uiDelegate = self
        created.scrollView.delegate = self
        created.scrollView.contentInsetAdjustmentBehavior = .never
        created.scrollView.alwaysBounceVertical = true
        created.scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        created.scrollView.pinchGestureRecognizer?.isEnabled = false
        created.isOpaque = false
        created.allowsBackForwardNavigationGestures = false
        created.allowsLinkPreview = false
        created.accessibilityIdentifier = "reader.viewport"
        webView = created
        created.frame = view.bounds
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

        let horizontal = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        horizontal.minimumNumberOfTouches = 1
        horizontal.maximumNumberOfTouches = 1
        horizontal.delegate = self
        pagePan = horizontal
        created.addGestureRecognizer(horizontal)
        created.scrollView.panGestureRecognizer.require(toFail: horizontal)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView?.frame = view.bounds
        webView?.scrollView.pinchGestureRecognizer?.isEnabled = false
        applyReadingGesturePolicy()
        let insetBounds = view.bounds.inset(by: UIEdgeInsets(top: 56, left: 16, bottom: 56, right: 16))
        if insetBounds.width > 0 && insetBounds.height > 0 {
            canvasAccessibilityView.frame = insetBounds
        } else {
            canvasAccessibilityView.frame = view.bounds
        }
    }

    private func applyReadingGesturePolicy() {
        guard let webView, let request = activeRequest else { return }
        let vertical = request.readingMode == .scroll
        // WebKit may reset UIScrollView gesture state while installing new content.
        // Reassert the policy at lifecycle boundaries, without resetting an active vertical drag.
        if webView.scrollView.isScrollEnabled != vertical { webView.scrollView.isScrollEnabled = vertical }
        if webView.scrollView.panGestureRecognizer.isEnabled != vertical {
            webView.scrollView.panGestureRecognizer.isEnabled = vertical
        }
        pagePan?.isEnabled = !vertical
        webView.scrollView.alwaysBounceVertical = vertical
        webView.scrollView.showsVerticalScrollIndicator = vertical
        webView.scrollView.showsHorizontalScrollIndicator = false
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
        let previous = activeRequest
        let reuseDOM = !request.reloadDocument && renderedChapterPaths.contains(request.token.path) &&
            loadedDocumentToken?.sessionID == request.token.sessionID &&
            previous?.publication.package == request.publication.package &&
            previous?.publication.resourceRoot == request.publication.resourceRoot
        // Invalidated async preload work must not mutate a newly navigated document.
        windowTask?.cancel()
        windowTask = nil
        windowInFlight = false
        windowFailedToken = nil
        if !reuseDOM {
            renderedChapterPaths.removeAll()
            windowRequestedPaths.removeAll()
            windowChapterCount = EPUBChapterWindow.defaultChapters
        }
        loadingNavigation = nil
        if !reuseDOM { webView.stopLoading() }
        activeRequest = request
        readyToken = nil
        pageAnimationToken = nil
        dragOrigin = nil
        pagePanToken = nil
        scrollDirection = nil
        applyReadingGesturePolicy()
        let capability = EPUBResourceCapability(
            token: request.token,
            publication: request.publication,
            preferences: request.preferences,
            readingMode: request.readingMode
        )
        resourceHandler.activate(capability)

        loadTask?.cancel()
        loadTask = nil
        if reuseDOM, let previous {
            // The DOM is verified already. Move resource/link URLs to the new capability
            // without admitting the old epoch's URLs or downloading the XHTML again.
            rebaseLoadedDOM(from: previous.token, to: request)
            return
        }
        if loadedDocumentPath != nil, transitionSnapshot == nil {
            transitionSnapshot = webView.snapshotView(afterScreenUpdates: false)
            if let transitionSnapshot {
                transitionSnapshot.frame = webView.frame
                transitionSnapshot.isUserInteractionEnabled = false
                transitionSnapshot.accessibilityElementsHidden = true
                view.addSubview(transitionSnapshot)
            }
        }
        clearAccessibilityCanvas()
        loadedDocumentPath = nil
        loadedDocumentToken = nil
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.installContentRulesIfNeeded(on: self.webView.configuration.userContentController)
                guard !Task.isCancelled, self.activeRequest == request else { return }
                guard let url = EPUBResourceCapability.url(for: request.token) else { throw EPUBError.invalidPackage }
                self.documentLoadCount += 1
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
        readyToken = nil
        pageAnimationToken = nil
        dragOrigin = nil
        pagePanToken = nil
        windowTask?.cancel()
        windowTask = nil
        windowInFlight = false
        renderedChapterPaths.removeAll()
        onPreloadFailure = nil
        onChapterBoundary = nil
        loadedDocumentPath = nil
        loadedDocumentToken = nil
        transitionSnapshot?.removeFromSuperview()
        transitionSnapshot = nil
        scrollDirection = nil
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

    private func rebaseLoadedDOM(from oldToken: EPUBNavigationToken, to request: EPUBNavigationRequest) {
        let oldHost = EPUBResourceCapability.host(for: oldToken)
        let prefix = oldHost.components(separatedBy: "--e-")[0] + "--e-"
        let hosts = [prefix, EPUBResourceCapability.host(for: request.token)]
        guard let data = try? JSONSerialization.data(withJSONObject: hosts),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        (function(hosts) {
            document.querySelectorAll('[src], [href]').forEach(function(el) {
                ['src', 'href'].forEach(function(attr) {
                    var value = el.getAttribute(attr); if (!value) return;
                    // Keep decoded pixels attached. Reassigning complete image src can flash at every crossing.
                    if (attr === 'src' && el.complete && el.naturalWidth > 0) return;
                    try {
                        var url = new URL(value, document.baseURI);
                        if (url.protocol === 'yjepub:' && url.hostname.indexOf(hosts[0]) === 0) {
                            url.hostname = hosts[1]; el.setAttribute(attr, url.href);
                        }
                    } catch (_) {}
                });
            });
        })(\(json));
        """
        webView.__evaluateJavaScript(script, inFrame: nil, in: EPUBLocationScript.world) { [weak self] _, error in
            guard let self, self.activeRequest == request else { return }
            if let error {
                self.loadedDocumentPath = nil
                self.loadedDocumentToken = nil
                self.onLoadFailure?(error, request.token)
                return
            }
            self.loadedDocumentToken = request.token
            self.loadedDocumentPath = request.token.path
            self.configureLoadedDOM(for: request)
        }
    }

    private func configureLoadedDOM(for request: EPUBNavigationRequest) {
        do {
            let invoke = try EPUBLocationScript.configurationInvokeScript(
                token: request.token,
                package: request.publication.package,
                targetPosition: request.targetPosition,
                fragment: request.fragment,
                preferences: request.preferences,
                preserveTargetAnchor: request.preserveTargetAnchor,
                startAtEnd: request.startAtEnd,
                readingMode: request.readingMode,
                preserveViewport: request.preserveViewport
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

    func refreshChapterWindow() {
        guard let current = activeRequest, readyToken == current.token,
              !windowInFlight, windowFailedToken != current.token else { return }
        let desired = EPUBChapterWindow.paths(in: current.publication.package, around: current.token.path, count: windowChapterCount)
        guard Set(desired) != renderedChapterPaths else { return }
        windowInFlight = true
        windowRequestedPaths.formUnion(Set(desired).union(renderedChapterPaths))
        let chapterCount = windowChapterCount
        let installed = renderedChapterPaths
        let publication = current.publication
        let token = current.token
        let urls = Dictionary(uniqueKeysWithValues: desired.compactMap { path -> (String, String)? in
            guard let url = EPUBResourceCapability.url(for: token, path: path) else { return nil }
            return (path, url.absoluteString)
        })
        windowTask = Task { @MainActor [weak self] in
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try EPUBChapterWindow.invocation(publication: publication, token: token,
                                                     installedPaths: installed, urls: urls, chapterCount: chapterCount)
                }
                let script = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.activeRequest?.token == token else { return }
                self.webView.__evaluateJavaScript(script, inFrame: nil, in: EPUBLocationScript.world) { [weak self] value, error in
                    guard let self, self.activeRequest?.token == token else { return }
                    if error != nil || value as? Bool != true { self.failChapterWindow(token) }
                }
                // The JS transaction includes bounded image readiness; no unbounded busy state.
                try await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, self.activeRequest?.token == token, self.windowInFlight else { return }
                self.failChapterWindow(token)
            } catch is CancellationError {
            } catch {
                guard let self, self.activeRequest?.token == token else { return }
                self.failChapterWindow(token)
            }
        }
    }

    private func failChapterWindow(_ token: EPUBNavigationToken) {
        guard activeRequest?.token == token else { return }
        windowTask?.cancel()
        windowTask = nil
        windowInFlight = false
        windowFailedToken = token
        onPreloadFailure?()
    }

    private func handleWindowResult(_ body: [String: Any]) {
        guard let current = activeRequest, windowInFlight,
              body["sessionID"] as? String == current.token.sessionID,
              let epoch = body["epoch"] as? String, UUID(uuidString: epoch) == current.token.epoch,
              let paths = body["paths"] as? [String],
              paths.count <= EPUBChapterWindow.maximumChapters,
              Set(paths).count == paths.count,
              paths.contains(current.token.path),
              Set(paths).isSubset(of: windowRequestedPaths) else { return }
        renderedChapterPaths = Set(paths)
        windowInFlight = false
        windowTask?.cancel()
        windowTask = nil
        applyReadingGesturePolicy()
        if body["error"] as? Bool == true {
            failChapterWindow(current.token)
        } else if body["needsMore"] as? Bool == true, windowChapterCount < EPUBChapterWindow.maximumChapters {
            windowChapterCount = min(EPUBChapterWindow.maximumChapters, windowChapterCount + EPUBChapterWindow.defaultChapters)
            refreshChapterWindow()
        }
        // Refresh only accessibility diagnostics; preload completion must not save progress.
        Task { @MainActor [weak self] in _ = await self?.sampleVisibleNow() }
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == EPUBLocationScript.handlerName else { return }
        if let body = message.body as? [String: Any], body["kind"] as? String == "window" {
            handleWindowResult(body)
            return
        }
        guard let payload = EPUBLocationScript.parseMessage(message.body) else { return }
        receiveLocatorPayload(payload)
    }

    private func receiveLocatorPayload(_ payload: EPUBLocatorPayload) {
        guard let current = activeRequest,
              payload.sessionID == current.token.sessionID,
              payload.epoch == current.token.epoch else { return }
        if payload.path != current.token.path {
            // This is an observation, never a save authority. The model mints a new epoch.
            guard payload.kind == .scroll, interactionEnabled,
                  renderedChapterPaths.contains(payload.path) else { return }
            onLocatorEvent?(payload)
            return
        }
        if payload.kind == .ready {
            readyToken = current.token
            applyReadingGesturePolicy()
            renderedChapterPaths.insert(current.token.path)
            transitionSnapshot?.removeFromSuperview()
            transitionSnapshot = nil
            refreshChapterWindow()
        }
        if payload.kind == .error {
            readyToken = nil
            transitionSnapshot?.removeFromSuperview()
            transitionSnapshot = nil
        }
        if payload.kind == .ready || payload.kind == .scroll {
            updateAccessibilityCanvas(with: payload, preferences: current.preferences)
        }
        onLocatorEvent?(payload)
    }

    func sampleVisibleNow() async -> EPUBLocatorPayload? {
        guard let initial = activeRequest, webView != nil else { return nil }
        let initialLoadCount = documentLoadCount
        // A real scroll sample can promote a visible chapter while this IPC is in flight.
        // Discard that old callback, then sample anew under the promoted token; never
        // relabel stale data or retry across a new session/document/explicit navigation.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        repeat {
            guard !Task.isCancelled, let current = activeRequest,
                  current.token.sessionID == initial.token.sessionID,
                  documentLoadCount == initialLoadCount,
                  current.publication.package == initial.publication.package,
                  current.publication.resourceRoot == initial.publication.resourceRoot,
                  current.token == initial.token || (current.preserveViewport && !current.reloadDocument) else { return nil }
            if let payload = await sampleVisibleOnce(for: current) { return payload }
            guard ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        } while true
    }

    private func sampleVisibleOnce(for current: EPUBNavigationRequest) async -> EPUBLocatorPayload? {
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
                      self.renderedChapterPaths.contains(payload.path) else {
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
            "theme=\(validated.theme.rawValue)|scrollX=\(Int(payload.scrollX.rounded()))|" +
            "mode=\(activeRequest?.readingMode.rawValue ?? "scroll")|zoom=\(webView.scrollView.zoomScale)|" +
            "window=\(renderedChapterPaths.count)|loads=\(documentLoadCount)"
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
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
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
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
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
        renderedChapterPaths = [current.token.path]
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        applyReadingGesturePolicy()
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
        loadedDocumentPath = nil
        loadedDocumentToken = nil
        windowTask?.cancel()
        windowTask = nil
        windowInFlight = false
        renderedChapterPaths.removeAll()
        readyToken = nil
        transitionSnapshot?.removeFromSuperview()
        transitionSnapshot = nil
        onLoadFailure?(error, current.token)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleWebKitNavigationFailure(EPUBError.corruptResource)
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

    private var pageGeometry: EPUBPageGeometry {
        let scroll = webView.scrollView
        return EPUBPageGeometry(
            offset: scroll.contentOffset.y, contentHeight: scroll.contentSize.height,
            viewportHeight: scroll.bounds.height,
            topInset: scroll.adjustedContentInset.top, bottomInset: scroll.adjustedContentInset.bottom
        )
    }

    @discardableResult
    func turnPage(_ direction: EPUBPageDirection, animated: Bool = true) -> Bool {
        guard interactionEnabled, let token = activeRequest?.token, readyToken == token,
              pageAnimationToken == nil, webView != nil, pageGeometry.valid else { return false }
        let scroll = webView.scrollView
        let horizontal = activeRequest?.readingMode == .paged
        let destination = horizontal
            ? EPUBPageGeometry.horizontalDestination(direction, offset: scroll.contentOffset.x,
                contentWidth: scroll.contentSize.width, viewportWidth: scroll.bounds.width)
            : pageGeometry.destination(direction)
        if let destination {
            dragOrigin = nil
            scrollDirection = nil
            onToolsInteraction?(.scrollingBegan)
            let animate = animated && !UIAccessibility.isReduceMotionEnabled
            pageAnimationToken = animate ? token : nil
            let point = horizontal ? CGPoint(x: destination, y: 0) : CGPoint(x: 0, y: destination)
            scroll.setContentOffset(point, animated: animate)
            if !animate { reportVisiblePosition(for: token) }
            return true
        }
        // A window edge is not a chapter-navigation gesture. Never replace the document here.
        windowFailedToken = nil
        refreshChapterWindow()
        return false
    }

    private func reportVisiblePosition(for token: EPUBNavigationToken) {
        Task { @MainActor [weak self] in
            guard let self, let payload = await self.sampleVisibleNow(),
                  self.activeRequest?.token == token, self.readyToken == token else { return }
            self.receiveLocatorPayload(payload)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let token = pageAnimationToken else { return }
        pageAnimationToken = nil
        reportVisiblePosition(for: token)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pagePan, let pan = pagePan else { return true }
        let velocity = pan.velocity(in: view)
        return activeRequest?.readingMode == .paged && interactionEnabled && readyToken != nil && readyToken == activeRequest?.token &&
            pageAnimationToken == nil && !UIAccessibility.isVoiceOverRunning &&
            abs(velocity.x) > abs(velocity.y) * 1.5
    }

    @objc private func handlePagePan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            pagePanToken = readyToken
            return
        }
        guard recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed else { return }
        let token = pagePanToken
        pagePanToken = nil
        guard recognizer.state == .ended, let token, token == readyToken, token == activeRequest?.token else { return }
        let delta = recognizer.translation(in: view)
        guard abs(delta.x) >= 48, abs(delta.x) > abs(delta.y) * 1.5 else { return }
        _ = turnPage(delta.x < 0 ? .next : .previous)
    }

    private func turnPageAtEdge(_ direction: EPUBPageDirection, point: CGPoint) {
        guard interactionEnabled, let token = readyToken, token == activeRequest?.token else { return }
        let interaction = interactionGeneration
        // Preserve actual publication links and text selection rather than consuming their taps.
        let script = """
        (function() {
            var selection = window.getSelection();
            var element = document.elementFromPoint(\(point.x), \(point.y));
            return Boolean(element && !element.closest('a, button, input, textarea, select') &&
                (!selection || selection.isCollapsed));
        })();
        """
        webView.__evaluateJavaScript(script, inFrame: nil, in: EPUBLocationScript.world) { [weak self] value, error in
            guard error == nil, value as? Bool == true, let self,
                  self.interactionGeneration == interaction,
                  self.activeRequest?.token == token, self.readyToken == token else { return }
            _ = self.turnPage(direction)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pageAnimationToken = nil
        scrollDirection = nil
        if interactionEnabled, activeRequest?.readingMode == .scroll,
           let token = readyToken, token == activeRequest?.token {
            dragOrigin = (token, scrollView.contentOffset.y)
        } else {
            dragOrigin = nil
        }
        onToolsInteraction?(.scrollingBegan)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let origin = dragOrigin, interactionEnabled,
              activeRequest?.readingMode == .scroll,
              origin.token == readyToken, origin.token == activeRequest?.token else { return }
        let delta = scrollView.contentOffset.y - origin.offset
        if abs(delta) > 0.5 {
            scrollDirection = delta > 0 ? .next : .previous
            dragOrigin = (origin.token, scrollView.contentOffset.y)
        }
        // Native scrolling stays in one DOM across chapter boundaries.
    }

    private func continueUserScroll() {
        // Refresh only when the gesture settles; never hand the drag to a new document.
        refreshChapterWindow()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        continueUserScroll()
        if !decelerate {
            dragOrigin = nil
            scrollDirection = nil
            if let token = readyToken { reportVisiblePosition(for: token) }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        continueUserScroll()
        dragOrigin = nil
        scrollDirection = nil
        if let token = readyToken { reportVisiblePosition(for: token) }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer !== pagePan && otherGestureRecognizer !== pagePan
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        beganTapDuringDeceleration = webView?.scrollView.isDecelerating ?? false
        return true
    }

    @objc private func handleViewportTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let webView else { return }
        let location = recognizer.location(in: view)
        let scroll = webView.scrollView
        if activeRequest?.readingMode == .paged,
           let direction = EPUBPageGeometry.edgeDirection(at: location, size: view.bounds.size) {
            let canTurn = !beganTapDuringDeceleration && !scroll.isDragging && !scroll.isDecelerating &&
                !UIAccessibility.isVoiceOverRunning
            beganTapDuringDeceleration = false
            if canTurn { turnPageAtEdge(direction, point: recognizer.location(in: webView)) }
            return
        }
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
    let onChapterBoundary: @MainActor (EPUBPageDirection, EPUBNavigationToken) -> Bool
    let onPreloadFailure: @MainActor () -> Void
    let interactionEnabled: Bool
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
        controller.onChapterBoundary = onChapterBoundary
        controller.onPreloadFailure = onPreloadFailure
        controller.interactionEnabled = interactionEnabled
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
        controller.onChapterBoundary = onChapterBoundary
        controller.onPreloadFailure = onPreloadFailure
        controller.interactionEnabled = interactionEnabled
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
