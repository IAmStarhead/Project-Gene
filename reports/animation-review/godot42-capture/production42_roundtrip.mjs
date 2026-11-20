import {chromium} from '../../prototype/animation_preview/node_modules/playwright-core/index.mjs';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const root='.local/review/repair-42', out=root+'/production-roundtrip';await mkdir(out,{recursive:true});
const pack=await readFile('.local/godot-visual/public/production42.pck');
const expected=createHash('sha256').update(pack).digest('hex');
const served=await(await fetch('http://127.0.0.1:5175/production42.pck')).arrayBuffer();
assert.equal(createHash('sha256').update(Buffer.from(served)).digest('hex'),expected);
const browser=await chromium.launch({executablePath:'/tmp/chromium',headless:true,args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-zygote']});
const logs=[],geometry=[];
try{
 const page=await browser.newPage({viewport:{width:800,height:450}});page.setDefaultTimeout(120000);
 page.on('console',m=>logs.push(m.text()));page.on('pageerror',e=>logs.push('PAGEERROR '+e.stack));
 await page.goto('http://127.0.0.1:5175/?pack=production42.pck',{waitUntil:'networkidle',timeout:120000});
 await page.waitForFunction(()=>window.godotReady);
 async function frames(n=6){await page.evaluate(n=>new Promise(resolve=>{function tick(){if(--n<=0)resolve();else requestAnimationFrame(tick)}requestAnimationFrame(tick)}),n)}
 async function shot(name){
  await frames();const size=await page.evaluate(()=>{const c=document.querySelector('canvas');return {browser:[innerWidth,innerHeight],canvas:[c.width,c.height]}});
  assert.deepEqual(size.browser,size.canvas);geometry.push({name,...size});await page.screenshot({path:out+'/'+name+'.png'});
 }
 await shot('main');await page.locator('canvas').focus();
 await page.keyboard.press('Tab');await page.keyboard.press('F3');await shot('lock-debug');
 await page.keyboard.press('h');await frames();await page.keyboard.press('Space');await shot('showcase');
 await page.keyboard.press('g');await page.keyboard.press('b');await page.keyboard.press('F4');await page.keyboard.press('F4');await shot('showcase-toon-low');
 await page.keyboard.press('h');await shot('return-toon-low');
 await page.keyboard.press('g');await page.keyboard.press('h');await frames();await page.keyboard.press('g');
 await page.setViewportSize({width:1280,height:720});await shot('second-showcase-1280');
 await page.keyboard.press('h');await shot('second-return-1280');
 const errors=logs.filter(s=>/^SCRIPT ERROR:|^ERROR:|PAGEERROR/.test(s));
 await writeFile(root+'/production-roundtrip.json',JSON.stringify({pack_sha256:expected,geometry,errors,logs},null,2)+'\n');
 assert.deepEqual(errors,[]);console.log('Production roundtrip PASS: 7 screenshots; 2 H round trips; PBR/toon cache, B/F4, Tab/F3, 800/1280 canvas; no engine/page errors.');
}finally{await browser.close()}
console.log('Browser closed cleanly.');
