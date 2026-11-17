#!/usr/bin/env python3
"""Author and bake Gen's motion set directly onto its existing GLB skeleton.

    python prototype/tools/animation/build_motion_set.py
    python prototype/tools/animation/build_motion_set.py --check

The controls below describe wrists, foot contacts, weight shifts and timing in
metres/seconds, not unexplained Euler guesses. Analytic IK bakes these controls
into ordinary Godot Animation tracks (60 Hz quaternion keys). No Blender.
The GLB, skin weights, materials and original model are never modified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from rig_math import Rig

ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / 'prototype/assets/heroine/female_A_rigged_safe.glb'
OUTPUT = ROOT / 'prototype/assets/heroine/animations'
FPS = 60


def smooth(value):
    value = float(np.clip(value, 0, 1))
    return value * value * (3 - 2 * value)


def curve(t, keys):
    """Bounded C1 segments. Contact translations use a LINEAR path instead."""
    for (a, av), (b, bv) in zip(keys, keys[1:]):
        if t <= b:
            return av + (bv - av) * smooth((t - a) / (b - a))
    return keys[-1][1]


def mix(a, b, weight):
    return np.asarray(a, float) * (1 - weight) + np.asarray(b, float) * weight


def body(rig, hip=(0, .835, .02), yaw=(-6, -4, -7), lean=(3, 2), roll=0, breath=0):
    p = rig.pose()
    p.positions[0] = hip
    p.bend('hips', y=yaw[0], z=roll)
    p.bend('spine', x=lean[0], y=yaw[1], z=-roll * .45)
    p.bend('chest', x=lean[1] + breath, y=yaw[2], z=-roll * .35)
    p.bend('neck', x=-2)
    p.bend('head', x=-sum(lean) * .65 - breath * .5, y=-sum(yaw) * .85)
    return p


def guard_hands(p, y_offset=0, sway=0):
    p.arm('L', [.145, 1.295 + y_offset, .265 + sway], roll=8)
    p.arm('R', [-.145, 1.305 + y_offset, .205 - sway], roll=-8)


def guard_feet(p):
    p.foot('L', [.125, .08, .155], yaw=6)
    p.foot('R', [-.135, .08, -.135], yaw=-10)


def idle(rig, t):
    breath = np.sin(t / 2.8 * np.pi * 2)
    p = body(rig, hip=(.003 * breath, .835 + .002 * breath, .02), breath=breath * .65)
    guard_hands(p, breath * .0015, breath * .002)
    guard_feet(p)
    return p


GAITS = {
    # Slightly shorter walking steps allow upright single support on these
    # 0.82 m legs. Cadence changes with the stride, NOT the gameplay speed.
    'walk': {'duration': .76, 'stride': 1.25, 'duty': .58, 'clearance': .105},
    # Less overstriding: a shorter contact segment, then an actual flight phase.
    'run': {'duration': .54, 'stride': 2.40, 'duty': .26, 'clearance': .23},
}


def foot_path(phase, gait):
    stride, duty = gait['stride'], gait['duty']
    travel = stride * duty
    if phase <= duty:
        # EXACTLY cancels character translation during the flat support phase.
        z = travel * (.5 - phase / duty)
        pitch = curve(phase / duty, [(0, -7), (.12, 0), (.78, 0), (1, 25)])
        y = .08
    else:
        v = (phase - duty) / (1 - duty)
        # Cubic Hermite swing matches the support velocity at both ends.
        m = -stride * (1 - duty)
        z = (2*v**3 - 3*v**2 + 1) * (-travel / 2) + (v**3 - 2*v**2 + v) * m \
            + (-2*v**3 + 3*v**2) * (travel / 2) + (v**3 - v**2) * m
        lift = np.sin(np.pi * v)
        # Keep the recovering run foot clear longer, especially before landing.
        # The old narrow arc forced the pelvis down to keep the leg reachable.
        # Endpoint velocity remains zero (lift**1.5), without raising the peak.
        arc = lift ** 1.5 * (1 + 1.4 * (1 - lift) if duty < .5 else 1)
        y = .08 + gait['clearance'] * arc
        pitch = curve(v, [(0, 25), (.3, 12 if duty > .5 else 38), (.7, -10), (1, -7)])
    return y, z, pitch


def gait_pose(rig, t, name):
    gait = GAITS[name]
    phase = (t / gait['duration']) % 1
    step_sin = np.sin(phase * np.pi * 2)
    half = phase % .5
    if name == 'walk':
        # Rise over the supporting leg, rather than keeping BOTH knees bent.
        # The lower double-support moments are brief; the foot stays on the floor.
        height = curve(half, [(0, .813), (.08, .85), (.23, .885), (.35, .874),
                              (.42, .85), (.48, .812), (.5, .813)])
        p = body(rig, hip=(.014 * step_sin, height, .02),
                 yaw=(-4 + 3 * step_sin, -2, -5 - 5 * step_sin),
                 lean=(4, 2), roll=1.3 * step_sin)
        guard_hands(p, height - .835, .012 * step_sin)
    else:
        # Brief load absorption, then push-off and a higher flight/recovery.
        # Moving the whole Character node up would only make the feet float.
        height = curve(half, [(0, .845), (.10, .838), (.27, .866), (.36, .897),
                              (.48, .843), (.5, .845)])
        p = body(rig, hip=(.012 * step_sin, height, .04),
                 yaw=(5 * step_sin, -3 * step_sin, -7 * step_sin),
                 lean=(6, 3), roll=2 * step_sin)
        # Compact reciprocal arm action: fists stay in front of the ribs.
        p.arm('L', [.15, 1.22 + height - .75 + .035 * step_sin, .23 - .095 * step_sin], roll=10)
        p.arm('R', [-.15, 1.22 + height - .75 - .035 * step_sin, .23 + .095 * step_sin], roll=-10)
    for side, offset, sign in [('L', 0, 1), ('R', .5, -1)]:
        fp = (phase + offset) % 1
        y, z, pitch = foot_path(fp, gait)
        p.foot(side, [sign * (.115 if name == 'walk' else .10), y, z], pitch=pitch,
               yaw=sign * (4 if name == 'walk' else 1))
    return p


def attack(rig, t, side):
    # Reach coincides with the BEGINNING of the gameplay active window (.18 s).
    reach = curve(t, [(0, 0), (.085, -.045), (.125, .16), (.18, 1), (.215, 1),
                      (.30, .55), (.42, 0), (.56, 0)])
    twist = max(0, reach)
    right = side == 'R'
    yaw = (-6 + (16 if right else -4) * twist,
           -4 + (12 if right else -2) * twist,
           -7 + (24 if right else -6) * twist)
    p = body(rig, hip=(.018 * twist, .835 - .016 * twist, .02 + (.040 if right else .022) * twist),
             yaw=yaw, lean=(3 + 2 * twist, 2 + 2 * twist))
    # The clavicle protracts slightly, instead of dragging the whole chest mesh.
    p.bend('shoulder.' + side, x=5 * twist)
    start = [.145, 1.295, .265] if side == 'L' else [-.145, 1.305, .205]
    end = [.045, 1.305, .638] if side == 'L' else [-.035, 1.305, .677]
    wrist = mix(start, end, reach)
    pole = mix([.30 if side == 'L' else -.30, .99, .12],
               [.23 if side == 'L' else -.23, 1.15, .38], twist)
    p.arm(side, wrist, pole=pole, roll=(8 + 30 * twist) * (1 if side == 'L' else -1))
    other = 'L' if right else 'R'
    covered = [.145, 1.295, .265] if other == 'L' else [-.145, 1.305, .205]
    p.arm(other, np.asarray(covered) + [0, .008 * twist, .012 * twist],
          roll=8 if other == 'L' else -8)
    p.foot('L', [.125, .08, .155], yaw=6 + (-6 if not right else 3) * twist)
    p.foot('R', [-.135, .08, -.135], pitch=(24 if right else 8) * twist,
           yaw=-10 + (16 if right else 2) * twist)
    return p


def dodge(rig, t):
    load = curve(t, [(0, 0), (.06, .85), (.15, 1), (.26, .8), (.42, 0)])
    flight = curve(t, [(0, 0), (.05, 0), (.13, 1), (.28, .8), (.37, 0), (.42, 0)])
    p = body(rig, hip=(0, .835 - .16 * load, .02 + .035 * load),
             yaw=(-6, -4, -7), lean=(3 + 14 * load, 2 + 5 * load))
    guard_hands(p, -.14 * load, .025 * load)
    p.foot('L', [.125, .08 + .11 * flight, .155 + .08 * flight], pitch=10 * flight, yaw=6)
    p.foot('R', [-.135, .08 + .15 * flight, -.135 - .06 * flight], pitch=22 * flight, yaw=-10)
    return p


def air_pose(rig, falling=False):
    p = body(rig, hip=(0, .86, .02), yaw=(-4, -3, -4), lean=(6 if falling else 8, 2))
    guard_hands(p, -.04 if falling else -.02, .018)
    p.foot('L', [.12, .17 if falling else .31, .19], pitch=6 if falling else 12, yaw=3)
    p.foot('R', [-.13, .13 if falling else .19, -.13], pitch=12 if falling else 24, yaw=-5)
    return p


def jump_start(rig, t):
    # Visual take-off only: no extra input delay is introduced into the controller.
    u = smooth(t / .14)
    p = body(rig, hip=(0, .835 + .025 * u, .02), yaw=(-6 + 2*u, -4 + u, -7 + 3*u),
             lean=(3 + 5*u, 2))
    guard_hands(p, -.02*u, .018*u)
    p.foot('L', [.125 - .005*u, .08 + .23*u, .155 + .035*u], pitch=12*u, yaw=6 - 3*u)
    p.foot('R', [-.135 + .005*u, .08 + .11*u, -.135 + .005*u], pitch=24*u, yaw=-10 + 5*u)
    return p


def land(rig, t):
    compress = curve(t, [(0, .35), (.065, 1), (.16, .3), (.26, 0)])
    p = body(rig, hip=(0, .835 - .115 * compress, .02),
             lean=(3 + 8 * compress, 2 + 3 * compress))
    guard_hands(p, -.10 * compress, .01 * compress)
    guard_feet(p)
    return p


def hit(rig, t):
    flinch = curve(t, [(0, 0), (.055, 1), (.11, .8), (.32, 0)])
    p = body(rig, yaw=(-6, -4 + 5 * flinch, -7 - 9 * flinch),
             lean=(3 - 10 * flinch, 2 - 8 * flinch))
    p.bend('head', x=-3.25 - 10 * flinch, y=14.45 + 6 * flinch)
    guard_hands(p, .02 * flinch, -.035 * flinch)
    guard_feet(p)
    return p


def definitions():
    return [
        ('guard', 2.8, True, idle, {}),
        *[(name, g['duration'], True, lambda r, t, n=name: gait_pose(r, t, n),
           {'stride': g['stride'], 'speed': g['stride'] / g['duration'], 'duty': g['duty']})
          for name, g in GAITS.items()],
        ('attack_left', .56, False, lambda r, t: attack(r, t, 'L'),
         {'windup': .18, 'active_end': .30, 'impact': .18, 'side': 'L'}),
        ('attack_right', .56, False, lambda r, t: attack(r, t, 'R'),
         {'windup': .18, 'active_end': .30, 'impact': .18, 'side': 'R'}),
        ('dodge', .42, False, dodge, {}),
        ('jump_start', .14, False, jump_start, {}),
        ('jump_up', .2, True, lambda r, t: air_pose(r), {}),
        ('jump_down', .2, True, lambda r, t: air_pose(r, True), {}),
        ('land', .26, False, land, {}),
        ('hit', .32, False, hit, {}),
    ]


def bake():
    rig = Rig(MODEL)
    data = {'version': 1, 'fps': FPS, 'model_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
            'coordinates': '+Y up, +Z forward, metres; full parent-local xyzw quaternions',
            'bones': rig.names, 'clips': {}}
    for name, duration, loop, author, meta in definitions():
        # Include BOTH endpoints and all authored timing events exactly.
        times = np.unique(np.round(np.r_[np.arange(0, duration, 1 / FPS), duration,
            [v for k, v in meta.items() if k in ('impact', 'active_end')]], 9))
        quats, hips = [], []
        before = len(rig.unreachable)
        for t in times:
            q, pos = author(rig, float(t)).export()
            if quats:
                q[np.sum(q * quats[-1], axis=1) < 0] *= -1  # quaternion hemisphere continuity
            quats.append(q)
            hips.append(pos)
        if loop:
            quats[-1] = quats[0].copy()
            hips[-1] = hips[0].copy()
        clipped = rig.unreachable[before:]
        if clipped:
            worst = max(clipped, key=lambda x: x[1])
            print(f'  {name}: {len(clipped)} clamped IK targets, max {worst[1]*1000:.1f} mm ({worst[0]})')
        data['clips'][name] = {'duration': duration, 'loop': loop, **meta,
                                'times': np.round(times, 7).tolist(),
                                'rotations': np.round(quats, 8).tolist(),
                                'hips': np.round(hips, 7).tolist()}
    return data


def numbers(values):
    return ', '.join(format(float(v), '.8g') for v in np.asarray(values).ravel())


def tres(data):
    clips = data['clips']
    lines = [f'[gd_resource type="AnimationLibrary" load_steps={len(clips)+1} format=3]', '']
    for name, clip in clips.items():
        lines += [f'[sub_resource type="Animation" id="Animation_{name}"]',
                  f'resource_name = "{name}"', f'length = {clip["duration"]}',
                  f'loop_mode = {1 if clip["loop"] else 0}', f'step = {1 / FPS:.10f}']
        for key in ('stride', 'speed', 'duty', 'windup', 'active_end', 'impact', 'side'):
            if key in clip:
                lines.append(f'metadata/{key} = {json.dumps(clip[key])}')
        q = np.asarray(clip['rotations'])
        for i, bone in enumerate(data['bones']):
            values = np.c_[clip['times'], np.ones(len(q)), q[:, i]]
            lines += [f'tracks/{i}/type = "rotation_3d"',
                      f'tracks/{i}/path = NodePath(".:{bone}")',
                      f'tracks/{i}/interp = 1', f'tracks/{i}/loop_wrap = true',
                      f'tracks/{i}/keys = PackedFloat32Array({numbers(values)})']
        i = len(data['bones'])
        values = np.c_[clip['times'], np.ones(len(q)), clip['hips']]
        lines += [f'tracks/{i}/type = "position_3d"',
                  f'tracks/{i}/path = NodePath(".:hips")', f'tracks/{i}/interp = 1',
                  f'tracks/{i}/loop_wrap = true',
                  f'tracks/{i}/keys = PackedFloat32Array({numbers(values)})', '']
    lines += ['[resource]', '_data = {']
    lines += [f'&"{name}": SubResource("Animation_{name}")' + (',' if i < len(clips)-1 else '')
              for i, name in enumerate(clips)]
    lines += ['}', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if generated files are stale')
    args = parser.parse_args()
    data = bake()
    # Compact JSON is a browser/test mirror, not a second hand-maintained animation source.
    outputs = {'motion_set.json': json.dumps(data, separators=(',', ':'), ensure_ascii=False) + '\n',
               'motion_set.tres': tres(data)}
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, text in outputs.items():
        path = OUTPUT / name
        if args.check:
            if not path.exists() or path.read_text(encoding='utf-8') != text:
                raise SystemExit(f'Stale: {path}; run build_motion_set.py')
        else:
            path.write_text(text, encoding='utf-8')
        print(f'{"checked" if args.check else "wrote"} {path.relative_to(ROOT)} ({len(text):,} chars)')


if __name__ == '__main__':
    main()
