import * as THREE from 'three';
import { Appearance } from './appearance.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const MODEL_URL = new URL('../assets/heroine/female_A_rigged_safe.glb', import.meta.url).href;
const MOTION_URL = new URL('../assets/heroine/animations/motion_set.json', import.meta.url).href;
const $ = (id) => document.getElementById(id);
const CATALOG = [
  ['idle_relaxed', 'Спокойная стойка', 'Ровный корпус, мягкое дыхание, руки опущены.', 'locomotion', '○'],
  ['walk_relaxed', 'Обычная ходьба', 'Перекат с пятки на носок, свободный встречный мах рук.', 'locomotion', '↗'],
  ['run_relaxed', 'Лёгкий бег', 'Без модификаторов: лёгкий бег, подвижный корпус и мягкие кисти.', 'locomotion', '»'],
  ['sprint_relaxed', 'Быстрый бег', 'Shift: активный толчок, наклон всего тела и работа плеч.', 'locomotion', '»»'],
  ['guard', 'Боевая стойка', 'Дыхание, мягкие колени и компактная защита.', 'locomotion', '◇'],
  ['walk', 'Ходьба · бой', 'Перенос ноги, опора и встречное движение корпуса.', 'locomotion', '↗'],
  ['run', 'Бег · бой', 'Опора под тазом, отталкивание и встречный мах от плеча.', 'locomotion', '»'],
  ['attack_left', 'Джеб · левая', 'Короткая подготовка → прямой удар → возврат в защиту.', 'combat', '↗'],
  ['attack_right', 'Кросс · правая', 'Поворот таза и плеча. Свободная рука прикрывает лицо.', 'combat', '↗'],
  ['dodge', 'Уворот вперёд', 'Короткий подшаг с ведущей ногой, без разворота тела.', 'combat', '↑'],
  ['dodge_back', 'Уворот назад', 'Отход спиной, без поворота на 180 градусов.', 'combat', '↓'],
  ['dodge_left', 'Уворот влево', 'Боковой уход с приставлением второй ноги.', 'combat', '←'],
  ['dodge_right', 'Уворот вправо', 'Боковой уход с сохранением взгляда на противника.', 'combat', '→'],
  ['hit', 'Реакция на удар', 'Короткая отдача корпуса и восстановление защиты.', 'combat', '✧'],
  ['jump_start', 'Отрыв от земли', 'Разгибание ног и мах руками. Без задержки ввода.', 'air', '↑'],
  ['jump_up', 'Взлёт', 'Плавный подбор ног к вершине физической траектории.', 'air', '↥'],
  ['jump_down', 'Падение', 'Ноги готовятся принять вес при приземлении.', 'air', '↓'],
  ['land', 'Приземление', 'Амортизация коленями и возврат в стойку.', 'air', '↧'],
  ['combat_forward_walk', 'Вперёд · шаг', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_forward_jog', 'Вперёд · бег', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_forward_sprint', 'Вперёд · Shift', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_left_walk', 'Стрейф влево · шаг', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_left_jog', 'Стрейф влево · бег', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_left_sprint', 'Стрейф влево · Shift', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_right_walk', 'Стрейф вправо · шаг', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_right_jog', 'Стрейф вправо · бег', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_right_sprint', 'Стрейф вправо · Shift', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_back_walk', 'Отход назад · шаг', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_back_jog', 'Отход назад · бег', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
  ['combat_back_sprint', 'Отход назад · Shift', 'Направленный цикл с общей опорной фазой. Корпус смотрит на цель.', 'locomotion', '◇'],
];

const scene = new THREE.Scene();
scene.background = new THREE.Color('#15212c');
scene.fog = new THREE.Fog('#15212c', 7, 17);
const camera = new THREE.PerspectiveCamera(34, 1, .03, 60);
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.15;
$('viewport').appendChild(renderer.domElement);
const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, .88, 0);
controls.enableDamping = true;
controls.minDistance = 1.7;
controls.maxDistance = 6.5;
controls.maxPolarAngle = Math.PI * .52;
controls.minPolarAngle = Math.PI * .12;
controls.enablePan = false;
const cameras = { front: [0, 1.45, 4.5], side: [4.5, 1.45, .01], back: [0, 1.45, -4.5], three: [3, 1.55, 3.5] };
function setView(view) {
  camera.position.set(...cameras[view]);
  controls.update();
  document.querySelectorAll('[data-view]').forEach((button) => button.classList.toggle('active', button.dataset.view === view));
}
setView('front');
scene.add(new THREE.HemisphereLight('#d9e8fa', '#6e8391', 2.4));
const key = new THREE.DirectionalLight('#f0f5ff', 3.1);
key.position.set(3, 5, 4);
key.castShadow = true;
key.shadow.mapSize.set(1024, 1024);
key.shadow.camera.left = key.shadow.camera.bottom = -2;
key.shadow.camera.right = key.shadow.camera.top = 2;
key.shadow.normalBias = .018;
key.shadow.bias = -.0001;
key.shadow.radius = 4;
scene.add(key);
const rim = new THREE.DirectionalLight('#b8e9db', 2.2);
rim.position.set(-3, 2, -3);
scene.add(rim);
const ground = new THREE.Mesh(new THREE.PlaneGeometry(80, 80), new THREE.MeshStandardMaterial({ color: '#263b49', roughness: 1 }));
ground.rotation.x = -Math.PI / 2;
ground.position.y = -.003;
ground.receiveShadow = true;
scene.add(ground);
const grid = new THREE.GridHelper(20, 80, '#566a75', '#3b5260');
grid.material.transparent = true;
grid.material.opacity = .27;
grid.position.y = -.001;
scene.add(grid);
const forward = new THREE.ArrowHelper(new THREE.Vector3(0, 0, 1), new THREE.Vector3(0, .008, .45), .43, '#607f89', .075, .035);
scene.add(forward);

