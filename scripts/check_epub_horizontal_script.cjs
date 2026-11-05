'use strict';
// Runs the actual Swift-embedded production JS in a synthetic DOM. No browser/layout claims.
// Usage (repository root): node scripts/check_epub_horizontal_script.cjs
console.log('Scope: production JavaScript in synthetic DOM + static Swift checks only; no native/Swift/WebKit validation.');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const swift = fs.readFileSync(path.join(__dirname, '../App/EPUB/EPUBLocationScript.swift'), 'utf8');
const match = swift.match(/static let bootstrapSource: String = """\r?\n([\s\S]*?)\r?\n    """/);
assert.ok(match, 'production bootstrap must be extracted, not copied into tests');
const source = match[1].replace(/^    /gm, '');
assert.ok(!source.includes('\\'), 'update Swift string unescaping if production starts using escapes');
new vm.Script(source);

function harness(texts = ['a'.repeat(100) + '😀' + 'b'.repeat(98) + 'c'.repeat(100)], mode = 'paged') {
    const messages = [], calls = [], events = {}, frames = [], timers = new Map(), elements = new Map();
    let timerID = 0, observer, rangeCalls = 0, boundingCalls = 0;
    const model = { mode, perPage: 100, pages: 3, customRect: null };
    const window = {
        innerWidth: 320, innerHeight: 240, scrollX: 0, scrollY: 0,
        webkit: { messageHandlers: { yjepubLocator: { postMessage(p) { messages.push(p); } } } },
        addEventListener(name, fn) { (events[name] ||= []).push(fn); },
        requestAnimationFrame(fn) { frames.push(fn); },
        setTimeout(fn) { const id = ++timerID; timers.set(id, fn); return id; },
        clearTimeout(id) { timers.delete(id); },
        scrollTo(x, y) {
            calls.push([x, y]);
            this.scrollX = Math.max(0, Math.min(x, document.documentElement.scrollWidth - this.innerWidth));
            this.scrollY = Math.max(0, Math.min(y, document.documentElement.scrollHeight - this.innerHeight));
        }
    };
    function rect(left, top, width = 8, height = 16) {
        left -= window.scrollX; top -= window.scrollY;
        return { left, top, right: left + width, bottom: top + height, width, height };
    }
    function charRect(node, offset) {
        if (model.customRect) return model.customRect(node, offset, rect);
        // A surrogate pair is a single glyph; both UTF-16 units share the same rect.
        if (offset > 0 && /[\uDC00-\uDFFF]/.test(texts[node][offset])) offset--;
        const global = texts.slice(0, node).reduce((n, t) => n + t.length, 0) + offset;
        const page = Math.floor(global / model.perPage), within = global % model.perPage;
        return model.mode === 'paged'
            ? rect(page * window.innerWidth + 20 + (within % 10) * 10, 20 + Math.floor(within / 10) * 20)
            : rect(20 + (within % 10) * 10, page * 240 + 20 + Math.floor(within / 10) * 20);
    }
    function rects(node, start, end) {
        const out = [];
        for (let i = start; i < end; i++) out.push(charRect(node, i));
        return out;
    }
    function union(list) {
        boundingCalls++;
        const left = Math.min(...list.map(r => r.left)), right = Math.max(...list.map(r => r.right));
        const top = Math.min(...list.map(r => r.top)), bottom = Math.max(...list.map(r => r.bottom));
        return { left, right, top, bottom, width: right - left, height: bottom - top };
    }
    const root = {
        get scrollWidth() { return model.mode === 'paged' ? model.pages * window.innerWidth : window.innerWidth; },
        get scrollHeight() { return model.mode === 'paged' ? window.innerHeight : model.pages * 240; },
        get clientWidth() { return window.innerWidth; },
        get clientHeight() { return window.innerHeight; },
        appendChild(el) { elements.set(el.id, el); }
    };
    texts.forEach((text, index) => {
        const node = { nodeType: 3, nodeValue: text, nextSibling: null, index };
        elements.set('yj-t' + index, {
            id: 'yj-t' + index, getAttribute() { return null; },
            firstChild: node, textContent: text,
            getClientRects() { return rects(index, 0, text.length); },
            getBoundingClientRect() { return union(this.getClientRects()); }
        });
    });
    const document = {
        documentElement: root, body: root, head: root, images: [],
        getElementById(id) { return elements.get(id) || null; },
        getElementsByName(name) { return name === 'named' ? [elements.get('fragment')] : []; },
        createElement() {
            const attrs = {};
            return { id: '', textContent: '',
                setAttribute(k, v) { attrs[k] = v; }, getAttribute(k) { return attrs[k] || null; },
                querySelectorAll(selector) { return selector === 'img' || selector === 'a[href]' ? [] : [...elements.values()].filter(e => e.id); },
                getClientRects() { return [rect(0, 0, root.scrollWidth, root.scrollHeight)]; },
                getBoundingClientRect() { return this.getClientRects()[0]; }
            };
        },
        createRange() {
            let node, start, end;
            return {
                setStart(n, offset) { node = n; start = offset; },
                setEnd(n, offset) { assert.equal(n, node); end = offset; },
                getClientRects() { rangeCalls++; return rects(node.index, start, end); },
                getBoundingClientRect() { return union(this.getClientRects()); }
            };
        }
    };
    elements.set('fragment', {
        id: 'fragment', getAttribute(k) { return k === 'name' ? 'named' : null; },
        getClientRects() { return [rect(window.innerWidth * 2 + 20, 40)]; },
        getBoundingClientRect() { return union(this.getClientRects()); }
    });
    vm.runInNewContext(source, { window, document, ResizeObserver: class {
        constructor(fn) { observer = fn; }
        observe() {}
    } });
    const api = window.__yjEpub;
    function flush() {
        let count = 0;
        while (frames.length) {
            assert.ok(++count < 100, 'frames must settle');
            frames.shift()();
        }
    }
    function configure(extra = {}, settle = true) {
        api.configure({ sessionID: 'session', epoch: 'epoch-1', path: 'chapter.xhtml',
            chapterIndex: 0,
            expectedNodeCount: texts.length, expectedNodeLengths: texts.map(t => t.length),
            targetNode: -1, targetOffset: 0, preserveTargetAnchor: false,
            readingMode: mode, css: 'synthetic-style', ...extra });
        if (settle) flush();
    }
    return { window, document, api, model, messages, calls, elements, frames, timers, configure, flush,
        emit(name) { for (const fn of events[name] || []) fn(); },
        resizeDOM() { observer(); },
        get rangeCalls() { return rangeCalls; }, get boundingCalls() { return boundingCalls; } };
}

