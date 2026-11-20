"""Target-facing locomotion: authored lead/collect side steps and retreat.

Metres, +X anatomical left, +Z forward. These are new skeletal cycles, not a
rotation/reversal of the accepted ordinary running clips. Runtime keeps one
contact phase and blends four headings and three speed tiers by displacement.
"""
from __future__ import annotations
import numpy as np
import locomotion

DIRECTIONS = {'forward': (0, 1), 'left': (1, 0), 'right': (-1, 0), 'back': (0, -1)}
TIERS = {
    'walk': {'speed': 1.15, 'stride': .62, 'duty': .56, 'lift': .075, 'width': .220},
    'jog': {'speed': 2.9, 'stride': 1.30, 'duty': .24, 'lift': .155, 'width': .230},
    'sprint': {'speed': 3.4, 'stride': 1.65, 'duty': .18, 'lift': .205, 'width': .235},
}


def parameters(direction, tier):
    g = dict(TIERS[tier])
    if direction == 'forward':
        g.update(stride={'walk': .86, 'jog': 2.10, 'sprint': 3.12}[tier],
                 speed={'walk': 1.15, 'jog': 2.9, 'sprint': 5.6}[tier],
                 duty={'walk': .58, 'jog': .24, 'sprint': .16}[tier], width=.13)
    elif direction == 'back':
        g.update(stride={'walk': .92, 'jog': 1.65, 'sprint': 1.95}[tier], width=.15)
    g['duration'] = g['stride']/g['speed']
    return g


def contact_path(phase, g):
    """Linear support (-distance), C1 recovery; no support-leg skating."""
    d, stride = g['duty'], g['stride']
    travel = stride*d
    if phase <= d:
        return travel*.5-stride*phase, .08
    u = (phase-d)/(1-d)
    m = -stride*(1-d)
    a, extra = travel*.5, stride*(1-d)*.025
    # Brake just after toe-off, transfer, then match support velocity before
    # landing. A single Hermite across the whole swing overshot behind the
    # hip, crossed lateral feet and forced a deep sprint crouch.
    nodes = [(0., -a, m), (.12, -a-extra, 0.), (.88, a+extra, 0.), (1., a, m)]
    for (ua, va, ma), (ub, vb, mb) in zip(nodes, nodes[1:]):
        if u <= ub:
            v = (u-ua)/(ub-ua)
            along = (2*v**3-3*v*v+1)*va+(v**3-2*v*v+v)*ma*(ub-ua) \
                +(-2*v**3+3*v*v)*vb+(v**3-v*v)*mb*(ub-ua)
            break
    return along, .08+g['lift']*np.sin(np.pi*u)**1.25


def pose(rig, t, direction, tier, body, guard_hands):
    g = parameters(direction, tier)
    phase = (t/g['duration']) % 1
    dx, dz = DIRECTIONS[direction]
    wave = np.sin(phase*2*np.pi)
    lateral = dx != 0
    # Left/right use opposite LEADING feet, with a staggered boxing base.
    # The support clock is ALWAYS L=0/R=.5 across headings. On a right
    # step R is the travelling lead and L collects; don't phase-flip the
    # whole cycle when blending a forward/right diagonal or changing lock.
    targets = {}
    pitches = {}
    for side, sign in [('L', 1), ('R', -1)]:
        fp = (phase+(0 if side == 'L' else .5)) % 1
        along, y = contact_path(fp, g)
        x = sign*g['width']+dx*along
        z = (.045 if side == 'L' else -.045)+dz*along
        # Retreat lands on the forefoot then rolls onto the heel. Lateral
        # collection has low toe clearance, not a forward-running heel kick.
        if fp <= g['duty']:
            u = fp/g['duty']
            pitch = (10*(1-min(1, u/.2))-8*max(0, (u-.8)/.2)) if direction == 'back' else 0.
        else:
            u = (fp-g['duty'])/(1-g['duty'])
            pitch = (-8 if direction == 'back' else 5)*np.sin(np.pi*u)
        targets[side] = np.array([x, y, z])
        pitches[side] = pitch
    hip_x = (.010 if lateral else .012)*wave
    # A reach-limited hip trajectory, not clamped IK and not a physics/root
    # speed change. Lower briefly under a wide planted side step; rise when
    # both feet clear the floor. The ordinary accepted gait is untouched.
    flight = min(max(0., ((phase+offset) % 1-g['duty'])/(1-g['duty'])) for offset in [0, .5])
    height = .855+(.015 if tier == 'walk' else .055)*np.sin(np.pi*flight)
    for side, sign in [('L', 1), ('R', -1)]:
        foot = targets[side]
        root = np.array([hip_x+sign*.09, 0, .02])
        horizontal = (foot[0]-root[0])**2+(foot[2]-root[2])**2
        height = min(height, foot[1]+np.sqrt(max(.01, .805**2-horizontal)))
    p = body(rig, hip=(hip_x, height, .02), yaw=(-4+2*wave, -2-wave, -5+wave),
             lean=((2 if direction == 'back' else 4), 2), roll=-dx*1.8+wave*.8)
    guard_hands(p, max(-.12, height-.835), .005*wave)
    for side, sign in [('L', 1), ('R', -1)]:
        yaw = sign*(12 if lateral else 5)
        pitch = pitches[side]
        # Use the actual SOFT sole (including shin/toe weights), not a
        # guessed rigid ankle offset. This changes only the baked foot IK.
        local = targets[side].copy()
        desired_floor = local[1]-.08+.001
        p.foot(side, local, pitch=pitch, yaw=yaw, pivot=False, toe_pitch=pitch)
        for _ in range(3):
            correction = desired_floor-locomotion._sole_height(p, side)
            if abs(correction) < 1e-7:
                break
            local[1] += correction
            p.foot(side, local, pitch=pitch, yaw=yaw, pivot=False, toe_pitch=pitch)
    return p