const footMarkers = ['L', 'R'].map(() => {
  const marker = new THREE.Mesh(new THREE.RingGeometry(.045, .055, 32), new THREE.MeshBasicMaterial({ color: '#90e5bf', transparent: true, opacity: .8, depthWrite: false }));
  marker.rotation.x = -Math.PI / 2;
  marker.position.y = .006;
  scene.add(marker);
  return marker;
});
const trajectory = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: '#e8bc86', transparent: true, opacity: .8 }));
trajectory.visible = false;
scene.add(trajectory);
const impactDot = new THREE.Mesh(new THREE.SphereGeometry(.013, 12, 8), new THREE.MeshBasicMaterial({ color: '#b9f3d4' }));
impactDot.visible = false;
scene.add(impactDot);

let data, model, bones, helper, appearance;
let selected = 'idle_relaxed', time = 0, playing = true, speed = 1;
let last = performance.now();
const q0 = new THREE.Quaternion(), q1 = new THREE.Quaternion(), vector = new THREE.Vector3();

function samplePose(name, t) {
  const clip = data.clips[name];
  t = THREE.MathUtils.clamp(t, 0, clip.duration);
  let lo = 0, hi = clip.times.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (clip.times[mid] <= t) lo = mid; else hi = mid;
  }
  const u = (t - clip.times[lo]) / (clip.times[hi] - clip.times[lo]);
  bones.forEach((bone, i) => {
    q0.fromArray(clip.rotations[lo][i]);
    q1.fromArray(clip.rotations[hi][i]);
    bone.quaternion.copy(q0).slerp(q1, u).normalize();
  });
  bones[0].position.fromArray(clip.hips[lo]).lerp(vector.fromArray(clip.hips[hi]), u);
  model.updateMatrixWorld(true);
}

function support(side) {
  const c = data.clips[selected];
  if (c.duty) return ((time / c.duration + (side ? .5 : 0)) % 1) <= c.duty;
  if (selected.startsWith('jump')) return false;
  if (selected.startsWith('dodge')) {
    const lead = c.lead === (side ? 'R' : 'L');
    return time <= c[lead ? 'lead_lift' : 'trail_lift'] || time >= c[lead ? 'lead_land' : 'trail_land'];
  }
  return true;
}

function fistPoint(side) {
  const hand = bones[data.bones.indexOf(`hand.${side}`)];
  return hand.localToWorld(new THREE.Vector3(0, .075, 0));
}

function buildTrail() {
  if (!selected.startsWith('attack')) {
    trajectory.visible = impactDot.visible = false;
    return;
  }
  const c = data.clips[selected], points = [];
  for (let i = 0; i <= 70; i++) {
    samplePose(selected, c.duration * i / 70);
    points.push(fistPoint(c.side));
  }
  trajectory.geometry.dispose();
  trajectory.geometry = new THREE.BufferGeometry().setFromPoints(points);
  samplePose(selected, c.impact);
  impactDot.position.copy(fistPoint(c.side));
  trajectory.visible = impactDot.visible = $('trail').checked;
  samplePose(selected, time);
}