let passed = 0;
function test(name, body) { body(); passed++; console.log('PASS ' + name); }

test('Swift compatibility defaults, horizontal payload decoding, paged-only CSS contract (static)', () => {
    assert.match(swift, /trustedStyleSheet\(for preferences: ReaderPreferences, readingMode: EPUBReadingMode = \.scroll\)/);
    assert.match(swift, /startAtEnd: Bool = false,\s+readingMode: EPUBReadingMode = \.scroll/);
    assert.match(swift, /"readingMode": readingMode.rawValue/);
    for (const field of ['scrollX', 'viewportWidth', 'contentWidth']) {
        assert.ok(swift.includes(`var ${field}: Double = 0`));
        assert.ok(swift.includes(`${field}: (dict["${field}"] as? NSNumber)?.doubleValue ?? 0`));
    }
    assert.ok(swift.includes('guard readingMode == .paged else { return base }'));
    for (const rule of ['padding: 16px 20px 40px 20px', 'height: 100vh', 'column-width: calc(100vw - 40px)',
        'column-gap: 40px', 'column-fill: auto', 'overflow-y: hidden', 'max-height: calc(100vh - 64px)']) {
        assert.ok(swift.includes(rule), rule);
    }
});

test('target character restores to horizontal page, ready includes both axes', () => {
    const h = harness(); h.configure({ targetNode: 0, targetOffset: 145, preserveTargetAnchor: true });
    assert.deepEqual(h.calls[0], [320, 0]);
    const p = h.messages.at(-1);
    assert.equal(p.kind, 'ready'); assert.equal(p.utf16Offset, 100); assert.equal(p.restoredOffset, 145);
    assert.equal(p.scrollX, 320); assert.equal(p.viewportWidth, 320); assert.equal(p.contentWidth, 960);
    assert.equal(p.scrollY, 0); assert.equal(p.viewportHeight, 240); assert.equal(p.contentHeight, 240);
    assert.equal(p.sessionID, 'session'); assert.equal(p.epoch, 'epoch-1'); assert.equal(p.path, 'chapter.xhtml');
    assert.equal(p.visibleText, '😀' + 'b'.repeat(98));
    assert.equal(h.api.sampleNow().utf16Offset, 145);
});

