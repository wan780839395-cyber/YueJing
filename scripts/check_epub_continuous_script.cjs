'use strict';
// No dependencies/install/build. Uses an existing Chromium browser via local CDP.
// BROWSER_EXE=/path/to/chrome PI_SCRATCH_DIR=/temporary/directory node scripts/check_epub_continuous_script.cjs
// Real DOM/ranges/columns/scroll/ResizeObserver/image decode; native image transport alone is substituted.
console.log('Scope: production JS + CSS in real Chromium layout, NOT Swift/native/WKWebView. Image capability transport is a fixture substitute.');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const swift = fs.readFileSync(path.join(__dirname, '../App/EPUB/EPUBLocationScript.swift'), 'utf8');
const source = swift.match(/static let bootstrapSource: String = """\r?\n([\s\S]*?)\r?\n    """/)[1].replace(/^    /gm, '');
assert.ok(!source.includes('\\'), 'Swift JS escaping must be decoded if introduced');
let base = swift.match(/let base = """\r?\n([\s\S]*?)\r?\n        """/)[1];
const paged = swift.match(/return base \+ """\r?\n([\s\S]*?)\r?\n        """/)[1];
for (const [key, value] of Object.entries({'colors.bg':'white','colors.fg':'black','fontSize':'20','lineHeight':'30','max(8, spacing + 6)':'10'})) base = base.split('\\(' + key + ')').join(value);
assert.ok(!base.includes('\\('));
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function fixture(source, css, pagedCSS) {
    const results = [];
    function ok(condition, message) { if (!condition) throw new Error(message); }
    const tick = () => new Promise(r => requestAnimationFrame(r));
    async function settle() { for (let i = 0; i < 6; i++) await tick(); await new Promise(r => setTimeout(r, 110)); }
    const messages = [];
    window.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { messages.push(p); }}}};
    let epoch = 'epoch-1';
    const chapter = (i, image = false) => {
        const texts = image ? ['图片页'] : Array.from({length:8}, (_, n) => `chapter${i} paragraph${n} ` + 'abcdefghij '.repeat(9));
        const body = texts.map((text, n) => `<p${n === 0 ? ' id="frag"' : ''}><span id="yj-t${n}">${text}</span></p>`).join('') +
            (image ? '<img src="../Images/test.png" alt="fixture"/>' : '<a href="#frag"></a><a href="c0.xhtml#frag"></a>');
        return {path:`OEBPS/c${i}.xhtml`, index:i, lengths:texts.map(t => t.length), texts, body,
            url:`yjepub://s-session--e-${epoch}/OEBPS/c${i}.xhtml`,
            xhtml:`<html xmlns="http://www.w3.org/1999/xhtml"><head><title>fixture</title></head><body>${body}</body></html>`};
    };
    document.body.innerHTML = chapter(2).body;
    const originalDocument = document, originalSpan = document.getElementById('yj-t0');
    (0, eval)(source);
    const api = window.__yjEpub;
    const section = i => document.querySelector(`[data-yj-chapter="OEBPS/c${i}.xhtml"]`);
    const span = (i, n = 0) => section(i).querySelector(`[data-yj-original-id="yj-t${n}"], #yj-t${n}`);
    function config(i, extra = {}) {
        return {sessionID:'session', epoch, path:chapter(i).path, chapterIndex:i,
            expectedNodeCount:8, expectedNodeLengths:chapter(i).lengths,
            targetNode:-1, targetOffset:0, readingMode:'scroll', css, ...extra};
    }
    async function configure(i, extra) { api.configure(config(i, extra)); await settle(); ok(api.sampleNow(), 'configuration ready'); }
    async function sync(indices, extra = {}) {
        const start = messages.length;
        ok(api.syncWindow({sessionID:'session', epoch, chapters:indices.map(i => chapter(i)), keepPaths:indices.map(i => chapter(i).path), ...extra}), 'sync accepted');
        for (let n = 0; n < 120; n++) {
            const response = messages.slice(start).find(m => m.kind === 'window');
            if (response) { ok(!response.error, 'window success'); await settle(); return response; }
            await tick();
        }
        throw new Error('sync completion timeout');
    }
    function rectFor(sample) {
        const i = Number(sample.path.match(/c(\d+)\.xhtml/)[1]);
        const text = span(i, sample.node).firstChild, r = document.createRange();
        r.setStart(text, Math.min(text.length - 1, sample.utf16Offset)); r.setEnd(text, Math.min(text.length, sample.utf16Offset + 1));
        return r.getBoundingClientRect();
    }
    function sameRect(a,b,label) { ok(Math.abs(a.top-b.top) <= 1 && Math.abs(a.left-b.left) <= 1, `${label}: ${a.top},${a.left} != ${b.top},${b.left}`); }
    function atChapter(i, offset = 0) { scrollTo(0, scrollY + section(i).getBoundingClientRect().top + offset); }
    await configure(2);
    let anchor = api.sampleNow(), before = rectFor(anchor);
    const preloadMessageStart = messages.length;
    await sync([1,2,3]);
    ok(!messages.slice(preloadMessageStart).some(m=>m.kind === 'scroll'), 'preload cannot emit progress/scroll events');
    sameRect(before, rectFor(anchor), 'prepend exact character compensation');
    ok(originalSpan === document.getElementById('yj-t0') && document === originalDocument, 'initial DOM identity');
    results.push('prepend preserves exact character rect and initial IDs/DOM identity');

    scrollTo(0, scrollY + section(3).getBoundingClientRect().top - 130); await settle();
    let sample = api.sampleNow();
    ok(sample.path === chapter(2).path && sample.visibleText.includes('chapter3'), 'adjacent chapters simultaneously visible');
    atChapter(3, 20); await settle(); ok(api.sampleNow().path === chapter(3).path, 'forward crossing path');
    atChapter(2, 20); await settle(); ok(api.sampleNow().path === chapter(2).path, 'reverse crossing path');
    ok(originalSpan.isConnected && document === originalDocument, 'no reload/replacement across crossings');
    results.push('vertical adjacent text, forward/reverse boundary crossing without reload');

    await sync([0,1,2,3,4]); ok(api.windowPaths().length === 5, 'five resident bound');
    atChapter(3, 100); await settle();
    const priorY = scrollY, priorStyle = document.getElementById('yj-epub-style').textContent;
    epoch = 'epoch-2';
    api.configure(config(3, {preserveViewport:true, css:'body{display:none}', targetNode:-1}));
    ok(scrollY === priorY && document.getElementById('yj-epub-style').textContent === priorStyle, 'promotion cannot scroll or restyle');
    ok(messages.at(-2).kind === 'ready' && messages.at(-2).path === chapter(3).path && messages.at(-1).kind === 'scroll', 'promotion ready then actual scroll');
    anchor = api.sampleNow(); before = rectFor(anchor);
    const retained = span(3);
    await sync([2,3,4,5,6]);
    sameRect(before, rectFor(anchor), 'eviction exact character compensation');
    ok(span(3) === retained && api.windowPaths().length === 5 && !section(0) && !section(1), 'eviction identity and cap');
    results.push('epoch promotion has no reflow; five-window eviction preserves character rect');

    scrollTo(0, scrollY + section(3).getBoundingClientRect().top - 100); await settle();
    await sync([3,4,5,6,7]);
    ok(section(2) && !section(7) && api.windowPaths().length === 5, 'visible old section blocks additions beyond cap');
    results.push('visible old sections retained instead of exceeding cap');

    atChapter(3, 30); await settle();
    const movingStart = messages.length;
    // Keep sending scroll events more frequently than the reporting interval.
    // A trailing debounce would never notify native while the finger is moving.
    for (let n = 0; n < 30; n++) {
        scrollBy(0, 2); window.dispatchEvent(new Event('scroll')); await tick();
    }
    ok(messages.slice(movingStart).filter(m=>m.kind === 'scroll').length >= 2,
        'continuous scroll must report before the gesture settles');
    await settle();
    results.push('continuous scroll reports are bounded but cannot starve during a gesture');

    for (const target of [4, 2, 5, 3]) {
        epoch = `jump-${target}`;
        await configure(target, {fragment:'frag'});
        const visible = api.sampleNow();
        ok(visible.path === chapter(target).path && visible.visibleText.includes(`chapter${target}`), 'resident jump must show destination text');
        ok(document === originalDocument && span(3) === retained, 'resident jump must keep document and existing nodes');
    }
    const rapidStart = messages.length;
    epoch = 'rapid-obsolete'; api.configure(config(4));
    epoch = 'rapid-latest'; api.configure(config(3, {fragment:'frag'}));
    await settle();
    ok(api.sampleNow().path === chapter(3).path, 'latest rapid jump wins');
    ok(!messages.slice(rapidStart).some(m => m.kind === 'ready' && m.epoch === 'rapid-obsolete'), 'superseded configure cannot report ready');
    results.push('resident forward/backward fragment jumps show target; rapid jump cancels obsolete readiness without reload');

    atChapter(3, 120); await settle(); anchor = api.sampleNow();
    await configure(3, {readingMode:'paged', css:css + pagedCSS, targetNode:anchor.node, targetOffset:anchor.utf16Offset, preserveTargetAnchor:true});
    ok(api.sampleNow().path === chapter(3).path && api.sampleNow().node === anchor.node && api.sampleNow().utf16Offset === anchor.utf16Offset, 'mode anchor scoped to current chapter');
    anchor = api.sampleNow(); before = rectFor(anchor); const phase = scrollX % innerWidth;
    await sync([1,2,3,4,5]);
    sameRect(before, rectFor(anchor), 'paged prepend compensation');
    await sync([2,3,4,5,6]);
    sameRect(before, rectFor(anchor), 'paged eviction compensation');
    ok(Math.abs(scrollX % innerWidth - phase) < 1, 'paged phase retained');
    results.push('paged prepend/eviction preserves exact character rect and page phase');
    const x4 = scrollX + section(4).getClientRects()[0].left;
    scrollTo(Math.floor(x4 / innerWidth) * innerWidth, 0); await settle();
    ok(api.sampleNow().path === chapter(4).path, 'paged next chapter');
    const x3 = scrollX + section(3).getClientRects()[0].left;
    scrollTo(Math.floor(x3 / innerWidth) * innerWidth, 0); await settle();
    ok(api.sampleNow().path === chapter(3).path, 'paged reverse chapter');
    await configure(4, {readingMode:'paged', css:css + pagedCSS, fragment:'frag'});
    ok(api.sampleNow().path === chapter(4).path, 'duplicate fragment scoped');
    const links = section(4).querySelectorAll('a');
    ok(links[0].getAttribute('href') === chapter(4).url + '#frag' && links[1].getAttribute('href') === chapter(0).url + '#frag', 'fragment and relative href rebase');
    ok(span(3).id !== span(4).id && span(4).getAttribute('data-yj-original-id') === 'yj-t0', 'duplicate yj-t0 namespace');
    await configure(3, {readingMode:'paged', css:css + pagedCSS, startAtEnd:true});
    ok(api.sampleNow().path === chapter(3).path, 'chapter-specific end, not book/window end');
    anchor = api.sampleNow();
    await configure(3, {targetNode:anchor.node, targetOffset:anchor.utf16Offset, preserveTargetAnchor:true});
    ok(api.sampleNow().path === anchor.path && api.sampleNow().utf16Offset === anchor.utf16Offset, 'paged to vertical anchor');
    results.push('paged next/reverse chapter, scoped fragments/end, duplicate IDs, mode anchors');

    const reject = input => ok(api.syncWindow({sessionID:'session', epoch, chapters:[input], keepPaths:[input.path]}) === false, 'reject unsafe/invalid chapter');
    for (const bad of ['<script/>','<iframe/>','<img src="https://invalid.example/x"/>','<span onclick="x()"/>', '<span style="background:url(https://invalid.example/x)"/>', '<a href="javascript:x()"/>', '<img srcset="x 1x"/>']) {
        const c = chapter(7); c.xhtml = c.xhtml.replace('</body>',bad + '</body>'); reject(c);
    }
    let c = chapter(7); c.lengths = [1]; reject(c);
    c = chapter(7); c.index = 3; reject(c);
    c = chapter(7); c.url = c.url.replace(epoch, 'old-epoch'); reject(c);
    for (const list of [[chapter(7),chapter(7)], [0,1,2,3,4,5].map(i => chapter(i))]) {
        ok(!api.syncWindow({sessionID:'session',epoch,chapters:list,keepPaths:list.map(c=>c.path)}), 'reject duplicate/oversize');
    }
    ok(!api.syncWindow({sessionID:'session',epoch:'old',chapters:[],keepPaths:api.windowPaths()}), 'stale epoch rejected');
    ok(!api.syncWindow({sessionID:'other',epoch,chapters:[],keepPaths:api.windowPaths()}), 'stale session rejected');
    results.push('security: scripts, frames, events, CSS, external URLs/srcset, lengths, duplicate/count/index and stale tokens rejected');

    // Invalidate accepted async work synchronously, before its promise can commit.
    const keep = [3,4,5,6,7];
    ok(api.syncWindow({sessionID:'session',epoch,chapters:keep.map(i => chapter(i)),keepPaths:keep.map(i=>chapter(i).path)}), 'pending accepted');
    epoch = 'epoch-3'; api.configure(config(3,{preserveViewport:true})); await settle();
    ok(!section(7), 'old pending generation cannot insert after epoch promotion');
    results.push('configure invalidates pending sync generation');

    // Only the native image transport is substituted; actual HTMLImageElement decode/layout remain real.
    const canvas = document.createElement('canvas'); canvas.width = 40; canvas.height = 320;
    const dataURL = canvas.toDataURL('image/png');
    const nativeImport = document.importNode.bind(document), nativeDecode = HTMLImageElement.prototype.decode;
    let release, importedURL;
    const gate = new Promise(r => { release = r; });
    document.importNode = function(node, deep) {
        const imported = nativeImport(node, deep);
        const images = imported.nodeType === 1 ? (imported.localName === 'img' ? [imported] : [...imported.querySelectorAll('img')]) : [];
        for (const img of images) { importedURL = img.getAttribute('src'); img.src = dataURL; }
        return imported;
    };
    HTMLImageElement.prototype.decode = function() { return nativeDecode.call(this).then(() => gate); };
    atChapter(3, 80); await settle();
    const image = chapter(7, true), start = messages.length;
    ok(api.syncWindow({sessionID:'session',epoch,chapters:[image],keepPaths:[chapter(3).path,chapter(4).path,chapter(5).path,chapter(6).path,image.path]}), 'image sync accepted');
    await tick(); ok(!section(7), 'image stays off-flow until decoded');
    atChapter(4, 110); await settle(); anchor = api.sampleNow(); before = rectFor(anchor);
    release();
    for(let n=0;n<120 && !messages.slice(start).some(m=>m.kind==='window');n++) await tick();
    await settle();
    document.importNode = nativeImport; HTMLImageElement.prototype.decode = nativeDecode;
    ok(section(7) && importedURL === `yjepub://s-session--e-${epoch}/Images/test.png`, 'relative image rebased to epoch capability');
    sameRect(before, rectFor(anchor), 'capture anchor at image commit, not start');
    atChapter(7, 50); await settle();
    ok(api.sampleNow().path === image.path && api.sampleNow().node === 0, 'image-only synthetic anchor has image chapter path');
    results.push('off-flow real image decode; relative image URL; commit-time moved anchor; image-only locator');
    // Changing content below the viewport is not a viewport resize. An image
    // locator uses a chapter text anchor for persistence, not its pixel position.
    atChapter(7, 100); await settle();
    const imageY = scrollY;
    const extension = document.createElement('div'); extension.style.height = '300px';
    section(7).appendChild(extension); await settle();
    ok(Math.abs(scrollY - imageY) <= 1, 'content-only resize must not snap image viewport to chapter text anchor');
    extension.remove(); await settle();
    results.push('content-size notifications preserve image pixel viewport');

    const installed = api.windowPaths().join(), failureStart = messages.length;
    const broken = chapter(8, true);
    ok(api.syncWindow({sessionID:'session',epoch,chapters:[broken],keepPaths:[chapter(3).path,chapter(4).path,chapter(5).path,image.path,broken.path]}), 'broken image accepted pending load');
    for(let n=0;n<120 && !messages.slice(failureStart).some(m=>m.kind==='window');n++) await tick();
    const failure = messages.slice(failureStart).find(m=>m.kind==='window');
    ok(failure && failure.error && failure.sessionID === 'session' && failure.epoch === epoch && failure.path === chapter(3).path, 'image failure window payload');
    ok(api.windowPaths().join() === installed && !section(8), 'failed preload cannot mutate live window');
    results.push('image load failure reports installed paths without mutating DOM');
    const frame = document.createElement('iframe');
    frame.style.cssText = 'width:390px;height:844px;border:0';
    const xmlURL = URL.createObjectURL(new Blob(['<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body><span id="yj-t0">短章</span></body></html>'], {type:'application/xhtml+xml'}));
    frame.src = xmlURL;
    const loaded = new Promise(r => { frame.onload = r; }); document.body.appendChild(frame); await loaded;
    const w = frame.contentWindow, d = frame.contentDocument, tinyMessages = [];
    w.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { tinyMessages.push(p); }}}};
    ok(d.contentType === 'application/xhtml+xml', 'native-like XHTML MIME fixture');
    w.eval(source);
    const tiny = i => ({path:`tiny/c${i}.xhtml`, index:i, lengths:[2],
        url:`yjepub://s-session--e-tiny/tiny/c${i}.xhtml`,
        xhtml:'<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body><span id="yj-t0">短章</span></body></html>'});
    w.__yjEpub.configure({sessionID:'session',epoch:'tiny',path:tiny(0).path,chapterIndex:0,
        expectedNodeCount:1,expectedNodeLengths:[2],targetNode:-1,readingMode:'scroll',css});
    await settle();
    const tinyChapters = Array.from({length:5}, (_,i) => tiny(i));
    ok(w.__yjEpub.syncWindow({sessionID:'session',epoch:'tiny',chapters:tinyChapters,keepPaths:tinyChapters.map(c=>c.path)}), 'tiny window accepted');
    await settle();
    ok(tinyMessages.filter(m=>m.kind==='window').at(-1).needsMore === true, 'underfilled window requests more chapters');
    for (let count = 10; count <= 64; count = Math.min(64, count + 5)) {
        const all = Array.from({length:count}, (_,i)=>tiny(i));
        const resident = new Set(w.__yjEpub.windowPaths());
        ok(w.__yjEpub.syncWindow({sessionID:'session',epoch:'tiny',limit:count,
            chapters:all.filter(c=>!resident.has(c.path)),keepPaths:all.map(c=>c.path)}), 'adaptive sync accepted');
        await settle();
        if (!tinyMessages.filter(m=>m.kind==='window').at(-1).needsMore || count === 64) break;
    }
    ok(w.__yjEpub.windowPaths().length > 5 && w.__yjEpub.windowPaths().length <= 64, 'adaptive resident cap');
    const sixth = d.querySelector('[data-yj-chapter="tiny/c6.xhtml"]');
    w.scrollTo(0, w.scrollY + sixth.getBoundingClientRect().top); await settle();
    ok(w.__yjEpub.sampleNow().path === tiny(6).path, 'naturally reach the sixth short chapter');
    w.scrollTo(0, 0); await settle();
    ok(w.__yjEpub.sampleNow().path === tiny(0).path, 'reverse short chapter crossing');
    ok(!w.__yjEpub.syncWindow({sessionID:'session',epoch:'tiny',limit:65,chapters:[],keepPaths:w.__yjEpub.windowPaths()}), 'hard chapter cap rejected');
    ok(d.documentElement.scrollHeight > w.innerHeight, 'short chapters must allow natural progress beyond the first window');
    // At the end of a window, scrolling to a short chapter is clamped: an older
    // chapter remains at the viewport top. Readiness acknowledges the requested
    // chapter, not whichever chapter the visible-position sampler finds first.
    const lastIndex = w.__yjEpub.windowPaths().length - 1;
    for (const withImage of [false, true]) {
        if (withImage) {
            // Geometry fixture only: decoded image in the last, shorter-than-viewport chapter.
            const image = d.createElementNS('http://www.w3.org/1999/xhtml', 'img');
            image.src = dataURL;
            d.querySelector(`[data-yj-chapter="${tiny(lastIndex).path}"]`).appendChild(image);
            await image.decode(); await settle();
        }
        for (const preserveTargetAnchor of [false, true]) {
            const readyStart = tinyMessages.length;
            w.__yjEpub.configure({sessionID:'session',epoch:'tiny',path:tiny(lastIndex).path,chapterIndex:lastIndex,
                expectedNodeCount:1,expectedNodeLengths:[2],targetNode:preserveTargetAnchor ? 0 : -1,targetOffset:0,
                preserveTargetAnchor,readingMode:'scroll',css});
            await settle();
            const lastReady = tinyMessages.slice(readyStart).find(m=>m.kind==='ready');
            ok(w.__yjEpub.sampleNow().path !== tiny(lastIndex).path, 'fixture must retain earlier chapter at clamped viewport top');
            ok(lastReady && lastReady.path === tiny(lastIndex).path && lastReady.restoredNode === 0 && lastReady.restoredOffset === 0,
                'short last chapter readiness must acknowledge requested path, not visible predecessor');
            const priorY = w.scrollY; w.scrollBy(0, -100); await settle();
            ok(w.scrollY < priorY && w.__yjEpub.sampleNow() !== null, 'scroll remains responsive after clamped navigation');
        }
    }
    results.push('clamped text/image chapters acknowledge request; actual locator and subsequent scroll remain independent');
    frame.remove(); URL.revokeObjectURL(xmlURL);
    results.push('one-line chapters can continue beyond the first window');
    // Browser integration fixture: native capability promotion/window scheduling is
    // substituted, but all layout, scrolling and production JS events remain real.
    const rollingFrame = document.createElement('iframe');
    rollingFrame.style.cssText = 'width:390px;height:700px;border:0';
    rollingFrame.srcdoc = chapter(0).xhtml;
    const rollingLoaded = new Promise(r=>{ rollingFrame.onload = r; });
    document.body.appendChild(rollingFrame); await rollingLoaded;
    const rw = rollingFrame.contentWindow, rd = rollingFrame.contentDocument;
    let current = 0, serial = 0, rollingEpoch = 'rolling-0', promotionPending = false;
    const observed = new Set(), rollingErrors = [];
    const make = i => ({...chapter(i), url:`yjepub://s-session--e-${rollingEpoch}/OEBPS/c${i}.xhtml`});
    function refreshRolling() {
        const start = Math.max(0, Math.min(current - 2, 7));
        const all = Array.from({length:5},(_,n)=>make(start+n));
        const installed = new Set(rw.__yjEpub.windowPaths());
        ok(rw.__yjEpub.syncWindow({sessionID:'session',epoch:rollingEpoch,
            chapters:all.filter(c=>!installed.has(c.path)),keepPaths:all.map(c=>c.path)}), 'rolling window accepted');
    }
    rw.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) {
        if (p.kind === 'error' || (p.kind === 'window' && p.error)) rollingErrors.push(p.kind);
        if (p.kind !== 'scroll' || p.epoch !== rollingEpoch || promotionPending) return;
        const index = Number(p.path.match(/c(\d+)\.xhtml/)[1]); observed.add(index);
        if (index === current) return;
        promotionPending = true;
        rw.setTimeout(()=>{
            current = index; rollingEpoch = `rolling-${++serial}`;
            const c = make(index);
            rw.__yjEpub.configure({sessionID:'session',epoch:rollingEpoch,path:c.path,chapterIndex:index,
                expectedNodeCount:8,expectedNodeLengths:c.lengths,preserveViewport:true});
            refreshRolling(); promotionPending = false;
        },0);
    }}}};
    rw.eval(source);
    const first = make(0);
    rw.__yjEpub.configure({sessionID:'session',epoch:rollingEpoch,path:first.path,chapterIndex:0,
        expectedNodeCount:8,expectedNodeLengths:first.lengths,targetNode:-1,readingMode:'scroll',css});
    await settle(); refreshRolling(); await settle();
    const sameDocument = rd;
    for (let n=0;n<240 && current<9;n++) { rw.scrollBy(0,180); await tick(); }
    await settle();
    ok(current >= 9 && observed.has(6), 'continuous scrolling must advance beyond initial five-chapter window');
    for (let n=0;n<240 && current>0;n++) { rw.scrollBy(0,-180); await tick(); }
    await settle();
    ok(current === 0 && rw.__yjEpub.windowPaths().length <= 5 && rw.document === sameDocument,
        'continuous reverse scrolling returns to first chapter without reload or unbounded residency');
    ok(rollingErrors.length === 0, 'rolling window has no readiness/preload errors');
    rollingFrame.remove();
    results.push('12-chapter rolling fixture crosses chapter 9 and returns to 0 in one bounded DOM');
    return results;
}

