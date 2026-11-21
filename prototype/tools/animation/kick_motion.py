"""Three grounded, non-acrobatic kicks on Gen's original 21-bone skeleton.

Weight shift precedes leg lift. The support foot pivots around its forefoot;
chamber, striking arc, re-chamber and replant are distinct. No action-root
translation, physics change, knockback, extra stun or clone AI move is added.
This module owns the NEW moves' timings/balance; they are baked as Animation
metadata and read by the native move catalog, not duplicated in player.gd.
"""
from __future__ import annotations

import numpy as np
from locomotion import path, smooth, _sole_height
from rig_math import rotation

SPECS = {
    'front_kick': dict(clip='attack_front_kick', side='L', support='R',
        windup=.30, active_end=.42, duration=.90, damage=24., stamina=22.,
        reach=.90, cancel_window=.12, lift=.12, replant=.75, pivot=-18.),
    'low_kick': dict(clip='attack_low_kick', side='R', support='L',
        windup=.32, active_end=.44, duration=.94, damage=20., stamina=20.,
        reach=.86, cancel_window=.10, lift=.14, replant=.80, pivot=48.),
    'roundhouse': dict(clip='attack_roundhouse', side='R', support='L',
        windup=.46, active_end=.60, duration=1.24, damage=36., stamina=34.,
        reach=.90, cancel_window=.12, lift=.22, replant=1.06, pivot=76.),
}
REST_FEET = {'L': np.array([.125, .08, .155]), 'R': np.array([-.135, .08, -.135])}
REST_YAW = {'L': 6., 'R': -10.}


def line(t, keys):
    """C1 motion through vector waypoints, with quiet exact endpoints."""
    times, points = zip(*keys)
    return np.array([path(t, tuple(zip(times, np.asarray(points)[:, k])), 0.) for k in range(3)])


def support_foot(p, side, yaw, pitch):
    # The ball of the planted foot, not its ankle, is the yaw/pitch pivot.
    # This turns the support knee WITH its toes instead of twisting a locked
    # shin while the pelvis rotates. Lift the actual soft heel if necessary.
    rest = REST_FEET[side]
    lever = np.array([0., -.06, .12])
    anchor = rest + rotation(y=REST_YAW[side]) @ lever
    target = anchor - rotation(y=yaw) @ rotation(x=pitch) @ lever
    pole = target + rotation(y=yaw) @ np.array([0., .35, .65])
    for _ in range(2):
        p.foot(side, target, pitch=pitch, yaw=yaw, pivot=False,
               toe_pitch=0., knee_pole=pole)
        lift = max(0., .0006 - _sole_height(p, side))
        if lift < 1e-7:
            break
        target[1] += lift
        pole[1] += lift