function selectClip(name) {
  if (!data?.clips[name]) return;
  selected = name;
  time = 0;
  playing = true;
  const [_, title, description] = CATALOG.find((item) => item[0] === name);
  $('clip-title').textContent = title;
  $('clip-description').textContent = description;
  $('clip-code').textContent = name.toUpperCase().replaceAll('_', ' ');
  $('clip-number').textContent = `${String(CATALOG.findIndex((item) => item[0] === name) + 1).padStart(2, '0')} / ${CATALOG.length}`;
  const c = data.clips[name];
  $('duration').textContent = `${c.duration.toFixed(2)} с`;
  $('end-time').textContent = `${c.duration.toFixed(2)} с`;
  $('loop').textContent = c.loop ? 'Цикл' : 'Однократно';
  $('stride').textContent = c.stride ? `${c.stride.toFixed(2)} м` : '—';
  $('timeline').max = c.duration;
  $('phase-note').textContent = c.impact ? `Контакт: ${c.impact.toFixed(2)} с` : c.loop ? 'Зацикленная анимация' : 'Одиночное действие';
  document.querySelectorAll('.clip-button').forEach((button) => button.classList.toggle('active', button.dataset.clip === name));
  samplePose(name, 0);
  buildTrail();
  appearance?.setHands(name.endsWith("_relaxed") ? 1 : 0);
  appearance?.reset();
  updateUI();
}

function updateUI() {
  const c = data.clips[selected];
  $('timeline').value = time;
  $('timeline').style.setProperty('--progress', `${time / c.duration * 100}%`);
  $('current-time').textContent = `${time.toFixed(2)} с`;
  $('frame').textContent = `${String(Math.round(time * data.fps)).padStart(3, '0')} / ${Math.round(c.duration * data.fps)}`;
  $('play').textContent = playing ? 'Ⅱ' : '▶';
  $('play').setAttribute('aria-label', playing ? 'Пауза' : 'Воспроизвести');
  let phase = 'ДЫХАНИЕ / ЗАЩИТА';
  if (c.impact) phase = time < c.windup ? 'ПОДГОТОВКА / РАЗГОН' : time <= c.active_end ? 'КОНТАКТ / АКТИВНАЯ ФАЗА' : 'ВОЗВРАТ В ЗАЩИТУ';
  else if (c.duty) phase = `${support(0) ? 'ЛЕВАЯ: ОПОРА' : 'ЛЕВАЯ: ПЕРЕНОС'} · ${support(1) ? 'ПРАВАЯ: ОПОРА' : 'ПРАВАЯ: ПЕРЕНОС'}`;
  else if (selected !== 'guard') phase = CATALOG.find((item) => item[0] === selected)[1].toUpperCase();
  $('phase-label').textContent = phase;
}

function seek(value) {
  time = THREE.MathUtils.clamp(value, 0, data.clips[selected].duration);
  playing = false;
  samplePose(selected, time);
  appearance?.setHands(selected.endsWith("_relaxed") ? 1 : 0);
  appearance?.reset();
  updateUI();
}

$('timeline').addEventListener('input', (event) => seek(Number(event.target.value)));
$('play').addEventListener('click', () => {
  if (!data) return;
  if (time >= data.clips[selected].duration) time = 0;
  playing = !playing;
  updateUI();
});
$('speed').addEventListener('change', (event) => { speed = Number(event.target.value); });
$('prev-frame').addEventListener('click', () => data && seek(time - 1 / data.fps));
$('next-frame').addEventListener('click', () => data && seek(time + 1 / data.fps));
$('clothes').addEventListener('change', (event) => appearance?.setVisible(event.target.checked));
$('outfit').addEventListener('change', (event) => appearance?.setOutfit(event.target.value));
$('skeleton').addEventListener('change', (event) => { if (helper) helper.visible = event.target.checked; });
$('trail').addEventListener('change', () => data && buildTrail());
document.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => setView(button.dataset.view)));
window.addEventListener('keydown', (event) => {
  if (!data || ['INPUT', 'SELECT', 'TEXTAREA'].includes(event.target.tagName)) return;
  if (event.code === 'Space') { event.preventDefault(); $('play').click(); }
  if (event.code === 'ArrowLeft' || event.code === 'ArrowRight') {
    event.preventDefault(); seek(time + (event.code === 'ArrowRight' ? 1 : -1) / data.fps);
  }
});

