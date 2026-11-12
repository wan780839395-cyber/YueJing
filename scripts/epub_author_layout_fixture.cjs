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
        finish(); await f.ready('fonts');
        f.api.configure(f.config('font-new-session', {sessionID:'fresh-session',preserveViewport:true})); await f.ready('font-new-session');
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
        const releases = [];
        faces.forEach(face => {face.status='unloaded';face.load=()=>new Promise(resolve=>{releases.push(()=>{face.status='loaded';resolve(face);});});});
        f.api.configure(f.config('cancelled-font')); await settle();
        f.api.configure(f.config('cancel-reader', {layoutMode:'reader',css:readerCSS})); await f.ready('cancel-reader');
        releases.forEach(release=>release()); await settle();
        ok(!f.messages.some(p=>p.epoch==='cancelled-font' && (p.kind==='ready'||p.kind==='error')), 'cancelled font completion has no stale callback');
        ok(f.d.querySelectorAll('head style[data-yj-author-style]').length === 0, 'cancelled waits leave no temporary styles');
        faces.forEach(face => {face.load=()=>Promise.reject(new Error('fixture font failure'));});
        f.api.configure(f.config('font-error')); await settle();
        ok(f.messages.some(p=>p.kind==='error' && p.epoch==='font-error' && p.reason==='font-not-ready') && !f.api.sampleNow(), 'font failure cannot reveal ready');
        results.push('controlled font cancellation suppresses stale callbacks; failure cannot become ready');
    } finally { f.frame.remove(); }
    return results;
};
