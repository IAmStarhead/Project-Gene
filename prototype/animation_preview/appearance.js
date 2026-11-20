// Diagnostic mirror of character_appearance.gd. Same generated garment,
// relaxed-hand deltas and analytic collision shapes. Native review recordings
// can supply the actual Godot cloth vertices via applyRecorded().
import * as THREE from 'three';

const vector = (p) => new THREE.Vector3(...p);
const fabric = new THREE.MeshStandardMaterial({ color: '#ffffff', vertexColors: true,
  roughness: .96, side: THREE.DoubleSide });

export class Appearance {
  constructor(model, boneNames, data) {
    this.model = model; this.data = data; this.boneNames = boneNames; this.outfit = "dress"; this.visible = true;
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

    const suitGeometry = new THREE.BufferGeometry(), suitSource = data.suit;
    for (const [name, key, width] of [['position', 'positions', 3], ['normal', 'normals', 3], ['color', 'colors', 3], ['uv', 'uv', 2], ['skinWeight', 'weights', 4]])
      suitGeometry.setAttribute(name, new THREE.Float32BufferAttribute(suitSource[key].flat(), width));
    suitGeometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(suitSource.joints.flat(), 4));
    suitGeometry.setIndex(suitSource.indices);
    this.suit = new THREE.SkinnedMesh(suitGeometry, this.material);
    this.suit.name = 'LabTopAndTrousers'; this.suit.castShadow = true; this.suit.frustumCulled = false;
    this.suit.position.copy(body.position); this.suit.quaternion.copy(body.quaternion); this.suit.scale.copy(body.scale);
    body.parent.add(this.suit); this.suit.bind(body.skeleton, body.bindMatrix); this.suit.visible = false;
    const c = suitSource.coverage, hideSuit = [];
    for (let i = 0; i < pos.count; i++) {
      let arm = 0; const forearm = [0, 0];
      for (let k = 0; k < 4; k++) {
        const name = boneNames[g.attributes.skinIndex.getComponent(i, k)], w = g.attributes.skinWeight.getComponent(i, k);
        if (['shoulder.', 'upper_arm.', 'forearm.', 'hand.'].some((prefix) => name.startsWith(prefix))) arm += w;
        if (['forearm.L', 'hand.L'].includes(name)) forearm[0] += w;
        if (['forearm.R', 'hand.R'].includes(name)) forearm[1] += w;
      }
      const point = new THREE.Vector3().fromBufferAttribute(pos, i);
      hideSuit.push(arm < .15 ? point.y > c.ankle+c.skin_overlap && point.y < c.neck-c.skin_overlap
        : arm >= .85 && !c.wrists.some((w, side) => forearm[side] > .2 && point.clone().sub(vector(w.origin)).dot(vector(w.axis)) > w.end-c.skin_overlap));
    }
    const keptSuit = [];
    for (let i = 0; i < this.fullIndex.count; i += 3) {
      const ids = [0, 1, 2].map((j) => this.fullIndex.getX(i+j));
      if (!ids.every((id) => hideSuit[id])) keptSuit.push(...ids);
    }
    this.suitIndex = new THREE.Uint32BufferAttribute(keptSuit, 1);

