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
    var scrollX: Double = 0
    var viewportWidth: Double = 0
    var contentWidth: Double = 0
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

    static func trustedStyleSheet(for preferences: ReaderPreferences, readingMode: EPUBReadingMode = .scroll) -> String {
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
        let base = """
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
        html, body { overflow-anchor: none !important; }
        body > section[data-yj-chapter] { display: flow-root !important; }
        span[id^="yj-t"], span[data-yj-original-id^="yj-t"] {
            display: inline !important;
        }
        """
        guard readingMode == .paged else { return base }
        // Content width + column gap equals one viewport; padding is not added per column.
        return base + """

        html {
            padding: 0 !important;
            width: 100% !important;
            height: 100% !important;
            overflow-x: auto !important;
            overflow-y: hidden !important;
        }
        body {
            box-sizing: border-box !important;
            width: 100vw !important;
            height: 100vh !important;
            min-height: 0 !important;
            max-height: 100vh !important;
            padding: 16px 20px 24px !important;
            column-width: calc(100vw - 40px) !important;
            column-gap: 40px !important;
            column-count: auto !important;
            column-fill: auto !important;
            overflow: visible !important;
        }
        html, body {
            direction: ltr !important;
            writing-mode: horizontal-tb !important;
            scroll-behavior: auto !important;
        }
        body * {
            max-width: 100% !important;
            box-sizing: border-box !important;
            break-before: auto !important;
            break-after: auto !important;
            widows: 1 !important;
            orphans: 1 !important;
        }
        body img, body svg {
            max-height: calc(100vh - 64px) !important;
            object-fit: contain !important;
            break-inside: avoid !important;
        }
        body > section[data-yj-chapter] { break-before: column !important; }
        body > section[data-yj-chapter]:first-child { break-before: auto !important; }
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
        preserveTargetAnchor: Bool,
        startAtEnd: Bool = false,
        readingMode: EPUBReadingMode = .scroll,
        preserveViewport: Bool = false
    ) throws -> String {
        guard let chapterIndex = package.spine.firstIndex(of: token.path),
              let nodes = package.textNodes[token.path] else {
            throw EPUBError.invalidPackage
        }
        let lengths = nodes.map { $0.utf16.count }
        var config: [String: Any] = [
            "sessionID": token.sessionID,
            "epoch": token.epoch.uuidString,
            "path": token.path,
            "chapterIndex": chapterIndex,
            "chapterBytes": package.resource(at: token.path)?.byteCount ?? 0,
            "preserveViewport": preserveViewport,
            "expectedNodeCount": nodes.count,
            "expectedNodeLengths": lengths,
            "targetNode": targetPosition?.path == token.path ? (targetPosition?.node ?? -1) : -1,
            "targetOffset": targetPosition?.path == token.path ? (targetPosition?.utf16Offset ?? 0) : 0,
            "fragment": fragment ?? "",
            "preserveTargetAnchor": preserveTargetAnchor && (targetPosition?.path == token.path),
            "startAtEnd": startAtEnd && targetPosition == nil && fragment == nil,
            "readingMode": readingMode.rawValue,
            "css": trustedStyleSheet(for: preferences, readingMode: readingMode)
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
            reason: reason,
            scrollX: (dict["scrollX"] as? NSNumber)?.doubleValue ?? 0,
            viewportWidth: (dict["viewportWidth"] as? NSNumber)?.doubleValue ?? 0,
            contentWidth: (dict["contentWidth"] as? NSNumber)?.doubleValue ?? 0
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
            chapters: [],
            syncGeneration: 0,
            syncing: false,
            scrollActive: false,
            targetPath: "",
            ready: false,
            suppressingReflow: true,
            preserveTargetAnchor: false,
            targetNode: -1,
            targetOffset: 0,
            restoredScrollY: 0,
            restoredScrollX: 0,
            paginated: false,
            lastAnchor: null,
            reflowRevision: 0,
            layoutWidth: 0,
            layoutHeight: 0,
            observedScrollX: 0,
            observedScrollY: 0,
            scrollTimer: null
        };

        function diagnosticNow() { return window.performance && window.performance.now ? window.performance.now() : 0; }
        var diagnosticOrigin = diagnosticNow();
        var diagnosticTrace = {events: [], counts: {}, sampleCount: 0, sampleMS: 0, sampleMaxMS: 0, remaining: 0};
        function recordDiagnostic(name, value, extra) {
            diagnosticTrace.counts[name] = (diagnosticTrace.counts[name] || 0) + 1;
            if (diagnosticTrace.events.length === 128) { diagnosticTrace.events.shift(); }
            diagnosticTrace.events.push({event: name, ms: diagnosticNow() - diagnosticOrigin,
                value: Number.isFinite(value) ? value : 0, extra: Number.isFinite(extra) ? extra : 0,
                active: state.scrollActive});
        }
        function finishSample(start) {
            var duration = Math.max(0, diagnosticNow() - start);
            diagnosticTrace.sampleCount += 1;
            diagnosticTrace.sampleMS += duration;
            diagnosticTrace.sampleMaxMS = Math.max(diagnosticTrace.sampleMaxMS, duration);
        }
        function observedScrollTo(x, y) {
            recordDiagnostic("programmatic-scroll", x, y);
            window.scrollTo(x, y);
        }

        function post(payload) {
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yjepubLocator) {
                    window.webkit.messageHandlers.yjepubLocator.postMessage(payload);
                }
            } catch (_) {}
        }

        function chapterFor(path) {
            return state.chapters.find(function(c) { return c.path === path; });
        }

        function originalID(el) {
            return el.getAttribute("data-yj-original-id") || el.id;
        }

        function scopedElement(id, path) {
            var chapter = chapterFor(path || state.path);
            if (!chapter) { return null; }
            if (originalID(chapter.element) === id) { return chapter.element; }
            var elements = chapter.element.querySelectorAll("[id], [name]");
            for (var i = 0; i < elements.length; i++) {
                if (originalID(elements[i]) === id || elements[i].getAttribute("name") === id) { return elements[i]; }
            }
            return null;
        }

        function collectSpans(expectedCount, path) {
            var chapter = chapterFor(path || state.path);
            var spans = chapter ? chapter.spans : [];
            return {valid: spans.length > 0 && (!expectedCount || expectedCount === spans.length), spans: spans};
        }

        function installInitial(config) {
            if (state.chapters.length) { return; }
            var element = document.createElementNS ? document.createElementNS("http://www.w3.org/1999/xhtml", "section") : document.createElement("section");
            element.setAttribute("data-yj-chapter", config.path);
            element.setAttribute("data-yj-index", config.chapterIndex);
            if (document.body.id) { element.setAttribute("data-yj-original-id", document.body.id); }
            var spans = [], index = 0, span;
            while ((span = document.getElementById("yj-t" + index))) { spans.push(span); index++; }
            while (document.body.firstChild) { element.appendChild(document.body.firstChild); }
            document.body.appendChild(element);
            state.chapters.push({path: config.path, index: config.chapterIndex, element: element, spans: spans,
                bytes: Number.isSafeInteger(config.chapterBytes) ? config.chapterBytes : 0});
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
                style = document.createElementNS ? document.createElementNS("http://www.w3.org/1999/xhtml", "style") : document.createElement("style");
                style.id = "yj-epub-style";
                (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = cssText;
        }
        function updatePageMetrics() {
            state.layoutWidth = viewportWidth();
            state.layoutHeight = window.innerHeight;
            var style = document.getElementById("yj-epub-page-metrics");
            if (!style) {
                style = document.createElementNS ? document.createElementNS("http://www.w3.org/1999/xhtml", "style") : document.createElement("style");
                style.id = "yj-epub-page-metrics";
                (document.head || document.documentElement).appendChild(style);
            }
            if (!state.paginated) { style.textContent = ""; return; }
            var width = viewportWidth();
            // Use the exact same CSS-pixel step as the locator, avoiding vw rounding drift.
            var columns = "body { width: " + width + "px !important; column-width: " + Math.max(1, width - 40) + "px !important; }";
            style.textContent = columns + "body::after { content: none !important; }";
            var pages = Math.max(1, Math.ceil(contentWidth() / width - 0.001));
            // Absolute, empty extent pads only the scroll range, never adds a blank column.
            style.textContent = columns + "body::after { content: '' !important; position: absolute !important; top: 0 !important; left: " +
                (pages * width - 1) + "px !important; width: 1px !important; height: 1px !important; pointer-events: none !important; }";
        }


        function viewportWidth() {
            return window.innerWidth || document.documentElement.clientWidth || 1;
        }

        function contentWidth() {
            return Math.max(document.documentElement.scrollWidth || 0, document.body.scrollWidth || 0);
        }

        function scrollToRect(rect) {
            if (state.paginated) {
                var width = viewportWidth();
                var page = Math.floor(Math.max(0, (window.scrollX || 0) + rect.left) / width);
                observedScrollTo(page * width, 0);
            } else {
                observedScrollTo(0, Math.max(0, window.scrollY + rect.top - 18));
            }
        }

        function firstRect(rects) {
            for (var i = 0; i < rects.length; i++) {
                if (rects[i].width > 0 && rects[i].height > 0) { return rects[i]; }
            }
            return null;
        }

        function scrollToTarget(targetNode, targetOffset, fragment, path) {
            path = path || state.path;
            // Character ranges avoid the union bounding box of a multi-column span.
            if (typeof targetNode === "number" && targetNode >= 0) {
                var chapter = chapterFor(path);
                var span = chapter && chapter.spans[targetNode];
                if (!span) { return false; }
                var textNode = firstTextChild(span);
                var rect = null;
                if (textNode && textNode.nodeValue && textNode.nodeValue.length > 0) {
                    var len = textNode.nodeValue.length;
                    var clamped = Math.max(0, Math.min(targetOffset || 0, len - 1));
                    var code = textNode.nodeValue.charCodeAt(clamped);
                    if (clamped > 0 && code >= 0xDC00 && code <= 0xDFFF) { clamped -= 1; }
                    var scalarLength = textNode.nodeValue.codePointAt(clamped) > 0xFFFF ? 2 : 1;
                    var range = document.createRange();
                    range.setStart(textNode, clamped);
                    range.setEnd(textNode, Math.min(len, clamped + scalarLength));
                    rect = firstRect(range.getClientRects());
                }
                if (!rect || (rect.width === 0 && rect.height === 0 && rect.top === 0)) {
                    rect = firstRect(span.getClientRects()) || span.getBoundingClientRect();
                }
                scrollToRect(rect);
                return true;
            }
            if (typeof fragment === "string" && fragment.length > 0) {
                var target = scopedElement(fragment, path);
                if (target) {
                    var fragRect = firstRect(target.getClientRects()) || target.getBoundingClientRect();
                    scrollToRect(fragRect);
                    return true;
                }
            }
            var chapter = chapterFor(path);
            if (!chapter) { return false; }
            if (chapter === state.chapters[0]) { observedScrollTo(0, 0); }
            else { scrollToRect(chapter.element.getBoundingClientRect()); }
            return true;
        }

        function scrollToChapterEnd() {
            var chapter = chapterFor(state.path);
            if (!chapter) { return false; }
            var rects = chapter.element.getClientRects();
            var rect = rects[rects.length - 1] || chapter.element.getBoundingClientRect();
            if (state.paginated) {
                var width = viewportWidth();
                var page = Math.max(0, Math.ceil(((window.scrollX || 0) + rect.right) / width - 0.001) - 1);
                observedScrollTo(page * width, 0);
            } else {
                observedScrollTo(0, Math.max(0, window.scrollY + rect.bottom - window.innerHeight));
            }
            return true;
        }

        function sampleVisible(path) {
            var sampleStarted = diagnosticNow();
            var chapters = path ? state.chapters.filter(function(c) { return c.path === path; }) : state.chapters;
            var entries = [];
            chapters.forEach(function(c) {
                c.spans.forEach(function(span, node) { entries.push({span: span, node: node, path: c.path}); });
            });
            var spans = entries.map(function(e) { return e.span; });
            if (!spans || spans.length === 0) { return null; }
            var viewportH = window.innerHeight || document.documentElement.clientHeight || 700;
            var viewportW = viewportWidth();
            var top = state.paginated ? 0 : 18;
            function intersects(rects) {
                for (var r = 0; r < rects.length; r++) {
                    var rect = rects[r];
                    if (rect.width > 0 && rect.height > 0 && rect.right > 0 &&
                        rect.left < viewportW && rect.bottom > top && rect.top < viewportH) {
                        return true;
                    }
                }
                return false;
            }
            var chosenIndex = -1;
            var offset = 0;
            var visibleParts = [];
            var visibleLength = 0;
            for (var i = 0; i < spans.length && visibleLength < 600; i++) {
                if (!intersects(spans[i].getClientRects())) { continue; }
                var textNode = firstTextChild(spans[i]);
                if (!textNode) { continue; }
                var text = textNode.nodeValue || "";
                var range = document.createRange();
                var part = "";
                // Prune invisible subranges by their real fragments, never their union box.
                // Splits stay on scalar boundaries, so a visible surrogate pair is indivisible.
                function visit(start, end) {
                    if (start >= end || visibleLength >= 600) { return; }
                    range.setStart(textNode, start);
                    range.setEnd(textNode, end);
                    if (!intersects(range.getClientRects())) { return; }
                    var mid = Math.floor((start + end) / 2);
                    var code = text.charCodeAt(mid);
                    if (mid > start && code >= 0xDC00 && code <= 0xDFFF) { mid -= 1; }
                    if (mid <= start) { mid = start + (text.codePointAt(start) > 0xFFFF ? 2 : 1); }
                    if (mid >= end) {
                        if (chosenIndex < 0) { chosenIndex = i; offset = start; }
                        part += text.substring(start, end);
                        visibleLength += end - start;
                        return;
                    }
                    visit(start, mid);
                    visit(mid, end);
                }
                visit(0, text.length);
                if (part.length > 0) { visibleParts.push(part); }
            }
            // A visible image can precede the first visible text (including an adjacent chapter).
            var chosenPath = chosenIndex >= 0 ? entries[chosenIndex].path : null;
            var chosenNode = chosenIndex >= 0 ? entries[chosenIndex].node : 0;
            for (var c = 0; c < chapters.length; c++) {
                var chapter = chapters[c];
                if (chapter.path === chosenPath) { break; }
                var images = chapter.element.querySelectorAll("img");
                if (Array.prototype.some.call(images, function(img) { return intersects(img.getClientRects()); })) {
                    chosenPath = chapter.path; chosenNode = 0; offset = 0; break;
                }
            }
            if (!chosenPath) {
                var visibleChapter = chapters.find(function(c) { return intersects(c.element.getClientRects()); });
                chosenPath = visibleChapter ? visibleChapter.path : state.path;
                if (state.lastAnchor && state.lastAnchor.path === chosenPath) {
                    chosenNode = state.lastAnchor.node; offset = state.lastAnchor.utf16Offset;
                }
            }
            var result = {
                sessionID: state.sessionID,
                epoch: state.epoch,
                path: chosenPath,
                node: chosenNode,
                utf16Offset: offset,
                scrollY: window.scrollY || window.pageYOffset || 0,
                viewportHeight: viewportH,
                contentHeight: Math.max(document.documentElement.scrollHeight || 0, document.body.scrollHeight || 0),
                scrollX: window.scrollX || window.pageXOffset || 0,
                viewportWidth: viewportW,
                contentWidth: contentWidth(),
                visibleText: visibleParts.join(" ")
            };
            finishSample(sampleStarted);
            diagnosticTrace.remaining = Math.max(0, result.contentHeight - result.scrollY - viewportH);
            return result;
        }

        function waitForImagesAndTwoFrames(expectedSession, expectedEpoch, done) {
            var imagesStarted = diagnosticNow();
            recordDiagnostic("initial-images-start");
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
                recordDiagnostic("initial-images-settled", diagnosticNow() - imagesStarted);
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

        function validLengths(spans, lengths) {
            return Array.isArray(lengths) && lengths.length > 0 && spans.length === lengths.length &&
                lengths.every(function(n, i) {
                    return Number.isSafeInteger(n) && n >= 0 && spans[i] && (spans[i].textContent || "").length === n;
                });
        }

        function windowMessage(error, deferred) {
            recordDiagnostic(error ? "window-error" : deferred ? "window-deferred" : "window-committed", state.chapters.length);
            post({kind: "window", sessionID: state.sessionID, epoch: state.epoch, path: state.path,
                paths: state.chapters.map(function(c) { return c.path; }), error: error, deferred: deferred === true,
                needsMore: !error && (state.paginated ? contentWidth() < viewportWidth() * 2 :
                    Math.max(document.documentElement.scrollHeight || 0, document.body.scrollHeight || 0) < window.innerHeight * 2)});
        }

        function capabilityURL(value, base) {
            var url = new URL(value, base);
            var host = "s-" + state.sessionID.toLowerCase().replace(/[^a-z0-9-]/g, "-") + "--e-" + state.epoch.toLowerCase();
            if (url.protocol !== "yjepub:" || url.hostname !== host || url.username || url.password || url.port || url.search) {
                throw new Error("invalid-resource-capability");
            }
            return url;
        }

        function parseChapter(input, generation, validateOnly) {
            if (typeof input.xhtml !== "string" || input.xhtml.length > 8388608 || /<!DOCTYPE|<!ENTITY/i.test(input.xhtml)) {
                throw new Error("invalid-xhtml");
            }
            var byteLength = new TextEncoder().encode(input.xhtml).length;
            if (byteLength > 8388608) { throw new Error("xhtml-budget"); }
            var base = capabilityURL(input.url);
            if (base.hash || decodeURIComponent(base.pathname) !== "/" + input.path) { throw new Error("invalid-chapter-url"); }
            var parsed = new DOMParser().parseFromString(input.xhtml, "application/xhtml+xml");
            if (parsed.querySelector("parsererror") || parsed.doctype) { throw new Error("invalid-xml"); }
            var bodies = parsed.getElementsByTagNameNS("http://www.w3.org/1999/xhtml", "body");
            if (bodies.length !== 1) { throw new Error("invalid-body"); }
            var body = bodies[0];
            var allowed = ("article section nav aside header footer main div address h1 h2 h3 h4 h5 h6 hgroup " +
                "p blockquote pre hr br wbr figure figcaption details summary ul ol li dl dt dd span a em strong i b u s small sub sup mark " +
                "q cite code kbd samp var dfn abbr time bdi bdo ruby rt rp del ins table caption thead tbody tfoot tr th td colgroup col img").split(" ");
            var ids = new Set();
            // Validate the entire inert XML before importing anything into the live document.
            Array.prototype.forEach.call(parsed.querySelectorAll("*"), function(el) {
                var name = el.localName;
                var inBody = el === body || body.contains(el);
                if (el.namespaceURI !== "http://www.w3.org/1999/xhtml" ||
                    (inBody ? name !== "body" && allowed.indexOf(name) < 0 : ["html", "head", "meta", "title"].indexOf(name) < 0)) {
                    throw new Error("forbidden-element");
                }
                Array.prototype.forEach.call(el.attributes, function(attr) {
                    var key = attr.name, value = attr.value;
                    var permitted = key === "xmlns" || key === "id" || key === "dir" ||
                        (name === "a" && key === "href") || (name === "img" && (key === "src" || key === "alt")) ||
                        (!inBody && name === "meta" && ["charset", "http-equiv", "content"].indexOf(key) >= 0);
                    if (!permitted || (key === "xmlns" && value !== "http://www.w3.org/1999/xhtml") ||
                        (key === "http-equiv" && value.toLowerCase() !== "content-security-policy")) { throw new Error("forbidden-attribute"); }
                    if (key === "id") {
                        if (!value || ids.has(value)) { throw new Error("duplicate-id"); }
                        ids.add(value);
                    }
                    if (key === "src" || key === "href") { capabilityURL(value, base.href); }
                });
            });
            var parsedSpans = Array.prototype.filter.call(body.querySelectorAll("[id]"), function(el) { return el.id.indexOf("yj-t") === 0; });
            if (!validLengths(parsedSpans, input.lengths) || parsedSpans.some(function(el, i) {
                return el.id !== "yj-t" + i || el.localName !== "span" || el.childNodes.length !== 1 || el.firstChild.nodeType !== 3;
            })) { throw new Error("invalid-text-nodes"); }
            if (validateOnly) { return; }
            var element = document.createElementNS ? document.createElementNS("http://www.w3.org/1999/xhtml", "section") : document.createElement("section");
            element.setAttribute("data-yj-chapter", input.path);
            element.setAttribute("data-yj-index", input.index);
            if (body.hasAttribute("dir")) { element.setAttribute("dir", body.getAttribute("dir")); }
            // IDs are local to a chapter, including original body fragment IDs.
            if (body.id) { element.setAttribute("data-yj-original-id", body.id); }
            Array.prototype.forEach.call(body.querySelectorAll("[src], [href]"), function(el) {
                ["src", "href"].forEach(function(key) {
                    if (el.hasAttribute(key)) { el.setAttribute(key, capabilityURL(el.getAttribute(key), base.href).href); }
                });
            });
            Array.prototype.forEach.call(body.childNodes, function(node) { element.appendChild(document.importNode(node, true)); });
            var spans = [], count = 0;
            Array.prototype.forEach.call(element.querySelectorAll("[id]"), function(el) {
                var id = el.id;
                el.setAttribute("data-yj-original-id", id);
                el.id = "yj-chapter-" + input.index + "-" + generation + "-" + id;
                if (document.getElementById(el.id)) { throw new Error("id-collision"); }
                if (id.indexOf("yj-t") === 0) {
                    var n = Number(id.slice(4));
                    if (!Number.isSafeInteger(n) || n < 0 || id !== "yj-t" + n || el.localName !== "span" || spans[n]) {
                        throw new Error("invalid-text-id");
                    }
                    spans[n] = el; count++;
                }
            });
            if (count !== input.lengths.length || !validLengths(spans, input.lengths)) { throw new Error("node-length-mismatch"); }
            return {path: input.path, index: input.index, element: element, spans: spans, bytes: byteLength};
        }

        function cancelImagePreloads() {
            var cancels = state.imageCancels || [];
            state.imageCancels = [];
            cancels.forEach(function(cancel) { cancel(); });
        }

        function preloadChapter(chapter) {
            return Promise.all(Array.prototype.map.call(chapter.element.querySelectorAll("img"), function(img) {
                return new Promise(function(resolve, reject) {
                    var imageStarted = diagnosticNow();
                    recordDiagnostic("image-start");
                    var finished = false;
                    var timer = window.setTimeout(function() { finish(false); }, 8000);
                    function finish(ok, cancelled) {
                        if (finished) { return; }
                        finished = true;
                        recordDiagnostic(cancelled ? "image-cancelled" : ok ? "image-ready" : "image-failed", diagnosticNow() - imageStarted);
                        window.clearTimeout(timer);
                        img.removeEventListener("load", loaded);
                        img.removeEventListener("error", failed);
                        if (ok) { resolve(); } else { reject(new Error("image-not-ready")); }
                    }
                    state.imageCancels.push(function() {
                        if (!finished) { finish(false, true); img.removeAttribute("src"); }
                    });
                    function failed() { finish(false); }
                    function loaded() {
                        if (!img.naturalWidth) { finish(false); return; }
                        if (typeof img.decode === "function") { img.decode().then(function() { finish(true); }, failed); }
                        else { finish(true); }
                    }
                    img.addEventListener("load", loaded);
                    img.addEventListener("error", failed);
                    if (img.complete) { loaded(); }
                });
            }));
        }

        function inViewport(rect) {
            return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.left < viewportWidth() &&
                rect.bottom > 0 && rect.top < window.innerHeight;
        }

        function anchorRect(anchor) {
            if (anchor.measureRange) { return firstRect(anchor.measureRange.getClientRects()); }
            if (anchor.measureElement) { return anchor.measureElement.getBoundingClientRect(); }
            var chapter = chapterFor(anchor.path);
            if (!chapter) { return null; }
            var span = chapter.spans[anchor.node], text = span && firstTextChild(span);
            if (text && text.length) {
                var start = Math.min(anchor.utf16Offset, text.length - 1);
                var range = document.createRange();
                range.setStart(text, start);
                range.setEnd(text, Math.min(text.length, start + (text.nodeValue.codePointAt(start) > 0xFFFF ? 2 : 1)));
                var rect = firstRect(range.getClientRects());
                if (rect && inViewport(rect)) { anchor.measureRange = range; return rect; }
            }
            var images = chapter.element.querySelectorAll("img");
            for (var i = 0; i < images.length; i++) {
                var rect = images[i].getBoundingClientRect();
                if (inViewport(rect)) { anchor.measureElement = images[i]; return rect; }
            }
            return span ? firstRect(span.getClientRects()) : chapter.element.getBoundingClientRect();
        }

        function syncWindow(config) {
            if (!config || !state.ready || config.sessionID !== state.sessionID || config.epoch !== state.epoch) { return false; }
            var windowStarted = diagnosticNow();
            recordDiagnostic("window-start", diagnosticTrace.remaining, state.observedScrollY);
            var additions = [], paths = new Set(), indexes = new Set();
            var generation = state.syncGeneration + 1;
            var limit = config.limit === undefined ? 5 : config.limit;
            try {
                if (!Number.isSafeInteger(limit) || limit < 1 || limit > 64 ||
                    !Array.isArray(config.chapters) || config.chapters.length > limit || !Array.isArray(config.keepPaths) ||
                    config.keepPaths.length < 1 || config.keepPaths.length > limit || new Set(config.keepPaths).size !== config.keepPaths.length ||
                    config.keepPaths.some(function(p) { return typeof p !== "string" || !p; })) { throw new Error("invalid-window"); }
                config.chapters.forEach(function(c) {
                    if (!c || typeof c.path !== "string" || !c.path || !Number.isSafeInteger(c.index) || c.index < 0 ||
                        paths.has(c.path) || indexes.has(c.index) || !Array.isArray(c.lengths) || !c.lengths.length ||
                        c.lengths.some(function(n) { return !Number.isSafeInteger(n) || n < 0; }) ||
                        config.keepPaths.indexOf(c.path) < 0) { throw new Error("invalid-chapter"); }
                    paths.add(c.path); indexes.add(c.index);
                    var old = chapterFor(c.path);
                    if (state.chapters.some(function(old) { return old.index === c.index && old.path !== c.path; })) { throw new Error("index-collision"); }
                    if (old) {
                        if (old.index !== c.index || !validLengths(old.spans, c.lengths)) { throw new Error("changed-chapter"); }
                        parseChapter(c, generation, true);
                    } else { additions.push(parseChapter(c, generation)); }
                });
                if (config.keepPaths.some(function(p) { return !chapterFor(p) && !paths.has(p); })) { throw new Error("missing-chapter"); }
            } catch (_) { windowMessage(true); return false; }
            state.syncGeneration = generation;
            cancelImagePreloads();
            state.syncing = false;
            var session = state.sessionID, epoch = state.epoch;
            function live() { return generation === state.syncGeneration && session === state.sessionID && epoch === state.epoch; }
            // Prepending/evicting changes the scroll origin. Do not fight a native
            // drag or its deceleration with coordinate compensation. A deferred
            // acknowledgement releases the native timeout; idle retries the window.
            function deferForScroll() {
                return !state.paginated && state.scrollActive &&
                    (state.chapters.some(function(c) { return config.keepPaths.indexOf(c.path) < 0; }) ||
                     additions.some(function(c) { return c.index < state.chapters[0].index; }));
            }
            if (deferForScroll()) { windowMessage(false, true); return true; }
            Promise.all(additions.map(preloadChapter)).then(function() {
                if (!live()) { return; }
                recordDiagnostic("window-prepared", diagnosticNow() - windowStarted, additions.length);
                // A gesture may have begun while images were being decoded.
                if (deferForScroll()) { state.imageCancels = []; windowMessage(false, true); return; }
                state.imageCancels = [];
                // Capture AFTER image decoding: the reader may have moved while it was pending.
                var anchor = sampleVisible(), before = anchor && anchorRect(anchor);
                if (!anchor) { windowMessage(true); return; }
                state.syncing = true;
                state.reflowRevision += 1;
                var kept = state.chapters.filter(function(c) {
                    var visible = Array.prototype.some.call(c.element.getClientRects(), inViewport);
                    return config.keepPaths.indexOf(c.path) >= 0 || c.path === state.path || c.path === anchor.path || visible;
                });
                state.chapters.forEach(function(c) { if (kept.indexOf(c) < 0) { c.element.remove(); } });
                additions.sort(function(a, b) { return Math.abs(a.index - (chapterFor(anchor.path) || {index: 0}).index) -
                    Math.abs(b.index - (chapterFor(anchor.path) || {index: 0}).index); });
                var residentBytes = kept.reduce(function(sum, c) { return sum + c.bytes; }, 0);
                additions.forEach(function(c) {
                    var low = Math.min.apply(null, kept.map(function(k) { return k.index; }));
                    var high = Math.max.apply(null, kept.map(function(k) { return k.index; }));
                    if ((c.index === low - 1 || c.index === high + 1) && kept.length < limit && residentBytes + c.bytes <= 41943040) {
                        kept.push(c); residentBytes += c.bytes;
                    }
                });
                kept.sort(function(a, b) { return a.index - b.index; });
                // Only insert new sections; never detach/move an already resident node.
                for (var i = kept.length - 1; i >= 0; i--) {
                    if (!chapterFor(kept[i].path)) { document.body.insertBefore(kept[i].element, i + 1 < kept.length ? kept[i + 1].element : null); }
                }
                state.chapters = kept;
                updatePageMetrics();
                var after = anchor && anchorRect(anchor);
                var deltaX = before && after && state.paginated ? after.left - before.left : 0;
                var deltaY = before && after && !state.paginated ? after.top - before.top : 0;
                // Even scrollTo(currentX, currentY) can cancel WebKit's native momentum.
                // Append-only commits must not issue any programmatic scroll command.
                if (deltaX !== 0 || deltaY !== 0) {
                    observedScrollTo((window.scrollX || 0) + deltaX, state.paginated ? 0 : (window.scrollY || 0) + deltaY);
                }
                state.observedScrollX = window.scrollX || 0;
                state.observedScrollY = window.scrollY || 0;
                state.preserveTargetAnchor = false;
                state.suppressingReflow = false;
                state.lastAnchor = anchor && {path: anchor.path, node: anchor.node, utf16Offset: anchor.utf16Offset};
                // ResizeObserver delivery from this commit must not snap to a page/line start.
                window.requestAnimationFrame(function() { window.requestAnimationFrame(function() {
                    if (!live()) { return; }
                    state.syncing = false;
                    windowMessage(false);
                    // A preload is not user navigation and cannot create a progress event.
                }); });
            }).catch(function() {
                if (live()) { state.syncing = false; cancelImagePreloads(); windowMessage(true); }
            });
            return true;
        }

        function refreshChapterLinks() {
            var host = "s-" + state.sessionID.toLowerCase().replace(/[^a-z0-9-]/g, "-") + "--e-" + state.epoch.toLowerCase();
            state.chapters.forEach(function(c) {
                var base = "yjepub://" + host + "/" + c.path.split("/").map(encodeURIComponent).join("/");
                Array.prototype.forEach.call(c.element.querySelectorAll("a[href]"), function(link) {
                    var url = new URL(link.getAttribute("href"), base);
                    if (url.protocol === "yjepub:") { url.host = host; link.setAttribute("href", url.href); }
                });
            });
        }

        function configure(config) {
            if (!config || typeof config !== "object") { return; }
            recordDiagnostic(config.preserveViewport === true ? "promotion" : "navigation");
            state.syncGeneration += 1;
            cancelImagePreloads();
            state.syncing = false;
            installInitial(config);
            if (config.preserveViewport === true) {
                var selected = chapterFor(config.path);
                if (!selected || selected.index !== config.chapterIndex || selected.spans.length !== config.expectedNodeCount ||
                    !validLengths(selected.spans, config.expectedNodeLengths)) { return false; }
                state.sessionID = String(config.sessionID || "");
                state.epoch = String(config.epoch || "");
                state.path = config.path;
                refreshChapterLinks();
                state.reflowRevision += 1;
                state.ready = true;
                state.suppressingReflow = false;
                state.preserveTargetAnchor = false;
                state.observedScrollX = window.scrollX || 0;
                state.observedScrollY = window.scrollY || 0;
                var current = sampleVisible();
                var ready = Object.assign({}, current, {kind: "ready", path: config.path});
                if (current.path !== config.path) { ready.node = 0; ready.utf16Offset = 0; ready.visibleText = ""; }
                ready.restoredNode = ready.node; ready.restoredOffset = ready.utf16Offset;
                post(ready);
                reportScrollNow();
                return true;
            }
            if (state.scrollTimer !== null) {
                window.clearTimeout(state.scrollTimer);
                state.scrollTimer = null;
            }
            state.sessionID = String(config.sessionID || "");
            state.epoch = String(config.epoch || "");
            state.path = String(config.path || "");
            refreshChapterLinks();
            state.ready = false;
            state.suppressingReflow = true;
            state.preserveTargetAnchor = Boolean(config.preserveTargetAnchor);
            state.targetNode = typeof config.targetNode === "number" ? config.targetNode : -1;
            state.targetOffset = typeof config.targetOffset === "number" ? config.targetOffset : 0;
            state.targetPath = state.path;
            state.paginated = config.readingMode === "paged";
            state.lastAnchor = null;
            state.reflowRevision += 1;

            applyStyleSheet(config.css || "");
            updatePageMetrics();

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
                updatePageMetrics();
                var ok = config.startAtEnd === true && state.targetNode < 0 && !config.fragment
                    ? scrollToChapterEnd()
                    : scrollToTarget(state.targetNode, state.targetOffset, config.fragment || "");
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
                        // A short target near the window end cannot always reach the viewport
                        // top. Acknowledge the configured chapter, not a visible predecessor;
                        // ordinary scroll sampling remains unscoped and reports the real view.
                        var sample = sampleVisible(state.path);
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
                        state.restoredScrollX = sample.scrollX;
                        state.observedScrollX = sample.scrollX;
                        state.observedScrollY = sample.scrollY;
                        var restoredNode = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetNode : sample.node;
                        var restoredOffset = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetOffset : sample.utf16Offset;
                        state.lastAnchor = {path: sample.path, node: restoredNode, utf16Offset: restoredOffset};
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
                            scrollX: sample.scrollX,
                            viewportWidth: sample.viewportWidth,
                            contentWidth: sample.contentWidth,
                            visibleText: sample.visibleText
                        });
                    });
                });
            });
        }

        function sampleScrollPayload() {
            if (!state.ready || state.suppressingReflow || state.syncing) { return null; }
            var sample = sampleVisible();
            if (!sample) { return null; }
            var movement = state.paginated ? sample.scrollX - state.restoredScrollX : sample.scrollY - state.restoredScrollY;
            if (Math.abs(movement) > 2 || sample.path !== state.targetPath) {
                state.preserveTargetAnchor = false;
            }
            var activeNode = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetNode : sample.node;
            var activeOffset = (state.preserveTargetAnchor && state.targetNode >= 0) ? state.targetOffset : sample.utf16Offset;
            state.lastAnchor = {path: sample.path, node: activeNode, utf16Offset: activeOffset};
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
                scrollX: sample.scrollX,
                viewportWidth: sample.viewportWidth,
                contentWidth: sample.contentWidth,
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
            if (!state.ready || state.suppressingReflow || state.syncing) { return; }
            var x = window.scrollX || 0, y = window.scrollY || 0;
            // WebKit can deliver a programmatic compensation/restore event late.
            // Unchanged pixels are not a new user navigation (especially short chapters).
            if (x === state.observedScrollX && y === state.observedScrollY) { return; }
            state.observedScrollX = x; state.observedScrollY = y;
            // Cache the current real anchor before a subsequent resize can reflow the DOM.
            sampleScrollPayload();
            // Throttle, not debounce: continuous dragging must advance native
            // chapter authority/preload before reaching the installed window edge.
            if (state.scrollTimer !== null) { return; }
            var mySession = state.sessionID;
            var myEpoch = state.epoch;
            state.scrollTimer = window.setTimeout(function() {
                state.scrollTimer = null;
                if (state.sessionID !== mySession || state.epoch !== myEpoch) { return; }
                reportScrollNow();
            }, 90);
        }, { passive: true });

        function realignAfterResize() {
            if (!state.ready || !state.lastAnchor || state.syncing) { return; }
            // Body/document ResizeObserver also fires when neighbors are appended.
            // Those commits already compensate exact pixel anchors; a text-anchor
            // restore here would jump backwards on an image-only viewport.
            var width = viewportWidth(), height = window.innerHeight;
            if (!state.paginated && width === state.layoutWidth && height === state.layoutHeight) { return; }
            state.layoutWidth = width; state.layoutHeight = height;
            var anchor = state.lastAnchor;
            var mySession = state.sessionID;
            var myEpoch = state.epoch;
            var revision = ++state.reflowRevision;
            state.suppressingReflow = true;
            window.requestAnimationFrame(function() {
                if (state.sessionID !== mySession || state.epoch !== myEpoch || revision !== state.reflowRevision) { return; }
                updatePageMetrics();
                scrollToTarget(anchor.node, anchor.utf16Offset, "", anchor.path);
                window.requestAnimationFrame(function() {
                    if (state.sessionID !== mySession || state.epoch !== myEpoch || revision !== state.reflowRevision) { return; }
                    state.restoredScrollX = window.scrollX || 0;
                    state.restoredScrollY = window.scrollY || 0;
                    // Repeated reflows must retain this character, not drift to each new page start.
                    state.targetNode = anchor.node;
                    state.targetOffset = anchor.utf16Offset;
                    state.targetPath = anchor.path;
                    state.preserveTargetAnchor = true;
                    state.suppressingReflow = false;
                    reportScrollNow();
                });
            });
        }
        window.addEventListener("resize", realignAfterResize, { passive: true });
        if (typeof ResizeObserver !== "undefined") {
            var resizeObserver = new ResizeObserver(function() {
                if (!state.syncing) { realignAfterResize(); }
            });
            resizeObserver.observe(document.documentElement);
            resizeObserver.observe(document.body);
        }

        window.__yjEpub = {
            configure: configure,
            syncWindow: syncWindow,
            parkForReopen: function() {
                // Keep nodes/pixels only. No old async transaction, sample or epoch survives closing.
                state.syncGeneration += 1;
                cancelImagePreloads();
                if (state.scrollTimer !== null) { window.clearTimeout(state.scrollTimer); }
                state.scrollTimer = null;
                state.ready = false;
                state.syncing = false;
                state.suppressingReflow = true;
                state.scrollActive = false;
                state.reflowRevision += 1;
                state.sessionID = "";
                state.epoch = "";
                var imageBytes = 0;
                state.chapters.forEach(function(c) {
                    Array.prototype.forEach.call(c.element.querySelectorAll('img'), function(img) {
                        imageBytes = Math.min(536870912, imageBytes + (img.naturalWidth || 0) * (img.naturalHeight || 0) * 4);
                    });
                });
                return {paths: state.chapters.map(function(c) { return c.path; }), imageBytes: imageBytes};
            },
            setScrollActive: function(active) {
                if (state.scrollActive !== (active === true)) { recordDiagnostic(active === true ? "motion-start" : "motion-end"); }
                state.scrollActive = active === true;
            },
            diagnostics: function() {
                return {events: diagnosticTrace.events.map(function(e) { return Object.assign({}, e); }),
                    counts: Object.assign({}, diagnosticTrace.counts), sampleCount: diagnosticTrace.sampleCount,
                    sampleMS: diagnosticTrace.sampleMS, sampleMaxMS: diagnosticTrace.sampleMaxMS};
            },
            windowPaths: function() { return state.chapters.map(function(c) { return c.path; }); },
            sampleNow: sampleScrollPayload,
            sampleStatus: function() {
                return {ready: state.ready, reflow: state.suppressingReflow, syncing: state.syncing,
                    chapters: state.chapters.length, revision: state.reflowRevision, scrollActive: state.scrollActive,
                    configuredPathVisible: (sampleVisible() || {}).path === state.path};
            },
            realignAnchorIfStationary: function() {
                // Native callers must not pull a reader back after a horizontal user move.
                sampleScrollPayload();
                if (!state.ready || state.suppressingReflow || !state.preserveTargetAnchor || state.targetNode < 0) {
                    return false;
                }
                scrollToTarget(state.targetNode, state.targetOffset, "", state.targetPath);
                state.restoredScrollX = window.scrollX || 0;
                state.restoredScrollY = window.scrollY || 0;
                return true;
            }
        };
    })();
    """
}
