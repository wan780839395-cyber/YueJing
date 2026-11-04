import Foundation
import ReaderDomain
import WebKit

/// Validated locator event emitted from the isolated WKContentWorld script.
struct EPUBLocatorPayload: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case ready
        case scroll
        case error
    }

    let kind: Kind
    let sessionID: String
    let epoch: UUID
    let path: String
    let node: Int
    let utf16Offset: Int
    let restoredNode: Int
    let restoredOffset: Int
    let scrollY: Double
    let viewportHeight: Double
    let contentHeight: Double
    let visibleText: String
    let reason: String?
}

/// Isolated content-world script for DOM text-node + UTF-16 offset locating and restoration.
@MainActor
enum EPUBLocationScript {
    static let handlerName = "yjepubLocator"
    static let world = WKContentWorld.world(name: "dev.yuejing.epub.locator.v1")

    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: bootstrapSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        )
    }

    static func trustedStyleSheet(for preferences: ReaderPreferences) -> String {
        let validated = preferences.validated
        let fontSize = Int(validated.fontSize.rounded())
        let spacing = Int(validated.lineSpacing.rounded())
        let lineHeight = Int((validated.fontSize * 1.35 + validated.lineSpacing).rounded())
        let colors: (bg: String, fg: String) = {
            switch validated.theme {
            case .paper:
                return ("rgb(245, 240, 222)", "rgb(31, 31, 31)")
            case .light:
                return ("rgb(255, 255, 255)", "rgb(31, 31, 31)")
            case .dark:
                return ("rgb(23, 23, 23)", "rgb(224, 224, 224)")
            }
        }()
        return """
        html, body {
            margin: 0 !important;
            padding: 16px 20px 40px 20px !important;
            background-color: \(colors.bg) !important;
            color: \(colors.fg) !important;
            font-family: -apple-system, "PingFang SC", "Hiragino Sans GB", serif !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineHeight)px !important;
            word-wrap: break-word !important;
            overflow-wrap: break-word !important;
            -webkit-text-size-adjust: none !important;
        }
        p {
            margin: 0 0 \(max(8, spacing + 6))px 0 !important;
            line-height: \(lineHeight)px !important;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600 !important;
            line-height: 1.35 !important;
            margin: 0.9em 0 0.45em 0 !important;
            color: \(colors.fg) !important;
        }
        em, i { font-style: italic !important; }
        strong, b { font-weight: 600 !important; }
        ul, ol {
            margin: 0.5em 0 0.8em 1.4em !important;
            padding: 0 !important;
        }
        li {
            margin: 0.25em 0 !important;
            line-height: \(lineHeight)px !important;
        }
        img {
            max-width: 100% !important;
            height: auto !important;
            display: block !important;
            margin: 12px auto !important;
        }
        span[id^="yj-t"] {
            display: inline !important;
        }
        """
    }

    /// Snaps a DOM UTF-16 code-unit offset inside `text` to a valid Swift Character boundary.
    /// Out-of-bounds (< 0 or > utf16.count) offsets are rejected rather than silently clamped.
    static func snapUTF16OffsetToCharacterBoundary(_ utf16Offset: Int, in text: String) -> Int? {
        let totalUTF16 = text.utf16.count
        guard utf16Offset >= 0, utf16Offset <= totalUTF16 else { return nil }
        if utf16Offset == 0 || utf16Offset == totalUTF16 { return utf16Offset }
        let targetUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        if let exact = String.Index(targetUTF16, within: text), text.indices.contains(exact) {
            return utf16Offset
        }
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(after: current)
            guard let nextUTF16 = next.samePosition(in: text.utf16),
                  let currentUTF16 = current.samePosition(in: text.utf16) else {
                break
            }
            if nextUTF16 > targetUTF16 {
                return text.utf16.distance(from: text.utf16.startIndex, to: currentUTF16)
            }
            current = next
        }
        return totalUTF16
    }

    static func makeValidatedPosition(
        bookID: String,
        package: EPUBPackage,
        path: String,
        node: Int,
        rawUTF16Offset: Int
    ) throws -> EPUBReadingPosition {
        guard package.spine.contains(path),
              let nodes = package.textNodes[path],
              nodes.indices.contains(node),
              let snapped = snapUTF16OffsetToCharacterBoundary(rawUTF16Offset, in: nodes[node]) else {
            throw EPUBError.invalidPosition
        }
        let position = EPUBReadingPosition(
            bookID: bookID,
            versionID: package.versionID,
            path: path,
            node: node,
            utf16Offset: snapped
        )
        try position.validate(in: package)
        return position
    }

    static func configurationInvokeScript(
        token: EPUBNavigationToken,
        package: EPUBPackage,
        targetPosition: EPUBReadingPosition?,
        fragment: String?,
        preferences: ReaderPreferences,
        preserveTargetAnchor: Bool
    ) throws -> String {
        guard let nodes = package.textNodes[token.path] else {
            throw EPUBError.invalidPackage
        }
        let lengths = nodes.map { $0.utf16.count }
        var config: [String: Any] = [
            "sessionID": token.sessionID,
            "epoch": token.epoch.uuidString,
            "path": token.path,
            "expectedNodeCount": nodes.count,
            "expectedNodeLengths": lengths,
            "targetNode": targetPosition?.path == token.path ? (targetPosition?.node ?? -1) : -1,
            "targetOffset": targetPosition?.path == token.path ? (targetPosition?.utf16Offset ?? 0) : 0,
            "fragment": fragment ?? "",
            "preserveTargetAnchor": preserveTargetAnchor && (targetPosition?.path == token.path),
            "css": trustedStyleSheet(for: preferences)
        ]
        if targetPosition == nil {
            config["targetNode"] = -1
            config["targetOffset"] = 0
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [])
        let json = String(decoding: data, as: UTF8.self)
        return "window.__yjEpub && window.__yjEpub.configure(\(json));"
    }

    static func parseMessage(_ body: Any) -> EPUBLocatorPayload? {
        guard let dict = body as? [String: Any],
              let kindRaw = dict["kind"] as? String,
              let kind = EPUBLocatorPayload.Kind(rawValue: kindRaw),
              let sessionID = dict["sessionID"] as? String,
              let epochString = dict["epoch"] as? String,
              let epoch = UUID(uuidString: epochString),
              let path = dict["path"] as? String else {
            return nil
        }
        let node = dict["node"] as? Int ?? 0
        let utf16Offset = dict["utf16Offset"] as? Int ?? 0
        let restoredNode = dict["restoredNode"] as? Int ?? node
        let restoredOffset = dict["restoredOffset"] as? Int ?? utf16Offset
        let scrollY = (dict["scrollY"] as? NSNumber)?.doubleValue ?? 0
        let viewportHeight = (dict["viewportHeight"] as? NSNumber)?.doubleValue ?? 0
        let contentHeight = (dict["contentHeight"] as? NSNumber)?.doubleValue ?? 0
        let visibleText = dict["visibleText"] as? String ?? ""
        let reason = dict["reason"] as? String
        return EPUBLocatorPayload(
            kind: kind,
            sessionID: sessionID,
            epoch: epoch,
            path: path,
            node: node,
            utf16Offset: utf16Offset,
            restoredNode: restoredNode,
            restoredOffset: restoredOffset,
            scrollY: scrollY,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            visibleText: visibleText,
            reason: reason
        )
    }

    static let bootstrapSource: String = """
    (function() {
        if (window.__yjEpubInstalled) { return; }
        window.__yjEpubInstalled = true;

        var state = {
            sessionID: "",
            epoch: "",
            path: "",
            ready: false,
            suppressingReflow: true,
            preserveTargetAnchor: false,
            targetNode: -1,
            targetOffset: 0,
            restoredScrollY: 0,
            scrollTimer: null
        };

        function post(payload) {
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yjepubLocator) {
                    window.webkit.messageHandlers.yjepubLocator.postMessage(payload);
                }
            } catch (_) {}
        }

        function collectSpans(expectedCount) {
            var spans = [];
            if (typeof expectedCount === "number" && expectedCount > 0) {
                for (var i = 0; i < expectedCount; i++) {
                    var el = document.getElementById("yj-t" + i);
                    if (!el) { return { valid: false, spans: [] }; }
                    spans.push(el);
                }
                if (document.getElementById("yj-t" + expectedCount) !== null) {
                    return { valid: false, spans: [] };
                }
                return { valid: true, spans: spans };
            }
            var idx = 0;
            while (true) {
                var node = document.getElementById("yj-t" + idx);
                if (!node) { break; }
                spans.push(node);
                idx += 1;
            }
            return { valid: spans.length > 0, spans: spans };
        }

        function firstTextChild(span) {
            var child = span.firstChild;
            while (child) {
                if (child.nodeType === 3) { return child; }
                child = child.nextSibling;
            }
            return null;
        }

        function applyStyleSheet(cssText) {
            if (typeof cssText !== "string") { return; }
            var style = document.getElementById("yj-epub-style");
            if (!style) {
                style = document.createElement("style");
                style.id = "yj-epub-style";
                (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = cssText;
        }

        function scrollToTarget(targetNode, targetOffset, fragment) {
            var topInset = 18;
            if (typeof targetNode === "number" && targetNode >= 0) {
                var span = document.getElementById("yj-t" + targetNode);
                if (!span) { return false; }
                var textNode = firstTextChild(span);
                var rect = null;
                if (textNode && textNode.nodeValue && textNode.nodeValue.length > 0) {
                    var len = textNode.nodeValue.length;
                    var clamped = Math.max(0, Math.min(targetOffset || 0, len));
                    var range = document.createRange();
                    if (clamped < len) {
                        range.setStart(textNode, clamped);
                        range.setEnd(textNode, Math.min(len, clamped + 1));
                    } else {
                        range.setStart(textNode, Math.max(0, len - 1));
                        range.setEnd(textNode, len);
                    }
                    rect = range.getBoundingClientRect();
                }
                if (!rect || (rect.width === 0 && rect.height === 0 && rect.top === 0)) {
                    rect = span.getBoundingClientRect();
                }
                var desiredY = Math.max(0, window.scrollY + rect.top - topInset);
                window.scrollTo(0, desiredY);
                return true;
            }
            if (typeof fragment === "string" && fragment.length > 0) {
                var target = document.getElementById(fragment);
                if (!target) {
                    var named = document.getElementsByName(fragment);
                    if (named && named.length > 0) { target = named[0]; }
                }
                if (target) {
                    var fragRect = target.getBoundingClientRect();
                    window.scrollTo(0, Math.max(0, window.scrollY + fragRect.top - topInset));
                    return true;
                }
            }
            window.scrollTo(0, 0);
            return true;
        }

        function sampleVisible() {
            var collected = collectSpans(0);
            var spans = collected.spans;
            if (!spans || spans.length === 0) {
                return null;
            }
            var targetY = 18;
            var viewportH = window.innerHeight || document.documentElement.clientHeight || 700;
            var chosenIndex = spans.length - 1;
            for (var i = 0; i < spans.length; i++) {
                var r = spans[i].getBoundingClientRect();
                if (r.height > 0 && r.bottom > targetY) {
                    chosenIndex = i;
                    break;
                }
            }
            var chosenSpan = spans[chosenIndex];
            var textNode = firstTextChild(chosenSpan);
            var text = textNode ? (textNode.nodeValue || "") : (chosenSpan.textContent || "");
            var offset = 0;
            var spanRect = chosenSpan.getBoundingClientRect();
            if (textNode && text.length > 0 && spanRect.top < targetY - 2) {
                var low = 0;
                var high = text.length - 1;
                var range = document.createRange();
                while (low < high) {
                    var mid = (low + high) >> 1;
                    range.setStart(textNode, mid);
                    range.setEnd(textNode, mid + 1);
                    var cr = range.getBoundingClientRect();
                    if (cr.bottom <= targetY) {
                        low = mid + 1;
                    } else {
                        high = mid;
                    }
                }
                offset = low;
                if (offset > 0 && offset < text.length) {
                    var code = text.charCodeAt(offset);
                    if (code >= 0xDC00 && code <= 0xDFFF) {
                        offset -= 1;
                    }
                }
            }
            var visibleParts = [];
            for (var j = chosenIndex; j < spans.length; j++) {
                var sr = spans[j].getBoundingClientRect();
                if (sr.top > viewportH + 40 && visibleParts.length > 0) {
                    break;
                }
                var t = spans[j].textContent || "";
                if (j === chosenIndex && offset > 0 && offset < t.length) {
                    t = t.substring(offset);
                }
                if (t.length > 0) {
                    visibleParts.push(t);
                }
                if (visibleParts.join(" ").length >= 600) {
                    break;
                }
            }
            return {
                sessionID: state.sessionID,
                epoch: state.epoch,
                path: state.path,
                node: chosenIndex,
                utf16Offset: offset,
                scrollY: window.scrollY || window.pageYOffset || 0,
                viewportHeight: viewportH,
                contentHeight: document.documentElement.scrollHeight || document.body.scrollHeight || 0,
                visibleText: visibleParts.join(" ")
            };
        }

        function waitForImagesAndTwoFrames(expectedSession, expectedEpoch, done) {
            var images = Array.prototype.slice.call(document.images || []);
            var pending = [];
            for (var i = 0; i < images.length; i++) {
                if (!images[i].complete) {
                    pending.push(images[i]);
                }
            }
            var finished = false;
            function proceed() {
                if (finished) { return; }
                finished = true;
                if (state.sessionID !== expectedSession || state.epoch !== expectedEpoch) { return; }
                window.requestAnimationFrame(function() {
                    if (state.sessionID !== expectedSession || state.epoch !== expectedEpoch) { return; }
                    window.requestAnimationFrame(function() {
                        if (state.sessionID !== expectedSession || state.epoch !== expectedEpoch) { return; }
                        done();
                    });
                });
            }
            if (pending.length === 0) {
                proceed();
                return;
            }
            var remaining = pending.length;
            var timer = window.setTimeout(function() {
                if (finished || state.sessionID !== expectedSession || state.epoch !== expectedEpoch) { return; }
                finished = true;
                post({kind: "error", reason: "image-layout-not-ready", sessionID: state.sessionID,
                      epoch: state.epoch, path: state.path});
            }, 10000);
            function onSettled() {
                remaining -= 1;
                if (remaining <= 0) {
                    window.clearTimeout(timer);
                    proceed();
                }
            }
            for (var k = 0; k < pending.length; k++) {
                pending[k].addEventListener("load", onSettled, { once: true });
                pending[k].addEventListener("error", onSettled, { once: true });
            }
        }

        function configure(config) {
            if (!config || typeof config !== "object") { return; }
            if (state.scrollTimer !== null) {
                window.clearTimeout(state.scrollTimer);
                state.scrollTimer = null;
            }
            state.sessionID = String(config.sessionID || "");
            state.epoch = String(config.epoch || "");
            state.path = String(config.path || "");
            state.ready = false;
            state.suppressingReflow = true;
            state.preserveTargetAnchor = Boolean(config.preserveTargetAnchor);
            state.targetNode = typeof config.targetNode === "number" ? config.targetNode : -1;
            state.targetOffset = typeof config.targetOffset === "number" ? config.targetOffset : 0;

            applyStyleSheet(config.css || "");

            var expectedCount = typeof config.expectedNodeCount === "number" ? config.expectedNodeCount : 0;
            var expectedLengths = Array.isArray(config.expectedNodeLengths) ? config.expectedNodeLengths : [];
            var collected = collectSpans(expectedCount);
            if (!collected.valid || collected.spans.length !== expectedCount) {
                post({
                    kind: "error",
                    reason: "dom-node-count-mismatch",
                    sessionID: state.sessionID,
                    epoch: state.epoch,
                    path: state.path
                });
                return;
            }
            for (var i = 0; i < expectedCount; i++) {
                var actualLen = (collected.spans[i].textContent || "").length;
                if (expectedLengths[i] !== actualLen) {
                    post({
                        kind: "error",
                        reason: "dom-node-length-mismatch",
                        sessionID: state.sessionID,
                        epoch: state.epoch,
                        path: state.path
                    });
                    return;
                }
            }

            var mySession = state.sessionID;
            var myEpoch = state.epoch;
            waitForImagesAndTwoFrames(mySession, myEpoch, function() {
                var ok = scrollToTarget(state.targetNode, state.targetOffset, config.fragment || "");
                if (!ok) {
                    post({
                        kind: "error",
                        reason: "target-restore-failed",
                        sessionID: state.sessionID,
                        epoch: state.epoch,
                        path: state.path
                    });
                    return;
                }
                window.requestAnimationFrame(function() {
                    if (state.sessionID !== mySession || state.epoch !== myEpoch) { return; }
                    window.requestAnimationFrame(function() {
                        if (state.sessionID !== mySession || state.epoch !== myEpoch) { return; }
                        var sample = sampleVisible();
                        if (!sample) {
                            post({
                                kind: "error",
                                reason: "empty-visible-sample",
                                sessionID: state.sessionID,
                                epoch: state.epoch,
                                path: state.path
                            });
                            return;
                        }
                        state.ready = true;
                        state.suppressingReflow = false;
                        state.restoredScrollY = sample.scrollY;
                        var restoredNode = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetNode : sample.node;
                        var restoredOffset = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetOffset : sample.utf16Offset;
                        post({
                            kind: "ready",
                            sessionID: sample.sessionID,
                            epoch: sample.epoch,
                            path: sample.path,
                            node: sample.node,
                            utf16Offset: sample.utf16Offset,
                            restoredNode: restoredNode,
                            restoredOffset: restoredOffset,
                            scrollY: sample.scrollY,
                            viewportHeight: sample.viewportHeight,
                            contentHeight: sample.contentHeight,
                            visibleText: sample.visibleText
                        });
                    });
                });
            });
        }

        function sampleScrollPayload() {
            if (!state.ready || state.suppressingReflow) { return null; }
            var sample = sampleVisible();
            if (!sample) { return null; }
            if (Math.abs(sample.scrollY - state.restoredScrollY) > 2) {
                state.preserveTargetAnchor = false;
            }
            var activeNode = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetNode : sample.node;
            var activeOffset = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetOffset : sample.utf16Offset;
            var payload = {
                kind: "scroll",
                sessionID: sample.sessionID,
                epoch: sample.epoch,
                path: sample.path,
                node: activeNode,
                utf16Offset: activeOffset,
                restoredNode: activeNode,
                restoredOffset: activeOffset,
                scrollY: sample.scrollY,
                viewportHeight: sample.viewportHeight,
                contentHeight: sample.contentHeight,
                visibleText: sample.visibleText
            };
            return payload;
        }

        function reportScrollNow() {
            var payload = sampleScrollPayload();
            if (payload) { post(payload); }
            return payload;
        }

        window.addEventListener("scroll", function() {
            if (!state.ready || state.suppressingReflow) { return; }
            if (state.scrollTimer !== null) {
                window.clearTimeout(state.scrollTimer);
            }
            var mySession = state.sessionID;
            var myEpoch = state.epoch;
            state.scrollTimer = window.setTimeout(function() {
                state.scrollTimer = null;
                if (state.sessionID !== mySession || state.epoch !== myEpoch) { return; }
                reportScrollNow();
            }, 90);
        }, { passive: true });

        window.__yjEpub = {
            configure: configure,
            sampleNow: sampleScrollPayload,
            realignAnchorIfStationary: function() {
                if (!state.ready || state.suppressingReflow || !state.preserveTargetAnchor || state.targetNode < 0) {
                    return false;
                }
                scrollToTarget(state.targetNode, state.targetOffset, "");
                return true;
            }
        };
    })();
    """
}
