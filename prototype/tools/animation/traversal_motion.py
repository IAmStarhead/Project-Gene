"""Experimental roll and ledge poses on the existing skeleton, in metres.

These are authored prototype clips, not mocap or contact-constrained animation.
The controller owns all world movement and collision checks.
"""
import numpy as np

ROLL = .80
CLIMB = 1.15


def smooth(u):
    u = np.clip(u, 0, 1)
    return u*u*(3-2*u)


def roll(rig, t, body):
    crouch = smooth(t/.16) * (1-smooth((t-.62)/.18))
    turn = 360*smooth((t-.16)/.46)
    p = body(rig, hip=(0, .835-.37*crouch, .02), yaw=(0, 0, 0),
             lean=(32*crouch, 28*crouch))
    p.bend('head', x=25*crouch)
    for side, sign in [('L', 1), ('R', -1)]:
        p.foot(side, [sign*.13, .08+.09*crouch, .10-.08*crouch],
               pitch=35*crouch, pivot=False, knee_pole=[sign*.20, .40, .8])
        p.arm(side, [sign*(.145+.04*crouch), 1.295-.63*crouch, .265+.04*crouch],
              pole=[sign*.38, .99-.40*crouch, .12], roll=8*sign)
    # Rotate the whole tucked pose about its pelvis; dense keys preserve the
    # full turn (a single 0-to-360 quaternion interpolation would not).
    p.bend('hips', x=turn)
    # Keep the rotating skinned body near the floor rather than burying the
    # head at 180 degrees or hovering at 270. The capsule remains upright.
    if .16 <= t <= .62:
        q, hip = p.export()
        lowest = rig.skin(q, hip, _roll_mesh(rig))[:, 1].min()
        blend = smooth((t-.16)/.04) * (1-smooth((t-.58)/.04))
        p.positions[0][1] += (.012-lowest)*blend
    return p


from functools import lru_cache

@lru_cache(maxsize=2)
def _roll_mesh(rig):
    return rig.mesh_data()


def hang(rig, t, body):
    sway = np.sin(t*2*np.pi/2.4)
    p = body(rig, hip=(.008*sway, .835+.008*sway, .02), yaw=(0,0,0), lean=(0,0), roll=1.0*sway)
    for side, sign in [('L',1),('R',-1)]:
        p.arm(side, [sign*.20, 1.62, .32], pole=[sign*.42,1.36,.23], roll=0)
        p.foot(side, [sign*.13, .16+.035*sway*sign, .05+.04*sway], pitch=8, pivot=False)
    return p


def climb(rig, t, body):
    # The collision capsule first rises outside the wall. Offset the visual
    # pelvis below it during the pull so the hands can stay near the lip;
    # the offset returns to zero as the body steps onto the top.
    u = np.clip(t/CLIMB,0,1)
    rise = smooth(u/.65)
    across = smooth((u-.65)/.35)
    physical_rise = 1.66*rise
    offset = -1.0*rise*(1-across)
    release = smooth((u-.65)/.35)
    tuck = smooth(u/.35)*(1-smooth((u-.70)/.30))
    p = body(rig, hip=(0,.835-.10*tuck+offset,.02), yaw=(0,0,0), lean=(8*tuck, 5*tuck))
    for side, sign in [('L',1),('R',-1)]:
        grip_y = 1.62-physical_rise
        grip_z = .32-.80*across
        hand_y = (1-release)*grip_y + release*1.295
        hand_z = (1-release)*grip_z + release*.265
        p.arm(side, [sign*(.20-.055*release),hand_y,hand_z],
              pole=[sign*.40, .99+offset, .12], roll=sign*8*release)
        foot_y = (1-rise)*(.16+offset) + rise*(-.03+.11*across)
        p.foot(side, [sign*.13,foot_y,.05+.16*tuck], pitch=25*tuck, pivot=False,
               knee_pole=[sign*.20, .40+offset, -.25])
    return p


def definitions(body):
    return [('roll', ROLL, False, lambda r,t: roll(r,t,body), {}),
            ('ledge_hang', 2.4, True, lambda r,t: hang(r,t,body), {}),
            ('ledge_climb', CLIMB, False, lambda r,t: climb(r,t,body), {})]
