// Diagnostic mirror of character_appearance.gd. Same generated garment,
// relaxed-hand deltas and analytic collision shapes. Native review recordings
// can supply the actual Godot cloth vertices via applyRecorded().
import * as THREE from 'three';

const vector = (p) => new THREE.Vector3(...p);
const fabric = new THREE.MeshStandardMaterial({ color: '#ffffff', vertexColors: true,
  roughness: .96, side: THREE.DoubleSide });

export class Appearance {
  constructor(model, boneNames, data) {
    this.model = model; this.data = data; this.boneNames = boneNames;
    model.traverse((object) => { if (object.isSkinnedMesh && object.name.includes('body')) this.body = object; });
    if (!this.body) throw new Error('Appearance: body not found');
    const body = this.body;
    body.geometry = body.geometry.clone();
    const g = body.geometry, pos = g.attributes.position, norm = g.attributes.normal;
    const dp = new Float32Array(pos.count*3), dn = new Float32Array(pos.count*3);
    let matched = 0;
    for (const row of data.hands.rows) {
      const i = row[12];
      if (i >= pos.count) throw new Error('Source GLB hand index mismatch');
      dp.set(row.slice(6, 9), i*3);
      dn.set(row.slice(9, 12).map((value, j) => value-norm.getComponent(i, j)), i*3); matched++;
    }
    if (matched < 2500) throw new Error(`Only ${matched} hand vertices matched`);
    this.handVertices = matched;
    g.morphTargetsRelative = true;
    g.morphAttributes.position = [new THREE.BufferAttribute(dp, 3)];
    g.morphAttributes.normal = [new THREE.BufferAttribute(dn, 3)];
    body.updateMorphTargets();
    this.fullIndex = g.index.clone();
    const hide = [];
    for (let i = 0; i < pos.count; i++) {
      let axial = 0;
      for (let j = 0; j < 4; j++) {
        const name = boneNames[g.attributes.skinIndex.getComponent(i, j)];
        if (['hips', 'spine', 'chest', 'neck'].includes(name) || name.startsWith('thigh.')) axial += g.attributes.skinWeight.getComponent(i, j);
      }
      hide.push(pos.getY(i) > .78 && pos.getY(i) < 1.355 && axial > .8);
    }
    const kept = [];
    for (let i = 0; i < g.index.count; i += 3) {
      const a = g.index.getX(i), b = g.index.getX(i+1), c = g.index.getX(i+2);
      if (!(hide[a] && hide[b] && hide[c])) kept.push(a, b, c);
    }
    g.setIndex(kept); this.coveredIndex = g.index.clone();
    const source = data.gown, gownGeometry = new THREE.BufferGeometry();
    if (!source.indices.every(Number.isInteger)) throw new Error('Garment indices must be a flat integer array');
    for (const [name, values, width] of [['position', source.positions, 3], ['normal', source.normals, 3],
      ['color', source.colors, 3], ['uv', source.uv, 2], ['skinWeight', source.weights, 4]]) {
      gownGeometry.setAttribute(name, new THREE.Float32BufferAttribute(values.flat(), width));
    }
    gownGeometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(source.joints.flat(), 4));
    gownGeometry.setIndex(source.indices);
    this.material = fabric.clone();
    this.gown = new THREE.SkinnedMesh(gownGeometry, this.material);
    this.gown.name = 'LabGown'; this.gown.castShadow = true; this.gown.frustumCulled = false;
    this.gown.position.copy(body.position); this.gown.quaternion.copy(body.quaternion); this.gown.scale.copy(body.scale);
    body.parent.add(this.gown); this.gown.bind(body.skeleton, body.bindMatrix);

