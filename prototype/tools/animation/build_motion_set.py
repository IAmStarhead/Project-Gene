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
from functools import lru_cache

from scipy.interpolate import PchipInterpolator, CubicHermiteSpline

import numpy as np

from rig_math import Rig, unit
import locomotion

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
    # Touch down close to the pelvis, extend BEHIND it, recover heel first.
    'run': {'duration': .54, 'stride': 2.40, 'duty': .25, 'clearance': .24},
}


def swing_targets(p, side, shoulder_angle, elbow_bend, spread=.055, carrying=.015):
    """Anatomical shoulder swing, NOT a fist orbit around a fixed elbow pole.

    Degrees: zero upper arm hangs down; positive swings forward. Elbow flexion
    stays independent of the shoulder. Directions are in the model's sagittal
    plane; the small lateral component keeps the arm clear of the torso.
    Human references and the adaptation are documented in ANIMATIONS.md.
    """
    sign = 1 if side == 'L' else -1
    root = p.world('upper_arm.' + side)[:3, 3].copy()
    upper_angle, lower_angle = np.deg2rad([shoulder_angle, shoulder_angle + elbow_bend])
    upper = unit([sign * spread, -np.cos(upper_angle), np.sin(upper_angle)])
    lower = unit([sign * carrying, -np.cos(lower_angle), np.sin(lower_angle)])
    upper_length = np.linalg.norm(p.rig.positions[p.rig.index['forearm.' + side]])
    lower_length = np.linalg.norm(p.rig.positions[p.rig.index['hand.' + side]])
    elbow = root + upper_length * upper
    return elbow + lower_length * lower, elbow


def swing_arm(p, side, shoulder_angle, elbow_bend, spread=.055, roll=5, carrying=.015):
    wrist, elbow = swing_targets(p, side, shoulder_angle, elbow_bend, spread, carrying)
    p.arm(side, wrist, pole=elbow, roll=roll if side == 'L' else -roll)


def run_foot_path(phase, gait):
    stride, duty = gait['stride'], gait['duty']
    # Asymmetric contact: a modest reach forward, a long push behind the hip.
    # Ankle motion remains exactly -stride during flat support (no skating).
    touchdown = .16
    if phase <= duty:
        u = phase / duty
        return .08, touchdown - stride * phase, curve(u, [
            (0, 3), (.12, 0), (.52, 0), (.8, 35), (1, 60)])
    v = (phase - duty) / (1 - duty)
    start, end = touchdown - stride * duty, touchdown
    m = -stride * (1 - duty)
    z = (2*v**3 - 3*v**2 + 1)*start + (v**3 - 2*v**2 + v)*m \
        + (-2*v**3 + 3*v**2)*end + (v**3 - v**2)*m
    # The heel folds up early BEHIND the body, then the knee advances and the
    # foot lowers. A single symmetric sine arc looked like seated pedalling.
    y = curve(v, [(0, .08), (.10, .26), (.28, .08 + gait['clearance']),
                  (.60, .24), (.82, .19), (.90, .14), (1, .08)])
    pitch = curve(v, [(0, 60), (.15, 45), (.35, 18), (.60, -2), (.85, 0), (1, 3)])
    return y, z, pitch


def foot_path(phase, gait):
    if gait['duty'] < .5:
        return run_foot_path(phase, gait)
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
        # Preserve the accepted walking arc. Running has its own recovery
        # sequence above; both end with zero vertical swing velocity.
        arc = lift ** 1.5
        y = .08 + gait['clearance'] * arc
        pitch = curve(v, [(0, 25), (.3, 12), (.7, -10), (1, -7)])
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
        # Short compression -> extension/toe-off -> flight. The hip isn't held
        # low while the recovery leg passes. Only the skeleton moves, not the
        # CharacterBody / collider / gameplay trajectory.
        height = curve(half, [(0, .878), (.07, .863), (.17, .867), (.25, .874),
                              (.37, .937), (.48, .885), (.5, .878)])
        p = body(rig, hip=(.008 * step_sin, height, .04),
                 yaw=(3 * step_sin, -2 * step_sin, -4 * step_sin),
                 lean=(3, 2), roll=step_sin)
        # Opposite arm and leg: L foot touches down at phase 0 while L arm is
        # BACK, not raised beside the neck. Elbows stay below the shoulders.
        drive = np.cos(phase * np.pi * 2)
        swing_arm(p, 'L', 2.5 - 25 * drive, 100 + 5 * drive)
        swing_arm(p, 'R', 2.5 + 25 * drive, 100 - 5 * drive)
    for side, offset, sign in [('L', 0, 1), ('R', .5, -1)]:
        fp = (phase + offset) % 1
        y, z, pitch = foot_path(fp, gait)
        p.foot(side, [sign * (.115 if name == 'walk' else .10), y, z], pitch=pitch,
               yaw=sign * (4 if name == 'walk' else 1))
    return p


