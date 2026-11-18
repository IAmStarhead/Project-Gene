#!/usr/bin/env python3
"""Offline triangle/BVH diagnostic against an ACTUAL native garment recording.

Optional author tools, not runtime dependencies; see requirements-review.txt.
Record with tests/record_garment.gd, then:
  python prototype/tools/animation/check_garment_contacts.py /abs/trace.json \
      --require-skirt-clear --output /abs/contacts.json

Unlike particle/capsule gaps, this tests displayed body/garment triangle pairs.
It is NOT signed penetration depth, cloth self-collision, a proof for unsampled
poses, or a visibility test. Open body/facing surfaces can intersect internally.
Contact counts are not quality scores across different mesh topologies.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import numpy as np

from build_appearance import OUTPUT
from build_motion_set import MODEL, OUTPUT as MOTION_OUTPUT
from rig_math import Rig


def visible_body_triangles(rig, mesh, coverage):
    p, joints, weights = [mesh[key] for key in ['POSITION', 'JOINTS_0', 'WEIGHTS_0']]
    axial_ids = [i for i, name in enumerate(rig.names)
                 if name in ['hips', 'spine', 'chest', 'neck'] or name.startswith('thigh.')]
    arm_ids = [i for i, name in enumerate(rig.names)
               if name.startswith(('shoulder.', 'upper_arm.', 'forearm.', 'hand.'))]
    axial = (weights*np.isin(joints, axial_ids)).sum(axis=1)
    arms = (weights*np.isin(joints, arm_ids)).sum(axis=1)
    hidden = (p[:, 1] > .74) & (p[:, 1] < 1.355) & (axial > .80)
    if coverage.get('preserve_limbs'):
        hidden &= arms < coverage['arm_weight_threshold']
    cores = list(coverage.get('underarm_cores', []))
    if not coverage.get('preserve_limbs'):
        cores += coverage.get('sleeves', [])
    for core in cores:
        relative = p-np.asarray(core['origin'])
        along = relative@core['axis']
        hidden |= ((along >= core['start']) & (along <= core['end']) &
                   (np.linalg.norm(relative-along[:, None]*core['axis'], axis=1) < core['radius']))
    return mesh['indices'][~hidden[mesh['indices']].all(axis=1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--appearance', type=Path, default=OUTPUT)
    parser.add_argument('--motion-set', type=Path, default=MOTION_OUTPUT/'motion_set.json')
    parser.add_argument('--seeks-only', action='store_true', help='Only the four exact feedback seeks')
    parser.add_argument('--require-skirt-clear', action='store_true', help='Fail if any sampled skirt/body triangle pair intersects')
    parser.add_argument('--output', type=Path, help='Save summary and intersecting frames outside Git')
    args = parser.parse_args()
    try:
        import trimesh
        from trimesh.collision import CollisionManager
        import fcl  # noqa: F401: fail early, not after loading a large trace
    except ImportError as error:
        raise SystemExit('Optional diagnostic dependency missing: pip install -r '
                         'prototype/tools/animation/requirements-review.txt\n'+str(error)) from error

    appearance = json.loads(args.appearance.read_text())
    trace = json.loads(args.trace.read_text())
    stamp = hashlib.sha256(args.appearance.read_bytes()).hexdigest()
    if trace.get('appearance_sha256') != stamp:
        raise SystemExit('Stale/missing trace stamp: regenerate with tests/record_garment.gd and this appearance asset')
    motion_stamp = hashlib.sha256(args.motion_set.read_bytes()).hexdigest()
    if trace.get('motion_set_sha256') != motion_stamp:
        raise SystemExit('Stale/missing motion stamp: regenerate the native recording for this motion set')
    if appearance['model_sha256'] != hashlib.sha256(MODEL.read_bytes()).hexdigest():
        raise SystemExit('The appearance and actual body model hashes differ')
    rig = Rig(MODEL)
    mesh = rig.mesh_data()
    body_triangles = visible_body_triangles(rig, mesh, appearance['coverage'])
    # Labels are approximate dominant-weight attribution, not anatomical truth.
    dominant = mesh['JOINTS_0'][np.arange(len(mesh['POSITION'])), mesh['WEIGHTS_0'].argmax(axis=1)]
    body_labels = dominant[body_triangles[:, 0]]
    gown = appearance['gown']
    gown_mesh = {key: np.asarray(gown[value]) for key, value in [
        ('POSITION', 'positions'), ('JOINTS_0', 'joints'), ('WEIGHTS_0', 'weights')]}
    gown_triangles = np.asarray(gown['indices']).reshape(-1, 3)
    segments, rings = [appearance['cloth'][key] for key in ['segments', 'rings']]
    skirt_triangles = []
    for row in range(rings-1):
        for k in range(segments):
            a, b = row*segments+k, row*segments+(k+1) % segments
            skirt_triangles.extend([[a, a+segments, b], [b, a+segments, b+segments]])
    skirt_triangles = np.asarray(skirt_triangles)
    opened = mesh['POSITION'].copy()
    hand_rows = np.asarray(appearance['hands']['rows'])
    opened[hand_rows[:, 12].astype(int)] += hand_rows[:, 6:9]
    frames = list(trace['seeks'].items()) if args.seeks_only else [
        (f'{name}:{i}', frame) for name, frames in trace['takes'].items() for i, frame in enumerate(frames)]
    counts, parts, intersections = Counter(), Counter(), []
    start = time.monotonic()
    for name, frame in frames:
        q, h = frame['rotations'], frame['hips']
        body_mesh = mesh | {'POSITION': mesh['POSITION']*(1-frame['hand_open'])+opened*frame['hand_open']}
        manager = CollisionManager()
        manager.add_object('body', trimesh.Trimesh(rig.skin(q, h, body_mesh), body_triangles, process=False))
        cloth = np.asarray(frame['cloth'])
        if cloth.shape != (segments*rings, 3):
            raise SystemExit(f'{name}: stale cloth grid {cloth.shape}, expected {(segments*rings, 3)}')
        hits = {}
        for label, vertices, faces in [('gown', rig.skin(q, h, gown_mesh), gown_triangles),
                                       ('skirt', cloth, skirt_triangles)]:
            collision, contacts = manager.in_collision_single(trimesh.Trimesh(vertices, faces, process=False), return_data=True)
            if collision:
                counts[label] += 1
                names = sorted({rig.names[body_labels[c.index('body')]] for c in contacts})
                hits[label] = {'contacts': len(contacts), 'approximate_body_parts': names}
                for bone in names:
                    parts[f'{label}/{bone}'] += 1
        if hits:
            intersections.append({'frame': name, 'hits': hits})
    summary = {'frames': len(frames), 'appearance_sha256': stamp, 'motion_set_sha256': motion_stamp,
               'intersecting_frames': {label: counts[label] for label in ['gown', 'skirt']},
               'frames_by_approximate_body_part': dict(sorted(parts.items())),
               'seconds': round(time.monotonic()-start, 3),
               'limitations': 'Triangle intersection only; not signed depth, visibility, self-collision or an unsampled-pose guarantee.'}
    print(json.dumps(summary, indent=2))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'summary': summary, 'intersections': intersections}, indent=2)+'\n')
    if args.require_skirt_clear and counts['skirt']:
        raise SystemExit('Skirt intersects the visible body in sampled frames (see output)')


if __name__ == '__main__':
    main()
