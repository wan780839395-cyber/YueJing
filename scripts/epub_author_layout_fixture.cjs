'use strict';
// Serialized into the same real Chromium process as the existing layout checks.
// Native CSS parsing/transport is tested separately; this uses the sanitized contract.
module.exports = async function authorLayoutFixture(source, readerCSS, authorCSS) {
    const results = [];
    function ok(value, message) { if (!value) throw new Error(message); }
    const tick = () => new Promise(resolve => requestAnimationFrame(resolve));
    async function settle() { for (let i = 0; i < 6; i++) await tick(); }
    const texts = Array.from({length: 16}, (_, i) => 'author paragraph ' + i + ' abcdefghij '.repeat(24));
    function chapter(i, font = false) {
        const prefix = `html[data-yj-layout="original"] [data-yj-author-scope="scope${i}"]`;
        const css = `${prefix} .same {font-size:${26 + i * 8}px;line-height:42px;text-indent:30px;}
${prefix} [data-yj-original-id="original"] {color:rgb(${i ? '20, 80, 40' : '80, 20, 40'});}` +
            (font ? '@font-face {font-family:"fixture-font";src:url("/OPS/font.ttf");font-weight:700;font-style:italic;}' : '');
        const body = texts.map((text, n) => `<p class="same"${n === 0 ? ' id="original"' : ''}><span id="yj-t${n}">${text}</span></p>`).join('');
        return {path:`OPS/c${i}.xhtml`, index:i, lengths:texts.map(t => t.length), body, css,
            xhtml:`<html xmlns="http://www.w3.org/1999/xhtml"><head><title>fixture</title><style data-yj-author-style="true">${css}</style></head><body data-yj-author-scope="scope${i}">${body}</body></html>`};
    }
    async function create(font = false) {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:fixed;inset:0;width:520px;height:420px;border:0;z-index:99999';
        const loaded = new Promise(resolve => frame.onload = resolve);
        const c = chapter(0, font);
        frame.srcdoc = `<html><head><style data-yj-author-style="true">${c.css}</style></head><body data-yj-author-scope="scope0">${c.body}</body></html>`;
        document.body.appendChild(frame); await loaded;
        const w = frame.contentWindow, d = w.document, messages = [];
        w.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { messages.push(p); }}}};
        w.eval(source);
        const api = w.__yjEpub;
        const config = (epoch, extra = {}) => ({sessionID:'author-session', epoch, path:c.path, chapterIndex:0,
            expectedNodeCount:texts.length, expectedNodeLengths:texts.map(t => t.length),
            targetNode:-1, targetOffset:0, readingMode:'scroll', css:authorCSS, ...extra});
        async function ready(epoch) {
            for (let i = 0; i < 120; i++) {
                const p = messages.find(p => p.kind === 'ready' && p.epoch === epoch && !p.restorationPending);
                if (p) return p;
                const error = messages.find(p => p.kind === 'error' && p.epoch === epoch);
                if (error) throw new Error(JSON.stringify(error));
                await tick();
            }
            throw new Error('author ready timeout: ' + epoch);
        }
        function rect(sample) {
            const section = d.querySelector(`[data-yj-chapter="${sample.path}"]`);
            const span = section.querySelector(`[data-yj-original-id="yj-t${sample.node}"],#yj-t${sample.node}`);
            const range = d.createRange(), t = span.firstChild;
            range.setStart(t, sample.utf16Offset); range.setEnd(t, Math.min(t.length, sample.utf16Offset + 1));
            return range.getBoundingClientRect();
        }
        return {frame,w,d,messages,api,config,ready,rect};
    }
    let f = await create();
    try {
        f.api.configure(f.config('original')); await f.ready('original');
        const p0 = f.d.querySelector('p.same');
        ok(f.d.documentElement.getAttribute('data-yj-layout') === 'original', 'missing mode defaults original');
        let computed = f.w.getComputedStyle(p0);
        ok(computed.fontSize === '26px' && computed.lineHeight === '42px' && computed.textIndent === '30px', 'actual author typography');
        ok(computed.color === 'rgb(80, 20, 40)', 'original ID selector maps after mounting');
        const c1 = chapter(1); c1.url = 'yjepub://s-author-session--e-original/OPS/c1.xhtml';
        ok(f.api.syncWindow({sessionID:'author-session',epoch:'original',chapters:[c1],keepPaths:['OPS/c0.xhtml','OPS/c1.xhtml']}), 'author window accepted');
        for (let i=0;i<120 && !f.messages.some(p=>p.kind==='window');i++) await tick();
        ok(f.messages.some(p=>p.kind==='window' && !p.error), 'author window committed');
        const p1 = f.d.querySelector('[data-yj-author-scope="scope1"] p');
        ok(f.w.getComputedStyle(p1).fontSize === '34px' && f.w.getComputedStyle(p0).fontSize === '26px', 'same class isolated by chapter');
        ok(f.w.getComputedStyle(p1).color === 'rgb(20, 80, 40)', 'duplicate original ID isolated by chapter');
        results.push('original default applies author CSS; imported chapters isolate identical classes and IDs');
        f.w.scrollTo(0, 900); await settle();
        const anchor = f.api.sampleNow(), before = f.rect(anchor), originalNode = p0.firstChild;
        const target = {targetNode:anchor.node,targetOffset:anchor.utf16Offset,targetViewportOffset:anchor.viewportOffset,preserveTargetAnchor:true};
        f.api.configure(f.config('reader', {...target,layoutMode:'reader',css:readerCSS}));
        let ready = await f.ready('reader');
        ok(f.w.getComputedStyle(p0).fontSize === '20px' && f.w.getComputedStyle(p0).lineHeight === '30px', 'reader typography overrides only in reader mode');
        ok(ready.restoredNode === anchor.node && ready.restoredOffset === anchor.utf16Offset, 'reader switch retains text coordinate');
        ok(Math.abs(f.rect(anchor).top - before.top) <= 1, 'reader switch retains character viewport offset');
        f.api.configure(f.config('return', {...target,layoutMode:'original'})); ready = await f.ready('return');
        ok(f.w.getComputedStyle(p0).fontSize === '26px' && originalNode === p0.firstChild, 'return uses same original DOM');
        ok(ready.restoredNode === anchor.node && ready.restoredOffset === anchor.utf16Offset && Math.abs(f.rect(anchor).top-before.top)<=1, 'original roundtrip exact character');
        results.push('original/reader/original switch retains DOM, UTF16 coordinate and exact character top');
        f.api.parkForReopen();
        f.api.configure(f.config('warm', {...target,sessionID:'warm-session'})); await f.ready('warm');
        ok(originalNode === p0.firstChild && Math.abs(f.rect(anchor).top-before.top)<=1, 'author warm reopen keeps exact character');
        const cold = await create();
        try {
            cold.api.configure(cold.config('cold', target)); await cold.ready('cold');
            ok(Math.abs(cold.rect(anchor).top-before.top)<=1, 'author cold reopen keeps exact character');
        } finally { cold.frame.remove(); }
        results.push('author cold and fresh-session warm reopen preserve character pixels');
    } finally { f.frame.remove(); }

    function decodeBase64Bytes(b64) {
        const bin = atob(b64);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }
    const validGeomFontB64 =
        'AAEAAAAKAIAAAwAgT1MvMmYUbsEAAACsAAAAYGNtYXAAdABcAAABDAAAADxnbHlmvb57sgAAAUgA' +
        'AACAaGVhZC8KPKEAAAHIAAAANmhoZWEM5glkAAACAAAAACRobXR4EZQAyAAAAiQAAAAMbG9jYQAc' +
        'AFwAAAIwAAAACG1heHAABgANAAACOAAAACBuYW1lrwA06wAAAlgAAAH4cG9zdP+kAFYAAARQAAAA' +
        'KAAEBdwBkAAFAAACigJYAAAASwKKAlgAAAFeADIA+gAAAgAFAwAAAAAAAAAAAAEAAAAAAAAAAAAA' +
        'AABZSlRGAMAAIABBAyD/OAAAAyAAyAAAAAEAAAAAAfQCvAAAACAAAAAAAAIAAAADAAAAFAADAAEA' +
        'AAAUAAQAKAAAAAYABAABAAIAIABB//8AAAAgAEH////h/8EAAQAAAAAAAAACAGQAAAOEArwAAwAH' +
        'AAABAQEBAQEBAQBkAAADIAAA/UQCWAAA/agAAAK8AAD9RABkAAAB9AAAAAIAZAAACWACvAAHAAoA' +
        'AAEBAQEBAQEBAQEBAGQDtgGQA7b+Pv8a/FT/GgFyApT+tgAAArwAAP1EAAAAyAAA/zgBQAAAAPAA' +
        'AAEAAAABAABkdcbZXw889QADA+gAAAAA4xf8gAAAAADjF/yAAGQAAAlgArwAAAAIAAIAAAAAAAAA' +
        'AQAAAyD/OAAACcQAZABkCWAAAQAAAAAAAAAAAAAAAAAAAAMD6ABkA+gAAAnEAGQAAAAcABwAQAABA' +
        'AAAAwALAAIAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAADACWAAEAAAAAAAEAFAAAAAEAAAAAAAIABw' +
        'AUAAEAAAAAAAMAGAAbAAEAAAAAAAQAHAAzAAEAAAAAAAUACwBPAAEAAAAAAAYAHABaAAMAAQQJAA' +
        'EAKAB2AAMAAQQJAAIADgCeAAMAAQQJAAMAMACsAAMAAQQJAAQAOADcAAMAAQQJAAUAFgEUAAMAAQ' +
        'QJAAYAOAEqWXVlSmluZ1Rlc3RHZW9tZXRyaWNSZWd1bGFyWXVlSmluZ1Rlc3RHZW9tZXRyaWMtMS' +
        '4wWXVlSmluZ1Rlc3RHZW9tZXRyaWMgUmVndWxhclZlcnNpb24gMS4wWXVlSmluZ1Rlc3RHZW9tZX' +
        'RyaWMtUmVndWxhcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAUgBlAG' +
        'cAdQBsAGEAcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMALQAxAC4AMA' +
        'BZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAIABSAGUAZwB1AGwAYQByAF' +
        'YAZQByAHMAaQBvAG4AIAAxAC4AMABZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcg' +
        'BpAGMALQBSAGUAZwB1AGwAYQByAAIAAAAAAAD/nAAyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAMA' +
        'JA==';
    function makeBrokenSFNTBytes() {
        const valid = decodeBase64Bytes(validGeomFontB64);
        // Truncate after SFNT header + table directory so FontFace.load rejects decoding.
        return valid.slice(0, 128);
    }

    // 1. No-font sync fastpath: promotion without @font-face emits ready synchronously.
    f = await create(false);
    try {
        f.api.configure(f.config('nofont-init'));
        const initReady = await f.ready('nofont-init');
        ok(initReady.authorStyleFallback !== true, 'no-font init has no fallback flag');
        const beforeCount = f.messages.length;
        ok(f.api.configure(f.config('nofont-promo', {preserveViewport:true})) === true, 'no-font promotion accepted');
        ok(f.messages.slice(beforeCount).some(m => m.kind === 'ready' && m.epoch === 'nofont-promo' && m.authorStyleFallback !== true),
            'no-font promotion posts ready synchronously without async delay');
        results.push('no-font synchronous promotion fastpath preserved');
    } finally { f.frame.remove(); }

    // 2. Real Chromium FontFace SFNT decoding: valid glyph width vs rejected decode fallback width & anchor.
    for (const validMode of [true, false]) {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:fixed;inset:0;width:520px;height:420px;border:0;z-index:99999';
        const loaded = new Promise(resolve => frame.onload = resolve);
        const prefix = 'html[data-yj-layout="original"] [data-yj-author-scope="geom0"]';
        const css = `@font-face { font-family: "geom-face"; src: url("/OPS/geom.ttf") format("truetype"); font-weight: 400; font-style: normal; }\n` +
            `${prefix} p.geom { font-family: "geom-face", serif; font-size: 24px; line-height: 36px; }\n` +
            `${prefix} p.sys { font-family: serif; font-size: 24px; line-height: 36px; }`;
        const bodyTexts = ['AAAA', 'AAAA', ...Array.from({length: 12}, (_, i) => 'spacer paragraph ' + i + ' abcdefghij '.repeat(14))];
        const body = `<p id="g-custom" class="geom"><span id="yj-t0">AAAA</span></p>` +
            `<p id="g-sys" class="sys"><span id="yj-t1">AAAA</span></p>` +
            bodyTexts.slice(2).map((t, i) => `<p class="sys"><span id="yj-t${i + 2}">${t}</span></p>`).join('');
        frame.srcdoc = `<html><head><style data-yj-author-style="true">${css}</style></head><body data-yj-author-scope="geom0">${body}</body></html>`;
        document.body.appendChild(frame); await loaded;
        try {
            const w = frame.contentWindow, d = w.document, msgs = [];
            w.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { msgs.push(p); }}}};
            w.eval(source);
            const bytes = validMode ? decodeBase64Bytes(validGeomFontB64) : makeBrokenSFNTBytes();
            const realFace = new w.FontFace('geom-face', bytes);
            d.fonts.add(realFace);
            const origFonts = d.fonts;
            Object.defineProperty(d, 'fonts', {
                configurable: true,
                value: {
                    forEach(fn) { fn(realFace); },
                    get ready() { return origFonts.ready; }
                }
            });
            const cfg = {
                sessionID: 'geom-session', epoch: validMode ? 'geom-valid' : 'geom-bad',
                path: 'OPS/geom.xhtml', chapterIndex: 0,
                expectedNodeCount: bodyTexts.length, expectedNodeLengths: bodyTexts.map(t => t.length),
                targetNode: validMode ? -1 : 4, targetOffset: validMode ? 0 : 6,
                targetViewportOffset: validMode ? undefined : 24,
                preserveTargetAnchor: !validMode,
                readingMode: 'scroll', layoutMode: 'original', css: authorCSS
            };
            w.__yjEpub.configure(cfg);
            let rdy = null;
            for (let i = 0; i < 120; i++) {
                rdy = msgs.find(m => m.kind === 'ready' && m.epoch === cfg.epoch && !m.restorationPending);
                if (rdy) break;
                const err = msgs.find(m => m.kind === 'error' && m.epoch === cfg.epoch);
                if (err) throw new Error('unexpected error: ' + JSON.stringify(err));
                await tick();
            }
            ok(rdy, 'geom ready emitted for validMode=' + validMode);
            const span0 = d.querySelector('[data-yj-original-id="yj-t0"], #yj-t0');
            const span1 = d.querySelector('[data-yj-original-id="yj-t1"], #yj-t1');
            const r0 = d.createRange(); r0.selectNodeContents(span0.firstChild);
            const r1 = d.createRange(); r1.selectNodeContents(span1.firstChild);
            const wCustom = r0.getBoundingClientRect().width;
            const wSys = r1.getBoundingClientRect().width;
            if (validMode) {
                ok(rdy.authorStyleFallback !== true, 'valid SFNT keeps authorStyleFallback falsy');
                ok(Math.abs(wCustom - 240) <= 5, 'valid SFNT renders 240px AAAA width: ' + wCustom);
                ok(wSys > 20 && wSys < 110, 'system serif fallback width < 110: ' + wSys);
                ok(d.querySelector('style[data-yj-author-style]').textContent.includes('@font-face'), 'valid SFNT retains @font-face');
            } else {
                ok(rdy.authorStyleFallback === true, 'broken SFNT emits ready with authorStyleFallback=true');
                ok(rdy.restoredNode === 4 && rdy.restoredOffset === 6, 'broken SFNT fallback preserves target anchor');
                ok(wCustom > 20 && wCustom < 110 && Math.abs(wCustom - wSys) <= 2, 'broken SFNT falls back to usable serif width: ' + wCustom + ' vs ' + wSys);
                ok(!d.querySelector('style[data-yj-author-style]').textContent.includes('@font-face'), 'broken SFNT @font-face rule removed');
                ok(w.getComputedStyle(span0).fontSize === '24px', 'other author CSS declarations preserved on fallback');
                const targetSpan = d.querySelector('[data-yj-original-id="yj-t4"], #yj-t4');
                const tr = d.createRange(); tr.setStart(targetSpan.firstChild, 6); tr.setEnd(targetSpan.firstChild, 7);
                ok(Math.abs(tr.getBoundingClientRect().top - 24) <= 2, 'broken SFNT fallback preserves target viewport offset');
            }
        } finally { frame.remove(); }
    }
    results.push('real FontFace SFNT width unchanged for valid font; broken SFNT falls back to usable width and exact anchor');

    f = await create(true);
    try {
        let finish, loads = 0;
        const delayed = new Promise(resolve => finish = resolve);
        const faces = [
            {family:'fixture-font',weight:'700',style:'italic',status:'unloaded',load() { loads++; return delayed.then(()=>{this.status='loaded'; return this;}); }},
            {family:'fixture-font',weight:'400',style:'normal',status:'unloaded',load() { loads++; return delayed.then(()=>{this.status='loaded'; return this;}); }}
        ];
        Object.defineProperty(f.d, 'fonts', {configurable:true,value:{forEach(fn) { faces.forEach(fn); },ready:Promise.resolve()}});
        f.api.configure(f.config('fonts'));
        await settle();
        ok(loads === 2 && !f.api.sampleNow() && !f.messages.some(p=>p.kind==='ready'), 'all font weights/styles gate readiness');
        const style = f.d.querySelector('style[data-yj-author-style]');
        ok(style.textContent.includes('yjepub://s-author-session--e-fonts/OPS/font.ttf'), 'font URL bound to session epoch');
        finish();
        const fontsReady = await f.ready('fonts');
        ok(fontsReady.authorStyleFallback !== true, 'successful faces have authorStyleFallback falsy');
        ok(f.api.sampleNow().authorStyleFallback !== true, 'successful sampleNow has authorStyleFallback falsy');
        f.api.configure(f.config('font-new-session', {sessionID:'fresh-session',preserveViewport:true}));
        const promoReady = await f.ready('font-new-session');
        ok(promoReady.authorStyleFallback !== true, 'successful promotion has authorStyleFallback falsy');
        ok(style.textContent.includes('yjepub://s-fresh-session--e-font-new-session/OPS/font.ttf') && !style.textContent.includes('--e-fonts/'), 'promotion font URL uses new capability');
        results.push('controlled FontFace delay gates all variants and rebinds promotion capability');
        const mountedReleases = [];
        faces.forEach(face => {face.load=()=> f.d.querySelector('[data-yj-author-scope="scope1"]')
            ? new Promise(resolve=>mountedReleases.push(()=>resolve(face))) : Promise.resolve(face);});
        const appended = chapter(1, true);
        appended.url = 'yjepub://s-fresh-session--e-font-new-session/OPS/c1.xhtml';
        f.api.setScrollActive(true);
        ok(f.api.syncWindow({sessionID:'fresh-session',epoch:'font-new-session',chapters:[appended],keepPaths:['OPS/c0.xhtml','OPS/c1.xhtml']}), 'font append accepted');
        for (let i=0;i<120 && mountedReleases.length!==2;i++) await tick();
        ok(mountedReleases.length===2 && !f.api.sampleNow(), 'mounted font wait holds window readiness');
        const y = f.w.scrollY;
        f.w.scrollBy(0,57);
        const nativeY = f.w.scrollY, commands = [], originalScrollTo = f.w.scrollTo;
        f.w.scrollTo = function(...args) {commands.push(args);return originalScrollTo.apply(this,args);};
        mountedReleases.forEach(release=>release());
        for (let i=0;i<120 && !f.messages.some(p=>p.kind==='window');i++) await tick();
        await settle(); f.w.scrollTo = originalScrollTo;
        ok(f.messages.some(p=>p.kind==='window' && !p.error), 'font append completes');
        ok(nativeY===y+57 && f.w.scrollY===nativeY && commands.length===0, 'font commit must not undo natural scrolling or cancel momentum');
        f.api.setScrollActive(false);
        results.push('mounted font delay preserves natural scroll without compensating user movement');

        // Cancelled waiter (both resolving and rejecting late) must never emit ready or fallback!
        const releases = [], lateRejects = [];
        faces.forEach((face, idx) => {
            face.status='unloaded';
            face.load=()=>new Promise((resolve, reject)=>{
                if (idx === 0) releases.push(()=>{face.status='loaded';resolve(face);});
                else lateRejects.push(()=>{face.status='error';reject(new Error('late cancelled reject'));});
            });
        });
        f.api.configure(f.config('cancelled-font')); await settle();
        f.api.configure(f.config('cancel-reader', {layoutMode:'reader',css:readerCSS}));
        const cancelReaderReady = await f.ready('cancel-reader');
        ok(cancelReaderReady.authorStyleFallback !== true, 'reader mode after cancelled font has no fallback flag');
        releases.forEach(release=>release());
        lateRejects.forEach(rej=>rej());
        await settle();
        ok(!f.messages.some(p=>p.epoch==='cancelled-font' && (p.kind==='ready'||p.kind==='error')), 'cancelled font completion or late rejection has no stale callback');
        ok(f.d.querySelectorAll('head style[data-yj-author-style]').length === 0, 'cancelled waits leave no temporary styles');
        ok(style.textContent.includes('@font-face'), 'cancelled late rejection must not strip mounted @font-face');

        // Rejected FontFace decode in original mode -> single fallback transition, ready with authorStyleFallback=true, unchanged anchor, no error!
        f.api.configure(f.config('pre-fallback-pos', {layoutMode:'reader', css:readerCSS})); await f.ready('pre-fallback-pos');
        f.w.scrollTo(0, 600); await settle();
        const savedAnchor = f.api.sampleNow(), savedRect = f.rect(savedAnchor);
        const savedText = f.d.querySelector('[data-yj-original-id="yj-t0"], #yj-t0').textContent;
        let failLoads = 0;
        faces.forEach(face => {face.status='unloaded'; face.load=()=>{ failLoads++; face.status='error'; return Promise.reject(new Error('fixture font failure')); };});
        const fbMsgStart = f.messages.length;
        f.api.configure(f.config('font-fallback', {
            targetNode: savedAnchor.node, targetOffset: savedAnchor.utf16Offset,
            targetViewportOffset: savedRect.top, preserveTargetAnchor: true
        }));
        const fbReady = await f.ready('font-fallback');
        await settle();
        const fbEpochMsgs = f.messages.slice(fbMsgStart).filter(p => p.epoch === 'font-fallback');
        ok(fbEpochMsgs.filter(p => p.kind === 'ready').length === 1, 'multiple failing variants perform single fallback transition');
        ok(!fbEpochMsgs.some(p => p.kind === 'error'), 'decoded failure must fallback rather than emit font-not-ready error');
        ok(failLoads === 2, 'no endless retries on failing variants: loads=' + failLoads);
        ok(fbReady.authorStyleFallback === true, 'fallback ready exposes authorStyleFallback=true');
        ok(fbReady.restoredNode === savedAnchor.node && fbReady.restoredOffset === savedAnchor.utf16Offset, 'fallback ready preserves exact anchor');
        ok(Math.abs(f.rect(savedAnchor).top - savedRect.top) <= 2, 'fallback ready preserves exact viewport position');
        ok(f.d.querySelector('[data-yj-original-id="yj-t0"], #yj-t0').textContent === savedText, 'fallback preserves text');
        const fbSample = f.api.sampleNow();
        ok(fbSample && fbSample.authorStyleFallback === true, 'sampleNow exposes authorStyleFallback=true');
        ok(f.w.getComputedStyle(f.d.querySelector('p.same')).fontSize === '26px', 'non-font author typography remains active');
        ok(style.textContent.indexOf('@font-face') < 0 && style.__yjCSS.indexOf('@font-face') < 0, 'failed @font-face removed from style and __yjCSS');
        ok(Array.prototype.every.call(style.sheet.cssRules, r => r.type !== 5), 'failed @font-face removed from CSSOM');
        // Scroll event in fallback state exposes authorStyleFallback=true
        const scrollStart = f.messages.length;
        f.w.scrollBy(0, 40); await new Promise(r => setTimeout(r, 150)); await settle();
        ok(f.messages.slice(scrollStart).some(m => m.kind === 'scroll' && m.authorStyleFallback === true), 'scroll payload exposes authorStyleFallback=true');

        // Promotion / capability rebind after fallback must NOT resurrect failed @font-face!
        f.api.configure(f.config('fb-promoted', {sessionID:'rebind-sess', preserveViewport:true}));
        const fbPromoReady = await f.ready('fb-promoted');
        ok(fbPromoReady.authorStyleFallback === true, 'promotion preserves authorStyleFallback=true for degraded chapter');
        ok(style.textContent.indexOf('@font-face') < 0 && style.__yjCSS.indexOf('@font-face') < 0, 'promotion rebind does not resurrect failed @font-face');

        // original -> reader -> original: reader clears fallback flag, returning to degraded mounted style persists it without repeated font errors.
        f.api.configure(f.config('fb-to-reader', {sessionID:'rebind-sess', layoutMode:'reader', css:readerCSS}));
        const toReaderReady = await f.ready('fb-to-reader');
        ok(toReaderReady.authorStyleFallback !== true, 'reader mode does not leak authorStyleFallback=true');
        ok(f.api.sampleNow().authorStyleFallback !== true, 'reader sampleNow does not leak authorStyleFallback=true');
        f.api.configure(f.config('fb-back-orig', {sessionID:'rebind-sess', layoutMode:'original'}));
        const backOrigReady = await f.ready('fb-back-orig');
        ok(backOrigReady.authorStyleFallback === true, 'returning to original on degraded mounted style preserves authorStyleFallback=true without re-erroring');
        results.push('controlled font cancellation suppresses stale callbacks; rejected decode falls back once with anchor, scroll, and rebind persistence');
    } finally { f.frame.remove(); }

    // 3. Missing FontFace match, partial family fallback (keep good family, remove bad family), and preload+scroll fallback.
    f = await create(true);
    try {
        // Missing FontFace match (document.fonts has no entry for fixture-font)
        Object.defineProperty(f.d, 'fonts', {configurable:true, value:{forEach() {}, ready:Promise.resolve()}});
        f.api.configure(f.config('missing-match'));
        const missingReady = await f.ready('missing-match');
        ok(missingReady.authorStyleFallback === true, 'missing FontFace match triggers fallback and explicit notice');
        const style0 = f.d.querySelector('style[data-yj-author-style]');
        ok(!style0.textContent.includes('@font-face') && !style0.__yjCSS.includes('@font-face'), 'missing match removes unusable @font-face');

        // Unrelated chapter c1 with valid/no font does NOT inherit c0 fallback flag on promotion!
        const c1Clean = chapter(1, false);
        c1Clean.url = 'yjepub://s-author-session--e-missing-match/OPS/c1.xhtml';
        ok(f.api.syncWindow({sessionID:'author-session', epoch:'missing-match', chapters:[c1Clean], keepPaths:['OPS/c0.xhtml','OPS/c1.xhtml']}), 'clean c1 sync accepted');
        for (let i=0; i<120 && !f.messages.some(p=>p.kind==='window' && p.epoch==='missing-match'); i++) await tick();
        f.api.configure({...f.config('clean-c1-promo', {preserveViewport:true}), path:c1Clean.path, chapterIndex:1, expectedNodeCount:texts.length, expectedNodeLengths:texts.map(t=>t.length)});
        const cleanPromo = await f.ready('clean-c1-promo');
        ok(cleanPromo.authorStyleFallback !== true, 'promotion to clean chapter does not leak c0 fallback flag');

        // Preload chapter c2 with rejecting font under active scroll protection -> commits without interrupting scroll, and c2 keeps fallback state.
        const badFaces = [
            {family:'fixture-font', weight:'700', style:'italic', status:'unloaded', load() {
                return new Promise((_, reject) => setTimeout(() => { this.status = 'error'; reject(new Error('preload bad font')); }, 20));
            }}
        ];
        Object.defineProperty(f.d, 'fonts', {configurable:true, value:{forEach(fn) { badFaces.forEach(fn); }, ready:Promise.resolve()}});
        const c2Bad = chapter(2, true);
        c2Bad.url = 'yjepub://s-author-session--e-clean-c1-promo/OPS/c2.xhtml';
        f.api.setScrollActive(true);
        const winStart = f.messages.length;
        ok(f.api.syncWindow({sessionID:'author-session', epoch:'clean-c1-promo', chapters:[c2Bad], keepPaths:['OPS/c0.xhtml', c1Clean.path, c2Bad.path]}), 'bad-font preload accepted');
        const beforeScrollY = f.w.scrollY;
        f.w.scrollBy(0, 48);
        const userScrolledY = f.w.scrollY, scrollCmds = [], origScrollTo = f.w.scrollTo;
        f.w.scrollTo = function(...args) { scrollCmds.push(args); return origScrollTo.apply(this, args); };
        for (let i=0; i<120 && !f.messages.slice(winStart).some(p=>p.kind==='window'); i++) await tick();
        await settle(); f.w.scrollTo = origScrollTo;
        ok(f.messages.slice(winStart).some(p=>p.kind==='window' && !p.error), 'preload with bad author font completes via fallback');
        ok(userScrolledY === beforeScrollY + 48 && f.w.scrollY === userScrolledY && scrollCmds.length === 0, 'preload font fallback preserves natural scroll');
        f.api.setScrollActive(false);
        const c2Style = f.d.querySelector('[data-yj-chapter="OPS/c2.xhtml"] style[data-yj-author-style]');
        ok(!c2Style.textContent.includes('@font-face') && !c2Style.__yjCSS.includes('@font-face'), 'preloaded chapter strips failed @font-face before mount');
        f.api.configure({...f.config('c2-promo', {preserveViewport:true}), path:c2Bad.path, chapterIndex:2, expectedNodeCount:texts.length, expectedNodeLengths:texts.map(t=>t.length)});
        const c2PromoReady = await f.ready('c2-promo');
        ok(c2PromoReady.authorStyleFallback === true, 'promoted preloaded bad-font chapter exposes authorStyleFallback=true');
        results.push('missing FontFace fallback, clean-chapter isolation, and preload bad-font scroll protection verified');
    } finally { f.frame.remove(); }

    // 4. Partial family fallback: keep good @font-face rule + rebind its URL on promotion, remove only bad @font-face rule.
    {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:fixed;inset:0;width:520px;height:420px;border:0;z-index:99999';
        const loaded = new Promise(resolve => frame.onload = resolve);
        const css = '@font-face { font-family: "good-fam"; src: url("/OPS/good.ttf"); font-weight: 400; font-style: normal; }\n' +
            '@font-face { font-family: "bad-fam"; src: url("/OPS/bad.ttf"); font-weight: 700; font-style: italic; }\n' +
            'html[data-yj-layout="original"] [data-yj-author-scope="mix0"] p { font-family: "good-fam", "bad-fam", serif; font-size: 22px; }';
        const body = '<p><span id="yj-t0">mixed font fallback text</span></p>';
        frame.srcdoc = `<html><head><style data-yj-author-style="true">${css}</style></head><body data-yj-author-scope="mix0">${body}</body></html>`;
        document.body.appendChild(frame); await loaded;
        try {
            const w = frame.contentWindow, d = w.document, msgs = [];
            w.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { msgs.push(p); }}}};
            w.eval(source);
            let goodLoads = 0, badLoads = 0;
            const mixFaces = [
                {family:'good-fam', weight:'400', style:'normal', status:'unloaded', load() { goodLoads++; this.status='loaded'; return Promise.resolve(this); }},
                {family:'bad-fam', weight:'700', style:'italic', status:'unloaded', load() { badLoads++; this.status='error'; return Promise.reject(new Error('bad-fam decode error')); }}
            ];
            Object.defineProperty(d, 'fonts', {configurable:true, value:{forEach(fn) { mixFaces.forEach(fn); }, ready:Promise.resolve()}});
            const mixCfg = (epoch, extra = {}) => ({
                sessionID:'mix-sess', epoch, path:'OPS/mix.xhtml', chapterIndex:0,
                expectedNodeCount:1, expectedNodeLengths:['mixed font fallback text'.length], targetNode:-1, targetOffset:0,
                readingMode:'scroll', layoutMode:'original', css:authorCSS, ...extra
            });
            w.__yjEpub.configure(mixCfg('mix-1'));
            for (let i=0; i<120 && !msgs.some(m=>m.kind==='ready' && m.epoch==='mix-1'); i++) {
                const err = msgs.find(m => m.kind === 'error' && m.epoch === 'mix-1');
                if (err) throw new Error('mix-1 error: ' + JSON.stringify(err));
                await tick();
            }
            const mixReady = msgs.find(m => m.kind === 'ready' && m.epoch === 'mix-1');
            ok(mixReady && mixReady.authorStyleFallback === true, 'partial failure emits ready with authorStyleFallback=true');
            ok(goodLoads === 1 && badLoads === 1, 'each face loaded once in single transition');
            const mixStyle = d.querySelector('style[data-yj-author-style]');
            ok(mixStyle.__yjCSS.includes('/OPS/good.ttf') && !mixStyle.__yjCSS.includes('/OPS/bad.ttf'), 'only unusable @font-face removed from __yjCSS');
            ok(mixStyle.textContent.includes('/OPS/good.ttf') && !mixStyle.textContent.includes('/OPS/bad.ttf'), 'only unusable @font-face removed from style textContent');
            const fontRules = Array.prototype.filter.call(mixStyle.sheet.cssRules, r => r.type === 5);
            ok(fontRules.length === 1 && fontRules[0].style.getPropertyValue('font-family').includes('good-fam'), 'CSSOM retains only good-fam @font-face rule');
            w.__yjEpub.configure(mixCfg('mix-2', {sessionID:'mix-sess-2', preserveViewport:true}));
            for (let i=0; i<120 && !msgs.some(m=>m.kind==='ready' && m.epoch==='mix-2'); i++) await tick();
            const mixPromo = msgs.find(m => m.kind === 'ready' && m.epoch === 'mix-2');
            ok(mixPromo && mixPromo.authorStyleFallback === true, 'promotion after partial fallback preserves fallback notice');
            ok(mixStyle.textContent.includes('yjepub://s-mix-sess-2--e-mix-2/OPS/good.ttf') && !mixStyle.textContent.includes('/OPS/bad.ttf'),
                'promotion rebinds good-fam capability URL without resurrecting bad-fam');
            results.push('partial family fallback preserves good @font-face rules and capability rebind while keeping failed rule absent');
        } finally { frame.remove(); }
    }
    return results;
};
