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
  await page.waitForFunction(() => window.motionLab?.ready, { timeout: 30000 });
  const data = await (await fetch(base + '/assets/heroine/animations/motion_set.json')).json();
  const model = await (await fetch(base + '/assets/heroine/female_A_rigged_safe.glb')).arrayBuffer();
  assert.equal(createHash('sha256').update(Buffer.from(model)).digest('hex'), data.model_sha256);
  assert.equal(await page.locator('.clip-button').count(), 11);
  const settle = () => page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  for (const [name, clip] of Object.entries(data.clips)) {
    await page.locator(`[data-clip="${name}"]`).click();
    assert.equal(await page.evaluate(() => window.motionLab.state.selected), name);
    for (const fraction of [0, .17, .43, .79, 1]) {
      await page.evaluate((t) => window.motionLab.seek(t), clip.duration * fraction);
      const joints = await page.evaluate(() => window.motionLab.joints);
      assert.equal(joints.length, 21);
      assert(joints.every((joint) => joint.position.every(Number.isFinite)), `Non-finite joint in ${name}`);
      assert(joints.filter((joint) => joint.name.startsWith('hand.')).every((joint) => joint.position[1] > 1.1 && joint.position[2] > .1));
      frames++;
    }
    if (name.startsWith('attack')) {
      await page.evaluate((t) => window.motionLab.seek(t), clip.impact);
      const hand = (await page.evaluate(() => window.motionLab.joints)).find((joint) => joint.name === `hand.${clip.side}`);
      assert(Math.abs(hand.position[0]) < .06 && hand.position[2] > .61, `Forward contact in ${name}`);
    }
  }
  // Space must work even immediately after clicking a clip button.
  await page.locator('[data-clip="walk"]').click();
  await page.keyboard.press('Space');
  assert.equal(await page.evaluate(() => window.motionLab.state.playing), false);
  await page.evaluate(() => window.motionLab.seek(.1));
  await page.keyboard.press('ArrowRight');
  assert(Math.abs((await page.evaluate(() => window.motionLab.state.time)) - (.1 + 1/60)) < .000001);
  await page.locator('#speed').selectOption('0.25');
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
    for (const [name, times] of [
      ['walk', [0, .205, .41, .615]], ['run', [0, .135, .27, .405]],
      ['attack_left', [0, .10, .18, .30]], ['attack_right', [0, .10, .18, .30]],
      ['dodge', [0, .08, .20, .34]], ['land', [0, .065, .16, .26]],
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
  console.log(`GEN browser suite: 11 clips, ${frames} sampled poses, controls, mobile layout and static-server isolation OK.`);
} finally {
  await browser.close();
}
