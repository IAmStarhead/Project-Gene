#!/usr/bin/env python3
"""Build a small laboratory gown and relaxed hands from the EXISTING heroine.

No Blender, new character, cloth dependency, or morphs inside the imported GLB.
The JSON is shared by the native Godot appearance and the diagnostic browser.
Run from the repository root; --check verifies the checked-in authoring result.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from rig_math import Rig, accessor, read_glb
from build_motion_set import ROOT, MODEL, definitions
from garment import bodice, FABRIC, BINDING

OUTPUT = MODEL.parent / 'appearance' / 'lab_uniform.json'


def hand_shape(rig):
    original, binary = read_glb(ROOT / 'models/heroine/female_A_rigged.glb')
    mesh = original['meshes'][0]
    primitive = mesh['primitives'][0]
    attrs, targets = primitive['attributes'], primitive['targets']
    names = mesh['extras']['targetNames']
    q = .18  # a soft natural curl, not a splayed T-pose hand or a closed fist
    positions = accessor(original, binary, attrs['POSITION'])
    normals = accessor(original, binary, attrs['NORMAL'])
    for name, amount in [('Fists', q), ('FistQuarterCorrection', q*4)]:
        target = targets[names.index(name)]
        positions += amount * accessor(original, binary, target['POSITION'])
        normals += amount * accessor(original, binary, target['NORMAL'])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-10)
    body = rig.mesh_data()
    delta = positions-body['POSITION']
    affected = np.linalg.norm(delta, axis=1) > 1e-6
    # Position + source normal identifies seam copies even if the importer
    # reorders/compacts vertices. Never assume Godot keeps GLB vertex indices.
    rows = np.c_[body['POSITION'][affected], body['NORMAL'][affected],
                 delta[affected], normals[affected], np.flatnonzero(affected)]
    return {'curl': q, 'rows': np.round(rows, 7).tolist(),
            'max_displacement': float(np.linalg.norm(delta, axis=1).max())}


def floor_probes(rig):
    """Small soft-skin support set for the RUNTIME pose blender.

    SLERP of two floor-safe IK poses need not itself be floor-safe. Keep the
    actual source sole vertices which support gait / stance / idle blends;
    do not assume a rigid ankle-to-ground offset. Full-sole regression tests
    independently check the reduced set, including between training phases.
    """
    source = rig.mesh_data()
    ids = np.flatnonzero(source['POSITION'][:, 1] < .09)
    mesh = {key: value[ids] for key, value in source.items() if key != 'indices'}
    sides = [np.flatnonzero(mesh['POSITION'][:, 0]*sign > 0) for sign in [1, -1]]
    authors = {name: (duration, author) for name, duration, _, author, _ in definitions()
               if name in ['idle_relaxed', 'guard', 'walk_relaxed', 'run_relaxed', 'sprint_relaxed', 'walk', 'run']}
    selected = set()

    def blend(a, b, u):
        q0, h0 = a
        q1, h1 = b
        q1 = q1*np.where(np.sum(q0*q1, axis=1, keepdims=True) < 0, -1, 1)
        dot = np.clip(np.sum(q0*q1, axis=1), -1, 1)
        angle = np.arccos(dot)
        sine = np.maximum(np.sin(angle), 1e-10)
        q = (np.sin((1-u)*angle)/sine)[:, None]*q0+(np.sin(u*angle)/sine)[:, None]*q1
        q[dot > .9995] = (q0*(1-u)+q1*u)[dot > .9995]
        q /= np.linalg.norm(q, axis=1, keepdims=True)
        return q, h0*(1-u)+h1*u

    def register(pose):
        positions = rig.skin(*pose, mesh)
        for side in sides:
            selected.add(int(ids[side[np.argmin(positions[side, 1])]]))

    pairs = [('walk_relaxed', 'run_relaxed'), ('run_relaxed', 'sprint_relaxed'),
             ('walk_relaxed', 'sprint_relaxed'), ('walk_relaxed', 'walk'), ('run_relaxed', 'run'),
             ('sprint_relaxed', 'run'), ('walk', 'run'),
             *[('idle_relaxed', name) for name in ['walk_relaxed', 'run_relaxed', 'sprint_relaxed']],
             ('guard', 'walk'), ('guard', 'run')]
    for phase in np.linspace(0, 1, 49, endpoint=False):
        poses = {name: author(rig, phase*duration).export() for name, (duration, author) in authors.items()}
        for pose in poses.values():
            register(pose)
        for a, b in pairs:
            for u in [.2, .5, .8]:
                register(blend(poses[a], poses[b], u))
        for u in [.25, .5, .75]:
            register(blend(blend(poses['walk_relaxed'], poses['run_relaxed'], u), poses['sprint_relaxed'], u))
    ids = np.array(sorted(selected))
    return {'bones': rig.names, 'source_indices': ids.tolist(),
            'positions': np.round(source['POSITION'][ids], 7).tolist(),
            'joints': source['JOINTS_0'][ids].tolist(), 'weights': np.round(source['WEIGHTS_0'][ids], 8).tolist()}


def build():
    rig = Rig(MODEL)
    # The visual grid is deliberately finer than the former 16-sided skirt.
    # Scalar radial springs replace 2 passes of edge constraints that were
    # discarded immediately by the fixed-height/angular projection anyway.
    levels = [1.02, .96, .90, .84, .78, .72, .66, .60, .555, .543]
    segments = 32
    cloth = []
    for y in levels:
        u = (1.02-y)/(1.02-.543)
        for k in range(segments):
            theta = k/segments*2*np.pi
            pleat = .0008*np.cos(theta*8)*u
            rx, front, back = [np.interp(y, [.543, .90, 1.02], values)
                               for values in [[.228, .186, .155], [.210, .164, .160], [-.150, -.100, -.060]]]
            z = (front if np.cos(theta) >= 0 else -back)+pleat
            cloth.append([(rx+pleat)*np.sin(theta), y, z*np.cos(theta)])
    cloth = np.asarray(cloth)
    gown = bodice(rig, cloth[:segments], cloth[segments:2*segments])
    hips_bind = rig.inverse_bind[rig.index['hips']]
    return {'version': 2, 'hips_inverse_bind': np.vstack([hips_bind[:3, :3], hips_bind[:3, 3]]).tolist(),
            'model_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
            'hands': hand_shape(rig), 'floor_probes': floor_probes(rig),
            'coverage': {'preserve_limbs': True, 'arm_weight_threshold': .15, 'sleeves': [],
                         'underarm_cores': [
                             {'origin': rig.rest_world[rig.index['upper_arm.'+side], :3, 3].tolist(),
                              'axis': rig.rest_world[rig.index['upper_arm.'+side], :3, 1].tolist(),
                              'start': -.045, 'end': .105, 'radius': .080, 'cuff': .158}
                             for side in ['L', 'R']]},
            'gown': gown,
            'cloth': {'positions': np.round(cloth, 7).tolist(), 'segments': segments,
                      'rings': len(levels), 'edges': [], 'iterations': 0, 'step': 1/60,
                      'solver': 'bounded_radial_surface_v2', 'surface_samples': True,
                      'thickness': .004, 'surface_margin': .014, 'max_secondary_offset': .025,
                      'fabric': FABRIC, 'binding': BINDING, 'capsules': [
                          ['thigh.L', 'shin.L', .110, .20], ['thigh.R', 'shin.R', .110, .20],
                          ['shin.L', 'foot.L', .070, 0.0], ['shin.R', 'foot.R', .070, 0.0]]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    text = json.dumps(build(), separators=(',', ':'))+'\n'
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != text:
            raise SystemExit('Stale appearance asset: run build_appearance.py')
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(text)
    print(('checked' if args.check else 'wrote'), OUTPUT.relative_to(ROOT), len(text), 'characters')


if __name__ == '__main__':
    main()