def pose(rig, t, kind, body, guard_hands, guard_feet, guard_pole):
    s = SPECS[kind]
    duration, lift, down = s['duration'], s['lift'], s['replant']
    # Exact guard endpoints remain compatible with all old attacks/reactions.
    if t <= 0 or t >= duration:
        p = body(rig)
        guard_hands(p)
        guard_feet(p)
        return p
    if kind == 'front_kick':
        weight = path(t, [(0,0), (.12,.86), (.24,1), (.54,1), (.75,.60), (.90,0)], 0.)
        strike = path(t, [(0,0), (.21,0), (.30,1), (.36,1), (.52,0), (.90,0)], 0.)
        p = body(rig, hip=(-.092*weight, .835+.020*weight-.012*np.sin(np.pi*t/duration)**2, .02+.018*strike),
                 yaw=(-6+3*strike,-4+3*strike,-7-3*strike),
                 lean=(3-7*strike,2-4*strike), roll=-3*weight)
        target = line(t, [(0,REST_FEET['L']), (lift,REST_FEET['L']),
            (.23,[.10,.45,.18]), (.30,[.065,.86,.805]), (.36,[.055,.87,.825]),
            (.52,[.10,.45,.20]), (.64,[.125,.22,.16]), (down,REST_FEET['L']), (duration,REST_FEET['L'])])
        pitch = path(t, [(0,0), (lift,0), (.23,-18), (.30,-68), (.36,-68), (.54,-12), (down,0), (duration,0)], 0.)
        yaw = 6.
        # Keep the knee pole ABOVE the hip once the sole reaches body
        # height. A fixed (.11,.80,.90) became collinear with hip->ankle
        # near extension and flipped the real thigh by ~85 degrees/key.
        # The return follows the same anterior/upward knee plane.
        pole = line(t, [(0,[.125,.42,.70]), (lift,[.125,.60,.85]),
            (.23,[.12,1.25,.95]), (.30,[.11,1.55,.80]), (.36,[.11,1.55,.80]),
            (.52,[.12,1.25,.95]), (down,[.125,.42,.70]), (duration,[.125,.42,.70])])
        support_yaw = -10-8*weight
        support_pitch = 3*weight
    else:
        strong = kind == 'roundhouse'
        w,a,d = s['windup'],s['active_end'],duration
        weight = path(t, [(0,0), (lift,1), (a+.20,1), (down,.55), (d,0)], 0.)
        turn = path(t, [(0,0), (lift,.12), (w,1), (a,.98), (down,.15), (d,0)], 0.)
        load = path(t, [(0,0), (lift*.72,1), (w,0), (d,0)], 0.)
        hip_turn = (55 if strong else 33)*turn
        p = body(rig, hip=(.096*weight, .835-.018*load+(.025 if strong else .010)*turn, .02+.010*turn),
                 yaw=(-6+hip_turn,-4+(9 if strong else 5)*turn,-7+(7 if strong else 4)*turn),
                 lean=(3-(7 if strong else 2)*turn,2-2*turn), roll=-(9 if strong else 3)*turn)
        if strong:
            target = line(t, [(0,REST_FEET['R']), (lift,REST_FEET['R']),
                (.35,[-.30,.52,.08]), (.46,[-.18,1.00,.83]), (.53,[.10,1.00,.85]),
                (.60,[.40,.92,.73]), (.72,[-.25,.68,.40]), (.84,[-.21,.43,.08]), (.94,[-.16,.24,-.05]),
                (down,REST_FEET['R']), (d,REST_FEET['R'])])
            pole = line(t, [(0,[-.135,.42,.70]), (.35,[-.65,.98,.65]),
                (.46,[-.50,1.20,.60]), (.60,[-.10,1.15,.84]), (.85,[-.45,.75,.60]), (d,[-.135,.42,.70])])
        else:
            target = line(t, [(0,REST_FEET['R']), (lift,REST_FEET['R']),
                (.24,[-.31,.25,.08]), (.32,[-.13,.40,.67]), (.38,[.04,.40,.70]),
                (.44,[.24,.36,.59]), (.61,[-.20,.28,.09]), (.71,[-.15,.18,-.06]),
                (down,REST_FEET['R']), (d,REST_FEET['R'])])
            pole = line(t, [(0,[-.135,.42,.70]), (.24,[-.55,.57,.70]),
                (.32,[-.45,.65,.90]), (.44,[-.05,.62,.92]), (.65,[-.40,.55,.60]), (d,[-.135,.42,.70])])
        pitch = path(t, [(0,0),(lift,0),(w,25 if strong else 20),(a,25 if strong else 20),(down,0),(d,0)], 0.)
        yaw = -10+(86 if strong else 66)*turn
        support_yaw = 6+(s['pivot']-6)*turn
        support_pitch = (14 if strong else 8)*turn
        strike = turn
    support_foot(p, s['support'], support_yaw, support_pitch)
    p.foot(s['side'], target, pitch=pitch, yaw=yaw, pivot=False,
           toe_pitch=pitch, knee_pole=pole)
    # No 'isolated waving leg': counterweight on the striking side, other
    # hand covering, then a measured return. Never throw both fists away.
    guard_hands(p)
    sign = 1 if s['side'] == 'L' else -1
    home = np.array([.145,1.295,.265] if sign == 1 else [-.145,1.305,.205])
    balance = np.array([sign*(.27 if kind == 'roundhouse' else .23),
                        1.11 if kind == 'roundhouse' else 1.17,.12])
    wrist = home*(1-.85*strike)+balance*(.85*strike)
    p.arm(s['side'], wrist, pole=guard_pole(s['side'])+np.array([sign*.035*strike, -.04*strike, 0]),
          roll=8*sign)
    return p


def definitions(body, guard_hands, guard_feet, guard_pole):
    return [(s['clip'], s['duration'], False,
             lambda rig,t,k=kind: pose(rig,t,k,body,guard_hands,guard_feet,guard_pole),
             {k:v for k,v in s.items() if k not in ['clip','duration']} |
             {'kind':kind,'impact':s['windup'],'sample_fps':120,'ground_only':True})
            for kind,s in SPECS.items()]