    const cloth = data.cloth;
    this.rest = cloth.positions.map(vector); this.segments = cloth.segments;
    this.indices = [];
    for (let row = 0; row < cloth.rings-1; row++) for (let k = 0; k < cloth.segments; k++) {
      const a = row*cloth.segments+k, b = row*cloth.segments+(k+1)%cloth.segments;
      this.indices.push(a, b, a+cloth.segments, b, b+cloth.segments, a+cloth.segments);
    }
    this.clothGeometry = new THREE.BufferGeometry();
    this.clothGeometry.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(this.rest.length*3), 3));
    const colors = this.rest.map((_, i) => Math.floor(i/cloth.segments) === cloth.rings-1 ? cloth.binding : cloth.fabric);
    this.clothGeometry.setAttribute('color', new THREE.Float32BufferAttribute(colors.flat(), 3));
    this.clothGeometry.setIndex(this.indices);
    this.skirt = new THREE.Mesh(this.clothGeometry, this.material); this.skirt.name = 'LabGownSkirt';
    this.skirt.castShadow = true; this.skirt.frustumCulled = false; body.parent.add(this.skirt);
    this.hipsInverseBind = new THREE.Matrix4().set(
      ...[0, 1, 2].flatMap((i) => [...data.hips_inverse_bind[i], data.hips_inverse_bind[3][i]]), 0, 0, 0, 1);
    this.capsules = cloth.capsules.map(([a, b, radius]) => [body.skeleton.bones[boneNames.indexOf(a)], body.skeleton.bones[boneNames.indexOf(b)], radius+cloth.thickness]);
    this.points = []; this.previous = []; this.accumulator = 0; this.reset();
  }
  setHands(amount) { this.handOpen = THREE.MathUtils.clamp(amount, 0, 1); this.body.morphTargetInfluences[0] = this.handOpen; }
  setVariant(clone) { this.material.color.setRGB(...(clone ? [.78, .87, .93] : [1, 1, 1])); }
  setVisible(visible) {
    this.gown.visible = this.skirt.visible = visible;
    this.body.geometry.setIndex(visible ? this.coveredIndex : this.fullIndex);
  }
  transforms() {
    this.model.updateMatrixWorld(true);
    this.hips = this.body.skeleton.bones[this.boneNames.indexOf('hips')].matrixWorld.clone().multiply(this.hipsInverseBind);
    this.hipsInverse = this.hips.clone().invert();
    this.colliders = this.capsules.map(([a, b, radius]) => [a.getWorldPosition(new THREE.Vector3()), b.getWorldPosition(new THREE.Vector3()), radius]);
  }
  capsuleFar(origin, dir, [a, b, radius]) {
    if (origin.y < Math.min(a.y, b.y)-radius-Math.abs(dir.y) || origin.y > Math.max(a.y, b.y)+radius+Math.abs(dir.y)) return -1;
    const axis = b.clone().sub(a), relative = origin.clone().sub(a), lengthSquared = axis.lengthSq();
    const projectedDirection = axis.dot(dir), projectedOrigin = axis.dot(relative);
    const aa = lengthSquared-projectedDirection**2, bb = lengthSquared*dir.dot(relative)-projectedOrigin*projectedDirection;
    const cc = lengthSquared*(relative.lengthSq()-radius**2)-projectedOrigin**2, determinant = bb*bb-aa*cc;
    let result = -1;
    for (const center of [a, b]) {
      const rel = origin.clone().sub(center), along = dir.dot(rel), discriminant = along**2-rel.lengthSq()+radius**2;
      if (discriminant >= 0) result = Math.max(result, -along+Math.sqrt(discriminant));
    }
    if (aa > .000001 && determinant >= 0) {
      const far = (-bb+Math.sqrt(determinant))/aa, at = projectedOrigin+far*projectedDirection;
      if (at >= 0 && at <= lengthSquared) result = Math.max(result, far);
    }
    return result;
  }
  collide(p) {
    const local = p.clone().applyMatrix4(this.hipsInverse), radial = new THREE.Vector3(local.x, 0, local.z-.02);
    const distance = radial.length();
    if (distance < .00001) radial.set(0, 0, -1); else radial.divideScalar(distance);
    const origin = new THREE.Vector3(0, local.y, .02).applyMatrix4(this.hips), direction = radial.clone().transformDirection(this.hips);
    const dy = (local.y-.89)/.145;
    let minimum = Math.abs(dy) < 1 ? Math.sqrt((1-dy*dy)/(radial.x**2/.202**2+radial.z**2/.137**2)) : 0;
    for (const collider of this.colliders) minimum = Math.max(minimum, this.capsuleFar(origin, direction, collider));
    if (distance < minimum) p.copy(origin.addScaledVector(direction, minimum));
    return p;
  }
  fitGoals() {
    this.goals = this.rest.map((p, i) => { const goal = p.clone().applyMatrix4(this.hips); return i < this.segments ? goal : this.collide(goal); });
  }
  reset() {
    this.transforms(); this.accumulator = 0; this.fitGoals();
    this.points = this.goals.map((p) => p.clone());
    this.previous = this.points.map((p) => p.clone()); this.upload();
  }
  update(delta) {
    this.transforms(); this.fitGoals(); this.accumulator += Math.min(delta, .05);
    const h = this.data.cloth.step;
    let stepped = false;
    while (this.accumulator >= h) {
      this.accumulator -= h; stepped = true;
      this.points.forEach((p, i) => {
        const goal = this.goals[i];
        if (i < this.segments) { p.copy(goal); this.previous[i].copy(goal); return; }
        const velocity = p.clone().sub(this.previous[i]).multiplyScalar(.985);
        this.previous[i].copy(p);
        p.add(velocity).addScaledVector(goal.clone().sub(p).multiplyScalar(65).add(new THREE.Vector3(0, -3, 0)), h*h);
      });
      for (let iteration = 0; iteration < this.data.cloth.iterations; iteration++) {
        for (const [a, b, rest, strength] of this.data.cloth.edges) {
          const difference = this.points[b].clone().sub(this.points[a]), length = difference.length(), error = length-rest;
          difference.multiplyScalar(error/Math.max(length, .00001)*strength*(error < 0 ? .18 : 1));
          const wa = a < this.segments ? 0 : 1, wb = b < this.segments ? 0 : 1;
          if (wa+wb) { this.points[a].addScaledVector(difference, wa/(wa+wb)); this.points[b].addScaledVector(difference, -wb/(wa+wb)); }
        }
      }
      this.projectPoints();
    }
    if (!stepped) this.projectPoints();
    this.upload();
  }
  projectPoints() {
    for (let i = 0; i < this.segments; i++) { this.points[i].copy(this.goals[i]); this.previous[i].copy(this.goals[i]); }
    for (let i = this.segments; i < this.points.length; i++) {
      const offset = this.points[i].clone().sub(this.goals[i]), maximum = this.data.cloth.max_secondary_offset;
      if (offset.lengthSq() > maximum**2) this.points[i].copy(this.goals[i]).add(offset.normalize().multiplyScalar(maximum));
      this.collide(this.points[i]);
    }
  }
  upload() {
    const inverse = this.skirt.parent.matrixWorld.clone().invert(), attr = this.clothGeometry.attributes.position;
    this.points.forEach((p, i) => { const local = p.clone().applyMatrix4(inverse); attr.setXYZ(i, local.x, local.y, local.z); });
    attr.needsUpdate = true; this.clothGeometry.computeVertexNormals();
  }
  applyRecorded(frame) {
    this.setHands(frame.hand_open);
    if (!frame.cloth) { this.reset(); return; }
    // Recorder stores garment vertices in the character/rig coordinate frame.
    const attr = this.clothGeometry.attributes.position;
    frame.cloth.forEach((p, i) => attr.setXYZ(i, ...p)); attr.needsUpdate = true;
    this.clothGeometry.computeVertexNormals();
  }
}