(async () => {
    const browser = process.env.BROWSER_EXE || ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe','C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'].find(fs.existsSync);
    if (!browser) throw new Error('Set BROWSER_EXE to an existing Chromium browser (no installation performed).');
    if (!process.env.PI_SCRATCH_DIR) throw new Error('PI_SCRATCH_DIR is required for the temporary browser profile.');
    const profile = fs.mkdtempSync(path.join(process.env.PI_SCRATCH_DIR, 'epub-layout-'));
    const child = spawn(browser, ['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'], {stdio:'ignore'});
    let ws;
    try {
        const portFile = path.join(profile, 'DevToolsActivePort');
        for (let i=0; i<100 && !fs.existsSync(portFile); i++) await sleep(100);
        const port = fs.readFileSync(portFile,'utf8').split('\n')[0];
        const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
        ws = new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
        await new Promise((resolve,reject)=>{ws.onopen=resolve; ws.onerror=reject;});
        let next=0; const pending = new Map();
        ws.onmessage = e => { const m=JSON.parse(e.data); if(m.id && pending.has(m.id)) { const [resolve,reject]=pending.get(m.id); pending.delete(m.id); m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result); } };
        const send = (method,params={}) => new Promise((resolve,reject)=>{const id=++next;pending.set(id,[resolve,reject]);ws.send(JSON.stringify({id,method,params}));});
        await send('Emulation.setDeviceMetricsOverride',{width:520,height:420,deviceScaleFactor:1,mobile:false});
        const result = await send('Runtime.evaluate',{expression:`(${fixture.toString()})(${JSON.stringify(source)},${JSON.stringify(base)},${JSON.stringify(paged)})`,awaitPromise:true,returnByValue:true,timeout:45000});
        if(result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || JSON.stringify(result.exceptionDetails));
        for(const name of result.result.value) console.log('PASS ' + name);
        console.log(`${result.result.value.length} real-browser groups passed. Native resource transport, Swift compilation, and WKWebView NOT verified.`);
    } finally {
        if (ws) ws.close();
        child.kill();
        await sleep(500);
        try { fs.rmSync(profile,{recursive:true,force:true,maxRetries:5,retryDelay:200}); } catch { console.log('Temporary profile retained in scratch: ' + profile); }
    }
})().catch(error => { console.error(error.stack); process.exitCode=1; });
