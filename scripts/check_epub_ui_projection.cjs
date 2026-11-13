'use strict';
// Synthetic Astra design projection only, NEVER native SwiftUI acceptance.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),{spawn}=require('node:child_process');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const root=path.resolve(__dirname,'..'),out=path.join(root,'artifacts/reader-interaction-ui-next');
(async()=>{
 const html=fs.readFileSync(path.join(out,'astra-ui-preview.html'),'utf8');
 const browser=['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe','C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'].find(fs.existsSync);
 if(!browser||!process.env.PI_SCRATCH_DIR)throw Error('Existing browser and scratch required');
 const profile=fs.mkdtempSync(path.join(process.env.PI_SCRATCH_DIR,'astra-ui-'));
 const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html;charset=utf-8'});res.end(html);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const url=`http://127.0.0.1:${server.address().port}/`;
 const child=spawn(browser,['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--remote-debugging-port=0',`--user-data-dir=${profile}`,url],{stdio:'ignore'});
 let ws;const evidence={kind:'ASTRA_DESIGN_PROJECTION_NOT_NATIVE',checks:[],screenshots:[]};
 try{
  const portFile=path.join(profile,'DevToolsActivePort');for(let i=0;i<100&&!fs.existsSync(portFile);i++)await sleep(100);
  const port=fs.readFileSync(portFile,'utf8').split('\n')[0],targets=await(await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws=new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});
  let id=0;const pending=new Map();ws.onmessage=e=>{const m=JSON.parse(e.data);if(pending.has(m.id)){const [r,j]=pending.get(m.id);pending.delete(m.id);m.error?j(Error(JSON.stringify(m.error))):r(m.result);}};
  const send=(method,params={})=>new Promise((r,j)=>{const n=++id;pending.set(n,[r,j]);ws.send(JSON.stringify({id:n,method,params}));});
  const evaluate=async expression=>{const v=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,timeout:15000});if(v.exceptionDetails)throw Error(v.exceptionDetails.exception?.description||JSON.stringify(v.exceptionDetails));return v.result.value;};
  let ready=false;for(let i=0;i<50;i++){try{ready=await evaluate(`location.href===${JSON.stringify(url)} && document.readyState==='complete'`);}catch{}if(ready)break;await sleep(100);}if(!ready)throw Error('Initial page not ready');
  await send('Emulation.setDeviceMetricsOverride',{width:1600,height:1200,deviceScaleFactor:1,mobile:false});
  const results=await evaluate(`(async()=>{
   const checks=[],q=(i,s)=>document.querySelector('[data-specimen="'+i+'"] '+s);
   const check=(v,m)=>{checks.push({name:m,passed:!!v});};
   for(let i=0;i<4;i++){
    states[i].spacing=13;renderAll();q(i,'[data-focus="preset2"]').click();
    check(states[i].font===24&&states[i].spacing===13,'preset preserves reader spacing '+i);
    let range=q(i,'[data-focus="font"]');range.value=36;range.dispatchEvent(new Event('input',{bubbles:true}));
    check(states[i].draft===36&&states[i].font===24,'drag is preview only '+i);range.dispatchEvent(new Event('change',{bubbles:true}));
    check(states[i].font===36&&q(i,'[data-focus="plus"]').disabled,'upper boundary 180% '+i);
    range=q(i,'[data-focus="font"]');range.value=14;range.dispatchEvent(new Event('input',{bubbles:true}));range.dispatchEvent(new Event('change',{bubbles:true}));
    check(states[i].font===14&&q(i,'[data-focus="minus"]').disabled,'lower boundary 70% '+i);
    q(i,'[data-focus="restore"]').click();check(q(i,'dialog').open,'restore confirmation opens '+i);
    q(i,'dialog button:last-child').click();check(states[i].font===14,'cancel retains ratio '+i);
    q(i,'[data-focus="restore"]').click();q(i,'dialog button').click();
    check(states[i].font===20&&states[i].spacing===13&&q(i,'[data-focus="restore"]').disabled,'restore only changes author ratio '+i);
   }
   document.getElementById('inactive').checked=true;document.getElementById('inactive').dispatchEvent(new Event('change'));
   check([...document.querySelectorAll('.device button,.device input')].every(e=>e.disabled),'inactive disables controls');
   document.getElementById('inactive').checked=false;document.getElementById('inactive').dispatchEvent(new Event('change'));
   document.querySelector('[data-scene="directory"]').click();
   for(let i=0;i<4;i++){
    const before=states[i].current,input=q(i,'.search input');input.value='不存在';input.dispatchEvent(new Event('input',{bubbles:true}));
    check(!!q(i,'.empty')&&q(i,'.locate').textContent.includes('清空筛选'),'empty search and long locate label '+i);
    q(i,'.locate').click();check(states[i].query===''&&states[i].current===before&&!states[i].closed&&!!q(i,'[aria-current="true"]'),'locate scrolls directory without navigating '+i);
   }
   document.getElementById('missing').checked=true;document.getElementById('missing').dispatchEvent(new Event('change'));
   check([...document.querySelectorAll('.locate')].every(e=>e.disabled),'missing current disables locate');
   document.getElementById('empty').checked=true;document.getElementById('empty').dispatchEvent(new Event('change'));
   check(document.querySelectorAll('.empty').length===4,'empty directory state');
   document.getElementById('reset').click();document.querySelector('[data-scene="notice"]').click();
   for(let i=0;i<4;i++){
    const before=q(i,'.demo-text').getBoundingClientRect().top;
    q(i,'.notice button').click();check(!q(i,'.notice')&&q(i,'.demo-text').getBoundingClientRect().top===before,'notice dismiss does not shift text '+i);
   }
   document.getElementById('reset').click();return checks;
  })()`);evidence.checks.push(...results);
  for(const scene of ['settings','directory','notice']){
   await evaluate(`document.querySelector('[data-scene="${scene}"]').click();`);
   const checks=await evaluate(`(()=>{
    const checks=[];for(const d of document.querySelectorAll('.device')){
      const i=d.dataset.specimen,r=d.getBoundingClientRect();
      checks.push({name:'${scene}: no horizontal overflow '+i,passed:d.scrollWidth<=d.clientWidth+1});
      const buttons=[...d.querySelectorAll('button,input[type=range]')].filter(e=>e.getClientRects().length&&!e.closest('dialog:not([open])'));
      checks.push({name:'${scene}: 44px touch targets '+i,passed:buttons.every(e=>{const b=e.getBoundingClientRect();return b.width>=43.5&&b.height>=43.5;})});
      checks.push({name:'${scene}: controls contained '+i,passed:buttons.every(e=>{const b=e.getBoundingClientRect();return b.left>=r.left-1&&b.right<=r.right+1;})});
    }return checks;
   })()`);evidence.checks.push(...checks);
   await sleep(150); // Let the projection's 100ms hover/scene transition settle, not a product delay.
   const image=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});const file='astra-'+scene+'.png';fs.writeFileSync(path.join(out,file),Buffer.from(image.data,'base64'));evidence.screenshots.push(file);
   if(scene==='settings'){
    await evaluate("document.querySelectorAll('.panel-body').forEach(e=>e.scrollTop=e.scrollHeight)");
    const bottom=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});
    fs.writeFileSync(path.join(out,'astra-settings-bottom.png'),Buffer.from(bottom.data,'base64'));evidence.screenshots.push('astra-settings-bottom.png');
   }
  }
  await evaluate("document.querySelector('[data-scene=\"settings\"]').click();document.activeElement.blur();");
  await send('Input.dispatchKeyEvent',{type:'keyDown',key:'Tab',code:'Tab',windowsVirtualKeyCode:9});await send('Input.dispatchKeyEvent',{type:'keyUp',key:'Tab',code:'Tab',windowsVirtualKeyCode:9});
  evidence.checks.push({name:'keyboard focus has visible outline',passed:await evaluate("document.activeElement.tagName==='BUTTON' && getComputedStyle(document.activeElement).outlineStyle!=='none'")});
  await send('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  evidence.checks.push({name:'reduced motion removes button transition',passed:await evaluate("getComputedStyle(document.querySelector('button')).transitionDuration==='0s'")});
  evidence.passed=evidence.checks.every(c=>c.passed);fs.writeFileSync(path.join(out,'ASTRA-ui-browser-checks.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence,null,2));if(!evidence.passed)process.exitCode=1;
 }finally{if(ws)ws.close();child.kill();await new Promise(r=>server.close(r));await sleep(500);try{fs.rmSync(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}catch{console.log('scratch profile retained '+profile);}}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
