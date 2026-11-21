// Uninstrumented production main.tscn + actual DOM keyboard/UI smoke.
// This is a visual smoke with saved screenshots, NOT gameplay acceptance or
// an assertion that an outfit/clip changed just because pixels differ.
import {chromium} from '../../animation_preview/node_modules/playwright-core/index.mjs';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const config=JSON.parse(await readFile(process.argv[2],'utf8'));
await mkdir(config.out,{recursive:true});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE||'/tmp/chromium',
 headless:true,args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-zygote']});
const logs=[],shots=[];
try{
 const page=await browser.newPage({viewport:{width:1000,height:700}});
 // Software raster on a busy authoring host can take longer than 30 s.
 // This is only an IPC/screenshot timeout, NOT an FPS/settling assertion.
 page.setDefaultTimeout(120000);
 page.on('console',m=>logs.push(m.text()));
 page.on('pageerror',e=>logs.push('PAGEERROR '+e.stack));
 await page.goto((process.env.REVIEW_URL||'http://127.0.0.1:5182')+'/?pack='+config.pack,
  {waitUntil:'networkidle',timeout:120000});
 await page.waitForFunction(()=>window.godotReady===true,null,{timeout:120000});
 await page.locator('canvas').focus();
 async function screenshot(name,key){
  if(key)await page.keyboard.press(key);
  await page.waitForTimeout(2500);
  const file=config.out+'/'+name+'.png';await page.screenshot({path:file});
  shots.push({name,key:key??null,file,sha256:createHash('sha256').update(await readFile(file)).digest('hex')});
  console.log(name);
 }
 await screenshot('01-game-default-dress');
 await screenshot('02-game-F3','F3');
 await screenshot('03-game-suit-O','o');
 await screenshot('04-hotbar-front-4','4');
 await screenshot('05-hotbar-strong-6','6');
 await screenshot('06-hotbar-empty-0','0');
 await page.keyboard.press('v');
 await page.keyboard.press('n');
 await page.keyboard.press('k');
 await screenshot('07-blade-context-right-arm-2','2');
 await page.keyboard.press('v');
 await page.keyboard.press('1');
 await screenshot('08-showcase-retains-suit-H','h');
 await screenshot('09-showcase-next-clip','ArrowDown');
 await screenshot('10-showcase-dress-O','o');
 await screenshot('11-return-game-retains-dress','h');
 const errors=logs.filter(s=>/^(ERROR:|SCRIPT ERROR:|PAGEERROR)/.test(s));
 await writeFile(config.out+'/manifest.json',JSON.stringify({config,shots,logs,errors,
  conditions:'Unmodified production main_scene; Chromium keyboard input; native Compatibility WebGL2 / SwiftShader. Fixed 2.5 s wall-time waits, not fixed simulation-step evidence. Screenshots require visual inspection. NOT 940MX or Windows acceptance.'},null,2)+'\n');
 assert.deepEqual(errors,[],'Production smoke engine/page errors');
 assert.equal(shots.length,11);
 console.log('Uninstrumented production launch/UI smoke: 11 screenshots, no engine errors; selection/wardrobe states still require visual inspection');
}finally{await browser.close();}
