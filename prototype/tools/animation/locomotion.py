"""Whole-body walk / easy jog / athletic sprint for the existing heroine.

Rhythm controls are a small periodic fit to the attributed CMU observations in
locomotion_reference.json. They drive pelvis, lumbar spine, thorax and head;
they are NOT a foreign skeleton or a runtime mocap dependency. Feet, contact,
proportions, arm carriage and the three speed tiers are authored here.
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator, CubicHermiteSpline

from rig_math import rotation, unit

REFERENCE = json.loads(Path(__file__).with_name('locomotion_reference.json').read_text())
GAITS = {
    'walk': dict(duration=1.08, stride=1.242, duty=.58, width=.052, touchdown=.260,
                 height=.886, bounce=.012, lateral=.022,
                 pelvis=(2.0, 5.8, 3.2), lumbar=(9.5, 3.2, 1.9), thorax=(4.2, 5.4, 2.4),
                 arm=(0, 18, 20, 5)),
    'jog': dict(duration=.80, stride=2.32, duty=.28, width=.045, touchdown=.215,
                height=.893, bounce=.023, lateral=.010,
                pelvis=(6.0, 4.2, 3.0), lumbar=(17, 7.0, 2.4), thorax=(11, 10.0, 3.6),
                arm=(0, 25, 84, 8)),
    'sprint': dict(duration=.62, stride=3.472, duty=.20, width=.043, touchdown=.205,
                   height=.913, bounce=.034, lateral=.008,
                   pelvis=(10, 5.6, 3.7), lumbar=(22, 9.4, 3.1), thorax=(18, 13.0, 4.4),
                   arm=(2, 38, 83, 9)),
}


def wave(gait, channel, phase):
    control = REFERENCE['curves'][gait][channel]
    return sum(value * function(2*np.pi*h*phase)
               for h, pair in zip(control['harmonics'], np.asarray(control['coefficients']).reshape(-1, 2))
               for value, function in zip(pair, [np.cos, np.sin]))


@lru_cache(maxsize=3)
def _counter_scale(name):
    phase = np.linspace(0, 1, 512, endpoint=False)
    return float(np.max(abs(.45*wave(name, 'thorax_yaw', phase)-.85*wave(name, 'pelvis_yaw', phase))))


@lru_cache(maxsize=8)
def _sole_data(rig, side):
    mesh = rig.mesh_data()
    mask = (mesh['POSITION'][:, 1] < .09) & (mesh['POSITION'][:, 0]*(1 if side == 'L' else -1) > 0)
    return np.c_[mesh['POSITION'][mask], np.ones(mask.sum())], mesh['JOINTS_0'][mask], mesh['WEIGHTS_0'][mask]


def _sole_height(pose, side):
    points, joints, weights = _sole_data(pose.rig, side)
    matrices = np.asarray([pose.world(name) for name in pose.rig.names])@pose.rig.inverse_bind
    y = np.zeros(len(points))
    for k in range(4):
        y += weights[:, k]*np.einsum('nij,nj->ni', matrices[joints[:, k]], points)[:, 1]
    return float(y.min())


def _clear_floor(pose, side, point, pitch, toe_pitch):
    # Fit the actual SOFT SKIN sole, not just the ankle bone. The heel has
    # shin weights; assuming it is a rigid .08 m shoe let it sink by 6 mm.
    # Upward-only, smooth correction also applies near lift-off/landing.
    point = point.copy()
    for _ in range(2):
        floor = _sole_height(pose, side)
        correction = .0004*np.logaddexp(0, (.0006-floor)/.0004)
        if correction < 1e-7:
            break
        point[1] += correction
        pose.foot(side, point, pitch=pitch, pivot=False, toe_pitch=toe_pitch)


@lru_cache(maxsize=96)
def _spline(keys, endpoint_speed=None):
    x, y = np.array(keys, float).T
    source = PchipInterpolator(x, y)
    if endpoint_speed is None:
        return source
    slopes = source.derivative()(x)
    slopes[0] = slopes[-1] = endpoint_speed
    return CubicHermiteSpline(x, y, slopes)


def path(t, keys, endpoint_speed=None):
    return float(_spline(tuple(keys), endpoint_speed)(t))


def smooth(t):
    u = np.clip(t, 0, 1)
    return u*u*(3-2*u)


def roll_offset(pitch, yaw=0):
    # Ground contact is a HEEL rocker on landing and a forefoot rocker on
    # push-off. The old code had no heel pivot, and kept airborne toes flat.
    pivot = np.array([0, -.074, -.040] if pitch < 0 else [0, -.060, .120])
    return rotation(y=yaw) @ (pivot-rotation(x=pitch)@pivot)


def foot_path(gait_name, phase):
    g = GAITS[gait_name]
    duty, stride, touch = g['duty'], g['stride'], g['touchdown']
    toe_off = {'walk': 58, 'jog': 58, 'sprint': 62}[gait_name]
    landing = {'walk': -11, 'jog': -5, 'sprint': 3}[gait_name]
    if phase <= duty:
        u = phase/duty
        pitch = path(u, [(0, landing), (.14, 0), (.57, 0), (.80, 25), (1, toe_off)], 0.0)
        offset = roll_offset(pitch)
        return np.array([0, .080, touch-stride*phase])+offset, pitch, min(pitch, 0), True
    v = (phase-duty)/(1-duty)
    start = touch-stride*duty+roll_offset(toe_off)[2]
    end = touch+roll_offset(landing)[2]
    z = path(v, [(0, start), (.12, start-.020), (.30, -.31 if gait_name == 'walk' else -.39),
                 (.50, -.055 if gait_name == 'walk' else -.15),
                 (.73, touch-.04), (.90, touch+.020), (1, end)], -stride*(1-duty))
    peak = {'walk': .208, 'jog': .430, 'sprint': .605}[gait_name]
    start_y = .080+roll_offset(toe_off)[1]
    end_y = .080+roll_offset(landing)[1]
    y = path(v, [(0, start_y), (.13, start_y+(peak-start_y)*.65), (.32, peak),
                 (.47, peak*.96), (.64, peak*.75), (.80, max(.110, peak*.40)),
                 (.94, max(end_y, .095)), (1, end_y)], 0.0)
    pitch = path(v, [(0, toe_off), (.22, 20), (.50, 0), (.76, landing-2), (1, landing)], 0.0)
    # The toes unfold after leaving the floor and follow the airborne foot.
    # Neither a flat floating toe nor a sudden 60-degree toe snap is allowed.
    toe_pitch = pitch*smooth(v/.20) if pitch > 0 else pitch
    return np.array([0, y, z]), pitch, toe_pitch, False


def _body(rig, name, phase, height):
    g = GAITS[name]
    p = rig.pose()
    p.positions[0] = [g['lateral']*np.sin(2*np.pi*(phase-.08)), height, .024]
    for bone, channel in [('hips', 'pelvis'), ('spine', 'lumbar'), ('chest', 'thorax')]:
        pitch, yaw, roll = g[channel]
        x = pitch+(1.0 if name == 'walk' else 1.9)*wave(name, channel+'_pitch', phase)
        y = yaw*((.45*wave(name, 'thorax_yaw', phase)-.85*wave(name, 'pelvis_yaw', phase))/_counter_scale(name) if channel == 'thorax' else wave(name, channel+'_yaw', phase))
        z = roll*wave(name, channel+'_roll', phase)
        p.orient(bone, rotation(x, y, z)@rig.rest_world[rig.index[bone], :3, :3])
    # The head is stabilised, not glued to the chest. A small delayed nod and
    # counter-roll preserve a forward gaze while the thorax actively rotates.
    lag = phase-.035
    p.orient('neck', rotation(x=1.0+.5*wave(name, 'head_pitch', lag),
                            y=.7*wave(name, 'head_yaw', lag),
                            z=.5*wave(name, 'head_roll', lag))@rig.rest_world[rig.index['neck'], :3, :3])
    p.orient('head', rotation(x=.6*wave(name, 'head_pitch', lag),
                            y=.8*wave(name, 'head_yaw', lag),
                            z=.4*wave(name, 'head_roll', lag)))
    return p


def _arm(p, name, side, phase):
    g = GAITS[name]
    sign = 1 if side == 'L' else -1
    bias, amplitude, elbow, variation = g['arm']
    drive = -np.cos(2*np.pi*(phase-.025))
    shoulder = bias+amplitude*drive
    bend = elbow-variation*drive
    p.bend('shoulder.'+side, x=.8*np.sin(2*np.pi*(phase-.04)),
           y=sign*(1.0 if name == 'walk' else 2.2)*drive,
           z=sign*.7*np.sin(2*np.pi*phase))
    root = p.world('upper_arm.'+side)[:3, 3].copy()
    chest = p.world('chest')[:3, :3]
    # Angles are measured from gravity-down, while yaw/roll still follow
    # the thorax. Compensate mean forward lean rather than letting it pin
    # both hands down at the belt during a fast run.
    lean = g['thorax'][0]
    upper_angle, fore_angle = np.deg2rad([shoulder+lean, shoulder+bend+lean])
    # Arms inherit torso direction. Previously only their origin moved with
    # the torso while their entire swing stayed locked to global axes.
    upper = chest@unit([sign*.075, -np.cos(upper_angle), np.sin(upper_angle)])
    lower = chest@unit([sign*.150, -np.cos(fore_angle), np.sin(fore_angle)])
    l1 = np.linalg.norm(p.rig.positions[p.rig.index['forearm.'+side]])
    l2 = np.linalg.norm(p.rig.positions[p.rig.index['hand.'+side]])
    pole = root+l1*upper
    wrist = pole+l2*lower
    p.arm(side, wrist, pole=pole, roll=sign*(5+2*np.sin(2*np.pi*(phase-.06))))
    hand = p.world('hand.'+side)[:3, :3].copy()
    p.orient('hand.'+side, hand@rotation(x=2*np.sin(2*np.pi*(phase-.09))))


def gait(rig, time, name):
    g = GAITS[name]
    phase = (time/g['duration']) % 1
    height = g['height']+g['bounce']*wave(name, 'bounce', phase)
    if name != 'walk':
        # Brief, elastic loading under the body, not a locked straight leg
        # or a continuous crouch. Flight stays tall; sprint has a stronger push.
        support_phase = phase % .5
        if support_phase < g['duty']:
            height -= (.022 if name == 'jog' else .040)*np.sin(np.pi*support_phase/g['duty'])**2
    p = _body(rig, name, phase, height)
    feet, ceilings = [], [height]
    initial_height = height
    reach = sum(np.linalg.norm(rig.positions[rig.index[n+'.L']]) for n in ['shin', 'foot'])-.0015
    for side, sign, offset in [('L', 1, 0), ('R', -1, .5)]:
        fp = (phase+offset) % 1
        point, pitch, toe_pitch, contact = foot_path(name, fp)
        point[0] = sign*(g['width']+(.008*np.sin(np.pi*(fp-g['duty'])/(1-g['duty'])) if not contact else 0))
        root = p.world('thigh.'+side)[:3, 3]
        horizontal = np.linalg.norm((point-root)[[0, 2]])
        ceiling = point[1]+np.sqrt(max(.001, reach**2-horizontal**2))-(root[1]-initial_height)
        ceilings.append(ceiling)
        # Smooth reach envelope, not an IK clamp or a sudden pelvis drop.
        feet.append((side, point, pitch, toe_pitch))
    width, minimum = .0015, min(ceilings)
    height = minimum-width*np.log(np.exp(-(np.asarray(ceilings)-minimum)/width).sum())
    p.positions[0, 1] = height
    p._world = None
    for side, point, pitch, toe_pitch in feet:
        p.foot(side, point, pitch=pitch, yaw=0, pivot=False, toe_pitch=toe_pitch)
    for side, point, pitch, toe_pitch in feet:
        _clear_floor(p, side, point, pitch, toe_pitch)
    for side, offset in [('L', 0), ('R', .5)]:
        _arm(p, name, side, (phase+offset) % 1)
    return p


def idle(rig, time):
    phase = time/3.2
    breath = np.sin(phase*2*np.pi)
    p = _body(rig, 'walk', phase, .897+.001*breath)
    p.positions[0] = [.003*breath, .897+.001*breath, .014]
    for bone in ['hips', 'spine', 'chest']:
        # Idle breath is much quieter than a walking weight transfer.
        p.orient(bone, rotation(x=.35*breath if bone != 'hips' else 0,
                               y=.3*breath, z=.2*breath)@rig.rest_world[rig.index[bone], :3, :3])
    for side, sign in [('L', 1), ('R', -1)]:
        p.foot(side, [sign*.072, .08, .018 if side == 'L' else -.012], pivot=False)
        root = p.world('upper_arm.'+side)[:3, 3].copy()
        upper = unit([sign*.075, -1, .02])
        lower = unit([sign*.15, -.98, .20])
        l1, l2 = [np.linalg.norm(rig.positions[rig.index[n+'.'+side]]) for n in ['forearm', 'hand']]
        elbow = root+l1*upper
        p.arm(side, elbow+l2*lower, pole=elbow, roll=sign*5)
    return p