    const cloth = data.cloth;
    this.rest = cloth.positions.map(vector); this.segments = cloth.segments;
    this.circumferenceCoordinates=[];
    for(let row=0;row<cloth.rings;row++){
      let distance=0;
      for(let k=0;k<cloth.segments;k++){
        this.circumferenceCoordinates.push(distance/cloth.circumferences[row]);
        distance+=this.rest[row*cloth.segments+k].distanceTo(this.rest[row*cloth.segments+(k+1)%cloth.segments]);
      }
    }
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
    this.capsules = cloth.capsules.map(([a, b, radius, start, end]) => [body.skeleton.bones[boneNames.indexOf(a)], body.skeleton.bones[boneNames.indexOf(b)], radius+cloth.thickness+cloth.surface_margin, start, end]);
    this.points = []; this.previous = []; this.accumulator = 0; this.reset();
  }
  setHands(amount) { this.handOpen = THREE.MathUtils.clamp(amount, 0, 1); this.body.morphTargetInfluences[0] = this.handOpen; }
  setVariant(clone) { this.material.color.setRGB(...(clone ? [.94, .96, 1.0] : [1, 1, 1])); }
  setOutfit(outfit) {
    this.outfit = outfit === 'suit' ? 'suit' : 'dress';
    this.setVisible(this.visible);
    if (this.outfit === 'dress') this.reset();
  }
  setVisible(visible) {
    this.visible = visible;
    this.gown.visible = this.skirt.visible = visible && this.outfit === 'dress';
    this.suit.visible = visible && this.outfit === 'suit';
    this.body.geometry.setIndex(visible ? (this.outfit === 'suit' ? this.suitIndex : this.coveredIndex) : this.fullIndex);
  }
  transforms() {
    this.model.updateMatrixWorld(true);
    this.hips = this.body.skeleton.bones[this.boneNames.indexOf('hips')].matrixWorld.clone().multiply(this.hipsInverseBind);
    this.hipsInverse = this.hips.clone().invert();
    this.colliders = this.capsules.map(([a, b, radius, start, end]) => {const first=a.getWorldPosition(new THREE.Vector3()).applyMatrix4(this.hipsInverse), last=b.getWorldPosition(new THREE.Vector3()).applyMatrix4(this.hipsInverse);return [first.clone().lerp(last,start),first.lerp(last,end),radius];});
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

  surfaceMinimum(local, rejectOutside = false) {
    const radial = new THREE.Vector3(local.x, 0, local.z-.02).normalize();
    const origin = new THREE.Vector3(0, local.y, .02), dy = (local.y-.89)/.145;
    let minimum = Math.abs(dy) < 1 ? Math.sqrt((1-dy*dy)/(radial.x**2/.187**2+radial.z**2/.124**2)) : 0;
    for (const collider of this.colliders) {
      if (rejectOutside) {
        // Match native's supporting-plane rejection on FITTED points. Without
        // it each relaxation added another 0.1 mm clearance at tangencies.
        // Raw support-chart rays must still evaluate the complete capsule.
        const [a,b,radius]=collider,axis=b.clone().sub(a);
        const nearest=axis.clone().multiplyScalar(THREE.MathUtils.clamp(local.clone().sub(a).dot(axis)/Math.max(axis.lengthSq(),.000001),0,1)).add(a);
        const normal=local.clone().sub(nearest);
        if(normal.lengthSq()>=radius*radius&&normal.dot(radial)>=0)continue;
      }
      minimum = Math.max(minimum, this.capsuleFar(origin, radial, collider));
    }
    return minimum;
  }
  fitGoals() {
    const c=this.data.cloth, segments=this.segments, rows=c.sample_heights.length;
    const samples=c.sample_positions.map(p=>this.surfaceMinimum(vector(p)));
    let radii=c.drape_positions.map((p,i)=>{
      const row=Math.floor(i/segments), k=i%segments, base=Math.hypot(p[0],p[2]-.02);
      const minimum=row%2===0?samples[i]+.0001:
        Math.max(samples[i],samples[row*segments+(k+segments-1)%segments])/Math.cos(Math.PI/segments)+.0015;
      return row>0?Math.max(base,minimum):base;
    });
    // A calf's upper tangent can enter the support chart BETWEEN rows.
    // Spend arc length above that feature, instead of stretching the final
    // particle radially when it discovers the missed overhang later.
    for (const [a,b,radius] of this.colliders) {
      const axis=b.clone().sub(a), top=Math.max(a.y,b.y)+radius;
      if(top>=c.sample_heights[0]||top<=c.sample_heights.at(-1))continue;
      for(let k=0;k<segments;k++){
        let row=0,along=-1;
        while(row<rows-2&&c.sample_heights[row+1]>=top)row++;
        for(let iteration=0;iteration<2;iteration++){
          const p=c.drape_positions[row*segments+k],d=new THREE.Vector2(p[0],p[2]-.02).normalize();
          const crossA=a.x*d.y-(a.z-.02)*d.x,crossAxis=axis.x*d.y-axis.z*d.x;
          let at=axis.y>0?1:0;
          if(Math.abs(crossAxis)>.000001){
            const target=radius*axis.y*Math.sign(crossAxis)/Math.sqrt(axis.y**2+crossAxis**2);
            at=THREE.MathUtils.clamp((target-crossA)/crossAxis,0,1);
          }
          const transverse=crossA+at*crossAxis;
          if(Math.abs(transverse)>=radius){along=-1;break;}
          const height=a.y+at*axis.y+Math.sqrt(Math.max(0,radius**2-transverse**2));
          along=(a.x+at*axis.x)*d.x+(a.z-.02+at*axis.z)*d.y;
          if(along<=0||height<=c.sample_heights.at(-1)){along=-1;break;}
          row=0;while(row<rows-2&&c.sample_heights[row+1]>=height)row++;
        }
        if(row>0&&along>0)radii[row*segments+k]=Math.max(radii[row*segments+k],along+.0015);
      }
    }
    for(let pass=0;pass<4;pass++){
      const source=radii.slice();
      for(let row=1;row<rows;row++)for(let k=0;k<segments;k++){
        const i=row*segments+k;
        const angular=source[row*segments+(k+segments-1)%segments]*.25+source[i]*.50+source[row*segments+(k+1)%segments]*.25;
        const vertical=source[(row-1)*segments+k]*.20+source[i]*.60+source[Math.min(row+1,rows-1)*segments+k]*.20;
        radii[i]=Math.max(source[i],angular,vertical);
      }
    }
    this.curves=[];this.curveDistances=[];
    for(let k=0;k<segments;k++){
      const curve=[],distance=[0];
      for(let row=0;row<rows;row++){
        const i=row*segments+k, p=c.drape_positions[i], d=new THREE.Vector2(p[0],p[2]-.02).normalize();
        curve.push(new THREE.Vector3(d.x*radii[i],c.sample_heights[row],.02+d.y*radii[i]));
        if(row>0)distance.push(distance[row-1]+curve[row].distanceTo(curve[row-1]));
      }
      this.curves.push(curve);this.curveDistances.push(distance);
    }
    this.goalLocal=[];
    let previousLength=0;
    for(let row=0;row<c.rings;row++){
      const lengths=c.meridian_lengths[row], length=lengths[0];
      let ring=lengths.map((l,k)=>row>0?this.drapePoint(k,l):this.rest[k].clone()), fraction=1;
      const maximum=c.circumferences[row]*c.circumference_soft_limit;
      if(row>0&&this.ringLength(ring)>maximum){
        let low=Math.max(c.min_drape_fraction,Math.min(previousLength/Math.max(length,.000001),1)),high=1;
        ring=lengths.map((l,k)=>this.drapePoint(k,l*low));
        if(this.ringLength(ring)<=maximum)for(let pass=0;pass<5;pass++){
          const mid=(low+high)*.5;ring=lengths.map((l,k)=>this.drapePoint(k,l*mid));
          if(this.ringLength(ring)>maximum)high=mid;else low=mid;
        }
        fraction=low;ring=lengths.map((l,k)=>this.drapePoint(k,l*fraction));
      }
      previousLength=length*fraction;this.goalLocal.push(...ring);
    }
    const hemHeight=Array.from({length:segments},(_,k)=>this.goalLocal[(c.rings-1)*segments+k].y);
    let rounded=hemHeight.slice();
    for(let pass=0;pass<8;pass++){
      const source=rounded.slice();
      rounded=source.map((v,k)=>Math.min(hemHeight[k]+.060,Math.max(v,(source[(k+segments-1)%segments]+source[(k+1)%segments])*.5-.0025)));
    }
    for(let k=0;k<segments;k++){
      const lift=rounded[k]-hemHeight[k];if(lift<.000001)continue;
      for(let row=1;row<c.rings;row++){
        const i=row*segments+k,u=c.meridian_lengths[row][k]/c.meridian_lengths[c.rings-1][k];
        this.goalLocal[i]=this.drapeAtHeight(k,this.goalLocal[i].y+lift*u*u);
      }
    }
    this.goalRadii=this.goalLocal.map((p,i)=>{
      let radius=Math.hypot(p.x,p.z-.02);
      if(i>=segments){
        const minimum=this.surfaceMinimum(p,true)+.0001;
        if(minimum>radius){p.x*=minimum/radius;p.z=.02+(p.z-.02)*minimum/radius;radius=minimum;}
      }
      return radius;
    });
    this.redistributeSurface();
    this.filletSupportedSurface();
    this.goalRadii=this.goalLocal.map(p=>Math.hypot(p.x,p.z-.02));
    this.goals=this.goalLocal.map(p=>p.clone().applyMatrix4(this.hips));
  }
  // Match the native boundary-only fillet. This is an independent live
  // solve, not an interpolation of previously recorded Godot vertices.
  filletSupportedSurface(){
    const c=this.data.cloth,n=this.segments,base=(c.rings-1)*n;
    const original=this.goalLocal.slice(base).map(p=>p.clone());
    const restLap=original.map((_,k)=>this.rest[base+(k+n-1)%n].clone()
      .add(this.rest[base+(k+1)%n]).multiplyScalar(.5).sub(this.rest[base+k]));
    let hem=original.map(p=>p.clone());
    for(let iteration=0;iteration<24;iteration++){
      const source=hem;
      hem=source.map((p,k)=>this.normalClear(p.clone().addScaledVector(
        source[(k+n-1)%n].clone().add(source[(k+1)%n]).multiplyScalar(.5).sub(p).sub(restLap[k]),.5)));
    }
    for(let row=1;row<c.rings;row++)for(let k=0;k<n;k++){
      const i=row*n+k,u=c.meridian_lengths[row][k]/c.meridian_lengths[c.rings-1][k];
      this.goalLocal[i].addScaledVector(hem[k].clone().sub(original[k]),u*u);
    }
    this.clearFilletedSurface();
    for(let iteration=0;iteration<3;iteration++)this.resampleFilletedMeridians();
    for(let iteration=0;iteration<3;iteration++)for(let row=c.rings-2;row>0;row--)for(let k=0;k<n;k++){
      const i=row*n+k;
      if(this.goalLocal[i].y<this.goalLocal[i+n].y+.0002){
        this.goalLocal[i].y=this.goalLocal[i+n].y+.0002;
        this.normalClear(this.goalLocal[i]);
      }
    }
  }
  normalClear(point){
    const dy=(point.y-.89)/.145;
    if(Math.abs(dy)<1){
      const radius=Math.hypot(point.x,point.z-.02),x=point.x/Math.max(radius,.000001),z=(point.z-.02)/Math.max(radius,.000001);
      const minimum=Math.sqrt((1-dy*dy)/(x*x/(.187*.187)+z*z/(.124*.124)));
      if(radius<minimum){point.x=x*minimum;point.z=.02+z*minimum;}
    }
    for(const [a,b,r] of this.colliders){
      const radius=r+.00025;
      if(point.y<Math.min(a.y,b.y)-radius||point.y>Math.max(a.y,b.y)+radius)continue;
      const axis=b.clone().sub(a),at=THREE.MathUtils.clamp(point.clone().sub(a).dot(axis)/Math.max(axis.lengthSq(),.000001),0,1);
      const offset=point.clone().sub(a.clone().addScaledVector(axis,at)),distance=offset.length();
      if(distance<radius)point.addScaledVector(offset,(radius-distance)/Math.max(distance,.000001));
    }
    return point;
  }
  clearFilletedSurface(){
    // The native method batches the same independent projection by capsule.
    this.goalLocal.forEach((p,i)=>{if(i>=this.segments)this.normalClear(p);});
  }
  resampleFilletedMeridians(){
    const c=this.data.cloth,n=this.segments,source=this.goalLocal.map(p=>p.clone()),arc=[];
    for(let k=0;k<n;k++){
      arc[0]=0;
      for(let row=1;row<c.rings;row++)arc[row]=arc[row-1]+source[row*n+k].distanceTo(source[(row-1)*n+k]);
      const fraction=Math.min(1,arc[c.rings-1]/c.meridian_lengths[c.rings-1][k]);let at=1;
      for(let row=1;row<c.rings;row++){
        const length=c.meridian_lengths[row][k]*fraction;
        while(at<c.rings-1&&arc[at]<length)at++;
        const u=THREE.MathUtils.clamp((length-arc[at-1])/Math.max(arc[at]-arc[at-1],.000001),0,1);
        this.goalLocal[row*n+k]=source[(at-1)*n+k].clone().lerp(source[at*n+k],u);
      }
    }
    this.clearFilletedSurface();
  }
  safeSecondary(k,amount){
    if(amount<=.000001||this.secondaryClear(k,amount))return amount;
    let low=0,high=amount;
    for(let iteration=0;iteration<8;iteration++){
      const mid=(low+high)*.5;
      if(this.secondaryClear(k,mid))low=mid;else high=mid;
    }
    return low;
  }
  secondaryClear(k,amount){
    const c=this.data.cloth,n=this.segments;
    for(let row=1;row<c.rings;row++){
      const i=row*n+k,point=this.goalLocal[i].clone(),u=c.meridian_lengths[row][k]/c.meridian_lengths[c.rings-1][k];
      const radial=new THREE.Vector3(point.x,0,point.z-.02).normalize();point.addScaledVector(radial,amount*u*u);
      for(const [a,b,r] of this.colliders){
        const radius=r+.00003;
        if(point.y<Math.min(a.y,b.y)-radius||point.y>Math.max(a.y,b.y)+radius)continue;
        const axis=b.clone().sub(a),at=THREE.MathUtils.clamp(point.clone().sub(a).dot(axis)/Math.max(axis.lengthSq(),.000001),0,1);
        if(point.distanceToSquared(a.clone().addScaledVector(axis,at))<radius*radius)return false;
      }
    }
    return true;
  }
  redistributeSurface(){
    const c=this.data.cloth,segments=this.segments,arc=[];
    for(let iteration=0;iteration<c.surface_relaxations;iteration++){
      if(iteration<c.angular_relaxations){
        this.redistributeRings();
        for(let row=c.rings-2;row>0;row--)for(let k=0;k<segments;k++){
          const i=row*segments+k;this.goalLocal[i].y=Math.max(this.goalLocal[i].y,this.goalLocal[i+segments].y+.00001);
        }
      }
      const source=this.goalLocal.map(p=>p.clone());
      for(let k=0;k<segments;k++){
        arc[0]=0;
        for(let row=1;row<c.rings;row++)arc[row]=arc[row-1]+source[row*segments+k].distanceTo(source[(row-1)*segments+k]);
        const fraction=Math.min(1,arc[c.rings-1]/c.meridian_lengths[c.rings-1][k]);let at=1;
        for(let row=1;row<c.rings;row++){
          const length=c.meridian_lengths[row][k]*fraction;
          while(at<c.rings-1&&arc[at]<length)at++;
          const u=THREE.MathUtils.clamp((length-arc[at-1])/Math.max(arc[at]-arc[at-1],.000001),0,1);
          this.goalLocal[row*segments+k]=source[(at-1)*segments+k].clone().lerp(source[at*segments+k],u);
        }
      }
      this.goalLocal.forEach((p,i)=>{
        if(i<segments)return;
        const radius=Math.hypot(p.x,p.z-.02),minimum=this.surfaceMinimum(p,true)+.0001;
        if(minimum>radius){const factor=minimum/Math.max(radius,.000001);p.x*=factor;p.z=.02+(p.z-.02)*factor;}
      });
    }
  }
  redistributeRings(){
    const c=this.data.cloth,segments=this.segments,source=this.goalLocal.map(p=>p.clone()),arc=[];
    for(let row=1;row<c.rings;row++){
      const base=row*segments;arc[0]=0;
      for(let k=0;k<segments;k++)arc[k+1]=arc[k]+source[base+k].distanceTo(source[base+(k+1)%segments]);
      let at=1;
      for(let k=0;k<segments;k++){
        const length=this.circumferenceCoordinates[base+k]*arc[segments];
        while(at<segments&&arc[at]<length)at++;
        const u=THREE.MathUtils.clamp((length-arc[at-1])/Math.max(arc[at]-arc[at-1],.000001),0,1);
        this.goalLocal[base+k]=source[base+at-1].clone().lerp(source[base+at%segments],u);
      }
    }
  }
  ringLength(ring){return ring.reduce((sum,p,k)=>sum+p.distanceTo(ring[(k+1)%ring.length]),0);}
  drapePoint(k,length){
    const curve=this.curves[k],distance=this.curveDistances[k];let low=1,high=curve.length-1;
    while(low<high){const mid=Math.floor((low+high)/2);if(distance[mid]<length)low=mid+1;else high=mid;}
    const u=THREE.MathUtils.clamp((length-distance[low-1])/Math.max(distance[low]-distance[low-1],.000001),0,1);
    return curve[low-1].clone().lerp(curve[low],u);
  }
  drapeAtHeight(k,height){
    const h=this.data.cloth.sample_heights,curve=this.curves[k];let low=1,high=h.length-1;
    while(low<high){const mid=Math.floor((low+high)/2);if(h[mid]>height)low=mid+1;else high=mid;}
    const u=THREE.MathUtils.clamp((h[low-1]-height)/Math.max(h[low-1]-h[low],.000001),0,1);
    return curve[low-1].clone().lerp(curve[low],u);
  }
  reset() {
    if (this.outfit === "suit") return;
    this.transforms(); this.accumulator = 0; this.fitGoals();
    this.points = this.goals.map((p) => p.clone());
    this.previous = this.points.map((p) => p.clone()); this.upload();
  }
  update(delta) {
    if (this.outfit === "suit") return;
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
    const c=this.data.cloth;
    for(let k=0;k<this.segments;k++){
      const hem=(c.rings-1)*this.segments+k,local=this.points[hem].clone().applyMatrix4(this.hipsInverse),goal=this.goalLocal[hem];
      const radial=new THREE.Vector3(goal.x,0,goal.z-.02).normalize();
      const amount=this.safeSecondary(k,THREE.MathUtils.clamp(new THREE.Vector3(local.x,0,local.z-.02).dot(radial)-this.goalRadii[hem],0,c.max_secondary_offset));
      for(let row=1;row<c.rings;row++){
        const i=row*this.segments+k,u=c.meridian_lengths[row][k]/c.meridian_lengths[c.rings-1][k],p=this.goalLocal[i];
        radial.set(p.x,0,p.z-.02).normalize();const radius=this.goalRadii[i]+amount*u*u;
        this.points[i].set(radial.x*radius,p.y,.02+radial.z*radius).applyMatrix4(this.hips);
      }
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