@lru_cache(maxsize=64)
def _trajectory(keys, endpoint_speed=None):
    x, y = np.asarray(keys, dtype=float).T
    interpolant = PchipInterpolator(x, y)
    if endpoint_speed is None:
        return interpolant
    slopes = interpolant.derivative()(x)
    slopes[0] = slopes[-1] = endpoint_speed
    return CubicHermiteSpline(x, y, slopes)


def trajectory(t, keys, endpoint_speed=None):
    # C1 shape-preserving interpolation: do NOT come to a full stop at every
    # intermediate waypoint, as chained smoothsteps did in the old gait.
    return float(_trajectory(tuple(keys), endpoint_speed)(t))


# Three authored tiers; the runtime still advances their common contact phase
# by real travelled distance, not a faster wall-clock animation player.
RELAXED_WALK = locomotion.GAITS['walk']
RELAXED_RUN = locomotion.GAITS['jog']
SPRINT = locomotion.GAITS['sprint']


def relaxed_idle(rig, t):
    return locomotion.idle(rig, t)


def relaxed_walk_path(phase):
    point, pitch, _, _ = locomotion.foot_path('walk', phase)
    return point[1], point[2], pitch


def relaxed_walk(rig, t):
    return locomotion.gait(rig, t, 'walk')


def relaxed_run(rig, t):
    return locomotion.gait(rig, t, 'jog')


def sprint(rig, t):
    return locomotion.gait(rig, t, 'sprint')


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


DODGE_DURATION = .48
DODGE_DISTANCE = 1.10


def dodge_progress(value):
    u = float(np.clip(value, 0, 1))
    return u**3*(10-15*u+6*u*u)


@lru_cache(maxsize=4)
def _guard_chest_inverse(rig):
    return np.linalg.inv(body(rig).world('chest'))


def dodge(rig, t, direction=(0, 1)):
    # Game-reference quickstep: load -> push -> short flight -> catch ->
    # recover. The old 26 cm shuffle was unrelated to a 1.4 m root slide.
    # Here each planted foot is stationary in WORLD space at the shared
    # analytic root curve; leading and recovery contacts have separate times.
    dx, dz = direction
    load = trajectory(t, [(0, 0), (.055, .55), (.13, 1), (.23, .83),
                          (.32, .58), (.40, .18), (DODGE_DURATION, 0)], 0.0)
    lateral = abs(dx) > .5
    p = body(rig, hip=(dx*.055*load, .835-.115*load, .02+dz*.045*load),
             yaw=(-6+dx*8*load, -4-dx*5*load, -7-dx*9*load),
             lean=(3+(12 if dz > 0 else -8 if dz < 0 else 2)*load,
                   2+(6 if dz > 0 else -3 if dz < 0 else 2)*load),
             roll=-dx*16*load)
    p.bend('head', x=-(5+(18 if dz > 0 else -11 if dz < 0 else 4)*load)*.65,
           y=-(-17-6*dx*load)*.85, z=dx*4*load)
    leading = 'L' if dx > 0 or dz > 0 else 'R'
    root_travel = DODGE_DISTANCE*dodge_progress(t/DODGE_DURATION)
    for side, sign, z in [('L', 1, .155), ('R', -1, -.135)]:
        first = side == leading
        start, land_at = (.035, .32 if dz < 0 else .30) if first else (.12, .40)
        u = np.clip((t-start)/(land_at-start), 0, 1)
        travel = DODGE_DISTANCE*dodge_progress(u)-root_travel
        lift = (.15 if first else .18)*np.sin(np.pi*u)**1.6
        pitch = (12 if first else 26)*np.sin(np.pi*u)**2
        yaw = (6 if side == 'L' else -10)+dx*(10 if first else -4)*load
        p.foot(side, [sign*(.125 if side == 'L' else .135)+dx*travel,
                      .08+lift, z+dz*travel], pitch=pitch, yaw=yaw,
               pivot=False, toe_pitch=pitch if 0 < u < 1 else min(pitch, 0))
        # Hands must follow the lowering/leaning CHEST, not fixed world-Y
        # targets. Previously the leading wrist approached its shoulder to
        # ~4 cm: the IK folded almost 180 degrees, buried the fist in the
        # shoulder and made even an intact sleeve look like an amputated arm.
        reference = _guard_chest_inverse(rig)
        chest = p.world('chest')
        wrist = reference @ np.array([.145, 1.295, .265, 1] if side == 'L' else [-.145, 1.305, .205, 1])
        wrist[:3] += load*np.array([dx*.035 if lateral else sign*.018,
                                    -.025 if first else .010, .095 if first else .030])
        pole = reference @ np.array([sign*.30, .99, .12, 1])
        pole[:3] += load*np.array([dx*.025, -.015, .025])
        p.arm(side, (chest @ wrist)[:3], pole=(chest @ pole)[:3], roll=8*sign)
    return p


