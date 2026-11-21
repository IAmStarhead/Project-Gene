"""Coordinated take-off / crest / descent / landing, in two stances.

The CharacterBody supplies ALL ballistic motion and immediate impulse. These
non-looping clips only articulate the existing skeleton. Shared endpoints
avoid an apex switch; the relaxed set never routes through face-level guard.
"""
import numpy as np
from scipy.spatial.transform import Rotation
from locomotion import idle, smooth, path

START, UP, DOWN, LAND = .10, .22, .26, .30


def blend(a, b, u):
    q0, h0 = a.export()
    q1, h1 = b.export()
    q1 *= np.where(np.sum(q0*q1, axis=1, keepdims=True) < 0, -1, 1)
    dot = np.clip(np.sum(q0*q1, axis=1), -1, 1)
    angle = np.arccos(dot)
    sine = np.maximum(np.sin(angle), 1e-12)
    q = np.sin((1-u)*angle)[:,None]/sine[:,None]*q0 + np.sin(u*angle)[:,None]/sine[:,None]*q1
    q[dot > .9995] = (q0*(1-u)+q1*u)[dot > .9995]
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    p = a.rig.pose()
    p.rotations = Rotation.from_quat(q).as_matrix()
    p.positions[0] = h0*(1-u)+h1*u
    return p


def feet(relaxed):
    return ([.072,.08,.018],[-.072,.08,-.012]) if relaxed else ([.125,.08,.155],[-.135,.08,-.135])


def stage(rig, amount, falling, relaxed, body, swing_arm):
    """Extension -> asymmetric crest -> ready contact. Angles are degrees."""
    u = smooth(amount)
    rest = feet(relaxed)
    x = .09 if relaxed else .12
    extension = ([x,.095,rest[0][2]-.015],[-x-.005,.095,rest[1][2]+.015])
    crest = ([x,.315,.165],[-x-.005,.245,-.080])
    ready_height = .883 if relaxed else .875
    if falling:
        height = .874*(1-u)+ready_height*u
        lean = 7-2*u
        shoulder, elbow, spread = -4+14*u, 42-6*u, .25-.02*u
        points = [np.asarray(a)*(1-u)+np.asarray(b)*u for a,b in zip(crest,rest)]
        pitches = (8*(1-u),12*(1-u))
        yaws = ((0 if relaxed else 6)*u,(0 if relaxed else -10)*u)
    else:
        height = .938-.064*u
        lean = 4+3*u
        shoulder, elbow, spread = 32-36*u, 46-4*u, .18+.07*u
        points = [np.asarray(a)*(1-u)+np.asarray(b)*u for a,b in zip(extension,crest)]
        pitches = (28-20*u,26-14*u)
        yaws = ((0 if relaxed else 3)*(1-u),(0 if relaxed else -5)*(1-u))
    p = body(rig, hip=(0,height,.02), yaw=(-2,-1,-2), lean=(lean,2+u if not falling else 3-u))
    for side, offset in [('L',0),('R',0)]:
        # Open balancing arms pass below the chest at the crest instead of
        # keeping both forearms parallel in front of the face for the flight.
        # As the knee raises the REAL retained hem, carry the forearm a
        # little outwards (~27 mm at the wrist), not into the skirt. This
        # authors the arm path only: no wider sleeve/body mask or cloth hack.
        crest_weight = 1-u if falling else u
        swing_arm(p, side, shoulder, elbow, spread, roll=5,carrying=.015+.12*crest_weight)
    for k,side in enumerate(['L','R']):
        p.foot(side, points[k], pitch=pitches[k], yaw=yaws[k])
    return p


def takeoff(rig,t,relaxed,body,swing_arm,guard_hands,guard_feet):
    home = idle(rig,0) if relaxed else body(rig)
    if not relaxed:
        guard_hands(home); guard_feet(home)
    extension = stage(rig,0,False,relaxed,body,swing_arm)
    u = smooth(t/START)
    p = blend(home,extension,u)
    # IK target trajectories, not an ankle arc from quaternion blending.
    for k,side in enumerate(['L','R']):
        home_point = np.asarray(feet(relaxed)[k])
        end = np.array([(.09 if relaxed else .12)*(1 if side=='L' else -1)-(.005 if side=='R' else 0),
                        .095,home_point[2]+(-.015 if side=='L' else .015)])
        p.foot(side,home_point*(1-u)+end*u,pitch=(28 if side=='L' else 26)*u,
               yaw=(0 if relaxed else (6-3*u if side=='L' else -10+5*u)))
    return p


def landing(rig,t,relaxed,body,swing_arm,guard_hands,guard_feet):
    home = idle(rig,0) if relaxed else body(rig)
    if not relaxed:
        guard_hands(home); guard_feet(home)
    if t >= LAND: return home
    compress = path(t,[(0,0),(.075,1),(.17,.40),(LAND,0)],0.)
    recover = smooth(t/LAND)
    p = stage(rig,1,True,relaxed,body,swing_arm)
    p.positions[0,1] -= .13*compress
    p._world = None
    # Forward torso flexion accompanies the knee/pelvis load, then eases.
    p.bend('spine',x=5+9*compress,y=-1)
    p.bend('chest',x=2+4*compress,y=-2)
    for side in ['L','R']:
        swing_arm(p,side,10+7*compress,36+7*compress,.23,roll=5)
    p = blend(p,home,recover)
    # Keep each contact point fixed through the absorption and recovery.
    # A relaxed landing has its OWN neutral contacts, not a guard-to-idle
    # foot slide disguised by lowering only the wrists at the end.
    for k,side in enumerate(['L','R']):
        p.foot(side,feet(relaxed)[k],yaw=0 if relaxed else (6 if side=='L' else -10))
    return p
