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
        self.assertEqual(len(self.data['clips']), 11)

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
        np.testing.assert_allclose(self.globals('jump_start', .14), self.globals('jump_up', 0), atol=2e-7)

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
        for name in ['walk', 'run']:
            c = self.data['clips'][name]
            for side, offset in [('L', 0), ('R', .5)]:
                points = []
                for phase in np.linspace(c['duty'] * .15, c['duty'] * .72, 28):
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

    def test_hands_stay_in_front_and_joints_do_not_hyperextend(self):
        for name, c in self.data['clips'].items():
            for t in np.linspace(0, c['duration'], 35):
                g = self.globals(name, t)
                for side in ['L', 'R']:
                    hand = self.joint(g, 'hand.' + side)
                    self.assertGreater(hand[1], 1.10, (name, side))
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
