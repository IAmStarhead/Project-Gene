// Real Godot 4.7.2 scene tree / production lighting; offline 1/60 physics, 12 distinct captures/s.
import {chromium} from '../../prototype/animation_preview/node_modules/playwright-core/index.mjs';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const base='.local/review/repair-42';
const part=process.argv.find(x=>x.startsWith('--part='))?.slice(7)||'smoke';
const expected=JSON.parse(await readFile(base+'/source-hashes.json','utf8'));
// The isolated entry point is deliberately different; EVERY other stamp must match.
delete expected.project_sha256;
const browser=await chromium.launch({executablePath:'/tmp/chromium',headless:true,args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-zygote']});
const logs=[],responses=[],manifest=[],takes={};
const out=base+'/gameplay-'+part;await mkdir(out,{recursive:true});
try {
 const page=await browser.newPage({viewport:{width:800,height:450}});page.setDefaultTimeout(120000);
 page.on('console',m=>{logs.push(m.text());if(/ERROR|REPLAY_READY/.test(m.text()))console.log(m.text())});
 page.on('pageerror',e=>{logs.push('PAGEERROR '+e.stack);console.error(e.stack)});
 const ready=page.waitForEvent('console',{predicate:m=>m.text().includes('REPLAY_READY'),timeout:120000});
 await page.goto('http://127.0.0.1:5175/?pack=runtime42.pck',{waitUntil:'networkidle',timeout:120000});await ready;
 let id=0,number=0,active='';
 async function command(data) {
  const wanted=++id;const done=page.waitForEvent('console',{predicate:m=>m.text()==='REPLAY_DONE:'+wanted,timeout:120000});
  await page.evaluate(c=>window.mod.copyToFS('/replay'+c.id+'.json',new TextEncoder().encode(JSON.stringify(c))),{...data,id:wanted});await done;
  const record=logs.filter(s=>s.startsWith('REPLAY_DATA:')).at(-1);
  const parsed=JSON.parse(record.slice('REPLAY_DATA:'.length));assert.equal(parsed.id,wanted);
  for(const[k,v]of Object.entries(expected))assert.equal(parsed.stamps[k],v,'Stale pack '+k);
  responses.push(parsed);return parsed;
 }
 async function shot(data={},snapshot=true) {
  const result=await command({...data,snapshot});
  const file=out+'/'+String(number++).padStart(4,'0')+'.png';await page.screenshot({path:file});
  manifest.push({file,take:active,ticks:result.ticks,action:result.action,action_time:result.action_time,grounded:result.grounded,state:result.player?.state,health:result.health,clone_health:result.clone_health,clone_mode:result.clone_mode,hit_active:result.player?.hit_active,hit_time:result.player?.hit_time,clone_hit_active:result.clone?.hit_active,position:result.player?.position,stamina:result.stamina,lock_target:result.lock_target,last_contact:result.last_contact,yaw:result.yaw,velocity:result.velocity});
  if(snapshot && result.mode==='game')for(const who of ['player','clone']){const key=active+'/'+who;(takes[key]??=[]).push({...result[who],time:result.ticks/60});}
  return result;
 }
 async function run(name,ticks,data={}) {
  active=name;for(let step=0;step<ticks;step+=5)await shot({...(step===0?data:{}),steps:Math.min(5,ticks-step)});
  console.log(name,number,'rendered frames');
 }
 if(part==='smoke'){
  active='production-camera';await shot({steps:35});
  await run('production-lighting-and-driver',15,{ui:false,view:'three',press:['move_forward']});
 }
 if(part==='locomotion'){
  active='production-camera';await shot({steps:35});
  await command({route:true,steps:5});
  await run('relaxed-walk',60,{press:['move_left','walk_slow'],ui:false,view:'route'});
  await run('relaxed-jog',60,{release:['walk_slow']});
  await run('relaxed-sprint',50,{press:['run']});
  await run('moving-combat-switch',60,{release:['run'],stance:true});
  await run('combat-walk',60,{press:['walk_slow']});
  await run('moving-relaxed-switch',50,{stance:true,release:['walk_slow']});
  await run('stop',30,{release:['move_left']});
 }
 if(part==='dodge'){
  await command({center:true,steps:35,ui:false,view:'side'});
  for(const[name,dir,view]of [['forward',[0,1],'three'],['back',[0,-1],'side'],['left',[1,0],'back'],['right',[-1,0],'back']])await run('dodge-'+name,60,{dodge:dir,view});
 }
 if(part==='actions'){
  await command({steps:35,ui:false,view:'side'});
  await run('relaxed-jump',80,{jump:true});
  await run('jog-jump',80,{jump:true,press:['move_forward']});
  await run('stop-and-hit',40,{release:['move_forward'],hit:true,view:'three'});
  await run('jab',42,{attack:'L'});await run('cross',42,{attack:'R'});
 }
 if(part==='clone'){
  await command({pair:true,steps:35,ui:false,view:'pair'});
  await run('clone-engage',90,{clone:true});
  await run('clone-exchange-left',42,{attack:'L'});
  await run('clone-exchange-right',42,{attack:'R'});
  await run('clone-hit-reaction',60,{});
 }
 if(part==='lock'){
  await command({steps:35,view:'game'});
  await run('existing-lock-diagonal',60,{lock:true,press:['move_right','move_forward']});
  await run('existing-lock-backward',60,{release:['move_forward'],press:['move_back']});
  await run('existing-unlock',30,{release:['move_right','move_back'],lock:true});
 }
 // Keep attempted evidence even if a coverage assertion fails.
 await writeFile(out+'/capture-attempt.json',JSON.stringify(manifest,null,2));
 if(part==='locomotion')for(const name of ['relaxed-walk','relaxed-jog','relaxed-sprint','moving-combat-switch','combat-walk','moving-relaxed-switch']){
  const f=manifest.filter(f=>f.take===name);
  assert(Math.abs(f.at(-1).position[0]-f[0].position[0])>.6,'Blocked locomotion: '+name);
  assert(f.every(f=>f.grounded&&Math.abs(f.position[2]-4)<.001&&Math.abs(f.position[0])<8.65),'Invalid clear-corridor fixture');
 }
 if(part==='actions'){
  for(const state of ['attack_L','attack_R'])assert(manifest.some(f=>f.state===state),'Missing '+state);
  assert(manifest.filter(f=>f.take==='stop-and-hit'&&f.hit_active).length>=3,'Missing additive hit frames');
 }
 if(part==='clone'){
  assert(manifest.some(f=>f.hit_active)&&manifest.some(f=>f.clone_hit_active),'Missing reciprocal hit reactions');
  assert(manifest.some(f=>f.health<manifest[0].health&&f.clone_health<manifest[0].clone_health),'Missing reciprocal damage');
 }
 if(part==='lock'){
  assert(manifest.filter(f=>f.take==='existing-lock-diagonal').every(f=>f.lock_target==='Clone'),'Lock was not maintained');
  assert(manifest.filter(f=>f.take==='existing-unlock').every(f=>!f.lock_target),'Unlock failed');
 }
 await writeFile(out+'/frames.json',JSON.stringify(manifest,null,2));
 await writeFile(out+'/controller-contact-trace.json',JSON.stringify({fps:60,source:'Isolated Godot WebGL main.tscn: ACTUAL player + clone physics controllers, every 5 physics ticks, 800x450; PRODUCTION lighting/materials/geometry/physics; recording-only observer camera, starting fixtures and UI visibility',native_version:'4.7.2.stable.custom_build.3d95ead8f (WebGL2/SwiftShader)',...responses[0].stamps,capture_conditions:responses[0].capture_conditions,route_fixture:part==='locomotion'?'(7.8,.03,4), move_left across clear front corridor; no mid-take relocation':part==='clone'?'actors at (-.45,.03,2.5)/(.45,.03,2.5)':part==='dodge'?'player at (0,.03,2.5), to keep the observer inside the room':'production spawn',viewport:responses[0].viewport,window_pixels:responses[0].window_pixels,takes,seeks:{}}));
 const errors=logs.filter(s=>/^SCRIPT ERROR:|^ERROR:|PAGEERROR/.test(s));
 await writeFile(base+'/runtime-'+part+'.json',JSON.stringify({part,errors,logs,manifest,responses},null,2));
 assert.deepEqual(errors,[]);
 console.log('Godot rendered review complete',part,responses.length,'commands;',manifest.length,'framebuffers; zero engine/page errors');
} finally {await browser.close()}
