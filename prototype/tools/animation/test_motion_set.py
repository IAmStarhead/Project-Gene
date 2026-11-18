#!/usr/bin/env python3
"""Geometry / timing regressions on the real skinned heroine. No Godot or DCC.

    python -m unittest discover -s prototype/tools/animation -p 'test_*.py' -v

The native Godot integration suite is separate: tests/test_animation.gd.
"""
import hashlib
import json
import unittest

import numpy as np
from scipy.spatial.transform import Rotation

from build_motion_set import MODEL, OUTPUT, bake, definitions, tres
from rig_math import Rig, unit


def sample(clip, time):
    times = np.asarray(clip['times'])
    hi = int(np.clip(np.searchsorted(times, time, side='right'), 1, len(times) - 1))
    lo = hi - 1
    u = float(np.clip((time - times[lo]) / (times[hi] - times[lo]), 0, 1))
    a = np.asarray(clip['rotations'][lo])
    b = np.asarray(clip['rotations'][hi])
    b = b * np.where(np.sum(a * b, axis=1, keepdims=True) < 0, -1, 1)
    dot = np.clip(np.sum(a * b, axis=1), -1, 1)
    angle = np.arccos(dot)
    sine = np.sin(angle)
    safe = np.maximum(sine, 1e-10)
    q = np.sin((1-u)*angle)[:, None] / safe[:, None] * a + np.sin(u*angle)[:, None] / safe[:, None] * b
    q[dot > .9995] = (a * (1-u) + b * u)[dot > .9995]
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    hip = np.asarray(clip['hips'][lo]) * (1-u) + np.asarray(clip['hips'][hi]) * u
    return q, hip


def flexion(a, b, c):
    return np.rad2deg(np.arccos(np.clip(np.dot(unit(b-a), unit(c-b)), -1, 1)))


class MotionSetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((OUTPUT / 'motion_set.json').read_text())
        cls.rig = Rig(MODEL)
        cls.mesh = cls.rig.mesh_data()

    def globals(self, name, time):
        return self.rig.globals(*sample(self.data['clips'][name], time))

    def joint(self, matrices, name):
        return matrices[self.rig.index[name], :3, 3]

    def test_model_identity_and_rig(self):
        self.assertEqual(self.data['model_sha256'], hashlib.sha256(MODEL.read_bytes()).hexdigest())
        self.assertEqual(self.data['bones'], self.rig.names)
        self.assertEqual(len(self.rig.names), 21)
        self.assertEqual(len(self.data['clips']), 14)
        self.assertTrue({'idle_relaxed', 'walk_relaxed', 'run_relaxed'} <= self.data['clips'].keys())

    def test_generated_files_are_reproducible(self):
        result = bake()
        self.assertEqual(self.data, result)
        self.assertEqual((OUTPUT / 'motion_set.tres').read_text(), tres(result))

    def test_quaternions_times_and_closed_loops(self):
        for name, c in self.data['clips'].items():
            with self.subTest(clip=name):
                times, q, hip = map(np.asarray, (c['times'], c['rotations'], c['hips']))
                self.assertEqual(times[0], 0)
                self.assertAlmostEqual(times[-1], c['duration'])
                self.assertTrue(np.all(np.diff(times) > 0))
                self.assertTrue(np.isfinite(q).all() and np.isfinite(hip).all())
                np.testing.assert_allclose(np.linalg.norm(q, axis=2), 1, atol=2e-7)
                self.assertGreater(np.sum(q[1:] * q[:-1], axis=2).min(), .85,
                                   'Quaternion flip / discontinuous IK bend plane')
                if c['loop']:
                    np.testing.assert_allclose(q[0], q[-1], atol=1e-8)
                    np.testing.assert_allclose(hip[0], hip[-1], atol=1e-8)

    def test_authoring_never_clamps_ik_targets(self):
        rig = Rig(MODEL)
        for name, duration, _, author, _ in definitions():
            before = len(rig.unreachable)
            for t in np.linspace(0, duration, 241):
                author(rig, t)
            self.assertEqual(rig.unreachable[before:], [], name)

    def test_actions_return_to_same_guard(self):
        idle = self.globals('guard', 0)
        for name in ['attack_left', 'attack_right', 'dodge', 'land', 'hit']:
            end = self.globals(name, self.data['clips'][name]['duration'])
            np.testing.assert_allclose(end, idle, atol=2e-7, err_msg=name)
        for a, b in [('guard', 'jump_start'), ('jump_start', 'jump_up'),
                     ('jump_up', 'jump_down'), ('jump_down', 'land')]:
            at = 0 if a == 'guard' else self.data['clips'][a]['duration']
            np.testing.assert_allclose(self.globals(a, at), self.globals(b, 0),
                                       atol=2e-7, err_msg=f'{a} -> {b}')

    def test_punches_extend_forward_and_free_hand_covers(self):
        for name in ['attack_left', 'attack_right']:
            c = self.data['clips'][name]
            self.assertIn(c['impact'], c['times'])  # active boundary is an exact baked key
            self.assertEqual(c['impact'], c['windup'])
            g = self.globals(name, c['impact'])
            side, other = c['side'], 'R' if c['side'] == 'L' else 'L'
            wrist = self.joint(g, 'hand.' + side)
            self.assertLess(abs(wrist[0]), .06)
            self.assertGreater(wrist[2], .61)
            self.assertLess(flexion(*[self.joint(g, b + '.' + side)
                                      for b in ['upper_arm', 'forearm', 'hand']]), 17)
            self.assertGreater(self.joint(g, 'hand.' + other)[1], 1.28)
            self.assertGreater(self.joint(g, 'hand.' + other)[2], .18)
            for t in np.linspace(0, c['duration'], 80):
                w = self.joint(self.globals(name, t), 'hand.' + side)
                self.assertGreater(w[0] * (1 if side == 'L' else -1), -.001,
                                   'Fist crossed the body midline')

    def test_flat_support_cancels_forward_travel(self):
        for name in ['walk', 'run', 'walk_relaxed', 'run_relaxed']:
            c = self.data['clips'][name]
            for side, offset in [('L', 0), ('R', .5)]:
                points = []
                # Running toe-off now starts at 52% of contact: the ANKLE
                # must rise there. Test its flat interval, then the toe below.
                flat_end = .48 if name != 'walk' else .72
                for phase in np.linspace(c['duty'] * .15, c['duty'] * flat_end, 28):
                    t = ((phase - offset) % 1) * c['duration']
                    point = self.joint(self.globals(name, t), 'foot.' + side).copy()
                    point[2] += c['speed'] * t
                    points.append(point)
                # SLERP between baked IK poses introduces sub-mm path error.
                self.assertLess(np.ptp(points, axis=0).max(), .002, (name, side))

    def test_locomotion_has_upright_support_not_a_continuous_crouch(self):
        # A valid, reachable IK pose can still be a bad gait: the previous set
        # averaged 49 degrees of support-knee bend walking, 65 running. Measure
        # the SUPPORT leg here; a folded recovery leg is expected in a run.
        for name, hip_floor, knee_mean_limit in [('walk', .80, 32), ('run', .825, 40)]:
            c = self.data['clips'][name]
            hips, support = [], {'L': [], 'R': []}
            for phase in np.linspace(0, 1, 241, endpoint=False):
                g = self.globals(name, phase * c['duration'])
                hips.append(self.joint(g, 'hips')[1])
                for side, offset in [('L', 0), ('R', .5)]:
                    if (phase + offset) % 1 <= c['duty']:
                        support[side].append(flexion(*[self.joint(g, b + '.' + side)
                            for b in ['thigh', 'shin', 'foot']]))
            self.assertGreater(min(hips), hip_floor, name)
            self.assertGreater(np.mean(hips), .85, name)
            for side, bends in support.items():
                self.assertLess(np.mean(bends), knee_mean_limit, (name, side))
                self.assertLess(max(bends), 50, (name, side))
                self.assertLess(min(bends), 25, (name, side, 'leg never extends'))
            bends = support['L'] + support['R']
            print(f'\n  {name}: hips {min(hips):.3f}–{max(hips):.3f} m; '
                  f'support knee mean {np.mean(bends):.1f}°, max {max(bends):.1f}°')

    def test_running_toe_off_keeps_the_forefoot_planted(self):
        c = self.data['clips']['run']
        for side, offset in [('L', 0), ('R', .5)]:
            toes, ankles = [], []
            for phase in np.linspace(c['duty'] * .55, c['duty'] * .95, 32):
                t = ((phase - offset) % 1) * c['duration']
                g = self.globals('run', t)
                for bone, points in [('toe.', toes), ('foot.', ankles)]:
                    point = self.joint(g, bone + side).copy()
                    point[2] += c['speed'] * t
                    points.append(point)
            # Toe pivot, NOT sliding the entire foot back through the floor.
            self.assertLess(np.ptp(toes, axis=0).max(), .004, side)
            self.assertGreater(ankles[-1][1] - ankles[0][1], .05, side)

    def test_run_arms_swing_from_low_elbows_not_around_the_neck(self):
        c = self.data['clips']['run']
        elbows_z = {'L': [], 'R': []}
        for phase in np.linspace(0, 1, 241, endpoint=False):
            g = self.globals('run', phase * c['duration'])
            for side, sign in [('L', 1), ('R', -1)]:
                shoulder, elbow, wrist = [self.joint(g, b + '.' + side)
                                          for b in ['upper_arm', 'forearm', 'hand']]
                self.assertLess(elbow[1] - shoulder[1], -.21, side)
                self.assertLess(wrist[1] - shoulder[1], -.09, side)
                self.assertGreater(wrist[1], 1.0, side)
                self.assertGreater(wrist[0] * sign, .13, side)
                bend = flexion(shoulder, elbow, wrist)
                self.assertGreater(bend, 90, side)
                self.assertLess(bend, 110, side)
                elbows_z[side].append(elbow[2] - shoulder[2])
        for side, values in elbows_z.items():
            self.assertGreater(np.ptp(values), .21, (side, 'shoulder is not swinging'))
        # Left leg lands in front while left arm is back; reverse half a cycle later.
        for phase, sign in [(0, -1), (.5, 1)]:
            g = self.globals('run', phase * c['duration'])
            self.assertGreater(sign * (self.joint(g, 'forearm.L')[2]
                                       - self.joint(g, 'forearm.R')[2]), .20)

    def test_relaxed_walking_is_upright_and_arms_are_reciprocal(self):
        c = self.data['clips']['walk_relaxed']
        heights, knees, elbows = [], [], {'L': [], 'R': []}
        for phase in np.linspace(0, 1, 241, endpoint=False):
            g = self.globals('walk_relaxed', phase*c['duration'])
            hip, neck = self.joint(g, 'hips'), self.joint(g, 'neck')
            heights.append(hip[1])
            self.assertLess(abs(np.rad2deg(np.arctan2((neck-hip)[2], (neck-hip)[1]))), 4)
            for side, offset in [('L', 0), ('R', .5)]:
                elbows[side].append(self.joint(g, 'forearm.'+side)[2])
                if (phase+offset) % 1 <= c['duty']:
                    knees.append(flexion(*[self.joint(g, bone+'.'+side)
                                           for bone in ['thigh', 'shin', 'foot']]))
        self.assertGreater(min(heights), .85)
        self.assertGreater(np.mean(heights), .87)
        self.assertLess(np.mean(knees), 25)
        self.assertLess(max(knees), 42)  # includes the expected pre-swing flexion
        self.assertLess(np.corrcoef(elbows['L'], elbows['R'])[0, 1], -.98)
        for phase, sign in [(0, -1), (.5, 1)]:
            g = self.globals('walk_relaxed', phase*c['duration'])
            self.assertGreater(sign*(self.joint(g, 'forearm.L')[2]
                                      - self.joint(g, 'forearm.R')[2]), .12)
        print(f'\n  Ordinary walk: hips {min(heights):.3f}–{max(heights):.3f} m; '
              f'support knee mean {np.mean(knees):.1f}°, max {max(knees):.1f}°')

    def test_relaxed_run_retains_the_accepted_leg_cycle(self):
        a, b = [self.data['clips'][name] for name in ('run', 'run_relaxed')]
        self.assertEqual(a['times'], b['times'])
        self.assertEqual(a['hips'], b['hips'])
        indices = [i for i, name in enumerate(self.rig.names)
                   if name == 'hips' or name.startswith(('thigh.', 'shin.', 'foot.', 'toe.'))]
        np.testing.assert_array_equal(np.asarray(a['rotations'])[:, indices],
                                      np.asarray(b['rotations'])[:, indices])
        # The variant is still genuinely different above the waist.
        i = self.rig.index['forearm.L']
        self.assertGreater(np.max(np.abs(np.asarray(a['rotations'])[:, i]
                                          - np.asarray(b['rotations'])[:, i])), .15)

    def test_relaxed_walk_heel_rise_pivots_about_the_forefoot(self):
        c = self.data['clips']['walk_relaxed']
        for side, offset in [('L', 0), ('R', .5)]:
            toes, ankles = [], []
            for phase in np.linspace(.33, .52, 35):
                t = ((phase-offset) % 1)*c['duration']
                g = self.globals('walk_relaxed', t)
                for bone, points in [('toe.', toes), ('foot.', ankles)]:
                    point = self.joint(g, bone+side).copy()
                    # Right support crosses the loop boundary; world travel
                    # continues forward rather than teleporting back a stride.
                    point[2] += c['stride']*(phase-offset)
                    points.append(point)
            self.assertLess(np.ptp(toes, axis=0).max(), .004)
            self.assertGreater(ankles[-1][1] - ankles[0][1], .05)

    def test_jump_extends_then_folds_and_prepares_for_contact(self):
        ends = {name: self.globals(name, self.data['clips'][name]['duration'])
                for name in ['jump_start', 'jump_up', 'jump_down']}
        compression = self.globals('land', .075)
        for side in ['L', 'R']:
            bends = {name: flexion(*[self.joint(g, b + '.' + side)
                     for b in ['thigh', 'shin', 'foot']]) for name, g in ends.items()}
            self.assertLess(bends['jump_start'], 30, (side, 'take-off did not extend'))
            self.assertGreater(bends['jump_up'], 75, (side, 'legs never fold'))
            self.assertLess(bends['jump_down'], 25, (side, 'contact is still tucked'))
            self.assertGreater(flexion(*[self.joint(compression, b + '.' + side)
                for b in ['thigh', 'shin', 'foot']]), 60, side)
            self.assertGreater(self.joint(ends['jump_up'], 'foot.' + side)[1]
                               - self.joint(ends['jump_start'], 'foot.' + side)[1], .12)
        for name in ['jump_up', 'jump_down']:
            c = self.data['clips'][name]
            self.assertFalse(c['loop'], name)
            self.assertGreater(np.ptp(np.asarray(c['rotations']), axis=0).max(), .10,
                               f'{name} regressed to a frozen pose')
        for t in np.linspace(0, self.data['clips']['land']['duration'], 61):
            g = self.globals('land', t)
            for side, target in [('L', [.125, .08, .155]), ('R', [-.135, .08, -.135])]:
                np.testing.assert_allclose(self.joint(g, 'foot.' + side), target, atol=.002)

    def test_hand_clearance_and_joints_do_not_hyperextend(self):
        for name, c in self.data['clips'].items():
            for t in np.linspace(0, c['duration'], 35):
                g = self.globals(name, t)
                for side in ['L', 'R']:
                    hand = self.joint(g, 'hand.' + side)
                    # Guard/attacks stay high; relaxed running and balancing
                    # arms on landing must NOT be forced back to combat guard.
                    if name.endswith('_relaxed'):
                        self.assertGreater(hand[1], .95 if name == 'run_relaxed' else .78, (name, side))
                        self.assertLess(hand[1], 1.23, (name, side, 'not a face-level guard'))
                        self.assertGreater(hand[2], -.10, (name, side))
                        self.assertGreater(hand[0] * (1 if side == 'L' else -1), .17, (name, side))
                    else:
                        self.assertGreater(hand[1], .95 if name in ('run', 'jump_down', 'land') else 1.10,
                                           (name, side))
                        self.assertGreater(hand[2], .10, (name, side))
                    self.assertLess(flexion(*[self.joint(g, b + '.' + side)
                                              for b in ['thigh', 'shin', 'foot']]), 135)
                    thigh, shin, foot = [self.joint(g, b + '.' + side) for b in ['thigh', 'shin', 'foot']]
                    # Knees bend forward in world +Z, not through the back.
                    axis = unit(foot - thigh)
                    projection = thigh + axis * np.dot(shin-thigh, axis)
                    self.assertGreater(shin[2] - projection[2], -.001, (name, side))

    def test_feet_do_not_sink_and_skin_seams_stay_closed(self):
        pos = self.mesh['POSITION']
        feet = pos[:, 1] < .09
        groups = {}
        for i, p in enumerate(pos):
            groups.setdefault(tuple(np.round(p, 6)), []).append(i)
        pairs = np.array([(vs[0], i) for vs in groups.values() for i in vs[1:]])
        worst_floor, worst_seam = 0, 0
        for name, c in self.data['clips'].items():
            for t in np.linspace(0, c['duration'], 31):
                v = self.rig.skin(*sample(c, t), self.mesh)
                worst_floor = min(worst_floor, v[feet, 1].min())
                gap = np.linalg.norm(v[pairs[:, 0]] - v[pairs[:, 1]], axis=1).max()
                worst_seam = max(worst_seam, gap)
        # The existing soft ankle skin has ~4 mm deformation, not a rigid sole.
        self.assertGreater(worst_floor, -.008)
        self.assertLess(worst_seam, .00001)
        print(f'\n  Skin: floor {worst_floor*1000:.2f} mm; seam {worst_seam*1000:.5f} mm')


if __name__ == '__main__':
    unittest.main(verbosity=2)
