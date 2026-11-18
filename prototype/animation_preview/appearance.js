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
      let axial = 0, arm = 0;
      for (let j = 0; j < 4; j++) {
        const name = boneNames[g.attributes.skinIndex.getComponent(i, j)];
        if (['hips', 'spine', 'chest', 'neck'].includes(name) || name.startsWith('thigh.')) axial += g.attributes.skinWeight.getComponent(i, j);
        if (['upper_arm.', 'forearm.', 'hand.', 'shoulder.'].some((prefix) => name.startsWith(prefix))) arm += g.attributes.skinWeight.getComponent(i, j);
      }
      const insideSleeve = (data.coverage?.sleeves ?? []).some((sleeve) => {
        const relative = new THREE.Vector3().fromBufferAttribute(pos, i).sub(vector(sleeve.origin));
        const axis = vector(sleeve.axis), along = relative.dot(axis);
        return along >= sleeve.start && along <= sleeve.end && relative.addScaledVector(axis, -along).length() < sleeve.radius;
      });
      const insideCore = (data.coverage?.underarm_cores ?? []).some((core) => {
        const relative = new THREE.Vector3().fromBufferAttribute(pos, i).sub(vector(core.origin));
        const axis = vector(core.axis), along = relative.dot(axis);
        return along >= core.start && along <= core.end && relative.addScaledVector(axis, -along).length() < core.radius;
      });
      // Keep the real arm below the closed proximal axillary core; its
      // cutoff is 53 mm INSIDE the cuff, not at the visible sleeve opening.
      hide.push(insideCore || (!data.coverage?.preserve_limbs && insideSleeve) ||
        (pos.getY(i) > .74 && pos.getY(i) < 1.355 && axial > .8 && (!data.coverage?.preserve_limbs || arm < (data.coverage.arm_weight_threshold ?? .15))));
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
      this.indices.push(a, a+cloth.segments, b, b, a+cloth.segments, b+cloth.segments);
    }
    this.clothGeometry = new THREE.BufferGeometry();
    this.clothGeometry.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(this.rest.length*3), 3));
    this.clothGeometry.setAttribute('normal', new THREE.Float32BufferAttribute(new Float32Array(this.rest.length*3), 3));
    this.waistNormals = source.waist_normals.map(vector);
    const colors = this.rest.map((_, i) => Math.floor(i/cloth.segments) === cloth.rings-1 ? cloth.binding : cloth.fabric);
    this.clothGeometry.setAttribute('color', new THREE.Float32BufferAttribute(colors.flat(), 3));
    this.clothGeometry.setIndex(this.indices);
    this.skirt = new THREE.Mesh(this.clothGeometry, this.material); this.skirt.name = 'LabGownSkirt';
    this.skirt.castShadow = true; this.skirt.frustumCulled = false; body.parent.add(this.skirt);
    this.hipsInverseBind = new THREE.Matrix4().set(
      ...[0, 1, 2].flatMap((i) => [...data.hips_inverse_bind[i], data.hips_inverse_bind[3][i]]), 0, 0, 0, 1);
    this.capsules = cloth.capsules.map(([a, b, radius, start]) => [body.skeleton.bones[boneNames.indexOf(a)], body.skeleton.bones[boneNames.indexOf(b)], radius+cloth.thickness+(cloth.surface_margin ?? 0), start]);
    this.points = []; this.previous = []; this.accumulator = 0; this.reset();
  }
  setHands(amount) { this.handOpen = THREE.MathUtils.clamp(amount, 0, 1); this.body.morphTargetInfluences[0] = this.handOpen; }
  setVariant(clone) { this.material.color.setRGB(...(clone ? [.94, .96, 1.0] : [1, 1, 1])); }
  setVisible(visible) {
    this.gown.visible = this.skirt.visible = visible;
    this.body.geometry.setIndex(visible ? this.coveredIndex : this.fullIndex);
  }
  transforms() {
    this.model.updateMatrixWorld(true);
    this.hips = this.body.skeleton.bones[this.boneNames.indexOf('hips')].matrixWorld.clone().multiply(this.hipsInverseBind);
    this.hipsInverse = this.hips.clone().invert();
    this.colliders = this.capsules.map(([a, b, radius, start]) => {const first=a.getWorldPosition(new THREE.Vector3()).applyMatrix4(this.hipsInverse), last=b.getWorldPosition(new THREE.Vector3()).applyMatrix4(this.hipsInverse);return [first.lerp(last,start),last,radius];});
  }
  capsuleFar(origin, dir, [a, b, radius]) {
    if (origin.y < Math.min(a.y, b.y)-radius-Math.abs(dir.y) || origin.y > Math.max(a.y, b.y)+radius+Math.abs(dir.y)) return -1;
    const axis = b.clone().sub(a), relative = origin.clone().sub(a), lengthSquared = axis.lengthSq();
    const projectedDirection = axis.dot(dir), projectedOrigin = axis.dot(relative);
    const aa = lengthSquared-projectedDirection**2, bb = lengthSquared*dir.dot(relative)-projectedOrigin*projectedDirection;
    const cc = lengthSquared*(relative.lengthSq()-radius**2)-projectedOrigin**2, determinant = bb*bb-aa*cc;
    const sphere=(center)=>{const rel=origin.clone().sub(center),along=dir.dot(rel),disc=along**2-rel.lengthSq()+radius**2;return disc>=0?-along+Math.sqrt(disc):-1;};
    if(aa>.000001){
      if(determinant<0)return -1;
      const far=(-bb+Math.sqrt(determinant))/aa;
      if(far<=0)return -1;
      const at=projectedOrigin+far*projectedDirection;
      return at>=0&&at<=lengthSquared?far:sphere(at<0?a:b);
    }
    return Math.max(sphere(a),sphere(b));
  }

  surfaceMinimum(local) {
    const radial = new THREE.Vector3(local.x, 0, local.z-.02).normalize();
    const origin = new THREE.Vector3(0, local.y, .02), dy = (local.y-.89)/.145;
    let minimum = Math.abs(dy) < 1 ? Math.sqrt((1-dy*dy)/(radial.x**2/.187**2+radial.z**2/.124**2)) : 0;
    for (const collider of this.colliders) minimum = Math.max(minimum, this.capsuleFar(origin, radial, collider));
    return minimum;
  }
  fitGoals() {
    const segments=this.segments, rings=this.data.cloth.rings;
    const radii = this.rest.map((p, i) => i < segments ? Math.hypot(p.x,p.z-.02) :
      Math.max(Math.hypot(p.x,p.z-.02),this.surfaceMinimum(p)+.0001));
    // Contact at quad centres, not just at the old sparse particles. A
    // half-cell knee bulge supports all four corners of its displayed faces.
    const factor=1/Math.cos(Math.PI/segments);
    for(let row=0;row<rings-1;row++)for(let k=0;k<segments;k++){
      const ids=[row*segments+k,row*segments+(k+1)%segments,(row+1)*segments+k,(row+1)*segments+(k+1)%segments];
      const mid=new THREE.Vector3();ids.forEach(i=>mid.add(this.rest[i]));mid.multiplyScalar(.25);
      let minimum=this.surfaceMinimum(mid)*factor+.0015;
      if(row===0)minimum=Math.max(minimum,2*minimum-(Math.hypot(this.rest[k].x,this.rest[k].z-.02)+Math.hypot(this.rest[(k+1)%segments].x,this.rest[(k+1)%segments].z-.02))*.5);
      for(const i of ids)if(i>=segments)radii[i]=Math.max(radii[i],minimum);
    }
    // Only a local bend spread. The previous max-dilation propagated a knee
    // around half the circumference and down to the hem: the rigid umbrella.
    for(let pass=0;pass<2;pass++){
      const source=radii.slice();
      for(let row=1;row<rings;row++)for(let k=0;k<segments;k++){
        const i=row*segments+k;
        radii[i]=Math.max(source[i],source[row*segments+(k+segments-1)%segments]*.18+source[i]*.64+source[row*segments+(k+1)%segments]*.18);
      }
    }
    this.goals=this.rest.map((p,i)=>{
      const radial=new THREE.Vector3(p.x,0,p.z-.02).normalize();
      return new THREE.Vector3(radial.x*radii[i],p.y,.02+radial.z*radii[i]).applyMatrix4(this.hips);
    });
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
        const velocity = p.clone().sub(this.previous[i]).multiplyScalar(.92);
        const force = goal.clone().sub(p).multiplyScalar(65).add(new THREE.Vector3(0, -3, 0));
        this.previous[i].copy(p);
        p.add(velocity).addScaledVector(force, h*h);
      });
      this.projectPoints();
    }
    if (!stepped) this.projectPoints();
    this.upload();
  }
  projectPoints() {
    for (let i = 0; i < this.segments; i++) { this.points[i].copy(this.goals[i]); this.previous[i].copy(this.goals[i]); }
    for (let i = this.segments; i < this.points.length; i++) {
      const local = this.points[i].clone().applyMatrix4(this.hipsInverse);
      const radial = new THREE.Vector3(this.rest[i].x, 0, this.rest[i].z-.02).normalize();
      const goal = this.goals[i].clone().applyMatrix4(this.hipsInverse);
      const minimum = Math.hypot(goal.x, goal.z-.02);
      const radius = THREE.MathUtils.clamp(new THREE.Vector3(local.x, 0, local.z-.02).dot(radial), minimum, minimum+this.data.cloth.max_secondary_offset);
      this.points[i].set(radial.x*radius, this.rest[i].y, .02+radial.z*radius).applyMatrix4(this.hips);
    }
  }
  upload() {
    const inverse = this.skirt.parent.matrixWorld.clone().invert(), attr = this.clothGeometry.attributes.position;
    this.points.forEach((p, i) => { const local = p.clone().applyMatrix4(inverse); attr.setXYZ(i, local.x, local.y, local.z); });
    attr.needsUpdate = true; this.updateNormals();
  }
  updateNormals() {
    const pos = this.clothGeometry.attributes.position, normals = this.clothGeometry.attributes.normal;
    const rows = this.data.cloth.rings, segments = this.segments;
    const tangent = new THREE.Vector3(), vertical = new THREE.Vector3(), other = new THREE.Vector3();
    const toLocal = this.skirt.parent.matrixWorld.clone().invert().multiply(this.hips);
    for (let row = 0; row < rows; row++) for (let k = 0; k < segments; k++) {
      const i = row*segments+k;
      tangent.fromBufferAttribute(pos, row*segments+(k+1)%segments).sub(other.fromBufferAttribute(pos, row*segments+(k+segments-1)%segments));
      vertical.fromBufferAttribute(pos, Math.min(row+1, rows-1)*segments+k).sub(other.fromBufferAttribute(pos, Math.max(row-1, 0)*segments+k));
      const n = row === 0 ? other.copy(this.waistNormals[k]).transformDirection(toLocal) : vertical.cross(tangent).normalize();
      normals.setXYZ(i, n.x, n.y, n.z);
    }
    normals.needsUpdate = true;
  }
  applyRecorded(frame) {
    this.setHands(frame.hand_open);
    if (!frame.cloth) { this.reset(); return; }
    // Recorder stores garment vertices in the character/rig coordinate frame.
    const attr = this.clothGeometry.attributes.position;
    frame.cloth.forEach((p, i) => attr.setXYZ(i, ...p)); attr.needsUpdate = true;
    this.transforms(); this.updateNormals();
  }
}
