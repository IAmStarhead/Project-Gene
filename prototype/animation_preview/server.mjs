// Dependency-free static preview server. Exposes only the viewer, its two
// source assets, and Three.js modules — never the repository or .git directory.
import http from 'node:http';
import { createReadStream } from 'node:fs';
import { stat, realpath } from 'node:fs/promises';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const vendor = resolve(root, 'node_modules/three');
const files = new Map([
  ['/', resolve(root, 'index.html')],
  ...['index.html', 'main.js', 'style.css'].map((name) => ['/' + name, resolve(root, name)]),
  ...['female_A_rigged_safe.glb', 'animations/motion_set.json'].map((name) => [
    '/assets/heroine/' + name, resolve(root, '../assets/heroine', name),
  ]),
]);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.glb': 'model/gltf-binary' };
const server = http.createServer(async (req, res) => {
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405).end(); return; }
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://preview.invalid').pathname);
    let path = files.get(pathname);
    if (!path && pathname.startsWith('/vendor/three/') && extname(pathname) === '.js') {
      const candidate = resolve(vendor, pathname.slice('/vendor/three/'.length));
      const actual = await realpath(candidate);
      if (actual.startsWith(vendor + sep)) path = actual;
    }
    if (!path) { res.writeHead(404).end('Not found'); return; }
    const info = await stat(path);
    if (!info.isFile()) { res.writeHead(404).end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': types[extname(path)] || 'application/octet-stream',
      'Content-Length': info.size, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-cache' });
    if (req.method === 'HEAD') res.end();
    else createReadStream(path).on('error', () => res.destroy()).pipe(res);
  } catch { res.writeHead(404).end('Not found'); }
});
const port = Number(process.env.PORT || 5173);
server.listen(port, '0.0.0.0', () => console.log(`GEN Motion Lab listening on 0.0.0.0:${port}`));
