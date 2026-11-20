// Start `npm run dev` first. Use an installed Chromium/Chrome, no downloads:
// CHROMIUM_EXECUTABLE=/path/to/chromium npm test
// Optional REVIEW_DIR writes screenshots; SOFTWARE_GL=1 enables SwiftShader.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromium } from 'playwright-core';

const base = process.env.PREVIEW_URL || 'http://127.0.0.1:5173';
const executablePath = process.env.CHROMIUM_EXECUTABLE || [
  '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].find(existsSync);
assert(executablePath, 'Set CHROMIUM_EXECUTABLE to an installed Chrome/Chromium executable.');
const args = process.env.SOFTWARE_GL === '1'
  ? ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--no-zygote'] : [];
const browser = await chromium.launch({ executablePath, args, headless: true });
const output = process.env.REVIEW_DIR;
if (output) await mkdir(output, { recursive: true });
const errors = [];
let frames = 0;
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 1 });
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto(base, { waitUntil: 'networkidle' });
  await page.waitForFunction(() => window.motionLab?.ready, null, { timeout: 30000 });
  const data = await (await fetch(base + '/assets/heroine/animations/motion_set.json')).json();
  const model = await (await fetch(base + '/assets/heroine/female_A_rigged_safe.glb')).arrayBuffer();
  assert.equal(createHash('sha256').update(Buffer.from(model)).digest('hex'), data.model_sha256);
  assert.equal(await page.locator('.clip-button').count(), 30);
  assert.equal(await page.evaluate(() => window.motionLab.state.selected), 'idle_relaxed');
  assert.match(await page.locator('#clip-count').textContent(), /30/);
  const settle = () => page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  for (const [name, clip] of Object.entries(data.clips)) {
    await page.locator(`[data-clip="${name}"]`).click();
    assert.equal(await page.evaluate(() => window.motionLab.state.selected), name);
    for (const fraction of [0, .17, .43, .79, 1]) {
      await page.evaluate((t) => window.motionLab.seek(t), clip.duration * fraction);
      const joints = await page.evaluate(() => window.motionLab.joints);
      assert.equal(joints.length, 21);
      assert(joints.every((joint) => joint.position.every(Number.isFinite)), `Non-finite joint in ${name}`);
      const relaxed = name.endsWith('_relaxed');
      // A running recovery passes near the moving hip, not an arbitrary
      // fixed y=.90/.92 plane which pinned the old hands in front of the belt.
      const runningRelaxed = ['run_relaxed', 'sprint_relaxed'].includes(name);
      const minHandHeight = runningRelaxed ? joints.find((joint) => joint.name === 'hips').position[1] + .02
        : name.startsWith('dodge') ? 1.0 : ['run', 'jump_down', 'land'].includes(name) ? .95 : relaxed ? .78 : 1.1;
      assert(joints.filter((joint) => joint.name.startsWith('hand.')).every((joint) => joint.position[1] > minHandHeight && joint.position[2] > (relaxed ? -.1 : .1)), `Hand/hip carriage in ${name}`);
      if (relaxed) {
        assert(joints.filter((joint) => joint.name.startsWith('hand.')).every((joint) => joint.position[1] < (['run_relaxed', 'sprint_relaxed'].includes(name) ? 1.30 : .95)), 'Ordinary arms must not return to face-level guard');
      }
      if (name === 'run') {
        for (const side of ['L', 'R']) {
          const get = (bone) => joints.find((joint) => joint.name === `${bone}.${side}`).position;
          assert(get('forearm')[1] < get('upper_arm')[1] - .21, 'Running elbow must stay below the shoulder');
          assert(get('hand')[1] < get('upper_arm')[1] - .09, 'Running fist must not return to the neck');
        }
      }
      if (['walk', 'run', 'walk_relaxed', 'run_relaxed', 'sprint_relaxed'].includes(name)) {
        assert(joints.find((joint) => joint.name === 'hips').position[1] > (name === 'walk' ? .80 : name === 'walk_relaxed' ? .865 : name === 'sprint_relaxed' ? .84 : .825),
          `Locomotion must not sink into a crouch: ${name}`);
      }
      const appearance = await page.evaluate(() => window.motionLab.appearance);
      assert.equal(appearance.handOpen, relaxed ? 1 : 0, `Actual hand morph in ${name}`);
      assert(appearance.handVertices >= 3400, 'Existing fingers must actually open, not just move their wrists');
      assert(appearance.gownVertices > 800 && appearance.gownIndexCount > 5000 && appearance.cloth.length === 320, 'Shared garment is loaded');
      assert(appearance.cloth.every((p) => p.every(Number.isFinite)), 'Finite cloth positions');
      frames++;
    }
    if (name.startsWith('attack')) {
      await page.evaluate((t) => window.motionLab.seek(t), clip.impact);
      const hand = (await page.evaluate(() => window.motionLab.joints)).find((joint) => joint.name === `hand.${clip.side}`);
      assert(Math.abs(hand.position[0]) < .06 && hand.position[2] > .61, `Forward contact in ${name}`);
    }
  }
  await page.locator('#outfit').selectOption('suit');
  assert.equal((await page.evaluate(() => window.motionLab.appearance)).outfit, 'suit');
  for (const [name, clip] of Object.entries(data.clips)) {
    await page.evaluate((name) => window.motionLab.select(name), name);
    for (const fraction of [0, .43, .87]) {
      await page.evaluate((t) => window.motionLab.seek(t), clip.duration*fraction);
      const a = await page.evaluate(() => window.motionLab.appearance);
      assert.equal(a.outfit, 'suit');
      assert(a.suitVertices > 6000 && a.suitVertices < 14000, 'real rigged top + trousers');
      assert.equal(a.handOpen, name.endsWith('_relaxed') ? 1 : 0, 'same hand morph in the suit');
      assert(a.bodyIndices > 1000, 'outfit masking cannot remove the entire body');
      frames++;
    }
  }
  await page.locator('#outfit').selectOption('dress');
  assert.equal((await page.evaluate(() => window.motionLab.appearance)).outfit, 'dress');
  // Cloth is part of the selected pose: pause must freeze its history, and
  // explicit scrubbing must reset to a deterministic body-safe result.
  await page.evaluate(() => { window.motionLab.select('run_relaxed'); window.motionLab.seek(.2); });
  const soughtCloth = await page.evaluate(() => window.motionLab.appearance.cloth);
  await page.evaluate(() => { window.motionLab.seek(.5); window.motionLab.seek(.2); });
  assert.deepEqual(await page.evaluate(() => window.motionLab.appearance.cloth), soughtCloth,
    'Seeking the same time must not depend on previous cloth history');
  const animationFrames = (count) => page.evaluate((n) => new Promise((done) => {
    const step = () => --n > 0 ? requestAnimationFrame(step) : done();
    requestAnimationFrame(step);
  }), count);
  await animationFrames(6);
  assert.deepEqual(await page.evaluate(() => window.motionLab.appearance.cloth), soughtCloth,
    'Paused scrubbing must leave cloth motionless across rendered frames');
  await page.locator('#play').click();
  await animationFrames(3);
  await page.locator('#play').click();
  const pausedCloth = await page.evaluate(() => window.motionLab.appearance.cloth);
  assert.notDeepEqual(pausedCloth, soughtCloth, 'Playing must actually simulate secondary motion');
  await animationFrames(6);
  assert.deepEqual(await page.evaluate(() => window.motionLab.appearance.cloth), pausedCloth,
    'Pausing during motion must preserve, not reset or continue, the simulated cloth');
  // Space must work even immediately after clicking a clip button.
  await page.locator('[data-clip="walk"]').click();
  await page.keyboard.press('Space');
  assert.equal(await page.evaluate(() => window.motionLab.state.playing), false);
  await page.evaluate(() => window.motionLab.seek(.1));
  await page.keyboard.press('ArrowRight');
  assert(Math.abs((await page.evaluate(() => window.motionLab.state.time)) - (.1 + 1/60)) < .000001);
  await page.locator('#speed').selectOption('0.25');
  await page.locator('#clothes').uncheck();
  await page.locator('#clothes').check();
  await page.locator('#skeleton').check();
  await page.locator('#skeleton').uncheck();
  await page.locator('#trail').check();
  await page.locator('[data-clip="attack_right"]').click();
  await page.evaluate(() => window.motionLab.seek(.18));
  await page.locator('[data-view="side"]').click();
  await settle();
  if (output) await page.screenshot({ path: resolve(output, 'preview-desktop.png') });
  await page.locator('#trail').uncheck();
  if (output) {
    const quarters = (name) => [0, .25, .5, .75].map((phase) => phase * data.clips[name].duration);
    for (const [name, times] of [
      ['walk', quarters('walk')], ['run', quarters('run')],
      ['idle_relaxed', quarters('idle_relaxed')], ['walk_relaxed', quarters('walk_relaxed')], ['run_relaxed', quarters('run_relaxed')], ['sprint_relaxed', quarters('sprint_relaxed')],
      ['attack_left', [0, .10, .18, .30]], ['attack_right', [0, .10, .18, .30]],
      ...['dodge', 'dodge_back', 'dodge_left', 'dodge_right'].map((name) => [name, [0, .08, .20, .34]]), ['land', [0, .075, .18, data.clips.land.duration]],
      ...['jump_start', 'jump_up', 'jump_down'].map((name) => [name, quarters(name)]),
    ]) {
      for (let i = 0; i < times.length; i++) {
        await page.evaluate(({ name, t }) => { window.motionLab.select(name); window.motionLab.seek(t); window.motionLab.setView('side'); }, { name, t: times[i] });
        await settle();
        await page.locator('canvas').screenshot({ path: resolve(output, `${name}-${i}.png`) });
      }
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('[data-clip="guard"]').click();
  await page.evaluate(() => { window.motionLab.seek(.7); window.motionLab.setView('three'); });
  await settle();
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile horizontal overflow');
  if (output) await page.screenshot({ path: resolve(output, 'preview-mobile.png') });
  for (const route of ['/.git/config', '/@fs/etc/passwd', '/vendor/three/../../../.git/config']) {
    assert.equal((await fetch(base + route)).status, 404, `Denied repository traversal: ${route}`);
  }
  assert.equal((await fetch(base, { headers: { Host: '5173-session.e2b.app' } })).status, 200);
  assert.deepEqual(errors, []);
  console.log(`GEN browser suite: 30 clips, ${frames} sampled poses, cloth pause/seek/resume, controls, mobile layout and static-server isolation OK.`);
} finally {
  await browser.close();
}
