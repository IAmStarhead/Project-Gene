// Native Godot WebGL frame_post_draw captures, NOT the Three.js viewer.
// Usage: node prototype/tests/rendered_review/capture.mjs config.json
import {chromium} from '../../animation_preview/node_modules/playwright-core/index.mjs';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const config=JSON.parse(await readFile(process.argv[2],'utf8'));
const expected=JSON.parse(await readFile(config.hashes,'utf8'));
const out=config.out, step=config.sample_ticks??6;
await mkdir(out,{recursive:true});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE||'/tmp/chromium',headless:true,
 args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-zygote']});
const logs=[],responses=[],frames=[],takes={};
let id=0,frameNumber=0,part='setup';
try{
 const page=await browser.newPage({viewport:config.viewport??{width:800,height:450}});
 page.setDefaultTimeout(120000);
 page.on('console',m=>{logs.push(m.text());if(/^(ERROR:|SCRIPT ERROR:|REPLAY_READY)/.test(m.text()))console.log(m.text());});
 page.on('pageerror',e=>logs.push('PAGEERROR '+e.stack));
 const ready=page.waitForEvent('console',{predicate:m=>m.text().includes('REPLAY_READY'),timeout:120000});
 await page.goto((process.env.REVIEW_URL||'http://127.0.0.1:5175')+'/?pack='+config.pack,{waitUntil:'networkidle',timeout:120000});
 await ready;
 async function command(data){
  const wanted=++id;
  const done=page.waitForEvent('console',{predicate:m=>m.text()==='REPLAY_DONE:'+wanted,timeout:120000});
  await page.evaluate(cmd=>window.mod.copyToFS('/replay'+cmd.id+'.json',new TextEncoder().encode(JSON.stringify(cmd))),{...data,id:wanted});
  await done;
  const record=logs.filter(s=>s.startsWith('REPLAY_DATA:')).at(-1);
  const result=JSON.parse(record.slice('REPLAY_DATA:'.length));assert.equal(result.id,wanted);
  for(const[k,v]of Object.entries(expected))assert.equal(result.stamps[k],v,'Stale production pack '+k);
  responses.push(result);return result;
 }
 async function shot(data,label){
  const r=await command({...data,snapshot:true});
  const file=out+'/'+String(frameNumber++).padStart(4,'0')+'.png';
  await page.screenshot({path:file});
  const digest=createHash('sha256').update(await readFile(file)).digest('hex');
  frames.push({file,take:part,label,ticks:r.ticks,steps:data.steps??0,sha256:digest,...r});
  for(const who of ['player','clone'])if(r[who]){
   const key=part+'/'+who;
   (takes[key]??=[]).push({...r[who],time:r.ticks/60});
  }
  return r;
 }
 for(const scene of config.timeline){
  if(scene.setup){await command(scene.setup);continue;}
  part=scene.take;
  const started=frames.length;
  for(let tick=0;tick<scene.ticks;tick+=step){
   await shot({...(tick===0?(scene.command??{}):{}),steps:Math.min(step,scene.ticks-tick)},scene.label??part);
  }
  console.log(part,frames.length-started,'native framebuffers');
 }
 const errors=logs.filter(s=>/^(SCRIPT ERROR:|ERROR:|PAGEERROR)/.test(s));
 const report={config,errors,frames,responses,source_hashes:expected,
  unique_pngs:new Set(frames.map(f=>f.sha256)).size,simulation_seconds:frames.reduce((sum,f)=>sum+f.steps,0)/60,
  conditions:'Godot native scene tree, Compatibility WebGL2 / Chromium ANGLE SwiftShader. Production medium/PBR lighting/shadows. Offline physics 60 Hz; one framebuffer every '+step+' ticks. Starting fixtures, observer camera, pause between commands and UI visibility are review-only. NOT Windows/OpenGL3.3/940MX performance.'};
 await writeFile(out+'/manifest.json',JSON.stringify(report,null,2)+'\n');
 await writeFile(out+'/contact-trace.json',JSON.stringify({fps:60/step,outfit:'mixed',source:report.conditions,...expected,takes,seeks:{}})+'\n');
 assert.deepEqual(errors,[],'native engine/page errors');
 if(config.coverage==='wardrobe'){
  for(const outfit of ['dress','suit']){
   const f=frames.filter(f=>f.player?.outfit===outfit);
   assert(f.some(f=>f.player.state==='air')&&f.some(f=>f.player.state==='dodge'),'Missing actual jump/dodge '+outfit);
   assert(f.some(f=>f.player.hand_open>.9),'Missing original manual hand morph '+outfit);
   const directions=new Set(f.filter(f=>f.action==='dodge').map(f=>f.dodge_local.map(v=>Math.round(v)).join(',')));
   assert(directions.size>=4,'Four actual directional dodge states '+outfit);
  }
 }
 if(config.coverage==='gaits'){
  for(const outfit of ['dress','suit']){
   const idle=frames.filter(f=>f.take===outfit+'-gaits-idle');
   assert(idle.length===32&&idle.every(f=>f.player.hand_open>.99),'One full relaxed idle '+outfit);
   for(const[gait,speed]of [['walk',1.15],['jog',2.9],['sprint',5.6]]){
    const f=frames.filter(f=>f.take===outfit+'-gaits-'+gait);
    const quarters=new Set(f.map(f=>Math.floor(f.player.phase*4)%4));
    assert.equal(quarters.size,4,'Both feet / complete gait phase '+outfit+' '+gait);
    for(let i=6;i<f.length;i++){
     const a=f[i-1].player.position,b=f[i].player.position;
     const actual=Math.hypot(b[0]-a[0],b[2]-a[2])/(f[i].steps/60);
     assert(Math.abs(actual-speed)<.005,'Free gait must really travel at its original speed '+outfit+' '+gait);
    }
   }
  }
 }
 if(config.coverage==='strafe'){
  for(const outfit of ['dress','suit']){
   const f=frames.filter(f=>f.player?.outfit===outfit&&f.lock_target==='Clone');
   assert(f.length>=12&&f.some(f=>f.player.direction_weights[3]>.7),'Missing locked retreat '+outfit);
   assert(f.some(f=>f.player.direction_weights[1]>.7||f.player.direction_weights[2]>.7),'Missing actual lateral stride '+outfit);
  }
  const wall=frames.filter(f=>f.take==='wall-stop').slice(-4);
  assert(wall.length===4&&wall.every(f=>f.player.move_weight===0),'Held input must settle at the real wall');
  assert(Math.max(...wall.map(f=>f.player.phase))-Math.min(...wall.map(f=>f.player.phase))<1e-5,'Actual wall freezes phase');
 }
 if(config.coverage==='combat'){
  for(const f of frames){
   assert.equal(f.framing.length,4,'Both actors head/feet must have framing probes');
   for(const[x,y,behind]of f.framing){
    assert(!behind&&x>8&&x<f.viewport[0]-8&&y>8&&y<f.viewport[1]-8,
     'Pair observer clips a real jump/step, not acceptable combat footage');
   }
  }
  for(const outfit of ['dress','suit']){
   const f=frames.filter(f=>f.player?.outfit===outfit);
   assert(f.some(f=>f.attack_kind==='hook'&&f.action==='attack'),'Missing actual Q '+outfit);
   for(const who of ['player','clone'])for(const zone of ['head','torso']){
    assert(f.some(f=>f[who]?.hit_active&&f[who]?.zone===zone),'Missing visible confirmed '+who+' '+zone+' '+outfit);
   }
  }
 }
 console.log('GEN rendered review:',config.coverage,frames.length,'captures,',report.unique_pngs,'unique PNGs,',report.simulation_seconds.toFixed(3),'s at 1x; no engine errors');
}finally{await browser.close();}
