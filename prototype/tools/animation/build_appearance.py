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
from scipy.spatial import cKDTree

from rig_math import Rig, accessor, read_glb
from build_motion_set import ROOT, MODEL

OUTPUT = MODEL.parent / 'appearance' / 'lab_uniform.json'
FABRIC = [.46, .65, .70]
BINDING = [.018, .085, .115]


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


def build():
    rig = Rig(MODEL)
    body = rig.mesh_data()
    p, j, w = body['POSITION'], body['JOINTS_0'], body['WEIGHTS_0']
    dominant = j[np.arange(len(j)), w.argmax(axis=1)]
    axial_names = ['hips', 'spine', 'chest', 'neck', 'head', 'shoulder.L', 'shoulder.R']
    axial = [rig.index[name] for name in axial_names]
    selected = np.isin(dominant, axial)
    tree = cKDTree(p[selected])
    dense = np.zeros((len(p), len(rig.names)))
    for k in range(4):
        dense[np.arange(len(p)), j[:, k]] += w[:, k]
    dense[:, [i for i in range(len(rig.names)) if i not in axial]] = 0
    dense /= np.maximum(dense.sum(axis=1, keepdims=True), 1e-10)

    vertices, weights, joints, colors, uv, indices = [], [], [], [], [], []

    def add(point, color=FABRIC, tex=(0, 0), bone=None):
        if bone is None:
            distance, nearby = tree.query(point, k=12)
            blend = 1/np.maximum(distance, .006)**2
            values = np.average(dense[selected][nearby], axis=0, weights=blend)
            top = np.argsort(-values, kind='stable')[:4]
            values = values[top]; values /= values.sum()
        elif isinstance(bone, dict):
            top = [rig.index[name] for name in bone]
            values = list(bone.values())
            top += [0]*(4-len(top)); values += [0]*(4-len(values))
        else:
            top, values = [rig.index[bone], 0, 0, 0], [1, 0, 0, 0]
        vertices.append(point); colors.append(color); uv.append(tex)
        joints.append(top); weights.append(values)
        return len(vertices)-1

    # A very small skirt solver: 16 x 7 particles, two constraint iterations,
    # fixed substeps, and analytic body capsules. The waist ring is pinned.
    levels = [.95, .87, .79, .71, .63, .555, .543]
    segments = 16
    cloth = []
    for y in levels:
        u = (.95-y)/(.95-.543)
        for k in range(segments):
            theta = k/segments*2*np.pi
            pleat = .003*np.cos(theta*8)*(u+.1)
            rx = .201+.059*u+pleat
            z = (.157+.075*u if np.cos(theta) >= 0 else .106+.075*u)+pleat
            cloth.append([rx*np.sin(theta), y, .008+z*np.cos(theta)])
    cloth = np.asarray(cloth)

    # Closed-front AND closed-back patient gown. Broad shoulder panels and
    # real arm holes, with separate loose cap sleeves. No painted-on clothing.
    profile = [(.950, .201, .165, -.098), (.980, .187, .164, -.095),
               (1.010, .177, .166, -.083), (1.017, .176, .167, -.082),
               (1.029, .174, .168, -.080), (1.036, .173, .169, -.078), (1.08, .158, .173, -.065),
               (1.15, .167, .181, -.073), (1.22, .179, .194, -.084),
               (1.27, .187, .175, -.094), (1.305, .198, .147, -.096),
               (1.345, .208, .125, -.096), (1.378, .202, .102, -.087),
               (1.399, .170, .074, -.065), (1.415, .120, .060, -.051),
               (1.430, .064, .052, -.049), (1.438, .063, .050, -.048)]
    count = segments*3
    for row, (y, rx, front, back) in enumerate(profile):
        for k in range(count):
            theta = k/count*2*np.pi
            sn, cs = np.sin(theta), np.cos(theta)
            x = rx*np.sign(sn)*abs(sn)**.85
            z = (front if cs >= 0 else -back)*np.sign(cs)*abs(cs)**.85
            color = BINDING if row >= len(profile)-2 or 1.017 <= y <= 1.029 else FABRIC
            point = [x, y, z]
            if row == 0:
                # A genuine shared seam, not two overlapping surfaces that
                # z-fight into a jagged line. Interpolate the pinned cloth rim
                # and give it EXACTLY the same hips-only bind weights.
                at = k/count*segments
                lo = int(at)
                point = cloth[lo]*(1-(at-lo))+cloth[(lo+1)%segments]*(at-lo)
            add(point, color, (k/count, (y-.54)/.9), 'hips' if row == 0 else None)
    for row in range(len(profile)-1):
        y = (profile[row][0]+profile[row+1][0])/2
        for k in range(count):
            angle = (k+.5)/count*2*np.pi
            if 1.275 < y < 1.345 and abs(np.sin(angle)) > .88:
                continue
            a, b = row*count+k, row*count+(k+1)%count
            c, d = a+count, b+count
            indices += [a, c, b, b, c, d]

    # Cap sleeves follow the upper arm, never pinning an arm to the chest.
    for side in ['L', 'R']:
        root = rig.rest_world[rig.index['upper_arm.'+side]]
        base = len(vertices)
        rows = [(-.055, .024), (-.040, .050), (-.015, .071), (.015, .079),
                (.055, .080), (.110, .074), (.145, .071), (.155, .071)]
        n = 24
        for row, (along, radius) in enumerate(rows):
            for k in range(n):
                angle = k/n*2*np.pi
                local = [radius*np.cos(angle), along, radius*np.sin(angle)*.93]
                point = root[:3, 3]+root[:3, :3]@local
                add(point, BINDING if row == len(rows)-1 else FABRIC,
                    (k/n, row/len(rows)),
                    {'chest': .45, 'shoulder.'+side: .55} if row == 0 else
                    {'chest': .20, 'shoulder.'+side: .30, 'upper_arm.'+side: .50} if row == 1 else
                    {'shoulder.'+side: .15, 'upper_arm.'+side: .85} if row == 2 else 'upper_arm.'+side)
        for row in range(len(rows)-1):
            for k in range(n):
                a, b = base+row*n+k, base+row*n+(k+1)%n
                c, d = a+n, b+n
                indices += [a, b, c, b, d, c]

    # Geometric identification patch sits ON the fabric rather than floating
    # over the chest. No new image/texture/import dependency is required.
    def patch_z(x, y):
        rx, front = [np.interp(y, [r[0] for r in profile], [r[k] for r in profile]) for k in [1, 2]]
        sn = (abs(x)/rx)**(1/.85)
        return front*np.sqrt(max(0, 1-sn*sn))**.85+.006

    for x0, x1, y0, y1, color in [(.055, .110, 1.225, 1.263, BINDING),
                                   (.062, .103, 1.247, 1.254, [.48, .83, .78]),
                                   (.062, .086, 1.235, 1.240, FABRIC)]:
        for x, y in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)]:
            add([x, y, patch_z(x, y)+(.001 if color != BINDING else 0)], color)
        a = len(vertices)-4; indices += [a, a+2, a+1, a+1, a+2, a+3]

    verts = np.asarray(vertices)
    normals = np.zeros_like(verts)
    tri = np.asarray(indices).reshape(-1, 3)[:, [0, 2, 1]]
    indices = tri.ravel().tolist()
    face = np.cross(verts[tri[:, 1]]-verts[tri[:, 0]], verts[tri[:, 2]]-verts[tri[:, 0]])
    for k in range(3):
        np.add.at(normals, tri[:, k], face)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-10)
    used, inverse = np.unique(tri, return_inverse=True)
    verts, normals = verts[used], normals[used]
    weights, joints, colors, uv = [np.asarray(values)[used].tolist() for values in [weights, joints, colors, uv]]
    indices = inverse.ravel().tolist()

    edges = []
    for row in range(len(levels)):
        for k in range(segments):
            a, b = row*segments+k, row*segments+(k+1)%segments
            edges.append([a, b, float(np.linalg.norm(cloth[a]-cloth[b])), .65])
            if row:
                edges.append([a, a-segments, float(np.linalg.norm(cloth[a]-cloth[a-segments])), .92])
            if row > 1:
                edges.append([a, a-2*segments, float(np.linalg.norm(cloth[a]-cloth[a-2*segments])), .18])
    hips_bind = rig.inverse_bind[rig.index['hips']]
    return {'version': 1, 'hips_inverse_bind': np.vstack([hips_bind[:3, :3], hips_bind[:3, 3]]).tolist(),
            'model_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
            'hands': hand_shape(rig),
            'gown': {'waist_vertices': count, 'positions': np.round(verts, 7).tolist(), 'normals': np.round(normals, 7).tolist(),
                     'joints': np.asarray(joints).tolist(), 'weights': np.round(weights, 7).tolist(),
                     'uv': np.round(uv, 6).tolist(), 'colors': colors, 'indices': indices},
            'cloth': {'positions': np.round(cloth, 7).tolist(), 'segments': segments,
                      'rings': len(levels), 'edges': edges, 'iterations': 2, 'step': 1/60,
                      'thickness': .018, 'max_secondary_offset': .07,
                      'fabric': FABRIC, 'binding': BINDING, 'capsules': [
                          ['thigh.L', 'shin.L', .122], ['thigh.R', 'shin.R', .122],
                          ['shin.L', 'foot.L', .076], ['shin.R', 'foot.R', .076]]}}


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
