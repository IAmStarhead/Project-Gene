// Review-only, dependency-free same-origin static host. Never serve the repo.
// node prototype/tests/rendered_review/serve.mjs --root .local/review/public
import http from 'node:http';
import {createReadStream} from 'node:fs';
import {readFile,realpath,stat} from 'node:fs/promises';
import {dirname,extname,resolve,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const args=process.argv.slice(2),value=name=>args[args.indexOf(name)+1];
assert(args.includes('--root'),'Pass --root with an ignored public asset directory');
const root=await realpath(resolve(value('--root'))),port=Number(args.includes('--port')?value('--port'):5175);
const here=dirname(fileURLToPath(import.meta.url)),html=await readFile(resolve(here,'web.html'));
const types={'.js':'text/javascript; charset=utf-8','.wasm':'application/wasm','.pck':'application/octet-stream',
 '.png':'image/png','.jpg':'image/jpeg','.json':'application/json'};
http.createServer(async(req,res)=>{
 try{
  if(!['GET','HEAD'].includes(req.method)){res.writeHead(405).end();return;}
  const url=new URL(req.url,'http://review.invalid'),path=decodeURIComponent(url.pathname);
  const headers={'Cache-Control':'no-store','Cross-Origin-Opener-Policy':'same-origin',
   'Cross-Origin-Embedder-Policy':'require-corp','X-Content-Type-Options':'nosniff'};
  if(path==='/'||path==='/index.html'){
   res.writeHead(200,{...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':html.length});
   res.end(req.method==='HEAD'?undefined:html);return;
  }
  if(path.split('/').some(p=>p.startsWith('.'))||!types[extname(path)])throw Error('Not public');
  const file=await realpath(resolve(root,'.'+path));
  if(!file.startsWith(root+sep))throw Error('Outside public root');
  const info=await stat(file);if(!info.isFile())throw Error('Not a file');
  res.writeHead(200,{...headers,'Content-Type':types[extname(file)],'Content-Length':info.size});
  if(req.method==='HEAD')res.end();else createReadStream(file).on('error',()=>res.destroy()).pipe(res);
 }catch{res.writeHead(404).end('Not found');}
}).listen(port,'0.0.0.0',()=>console.log(`Godot review host: 0.0.0.0:${port} (public assets only)`));
