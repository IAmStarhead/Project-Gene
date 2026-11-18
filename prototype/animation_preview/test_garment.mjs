// Independent live JS/native cloth parity, NOT a playback of native cloth.
// 1. Record native: GEN_GARMENT_OUTPUT=/abs/trace.json godot --headless \
//      --path prototype --script res://tests/record_garment.gd
// 2. Start npm run dev, then GEN_GARMENT_TRACE=/abs/trace.json \
//      CHROMIUM_EXECUTABLE=/path/to/chromium npm run test:garment
// SOFTWARE_GL=1 uses SwiftShader. Traces stay outside Git.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { chromium } from 'playwright-core';

const tracePath = process.env.GEN_GARMENT_TRACE;
assert(tracePath, 'Record with record_garment.gd and set GEN_GARMENT_TRACE=/absolute/trace.json');
const executablePath = process.env.CHROMIUM_EXECUTABLE;
assert(executablePath, 'Set CHROMIUM_EXECUTABLE to installed Chromium/Chrome.');
const trace = JSON.parse(await readFile(tracePath, 'utf8'));
const base = process.env.PREVIEW_URL || 'http://127.0.0.1:5173';
for (const [key, path] of [['appearance_sha256', '/assets/heroine/appearance/lab_uniform.json'],
  ['motion_set_sha256', '/assets/heroine/animations/motion_set.json']]) {
  const body = Buffer.from(await (await fetch(base + path)).arrayBuffer());
  assert.equal(trace[key], createHash('sha256').update(body).digest('hex'),
    'Stale/missing native trace stamp: rerun record_garment.gd after regenerating the assets');
}
const browser = await chromium.launch({ executablePath, headless: true, args: process.env.SOFTWARE_GL === '1'
  ? ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--no-zygote'] : [] });
const html = `<!doctype html><meta charset="UTF-8">
<script type="importmap">{"imports":{"three":"/vendor/three/build/three.module.js","three/addons/":"/vendor/three/examples/jsm/"}}</script>
<script type="module">
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { Appearance } from '/appearance.js';
const [motion, uniform, gltf] = await Promise.all([
  fetch('/assets/heroine/animations/motion_set.json').then(r => r.json()),
  fetch('/assets/heroine/appearance/lab_uniform.json').then(r => r.json()),
  new GLTFLoader().loadAsync('/assets/heroine/female_A_rigged_safe.glb'),
]);
const model = gltf.scene, byName = new Map();
model.traverse(o => { const a = gltf.parser.associations.get(o);
  if (a?.nodes !== undefined) byName.set(gltf.parser.json.nodes[a.nodes].name, o); });
const bones = motion.bones.map(n => byName.get(n)), app = new Appearance(model, motion.bones, uniform);
function pose(f) {
  bones.forEach((b, i) => b.quaternion.fromArray(f.rotations[i]));
  bones[0].position.fromArray(f.hips); model.updateMatrixWorld(true); app.setHands(f.hand_open);
}
function difference(f) {
  let maximum = 0;
  app.points.forEach((p, i) => { maximum = Math.max(maximum, p.distanceTo(new THREE.Vector3(...f.cloth[i]))); });
  return maximum;
}
window.garmentParity = {
  ready: true,
  seek(f) { pose(f); app.reset(); return difference(f); },
  cycle(frames, fps) {
    pose(frames[0]); app.reset();
    for (const f of frames) { pose(f); app.update(1/fps); }
    let maximum = 0;
    for (const f of frames) { pose(f); app.update(1/fps); maximum = Math.max(maximum, difference(f)); }
    const normals = app.clothGeometry.attributes.normal;
    let normalError = 0;
    for (let i = 0; i < normals.count; i++) normalError = Math.max(normalError,
      Math.abs(new THREE.Vector3().fromBufferAttribute(normals, i).length()-1));
    return { maximum, normalError };
  },
};
</script>`;
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/__garment-parity__', route => route.fulfill({ contentType: 'text/html', body: html }));
  await page.goto(base + '/__garment-parity__', { waitUntil: 'networkidle' });
  await page.waitForFunction(() => window.garmentParity?.ready, null, { timeout: 30000 });
  let maximum = 0, count = 0;
  for (const [name, frames] of Object.entries(trace.takes)) {
    const result = await page.evaluate(({ frames, fps }) => window.garmentParity.cycle(frames, fps), { frames, fps: trace.fps });
    console.log(`${name}: ${frames.length} frames, live solver max difference ${(result.maximum*1000).toFixed(4)} mm`);
    maximum = Math.max(maximum, result.maximum); count += frames.length;
    assert(result.normalError < 1e-6, 'Browser textile normals must remain unit length');
  }
  for (const [name, frame] of Object.entries(trace.seeks)) {
    const error = await page.evaluate(f => window.garmentParity.seek(f), frame);
    console.log(`${name}: exact seek difference ${(error*1000).toFixed(4)} mm`);
    maximum = Math.max(maximum, error);
  }
  assert.deepEqual(errors, []);
  // Native uses float32 vectors; JS uses doubles. Do not silently permit the
  // former millimetre-level difference between the generic/batched solvers.
  assert(maximum < .00025, `Live solver parity exceeds 0.25 mm: ${maximum*1000} mm`);
  console.log(`GEN live garment parity: ${count} frames + ${Object.keys(trace.seeks).length} seeks; maximum ${(maximum*1000).toFixed(4)} mm.`);
} finally {
  await browser.close();
}