JUMP_START = .10
JUMP_UP = .22
JUMP_DOWN = .26
LAND = .30


def jump_start(rig, t):
    # Immediate game jump: EXTEND before folding, rather than pulling both feet
    # up on the first frame. Physics supplies the entire ballistic root motion.
    u = smooth(t / JUMP_START)
    p = body(rig, hip=(0, .835 + .100 * u, .02),
             yaw=(-6 + 4*u, -4 + 3*u, -7 + 5*u), lean=(3, 2))
    for side, sign, start in [('L', 1, [.145, 1.295, .265]),
                              ('R', -1, [-.145, 1.305, .205])]:
        wrist, elbow = swing_targets(p, side, 38, 72, .16)
        p.arm(side, mix(start, wrist, u),
              pole=mix([sign*.30, .99, .12], elbow, u),
              roll=(8 - 3*u) * sign)
    p.foot('L', [.125 - .005*u, .08 + .01*u, .155 - .035*u], pitch=28*u, yaw=6 - 3*u)
    p.foot('R', [-.135 + .005*u, .08 + .01*u, -.135 + .035*u], pitch=26*u, yaw=-10 + 5*u)
    return p


def air_pose(rig, t, falling=False):
    # Non-looping segments, sampled by vertical velocity in character_anim.gd.
    # The ascent ends in the SAME crest pose that begins the descent. Feet
    # unfold before contact; the apex is not a switch between frozen poses.
    u = smooth(t / (JUMP_DOWN if falling else JUMP_UP))
    if falling:
        height, lean = .88 - .005*u, 6 - 3*u
        shoulder, elbow, spread = 15 + 3*u, 100 - 35*u, .16 + .04*u
        left = mix([.12, .31, .21], [.125, .08, .155], u)
        right = mix([-.13, .24, -.10], [-.135, .08, -.135], u)
        pitches, yaws = (4*(1-u), 12*(1-u)), (3 + 3*u, -5 - 5*u)
    else:
        height, lean = .935 - .055*u, 3 + 3*u
        shoulder, elbow, spread = 38 - 23*u, 72 + 28*u, .16
        left = mix([.12, .09, .12], [.12, .31, .21], u)
        right = mix([-.13, .09, -.10], [-.13, .24, -.10], u)
        pitches, yaws = (28 - 24*u, 26 - 14*u), (3, -5)
    p = body(rig, hip=(0, height, .02), yaw=(-2, -1, -2), lean=(lean, 2))
    for side in ['L', 'R']:
        swing_arm(p, side, shoulder, elbow, spread)
    p.foot('L', left, pitch=pitches[0], yaw=yaws[0])
    p.foot('R', right, pitch=pitches[1], yaw=yaws[1])
    return p