const observer = new ResizeObserver(([entry]) => {
  const { width, height } = entry.contentRect;
  if (width < 1 || height < 1) return;
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
  renderer.setSize(width, height);
});
observer.observe($('viewport'));

function render(now) {
  requestAnimationFrame(render);
  const dt = Math.min((now - last) / 1000, .08);
  last = now;
  if (data && model) {
    const c = data.clips[selected];
    if (playing) {
      time += dt * speed;
      if (c.loop) time %= c.duration;
      else if (time >= c.duration) { time = c.duration; playing = false; }
    }
    samplePose(selected, time);
    if (playing) appearance?.update(dt*speed);
    footMarkers.forEach((marker, i) => {
      const foot = bones[data.bones.indexOf(`foot.${i ? 'R' : 'L'}`)];
      foot.getWorldPosition(vector);
      marker.position.set(vector.x, .006, vector.z + .045);
      marker.material.color.set(support(i) ? '#90e5bf' : '#cb9870');
      marker.material.opacity = support(i) ? .9 : .35;
      marker.visible = $('contacts').checked;
    });
    updateUI();
  }
  controls.update();
  renderer.render(scene, camera);
}
requestAnimationFrame(render);

async function load() {
  const [response, gltf] = await Promise.all([fetch(MOTION_URL), new GLTFLoader().loadAsync(MODEL_URL)]);
  if (!response.ok) throw new Error(`Не удалось загрузить motion_set.json (${response.status})`);
  data = await response.json();
  model = gltf.scene;
  const byName = new Map();
  model.traverse((object) => {
    const association = gltf.parser.associations.get(object);
    const originalName = association?.nodes === undefined ? undefined : gltf.parser.json.nodes[association.nodes].name;
    if (originalName) byName.set(originalName, object);
    if (object.isMesh) {
      object.castShadow = true;
      object.receiveShadow = false;
      if (object.name.includes('body')) object.material = new THREE.MeshStandardMaterial({ color: '#a8bbc5', roughness: .8, metalness: .04 });
    }
  });
  bones = data.bones.map((name) => byName.get(name));
  if (bones.some((bone) => !bone)) throw new Error('Риг модели не соответствует набору анимаций.');
  scene.add(model);
  const uniform = await (await fetch("/assets/heroine/appearance/lab_uniform.json")).json();
  appearance = new Appearance(model, data.bones, uniform);
  helper = new THREE.SkeletonHelper(model);
  helper.material.color.set('#b5efd8');
  helper.material.depthTest = false;
  helper.material.transparent = true;
  helper.material.opacity = .65;
  helper.visible = false;
  scene.add(helper);
  CATALOG.forEach(([name, title, , section, icon]) => {
    const button = document.createElement('button');
    button.className = 'clip-button';
    button.dataset.clip = name;
    button.innerHTML = `<span class="clip-icon">${icon}</span><span>${title}</span><span class="clip-length">${data.clips[name].duration.toFixed(2)}</span>`;
    button.addEventListener('click', () => selectClip(name));
    $(section).appendChild(button);
  });
  $('clip-count').textContent = `${CATALOG.length} КЛИПОВ`;
  selectClip('idle_relaxed');
  $('load-state').classList.add('hidden');
  window.motionLab = {
    select: selectClip, seek, setView, setOutfit: (value) => appearance.setOutfit(value),
    get appearance() { return { outfit: appearance.outfit, suitVertices: appearance.suit.geometry.attributes.position.count, bodyIndices: appearance.body.geometry.index.count, handOpen: appearance.handOpen, handVertices: appearance.handVertices, gownVertices: appearance.gown.geometry.attributes.position.count, gownIndexCount: appearance.gown.geometry.index.count, cloth: appearance.points.map((p) => p.toArray()) }; },
    get state() { return { selected, time, playing, clips: Object.keys(data.clips) }; },
    get joints() { return data.bones.map((name, i) => ({ name, position: bones[i].getWorldPosition(new THREE.Vector3()).toArray() })); },
    // Tests can pause/seek the exact source clips without synthesizing input events.
    get ready() { return true; },
  };
}
load().catch((error) => {
  console.error(error);
  $('load-state').className = 'error';
  $('load-state').textContent = `Просмотрщик не загрузился.\n${error.message}\nЗапуск: npm install && npm run dev`;
});
