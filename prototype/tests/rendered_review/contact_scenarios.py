#!/usr/bin/env python3
"""Re-render explicit high-risk FCL snapshots, not a visibility classifier.

Input: completed scenarios.py/capture.mjs/split_trace.py recordings. The cases
are named, not silently selected by a favourable contact score. Red = an
intersecting garment triangle; it is NOT signed depth or proof of burn-through.
All views still need visual inspection. No gameplay sources are modified.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parents[1]/'tools/animation'
sys.path.insert(0, str(TOOLS))

# Both feet, free/target-relative motion, deceleration, dodges, moving arms,
# and a confirmed reaction blend. Exact names/indexes from the final traces.
CASES = [
    ('gaits', 'suit', 'suit-gaits-jog/player', 4, 'foot'),
    ('gaits', 'suit', 'suit-gaits-sprint/player', 8, 'foot'),
    ('wardrobe', 'suit', 'suit-dodge-forward/player', 1, 'foot'),
    ('wardrobe', 'suit', 'suit-dodge-back/player', 1, 'foot'),
    ('strafe', 'suit', 'suit-retreat/player', 3, 'foot'),
    ('strafe', 'suit', 'wall-stop/player', 2, 'foot'),
    ('gaits', 'dress', 'dress-gaits-jog/player', 9, 'forearm'),
    ('combat', 'dress', 'dress-Q/clone', 2, 'forearm'),
]


def rounded(value):
    if isinstance(value, float):
        # Normalize signed zero too: Godot serializes -0.0 as 0. This does
        # not relax acknowledgements or contact tests; inputs are quantized.
        return round(value, 7) or 0
    if isinstance(value, list):
        return [rounded(x) for x in value]
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--pack', required=True)
    a = p.parse_args()
    a.work.mkdir(parents=True, exist_ok=True)
    hashes = json.loads((a.runtime/'source-hashes.json').read_text())
    expected = {k: hashes[k] for k in ['model_sha256', 'appearance_sha256', 'motion_set_sha256',
                                      'runtime_sha256', 'controller_sha256']}
    snapshots = {}
    for part, outfit, take, index, region in CASES:
        trace = json.loads((a.runtime/('captures-'+part)/('trace-'+outfit+'.json')).read_text())
        for key, value in expected.items():
            if trace[key] != value:
                raise ValueError('Mixed source stamps: '+key)
        snapshots[(part, outfit, take, index)] = trace['takes'][take][index]
    contacts = {}
    for outfit in ['dress', 'suit']:
        seeks = {f'{part}/{take}:{i}': snapshots[part, o, take, i]
                 for part, o, take, i, _ in CASES if o == outfit}
        path = a.work/('cases-'+outfit+'.json')
        path.write_text(json.dumps(expected | {'outfit': outfit, 'seeks': seeks})+'\n')
        output = a.work/('contacts-'+outfit+'.json')
        subprocess.run([sys.executable, str(TOOLS/'check_garment_contacts.py'), str(path),
                        '--outfit', outfit, '--seeks-only', '--contact-details', '--output', str(output)], check=True)
        contacts[outfit] = {f['frame']: f for f in json.loads(output.read_text())['intersections']}
    from rig_math import Rig
    from build_motion_set import MODEL
    from build_appearance import OUTPUT
    from check_garment_contacts import visible_body_triangles, suit_body_triangles
    import numpy as np
    rig = Rig(MODEL)
    body = rig.mesh_data()
    appearance = json.loads(OUTPUT.read_text())
    dominant = body['JOINTS_0'][np.arange(len(body['POSITION'])), body['WEIGHTS_0'].argmax(axis=1)]
    labels = {}
    for outfit in ['dress', 'suit']:
        tri = (visible_body_triangles(rig, body, appearance['coverage']) if outfit == 'dress' else
               suit_body_triangles(rig, body, appearance['suit']['coverage']))
        labels[outfit] = [rig.names[bone] for bone in dominant[tri[:, 0]]]
    shots = []
    for number, (part, outfit, take, index, region) in enumerate(CASES, 1):
        name = f'{part}/{take}:{index}'
        frame = snapshots[part, outfit, take, index]
        hit = contacts[outfit][name]['hits']['gown' if outfit == 'dress' else 'suit']
        prefixes = ('foot.', 'toe.') if region == 'foot' else ('forearm.',)
        faces = sorted({c['garment_triangle'] for c in hit['details']
                        if labels[outfit][c['body_triangle']].startswith(prefixes)})
        if not faces:
            raise ValueError('The explicitly selected case has no expected contact: '+name)
        pose = {k: rounded(frame[k]) for k in ['rotations', 'hips', 'hand_open', 'cloth']}
        for view in ['side', 'opposite', 'back']:
            shots.append(dict(outfit=outfit, clip='idle_relaxed', time=0, view=view, layer='both',
                close=True, focus=[0, .35, .03] if region == 'foot' else [0, 1.27, .05],
                magenta=True, contact_faces=faces, diagnostic_pose=pose, label=name,
                file=f'contact-{number:02d}-{view}'))
    config = {'pack': a.pack, 'out': str(a.work/'captures'), 'expected': expected, 'shots': shots}
    (a.work/'contacts.json').write_text(json.dumps(config)+'\n')
    print(a.work/'contacts.json', len(shots), 'diagnostic views; actual frame references retained')


if __name__ == '__main__':
    main()
