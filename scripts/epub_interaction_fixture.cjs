'use strict';
// Production DOM/CSS, controlled FontFace transport; not a WKWebView/inertia test.
module.exports = async function interactionFixture(source, readerCSS, authorCSS) {
    const results = [], failures = [];
    const tick = () => new Promise(r => requestAnimationFrame(r));
    const check = (v, m) => { if (!v) throw new Error(m); };
    async function run(name, body) {
        try { await body(); results.push(name); } catch (e) { failures.push(name + ': ' + e.message); }
    }
    async function create(image, fonts, css = authorCSS) {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:fixed;inset:0;width:390px;height:600px;border:0;z-index:99999';
        const loaded = new Promise(r => frame.onload = r);
        const canvas = document.createElement('canvas'); canvas.width = 160; canvas.height = 280;
        canvas.getContext('2d').fillRect(0, 0, 160, 280);
        const text = 'original text '.repeat(45);
        frame.srcdoc = `<html><head>${fonts ? '<style data-yj-author-style="true">@font-face {font-family:"controlled";src:url("/OPS/font.ttf");} html[data-yj-layout="original"] [data-yj-author-scope] p {font-family:"controlled",serif;}</style>' : ''}</head><body data-yj-author-scope="test"><p><span id="yj-t0">${text}</span></p>${image ? `<img width="160" height="280" src="${canvas.toDataURL()}"/>` : ''}<p><span id="yj-t1">${text}</span></p></body></html>`;
        document.body.appendChild(frame); await loaded;
        const w = frame.contentWindow, d = w.document, messages = [];
        if (image) await d.images[0].decode();
        let loads = 0;
        const face = {family:'controlled', weight:'400', style:'normal', status:'unloaded',
            load() { loads++; this.status = 'loaded'; return Promise.resolve(this); }};
        if (fonts) Object.defineProperty(d, 'fonts', {configurable:true, value:{
            forEach(fn) { fn(face); }, ready:Promise.resolve()
        }});
        w.webkit = {messageHandlers:{yjepubLocator:{postMessage(p) { messages.push(p); }}}};
        w.eval(source);
        const config = (epoch, extra = {}) => ({sessionID:'interaction', epoch, path:'OPS/c0.xhtml', chapterIndex:0,
            expectedNodeCount:2, expectedNodeLengths:[text.length,text.length], targetNode:0,targetOffset:3,
            preserveTargetAnchor:true,layoutMode:css === readerCSS ? 'reader' : 'original',readingMode:'scroll',css,...extra});
        async function ready(epoch) {
            for (let i=0;i<120;i++) {
                const found = messages.find(p=>p.kind==='ready' && p.epoch===epoch && !p.restorationPending);
                if (found) return found;
                const error = messages.find(p=>p.kind==='error' && p.epoch===epoch);
                if (error) throw new Error(JSON.stringify(error));
                await tick();
            }
            throw new Error('ready timeout ' + epoch);
        }
        return {frame,w,d,messages,config,ready,api:w.__yjEpub,face,loads:()=>loads};
    }
    for (const image of [false,true]) {
        await run(`loaded author font retained across directory/promotion/reopen; image=${image}`, async () => {
            const f = await create(image,true);
            try {
                f.api.configure(f.config('initial')); await f.ready('initial');
                const style = f.d.querySelector('style[data-yj-author-style]'), originalCSS = style.textContent;
                const imageNode = f.d.images[0], node = f.d.getElementById('yj-t0');
                const mutations = [];
                const observer = new f.w.MutationObserver(records=>mutations.push(...records));
                observer.observe(style,{childList:true,characterData:true,subtree:true});
                for (const action of ['directory','promotion','reopen']) {
                    if (action==='reopen') f.api.parkForReopen();
                    const commands = [], oldScroll = f.w.scrollTo;
                    f.w.scrollTo = function(...args) { commands.push(args); return oldScroll.apply(this,args); };
                    f.api.configure(f.config(action,{preserveViewport:action==='promotion',sessionID:action==='reopen'?'fresh':'interaction'}));
                    const ready = await f.ready(action);
                    f.w.scrollTo = oldScroll;
                    check(ready.restoredOffset===3 || action==='promotion','original target retained');
                    if (action==='promotion') check(commands.length===0,'promotion issues no scroll command');
                }
                observer.disconnect();
                check(style.textContent===originalCSS && mutations.length===0,
                    `loaded font stylesheet was replaced ${mutations.length} times despite stable decoded resources`);
                check(node===f.d.getElementById('yj-t0') && (!image || imageNode===f.d.images[0]),'DOM/image identities retained');
                f.face.status = 'unloaded';
                f.api.configure(f.config('font-evicted', {sessionID:'fresh'})); await f.ready('font-evicted');
                check(style.textContent.includes('s-fresh--e-font-evicted/OPS/font.ttf'), 'unloaded font must bind the current capability again');
                // A changed author stylesheet must not inherit the old retention proof.
                style.__yjCSS += '\nhtml[data-yj-layout="original"] [data-yj-author-scope] p {font-weight:400;}';
                f.api.configure(f.config('style-changed', {sessionID:'fresh'})); await f.ready('style-changed');
                check(style.textContent.includes('s-fresh--e-style-changed/OPS/font.ttf'), 'changed CSS invalidates loaded-font reuse');
            } finally { f.frame.remove(); }
        });
        for (const css of [readerCSS,authorCSS]) await run(`single reader gutter; mode=${css===readerCSS?'reader':'original'} image=${image}`, async () => {
            const f = await create(image,false,css);
            try {
                f.api.configure(f.config('gutter')); await f.ready('gutter');
                const rect = f.d.querySelector('section').getBoundingClientRect();
                check(Math.abs(rect.left-20)<=1 && Math.abs(f.d.documentElement.clientWidth-rect.right-20)<=1,
                    `reader-generated gutters were ${rect.left}/${390-rect.right}px, expected 20/20`);
            } finally { f.frame.remove(); }
        });
    }
    if (failures.length) throw new Error(`${results.length} passed; ${failures.length} failed\n` + failures.join('\n'));
    return results;
};
