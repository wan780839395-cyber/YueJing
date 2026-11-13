'use strict';
// Real layout using production JS; no Swift/WKWebView or native touch claim.
module.exports = async function authorScaleFixture(source, readerCSS, authorCSS, pagedCSS) {
    const results = [], failures = [];
    const tick = () => new Promise(resolve => requestAnimationFrame(resolve));
    const ok = (value, message) => { if (!value) throw new Error(message); };
    const near = (a,b,label,tolerance=0.12) => ok(Math.abs(a-b)<=tolerance,`${label}: ${a} != ${b}`);
    async function test(name, body) {
        try { await body(); results.push(name); } catch(e) { failures.push(name + ': ' + e.message); }
    }
    const text = 'Author typography keeps its own font and structure. '.repeat(12);
    function chapter(i) {
        const scope = `html[data-yj-layout="original"] [data-yj-author-scope="scale${i}"]`;
        const css = `${scope} {font-family:serif;font-size:18px;line-height:1.6;}
${scope} h2 {font-size:2em;line-height:1.25;font-weight:700;}
${scope} .absolute {font-size:24px;line-height:36px;text-indent:32px;margin:12px 7px;}
${scope} .relative {font-size:125%;line-height:1.7;text-indent:2em;}
${scope} .nested {font-size:0.8em;line-height:normal;font-style:italic;}
${scope} .points {font-size:15pt;line-height:180%;}
${scope} .rem {font-size:1.1rem;line-height:normal;}
${scope} img {width:160px;height:120px;margin:8px 0;}`;
        const body = `<h2><span id="yj-t0">Author heading</span></h2>` +
            `<p class="absolute"><span id="yj-t1">${text}</span></p>` +
            `<p class="relative"><span class="nested" id="yj-t2">${text}</span></p>` +
            `<p class="points"><span id="yj-t3">${text}</span></p>` +
            `<p class="rem" style="font-size:23px !important;line-height:normal;color:rgb(30,40,50)"><span id="yj-t4">${text}</span></p>` +
            `<img width="160" height="120" alt="original illustration"/>` +
            `<p><span id="yj-t5">${text.repeat(4)}</span></p>`;
        return {path:`OPS/scale${i}.xhtml`,index:i,css,body,lengths:[14,text.length,text.length,text.length,text.length,text.length*4],
            xhtml:`<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Scale</title><style data-yj-author-style="true">${css}</style></head><body data-yj-author-scope="scale${i}">${body.replace(/<img[^>]+\/>/,'').replace(/ style="[^"]*"/g,'')}</body></html>`};
    }
    async function create(mode='scroll') {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:fixed;inset:0;width:390px;height:600px;border:0;z-index:99999';
        const c = chapter(0), loaded = new Promise(resolve=>frame.onload=resolve);
        const canvas=document.createElement('canvas'); canvas.width=160;canvas.height=120;canvas.getContext('2d').fillRect(0,0,160,120);
        frame.srcdoc = `<html><head><style data-yj-author-style="true">${c.css}</style></head><body data-yj-author-scope="scale0">${c.body.replace('<img width=',`<img src="${canvas.toDataURL()}" width=`)}</body></html>`;
        document.body.appendChild(frame); await loaded;
        const w=frame.contentWindow,d=w.document,messages=[];
        await d.images[0].decode();
        w.webkit={messageHandlers:{yjepubLocator:{postMessage(p){messages.push(p);}}}};
        w.eval(source); const api=w.__yjEpub;
        const config=(epoch,scale=1,extra={})=>({sessionID:'scale-session',epoch,path:c.path,chapterIndex:0,
            expectedNodeCount:6,expectedNodeLengths:c.lengths,targetNode:1,targetOffset:11,targetViewportOffset:42,
            preserveTargetAnchor:true,layoutMode:'original',readingMode:mode,authorTextScale:scale,
            css:authorCSS+(mode==='paged'?pagedCSS:''),...extra});
        async function ready(epoch) {
            for(let i=0;i<120;i++) {
                const p=messages.find(p=>p.epoch===epoch&&p.kind==='ready'&&!p.restorationPending);
                if(p)return p;
                const e=messages.find(p=>p.epoch===epoch&&p.kind==='error');if(e)throw new Error(JSON.stringify(e));
                await tick();
            }
            throw new Error('readiness timeout '+epoch);
        }
        async function configure(epoch,scale=1,extra={}) {api.configure(config(epoch,scale,extra));return ready(epoch);}
        const selectors=['section','h2','.absolute','.relative','.nested','.points','.rem'];
        const styles=()=>selectors.map(selector=>{
            const e=d.querySelector(selector),s=w.getComputedStyle(e);
            return {e,size:parseFloat(s.fontSize),line:s.lineHeight,family:s.fontFamily,weight:s.fontWeight,
                italic:s.fontStyle,indent:s.textIndent,align:s.textAlign,margin:s.marginLeft};
        });
        function rect() {const t=d.getElementById('yj-t1').firstChild,r=d.createRange();r.setStart(t,11);r.setEnd(t,12);return r.getBoundingClientRect();}
        return {frame,w,d,messages,api,config,configure,ready,styles,rect,mode};
    }
    function checkScaled(before,after,scale) {
        before.forEach((b,i)=>{
            const a=after[i]; near(a.size,b.size*scale,'size '+i);
            if(b.line==='normal')ok(a.line==='normal','normal line-height retained');
            else near(parseFloat(a.line),parseFloat(b.line)*scale,'line-height '+i);
            for(const key of ['family','weight','italic','align'])ok(a[key]===b[key],`${key} retained ${i}`);
        });
    }
    for(const mode of ['scroll','paged']) await test(`${mode}: absolute/relative/pt/inline typography scales without compounding and restores`,async()=>{
        const f=await create(mode);
        try {
            await f.configure('base'); const before=f.styles(),node=f.d.getElementById('yj-t1').firstChild;
            const css=f.d.querySelector('style[data-yj-author-style]').textContent;
            const image=f.d.images[0],imageBefore=image.getBoundingClientRect();
            const inlineStyle=f.d.querySelector('.rem').style;
            const inline=JSON.stringify(['font-size','line-height','color'].map(p=>[inlineStyle.getPropertyValue(p),inlineStyle.getPropertyPriority(p)]));
            for(const scale of [1.4,1.8,0.7,1.4,1]) {
                const epoch='scale-'+scale+'-'+f.messages.length;
                const p=await f.configure(epoch,scale);
                checkScaled(before,f.styles(),scale);
                ok(p.restoredNode===1&&p.restoredOffset===11,'original node/offset preserved');
                if(mode==='scroll')near(f.rect().top,42,'viewport anchor',1);
                else ok(f.rect().right>0&&f.rect().left<f.w.innerWidth,'paged target character remains visible');
                near(image.getBoundingClientRect().width,imageBefore.width,'image width');
                near(image.getBoundingClientRect().height,imageBefore.height,'image height');
                near(parseFloat(f.w.getComputedStyle(f.d.querySelector('.absolute')).textIndent),32,'absolute indent');
                near(parseFloat(f.w.getComputedStyle(f.d.querySelector('.relative')).textIndent),45*scale,'relative indent');
                near(parseFloat(f.w.getComputedStyle(f.d.querySelector('.absolute')).marginLeft),7,'author margin');
                ok(node===f.d.getElementById('yj-t1').firstChild,'text node identity');
                ok(css===f.d.querySelector('style[data-yj-author-style]').textContent,'author CSS unmodified');
            }
            ok(JSON.stringify(['font-size','line-height','color'].map(p=>[inlineStyle.getPropertyValue(p),inlineStyle.getPropertyPriority(p)]))===inline,'100% restores author inline property values/priorities');
            // CSSOM may materialize an empty style attribute; declarations, not serialization, govern layout.
            ok(f.d.querySelector('.absolute').style.length===0,'100% removes every generated inline declaration');
        }finally{f.frame.remove();}
    });
    await test('scaled warm/cold reopen, mode roundtrip, appended chapter and natural promotion',async()=>{
        const f=await create();
        try {
            await f.configure('base');const before=f.styles();
            await f.configure('large',1.4);
            const node=f.d.getElementById('yj-t1').firstChild;
            f.api.parkForReopen();await f.configure('warm',1.4,{sessionID:'warm-session'});
            checkScaled(before,f.styles(),1.4);near(f.rect().top,42,'warm exact anchor',1);
            ok(node===f.d.getElementById('yj-t1').firstChild,'warm DOM reused');
            const cold=await create();try{
                await cold.configure('cold',1.4);checkScaled(before,cold.styles(),1.4);near(cold.rect().top,f.rect().top,'cold/warm anchor',1);
            }finally{cold.frame.remove();}
            await f.configure('reader',1.4,{layoutMode:'reader',css:readerCSS});
            near(parseFloat(f.w.getComputedStyle(f.d.querySelector('.absolute')).fontSize),20,'reader mode removes author overrides');
            await f.configure('original',1.4);checkScaled(before,f.styles(),1.4);
            const c=chapter(1);c.url='yjepub://s-scale-session--e-original/OPS/scale1.xhtml';
            const start=f.messages.length;
            ok(f.api.syncWindow({sessionID:'scale-session',epoch:'original',chapters:[c],keepPaths:['OPS/scale0.xhtml',c.path]}),'append accepted');
            for(let n=0;n<120&&!f.messages.slice(start).some(p=>p.kind==='window');n++)await tick();
            ok(f.messages.slice(start).some(p=>p.kind==='window'&&!p.error),'append succeeded');
            const keptAnchor=f.api.sampleNow();
            ok(keptAnchor.node===1&&keptAnchor.utf16Offset===11,'background append preserves restored UTF16 anchor');
            const next=f.d.querySelector('[data-yj-chapter="OPS/scale1.xhtml"] .absolute');
            near(parseFloat(f.w.getComputedStyle(next).fontSize),24*1.4,'new chapter same scale');
            const commands=[],scroll=f.w.scrollTo;
            f.w.scrollTo=function(...args){commands.push(args);return scroll.apply(this,args);};
            await f.configure('promotion',1.4,{path:c.path,chapterIndex:1,expectedNodeLengths:c.lengths,preserveViewport:true});
            f.w.scrollTo=scroll;ok(commands.length===0,'promotion never scrolls/reapplies scale');
            near(parseFloat(f.w.getComputedStyle(next).fontSize),24*1.4,'promotion keeps scale');
        }finally{f.frame.remove();}
    });
    await test('scale input bounds and omitted scale compatibility',async()=>{
        const f=await create();try{
            await f.configure('base');const before=f.styles();
            for(const [value,wanted] of [[100,1.8],[-10,0.7],[NaN,1],[undefined,1]]){
                await f.configure('bound-'+f.messages.length,value);checkScaled(before,f.styles(),wanted);
            }
        }finally{f.frame.remove();}
    });
    await test('delayed native scroll cannot publish ready at the old fragment',async()=>{
        const f=await create();try{
            await f.configure('initial');
            const scroll=f.w.scrollTo;let delivered=false;
            f.w.scrollTo=function(...args){let frames=8;function deliver(){if(--frames>0)f.w.requestAnimationFrame(deliver);else{scroll.apply(f.w,args);delivered=true;}}f.w.requestAnimationFrame(deliver);};
            const ready=await f.configure('delayed-fragment',1,{targetNode:-1,targetOffset:0,preserveTargetAnchor:false,fragment:'yj-t3'});
            ok(delivered&&ready.node>=3,'ready must acknowledge the actually reached fragment, not old pixels');
            f.w.scrollTo=scroll;
        }finally{f.frame.remove();}
    });
    await test('fractional restore rounding cannot accumulate across settings; real user movement stays real',async()=>{
        const f=await create();try{
            const scroll=f.w.scrollTo;f.w.scrollTo=function(x,y){return scroll.call(f.w,x,Math.floor(y));};
            const intended=42.375;
            await f.configure('fractional',1,{targetViewportOffset:intended});
            for(const scale of [1.4,1.8,0.7,1,1.4,1.8,0.7,1]){
                const saved=f.api.sampleNow();
                await f.configure('fractional-'+f.messages.length,scale,{targetViewportOffset:saved.viewportOffset});
                near(f.rect().top,intended,'no accumulated physical drift',1);
            }
            f.w.scrollTo=scroll;f.w.scrollBy(0,80);for(let i=0;i<8;i++)await tick();
            const moved=f.api.sampleNow(),span=f.d.getElementById('yj-t'+moved.node),range=f.d.createRange();
            range.setStart(span.firstChild,moved.utf16Offset);range.setEnd(span.firstChild,moved.utf16Offset+1);
            near(moved.viewportOffset,range.getBoundingClientRect().top,'user motion reports actual geometry',0.1);
        }finally{f.frame.remove();}
    });
    if(failures.length)throw new Error(`${results.length} passed; ${failures.length} failed\n${failures.join('\n')}`);
    return results;
};
