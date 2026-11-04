import Foundation
import ReaderDomain
import WebKit

/// Immutable capability for one reading session and one navigation epoch.
struct EPUBResourceCapability: Sendable, Equatable {
    let token: EPUBNavigationToken
    let publication: EPUBPublication
    var preferences: ReaderPreferences

    var expectedHost: String {
        Self.host(for: token)
    }

    static func host(for token: EPUBNavigationToken) -> String {
        let cleanSession = token.sessionID.lowercased().map { char -> Character in
            (char.isASCII && (char.isLetter || char.isNumber || char == "-")) ? char : "-"
        }
        return "s-" + String(cleanSession) + "--e-" + token.epoch.uuidString.lowercased()
    }

    static func url(for token: EPUBNavigationToken, path: String? = nil, fragment: String? = nil) -> URL? {
        let targetPath = path ?? token.path
        guard let canonical = try? EPUBResourcePath.canonical(targetPath),
              canonical == targetPath else {
            return nil
        }
        var components = URLComponents()
        components.scheme = EPUBResourceHandler.scheme
        components.host = host(for: token)
        components.path = "/" + canonical
        if let fragment, !fragment.isEmpty {
            components.fragment = fragment
        }
        return components.url
    }

    static func == (lhs: EPUBResourceCapability, rhs: EPUBResourceCapability) -> Bool {
        lhs.token == rhs.token &&
            lhs.publication.package == rhs.publication.package &&
            lhs.publication.resourceRoot == rhs.publication.resourceRoot &&
            lhs.preferences == rhs.preferences
    }
}

/// Serves only validated package resources for the current session+epoch over yjepub:.
@MainActor
final class EPUBResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "yjepub"
    static let contentSecurityPolicy =
        "default-src 'none'; img-src yjepub:; style-src 'unsafe-inline'; " +
        "script-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; " +
        "frame-src 'none'; child-src 'none'; form-action 'none'; base-uri 'none'"

    private var capability: EPUBResourceCapability?
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var servedPaths: [String] = []
    private(set) var rejectedURLs: [String] = []
    #if DEBUG
    var rawXHTMLOverrideForTesting: [String: Data] = [:]
    #endif

    func activate(_ capability: EPUBResourceCapability) {
        if self.capability?.token != capability.token {
            cancelInFlightTasks()
        }
        self.capability = capability
    }

    func updatePreferences(_ preferences: ReaderPreferences) {
        capability?.preferences = preferences.validated
    }

    func invalidate() {
        capability = nil
        cancelInFlightTasks()
    }

    private func cancelInFlightTasks() {
        let tasks = activeTasks.values
        activeTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            rejectedURLs.append("<missing-url>")
            urlSchemeTask.didFailWithError(EPUBError.corruptResource)
            return
        }
        guard let capability,
              url.scheme?.lowercased() == Self.scheme,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.host?.lowercased() == capability.expectedHost else {
            rejectedURLs.append(url.absoluteString)
            urlSchemeTask.didFailWithError(EPUBError.staleSession)
            return
        }
        let method = urlSchemeTask.request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" else {
            rejectedURLs.append(url.absoluteString)
            urlSchemeTask.didFailWithError(EPUBError.corruptResource)
            return
        }
        let rawPath = String(url.path.drop(while: { $0 == "/" }))
        guard !rawPath.isEmpty,
              let canonical = try? EPUBResourcePath.canonical(rawPath),
              canonical == rawPath,
              let resource = capability.publication.package.resource(at: canonical),
              ["application/xhtml+xml", "image/jpeg", "image/png"].contains(resource.mediaType) else {
            rejectedURLs.append(url.absoluteString)
            urlSchemeTask.didFailWithError(EPUBError.corruptResource)
            return
        }
        if resource.mediaType == "application/xhtml+xml", canonical != capability.token.path {
            rejectedURLs.append(url.absoluteString)
            urlSchemeTask.didFailWithError(EPUBError.corruptResource)
            return
        }
        let maxBytes = (resource.mediaType == "application/xhtml+xml" ? EPUBLimits().xhtmlBytes : EPUBLimits().imageBytes)
        guard resource.byteCount >= 0, resource.byteCount <= maxBytes else {
            rejectedURLs.append(url.absoluteString)
            urlSchemeTask.didFailWithError(EPUBError.limitExceeded)
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask)
        let publication = capability.publication
        let expectedToken = capability.token
        let preferences = capability.preferences
        #if DEBUG
        let overrideData = rawXHTMLOverrideForTesting[canonical]
        #else
        let overrideData: Data? = nil
        #endif

        let task = Task { @MainActor [weak self] in
            do {
                let rawData: Data
                if let overrideData {
                    guard overrideData.count <= maxBytes else { throw EPUBError.limitExceeded }
                    rawData = overrideData
                } else {
                    rawData = try await Task.detached(priority: .userInitiated) {
                        try EPUBResourceStore.data(path: canonical, publication: publication)
                    }.value
                }
                guard let self,
                      self.activeTasks.removeValue(forKey: taskID) != nil,
                      !Task.isCancelled,
                      self.capability?.token == expectedToken else {
                    return
                }
                let payload: Data
                if resource.mediaType == "application/xhtml+xml" {
                    payload = Self.decorateXHTML(rawData, preferences: preferences)
                } else {
                    payload = rawData
                }
                let headers: [String: String] = [
                    "Content-Type": resource.mediaType == "application/xhtml+xml"
                        ? "application/xhtml+xml; charset=utf-8"
                        : resource.mediaType,
                    "Content-Length": "\(payload.count)",
                    "Cache-Control": "no-store, no-cache, must-revalidate",
                    "X-Content-Type-Options": "nosniff",
                    "Content-Security-Policy": Self.contentSecurityPolicy
                ]
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else {
                    self.rejectedURLs.append(url.absoluteString)
                    urlSchemeTask.didFailWithError(EPUBError.corruptResource)
                    return
                }
                self.servedPaths.append(canonical)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(payload)
                urlSchemeTask.didFinish()
            } catch {
                guard let self,
                      self.activeTasks.removeValue(forKey: taskID) != nil else {
                    return
                }
                self.rejectedURLs.append(url.absoluteString)
                urlSchemeTask.didFailWithError(error)
            }
        }
        activeTasks[taskID] = task
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks.removeValue(forKey: taskID)?.cancel()
    }

    static func decorateXHTML(_ data: Data, preferences: ReaderPreferences) -> Data {
        guard var xhtml = String(data: data, encoding: .utf8) else { return data }
        let css = EPUBLocationScript.trustedStyleSheet(for: preferences)
        let cspMeta = xhtml.contains("Content-Security-Policy")
            ? ""
            : "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"/>"
        let injection = cspMeta + "<style id=\"yj-epub-style\">\(css)</style>"
        if let headClose = xhtml.range(of: "</head>", options: .caseInsensitive) {
            xhtml.insert(contentsOf: injection, at: headClose.lowerBound)
        } else if let htmlOpen = xhtml.range(of: "<body", options: .caseInsensitive) {
            let headBlock = "<head>\(injection)</head>"
            xhtml.insert(contentsOf: headBlock, at: htmlOpen.lowerBound)
        }
        return Data(xhtml.utf8)
    }
}