test('long cross-column span finds current first UTF16 character without union boxes', () => {
    const h = harness(['a'.repeat(4000)]); h.model.pages = 40;
    h.configure({ targetNode: 0, targetOffset: 2510 });
    assert.equal(h.api.sampleNow().utf16Offset, 2500);
    assert.equal(h.api.sampleNow().visibleText, 'a'.repeat(100));
    assert.equal(h.boundingCalls, 0);
    assert.ok(h.rangeCalls < 2000, 'invisible ranges must be pruned');
});

test('surrogate split pruning does not include the following invisible character', () => {
    const h = harness(['😀x']);
    h.model.customRect = (_, offset, rect) => rect(offset < 2 ? 20 : 340, 20);
    h.configure(); assert.equal(h.api.sampleNow().visibleText, '😀');
    h.window.scrollTo(320, 0);
    assert.equal(h.api.sampleNow().utf16Offset, 2);
    assert.equal(h.api.sampleNow().visibleText, 'x');
});

test('target low surrogate and end-of-node locate the complete final scalar', () => {
    const h = harness(['a'.repeat(100) + '😀']);
    h.configure({ targetNode: 0, targetOffset: 101 }); assert.deepEqual(h.calls[0], [320, 0]);
    h.configure({ epoch: 'epoch-2', targetNode: 0, targetOffset: 102 });
    assert.deepEqual(h.calls.at(-1), [320, 0]);
    assert.equal(h.api.sampleNow().utf16Offset, 100);
});

test('visible text excludes offscreen x and y even if a span union intersects', () => {
    const h = harness(['AB', 'V', 'Z']);
    h.model.customRect = (node, offset, rect) => node === 0
        ? rect(offset === 0 ? -50 : 400, 20) : rect(20, node === 1 ? 20 : 300);
    h.configure(); const p = h.api.sampleNow();
    assert.equal(p.node, 1); assert.equal(p.utf16Offset, 0); assert.equal(p.visibleText, 'V');
});

test('fragment ID and legacy named fragment restore horizontally', () => {
    for (const fragment of ['fragment', 'named']) {
        const h = harness(); h.configure({ fragment });
        assert.deepEqual(h.calls[0], [640, 0]); assert.equal(h.api.sampleNow().utf16Offset, 200);
    }
});

test('startAtEnd uses the last horizontal page, target has precedence', () => {
    const h = harness(); h.configure({ startAtEnd: true });
    assert.deepEqual(h.calls[0], [640, 0]); assert.equal(h.api.sampleNow().visibleText, 'c'.repeat(100));
    h.configure({ epoch: 'epoch-2', startAtEnd: true, targetNode: 0, targetOffset: 100 });
    assert.deepEqual(h.calls.at(-1), [320, 0]);
});

test('horizontal movement releases preserved target and native stationary realignment', () => {
    const h = harness(); h.configure({ targetNode: 0, targetOffset: 145, preserveTargetAnchor: true });
    assert.equal(h.api.realignAnchorIfStationary(), true);
    h.window.scrollTo(640, 0); // No scroll event yet: sample must itself detect movement.
    assert.equal(h.api.realignAnchorIfStationary(), false);
    assert.equal(h.api.sampleNow().utf16Offset, 200);
    assert.equal(h.api.sampleNow().restoredOffset, 200);
});

