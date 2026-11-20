// Real Godot frame_post_draw captures, command-driven isolated diagnostic pack.
import{chromium}from'../../animation_preview/node_modules/playwright-core/index.mjs';
import{readFile,writeFile,mkdir}from'node:fs/promises';
import assert from'node:assert/strict';
import {createHash} from 'node:crypto';
const config=JSON.parse(await readFile(process.argv[2],'utf8'));
const out=config.out;await mkdir(out,{recursive:true});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE||'/tmp/chromium',headless:true,args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-zygote']});
const logs=[],frames=[];
try{
 const page=await browser.newPage({viewport:{width:1000,height:700}});page.setDefaultTimeout(90000);
 page.on('console',m=>{logs.push(m.text());if(!m.text().startsWith('REVIEW_FRAME:'))console.log(m.text())});
 page.on('pageerror',e=>logs.push('PAGEERROR '+e.stack));
 const ready=page.waitForEvent('console',{predicate:m=>m.text()==='REVIEW_READY',timeout:120000});
 await page.goto((process.env.REVIEW_URL||'http://127.0.0.1:5175')+'/?pack='+config.pack,{waitUntil:'networkidle',timeout:120000});await ready;
 let id=0;
 for(const shot of config.shots){
  const command={...shot,id:++id};delete command.file;
  const done=page.waitForEvent('console',{predicate:m=>m.text()==='REVIEW_DONE:'+id,timeout:90000});
  await page.evaluate(cmd=>window.mod.copyToFS('/cmd'+cmd.id+'.json',new TextEncoder().encode(JSON.stringify(cmd))),command);await done;
  const frame=JSON.parse(logs.filter(s=>s.startsWith('REVIEW_FRAME:')).at(-1).slice(13));
  assert.deepEqual(frame.command,command);assert.equal(frame.id,id);
  for(const[key,value]of Object.entries(config.expected||{}))assert.equal(frame[key],value,'Stale pack '+key);
  const file=out+'/'+(shot.file||String(id).padStart(3,'0'))+'.png';
  await page.screenshot({path:file});frames.push({file,sha256:createHash('sha256').update(await readFile(file)).digest('hex'),...frame});console.log(file);
 }
 const errors=logs.filter(s=>/^SCRIPT ERROR:|^ERROR:|PAGEERROR/.test(s));
 await writeFile(out+'/manifest.json',JSON.stringify({config,frames,errors,logs},null,2)+'\n');assert.deepEqual(errors,[]);
 console.log('Verified',frames.length,'native rendered frames');
}finally{await browser.close()}
