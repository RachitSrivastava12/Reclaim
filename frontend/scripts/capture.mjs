import fs from 'node:fs';
import { spawn } from 'node:child_process';
const chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const out=process.env.RECLAIM_SCREENSHOT_DIR||'/private/tmp/reclaim-final-screenshots';
fs.mkdirSync(out,{recursive:true});
const port=9300+(process.pid%500);
const browser=spawn(chrome,['--headless=new','--no-sandbox','--disable-gpu',`--remote-debugging-port=${port}`,`--user-data-dir=/private/tmp/reclaim-cdp-final-${process.pid}`,'about:blank'],{stdio:'ignore'});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let target;
for(let i=0;i<80;i++){try{const response=await fetch(`http://127.0.0.1:${port}/json`);target=(await response.json()).find(page=>page.type==='page');if(target)break;}catch{}await wait(250);}
if(!target)throw new Error('Chrome CDP unavailable');
const ws=new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
let id=0;const pending=new Map();const errors=[];
ws.onmessage=event=>{const message=JSON.parse(event.data);if(message.id&&pending.has(message.id)){const {resolve,reject}=pending.get(message.id);pending.delete(message.id);if(message.error)reject(new Error(message.error.message));else resolve(message.result);}else if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.text);else if(message.method==='Log.entryAdded'&&message.params.entry.level==='error')errors.push(message.params.entry.text);};
const send=(method,params={})=>new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));});
const evaluate=async expression=>(await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true})).result.value;
await send('Page.enable');await send('Runtime.enable');await send('Log.enable');await send('Network.enable');
const targets=[['landing','/',''],['dashboard','/app','Recovery, verified.'],['cancellation','/app?view=executions&case=cancellation','Cancellation recovery'],['maturity','/app?view=executions&case=maturity','Maturity recovery'],['streams','/app?view=streams','Stream #214'],['policies','/app?view=policies','Stream #214'],['status','/app?view=status','Network and contract state']];
for(const width of [1440,1280,768,390]){for(const [name,url,ready] of targets){await send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:width<600});await send('Page.navigate',{url:`http://127.0.0.1:3000${url}`});let resolved=false;for(let i=0;i<70;i++){await wait(250);const state=await evaluate(`JSON.stringify({text:document.body?.innerText||'',width:document.documentElement.scrollWidth,inner:innerWidth,live:!!document.querySelector('.read-time'),error:!!document.querySelector('[role=alert]')})`);const value=JSON.parse(state||'{}');if(value.text?.includes(ready)&&(!['streams','policies','status'].includes(name)||value.live||value.error)){resolved=true;break;}}await wait(250);const metrics=JSON.parse(await evaluate('JSON.stringify({inner:innerWidth,scroll:document.documentElement.scrollWidth,heading:document.querySelector("h1")?.textContent||"",live:!!document.querySelector(".read-time"),alert:document.querySelector("[role=alert]")?.textContent||""})'));const png=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(`${out}/${name}-${width}.png`,Buffer.from(png.data,'base64'));process.stdout.write(`${name}-${width} ready=${resolved} overflow=${metrics.scroll>metrics.inner} live=${metrics.live} alert=${metrics.alert.slice(0,60)}\n`);}}
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});
await send('Page.navigate',{url:'http://127.0.0.1:3000/app?view=executions&case=cancellation'});await wait(1000);
await evaluate('document.querySelectorAll(".explorer-switch button")[1].click()');await wait(300);
const interaction=await evaluate('document.querySelector(".step-evidence details summary").click();JSON.stringify({case:document.querySelector(".execution-head h2")?.textContent,details:document.querySelector(".step-evidence details")?.open,url:location.search,receiptLinks:[...document.querySelectorAll(".execution-step a[href]")].every(a=>a.href.includes("/tx/0x"))})');
process.stdout.write(`interaction ${interaction}\n`);
const interactionResult=JSON.parse(interaction);if(interactionResult.case!=='Maturity recovery'||!interactionResult.details||!interactionResult.receiptLinks)throw new Error('Execution explorer interaction failed');
await send('Page.navigate',{url:'http://127.0.0.1:3000/app?view=policies'});await wait(1600);
const policyControls=await evaluate('JSON.stringify({futureDisabled:[...document.querySelectorAll(".future-actions button")].every(b=>b.disabled),withdrawEnabled:!document.querySelector(".action-row .button.primary")?.disabled,retirementExplained:document.body.innerText.includes("permanently retired")})');
process.stdout.write(`policy-controls ${policyControls}\n`);
const policyResult=JSON.parse(policyControls);if(!policyResult.futureDisabled||!policyResult.withdrawEnabled||!policyResult.retirementExplained)throw new Error('Retired policy controls are incorrect');
await send('Network.setBlockedURLs',{urls:['*127.0.0.1:3000/api/status*','*127.0.0.1:3000/api/stream/*']});
for(const [name,url] of [['status','/app?view=status'],['stream','/app?view=streams']]){await send('Page.navigate',{url:`http://127.0.0.1:3000${url}`});await wait(2500);const failure=await evaluate(`JSON.stringify({heading:document.querySelector("h1")?.textContent||"",alert:document.querySelector("[role=alert]")?.textContent||"",historical:document.body.innerText.includes("Demonstration completed"),evidenceLink:[...document.querySelectorAll("a[href]")].some(a=>a.getAttribute("href")==="/app?view=executions")})`);const png=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(`${out}/rpc-unavailable-${name}-1440.png`,Buffer.from(png.data,'base64'));process.stdout.write(`rpc-failure-${name} ${failure}\n`);const result=JSON.parse(failure);if(!result.alert||!result.evidenceLink)throw new Error(`RPC failure state missing for ${name}`);}
process.stdout.write(`browser-errors ${JSON.stringify(errors)}\n`);ws.close();browser.kill();