test('viewport and DOM resize retain the moved anchor, not original saved target', () => {
    const h = harness(); h.configure({ targetNode: 0, targetOffset: 45, preserveTargetAnchor: true });
    h.window.scrollTo(640, 0); h.emit('scroll');
    h.window.innerWidth = 400; h.model.perPage = 50; h.model.pages = 6;
    h.emit('resize'); h.resizeDOM(); h.flush();
    assert.deepEqual(h.calls.at(-1), [1600, 0]);
    assert.equal(h.api.sampleNow().utf16Offset, 200);
});

test('repeated resize does not drift to the first character of intermediate pages', () => {
    const h = harness(); h.configure({ targetNode: 0, targetOffset: 45, preserveTargetAnchor: true });
    h.window.scrollTo(640, 0); h.emit('scroll');
    h.model.perPage = 75; h.model.pages = 4; h.resizeDOM(); h.flush();
    assert.equal(h.api.sampleNow().utf16Offset, 200); // Page begins at 150, anchor remains 200.
    h.model.perPage = 50; h.model.pages = 6; h.resizeDOM(); h.flush();
    assert.deepEqual(h.calls.at(-1), [1280, 0]);
    assert.equal(h.api.sampleNow().utf16Offset, 200);
    h.window.scrollTo(1600, 0); h.emit('scroll');
    assert.equal(h.api.sampleNow().utf16Offset, 250);
});

test('resize stationary preserved target follows its new character page', () => {
    const h = harness(); h.configure({ targetNode: 0, targetOffset: 145, preserveTargetAnchor: true });
    h.model.perPage = 50; h.model.pages = 6; h.resizeDOM(); h.flush();
    assert.deepEqual(h.calls.at(-1), [640, 0]); assert.equal(h.api.sampleNow().utf16Offset, 145);
});

test('new configuration suppresses stale ready, resize and scroll epoch callbacks', () => {
    const h = harness();
    h.configure({ epoch: 'old', targetNode: 0, targetOffset: 200 }, false);
    h.configure({ epoch: 'current', targetNode: 0, targetOffset: 100 });
    assert.deepEqual(h.messages.map(p => p.epoch), ['current']);
    h.window.scrollTo(640, 0); h.emit('scroll');
    const staleTimers = [...h.timers.values()];
    h.emit('resize');
    h.configure({ sessionID: 'new-session', epoch: 'new-epoch' });
    for (const callback of staleTimers) callback();
    assert.deepEqual(h.calls.at(-1), [0, 0]);
    assert.equal(h.messages.at(-1).epoch, 'new-epoch');
    assert.equal(h.messages.at(-1).path, 'chapter.xhtml');
    assert.equal(h.messages.filter(p => p.kind === 'scroll').length, 0);
});

test('node count / UTF16 length validation still refuses inconsistent DOM', () => {
    for (const extra of [{ expectedNodeCount: 2 }, { expectedNodeLengths: [299] }]) {
        const h = harness(); h.configure(extra);
        assert.equal(h.messages.at(-1).kind, 'error'); assert.equal(h.api.sampleNow(), null);
        assert.equal(h.calls.length, 0);
    }
});

test('scroll mode keeps vertical target, movement and end-of-chapter behavior', () => {
    const h = harness(undefined, 'scroll');
    h.configure({ targetNode: 0, targetOffset: 145, preserveTargetAnchor: true });
    assert.deepEqual(h.calls[0], [0, 322]); assert.equal(h.api.sampleNow().utf16Offset, 145);
    h.window.scrollTo(0, 480); assert.equal(h.api.sampleNow().utf16Offset, 200);
    h.configure({ epoch: 'end', startAtEnd: true });
    assert.deepEqual(h.calls.at(-1), [0, 480]); assert.equal(h.window.scrollY, 480);
    assert.equal(h.api.sampleNow().scrollX, 0);
});

test('omitted readingMode defaults to vertical behavior in production JS', () => {
    const h = harness(undefined, 'scroll');
    h.configure({ readingMode: undefined, targetNode: 0, targetOffset: 145 });
    assert.deepEqual(h.calls[0], [0, 322]);
});

console.log(`${passed} synthetic/static checks passed; Swift compilation and WebKit layout NOT verified.`);