def land(rig, t):
    compress = curve(t, [(0, 0), (.075, 1), (.18, .32), (LAND, 0)])
    recover = smooth(t / LAND)
    height = .875 - .04*recover - .125*compress
    p = body(rig, hip=(0, height, .02),
             yaw=(-2 - 4*recover, -1 - 3*recover, -2 - 5*recover),
             lean=(3 + 8*compress, 2 + 3*compress))
    # Arms balance the landing first, then return to the existing combat guard.
    for side, sign, end in [('L', 1, [.145, 1.295, .265]),
                            ('R', -1, [-.145, 1.305, .205])]:
        wrist, elbow = swing_targets(p, side, 18 + 6*compress, 65 + 10*compress, .20)
        p.arm(side, mix(wrist, end, recover),
              pole=mix(elbow, [sign*.30, .99, .12], recover),
              roll=(5 + 3*recover) * sign)
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
        ('idle_relaxed', 3.2, True, relaxed_idle, {}),
        ('walk_relaxed', RELAXED_WALK['duration'], True, relaxed_walk,
         {'stride': RELAXED_WALK['stride'],
          'speed': RELAXED_WALK['stride'] / RELAXED_WALK['duration'], 'duty': RELAXED_WALK['duty'], 'sample_fps': 120}),
        ('run_relaxed', RELAXED_RUN['duration'], True, relaxed_run,
         {'stride': RELAXED_RUN['stride'], 'speed': RELAXED_RUN['stride'] / RELAXED_RUN['duration'],
          'duty': RELAXED_RUN['duty'], 'sample_fps': 120}),
        ('sprint_relaxed', SPRINT['duration'], True, sprint,
         {'stride': SPRINT['stride'], 'speed': SPRINT['stride'] / SPRINT['duration'], 'duty': SPRINT['duty'], 'sample_fps': 120}),
        *[(name, g['duration'], True, lambda r, t, n=name: gait_pose(r, t, n),
           {'stride': g['stride'], 'speed': g['stride'] / g['duration'], 'duty': g['duty']})
          for name, g in GAITS.items()],
        ('attack_left', .56, False, lambda r, t: attack(r, t, 'L'),
         {'windup': .18, 'active_end': .30, 'impact': .18, 'side': 'L'}),
        ('attack_right', .56, False, lambda r, t: attack(r, t, 'R'),
         {'windup': .18, 'active_end': .30, 'impact': .18, 'side': 'R'}),
        ('dodge', DODGE_DURATION, False, dodge, {'direction': 'forward', 'lead': 'L', 'lead_lift': .035, 'lead_land': .30, 'trail_lift': .12, 'trail_land': .40}),
        ('dodge_back', DODGE_DURATION, False, lambda r, t: dodge(r, t, (0, -1)), {'direction': 'back', 'lead': 'R', 'lead_lift': .035, 'lead_land': 0.32, 'trail_lift': .12, 'trail_land': .40}),
        ('dodge_left', DODGE_DURATION, False, lambda r, t: dodge(r, t, (1, 0)), {'direction': 'left', 'lead': 'L', 'lead_lift': .035, 'lead_land': 0.3, 'trail_lift': .12, 'trail_land': .40}),
        ('dodge_right', DODGE_DURATION, False, lambda r, t: dodge(r, t, (-1, 0)), {'direction': 'right', 'lead': 'R', 'lead_lift': .035, 'lead_land': 0.3, 'trail_lift': .12, 'trail_land': .40}),
        ('jump_start', JUMP_START, False, jump_start, {}),
        ('jump_up', JUMP_UP, False, lambda r, t: air_pose(r, t), {}),
        ('jump_down', JUMP_DOWN, False, lambda r, t: air_pose(r, t, True), {}),
        ('land', LAND, False, land, {}),
        ('hit', .32, False, hit, {}),
    ]


def bake():
    rig = Rig(MODEL)
    data = {'version': 1, 'fps': FPS, 'model_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
            'coordinates': '+Y up, +Z forward, metres; full parent-local xyzw quaternions',
            'bones': rig.names, 'clips': {}}
    for name, duration, loop, author, meta in definitions():
        # Include BOTH endpoints and authored timing/contact events exactly.
        events = [v for k, v in meta.items() if k in ('impact', 'active_end')]
        if name == 'run':
            events += [duration * (offset + u * meta['duty'])
                       for offset in (0, .5) for u in (.12, .52, .8, 1)]
        elif name in ('walk_relaxed', 'run_relaxed', 'sprint_relaxed'):
            events += [duration * ((offset + u * meta['duty']) % 1)
                       for offset in (0, .5) for u in (.14, .57, .80, 1)]
        elif name.startswith('dodge'):
            events += [meta[k] for k in ['lead_lift', 'lead_land', 'trail_lift', 'trail_land']]
        times = np.unique(np.round(np.r_[np.arange(0, duration, 1 / meta.get('sample_fps', FPS)), duration, events], 9))
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
                  f'loop_mode = {1 if clip["loop"] else 0}', f'step = {1 / clip.get("sample_fps", FPS):.10f}']
        for key in ('stride', 'speed', 'duty', 'windup', 'active_end', 'impact', 'side', 'direction', 'lead', 'lead_lift', 'lead_land', 'trail_lift', 'trail_land', 'sample_fps'):
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
