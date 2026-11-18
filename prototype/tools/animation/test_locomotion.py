"""Whole-body motion, three distinct tiers, real soles and anchored evasion.

These are specific regressions against the rejected stiff/wide shuffle. They
are not an automated claim that a human will find the resulting motion good.
"""
import json
import unittest

import numpy as np
from scipy.spatial.transform import Rotation

from build_motion_set import MODEL, OUTPUT, DODGE_DISTANCE, dodge_progress
from rig_math import Rig
from test_motion_set import sample


class WholeBodyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.data = json.loads((OUTPUT/'motion_set.json').read_text())
        cls.mesh = cls.rig.mesh_data()

    def globals(self, name, phase):
        c = self.data['clips'][name]
        return self.rig.globals(*sample(c, phase*c['duration']))

    def test_pelvis_torso_clavicles_and_head_are_not_a_rigid_block(self):
        r = self.rig
        for name, thorax_rom in [('walk_relaxed', 10), ('run_relaxed', 18), ('sprint_relaxed', 24)]:
            clips = self.data['clips'][name]
            matrices = np.asarray([self.globals(name, phase) for phase in np.linspace(0, 1, 121, endpoint=False)])
            euler = Rotation.from_matrix(matrices[:, [r.index['hips'], r.index['chest']], :3, :3].reshape(-1, 3, 3)).as_euler('XYZ', degrees=True).reshape(-1, 2, 3)
            self.assertGreater(np.ptp(euler[:, 0, 1]), 8, name)
            self.assertGreater(np.ptp(euler[:, 1, 1]), thorax_rom, name)
            self.assertGreater(np.ptp(euler[:, 0, 2]), 5.8, name)
            self.assertLess(np.corrcoef(euler[:, :, 1].T)[0, 1], -.75, name)
            # The local neck and clavicles actually articulate, rather than
            # inheriting a single rotation from the pelvis as a solid block.
            q = np.asarray(clips['rotations'])
            for bone in ['spine', 'chest', 'neck', 'head', 'shoulder.L', 'shoulder.R', 'hand.L', 'hand.R']:
                # The neck counters the chest while the head adds only a
                # quiet delayed nod. Requiring a large local head swing
                # would contradict the stabilised forward gaze below.
                minimum = .001 if bone == 'head' else .008
                self.assertGreater(np.ptp(q[:, r.index[bone]], axis=0).max(), minimum, (name, bone))
            head = Rotation.from_matrix(matrices[:, r.index['head'], :3, :3]).as_euler('XYZ', degrees=True)
            self.assertLess(abs(head[:, 1:]).max(), 1.2, 'Forward gaze stabilises against the moving torso')

    def test_calm_walk_is_narrow_with_small_vertical_excursion(self):
        r = self.rig
        matrices = np.asarray([self.globals('walk_relaxed', phase) for phase in np.linspace(0, 1, 121, endpoint=False)])
        width = matrices[:, r.index['foot.L'], 0, 3]-matrices[:, r.index['foot.R'], 0, 3]
        self.assertGreater(width.min(), .095)
        self.assertLess(width.max(), .125, 'The former 19 cm stance looked straddled/heavy')
        hips = matrices[:, r.index['hips'], 1, 3]
        self.assertGreater(hips.min(), .865)
        self.assertLess(np.ptp(hips), .027)

    def test_real_skin_soles_clear_the_ground_between_baked_keys(self):
        feet = self.mesh['POSITION'][:, 1] < .09
        for name in ['walk_relaxed', 'run_relaxed', 'sprint_relaxed']:
            c = self.data['clips'][name]
            minimum = 1
            for phase in np.linspace(0, 1, 193, endpoint=False):
                vertices = self.rig.skin(*sample(c, phase*c['duration']), self.mesh)
                minimum = min(minimum, vertices[feet, 1].min())
            self.assertGreater(minimum, -.0012, (name, minimum, 'skin sole, not an ankle-only check'))
            self.assertEqual(c['sample_fps'], 120)

    def test_airborne_toes_follow_the_foot_instead_of_staying_flat(self):
        r = self.rig
        for name in ['walk_relaxed', 'run_relaxed', 'sprint_relaxed']:
            c = self.data['clips'][name]
            for side, offset in [('L', 0), ('R', .5)]:
                phase = (c['duty']+(1-c['duty'])*.30-offset) % 1
                g = self.globals(name, phase)
                a = g[r.index['foot.'+side], :3, :3]@r.rest_world[r.index['foot.'+side], :3, :3].T
                b = g[r.index['toe.'+side], :3, :3]@r.rest_world[r.index['toe.'+side], :3, :3].T
                angle = Rotation.from_matrix(a.T@b).magnitude()
                self.assertLess(angle, .012, (name, side))
                self.assertGreater(Rotation.from_matrix(b).magnitude(), .12)

    def test_the_three_tiers_have_different_mechanics_not_just_durations(self):
        peaks = []
        r = self.rig
        for name, duty in [('walk_relaxed', .58), ('run_relaxed', .28), ('sprint_relaxed', .20)]:
            c = self.data['clips'][name]
            self.assertEqual(c['duty'], duty)
            matrices = np.asarray([self.globals(name, phase) for phase in np.linspace(0, 1, 97, endpoint=False)])
            peaks.append(matrices[:, r.index['foot.L'], 1, 3].max())
            # Walk has double support; jogging/sprinting have flight.
            contacts = np.array([[(phase+offset) % 1 < duty for offset in [0, .5]]
                                 for phase in np.linspace(0, 1, 100, endpoint=False)])
            self.assertEqual(contacts.all(1).any(), name == 'walk_relaxed')
            self.assertEqual((~contacts.any(1)).any(), name != 'walk_relaxed')
        self.assertGreater(peaks[1]-peaks[0], .19)
        self.assertGreater(peaks[2]-peaks[1], .15)

    def test_dodge_planted_feet_cancel_the_shared_root_displacement(self):
        r = self.rig
        for name, direction in [('dodge', [0, 0, 1]), ('dodge_back', [0, 0, -1]),
                                ('dodge_left', [1, 0, 0]), ('dodge_right', [-1, 0, 0])]:
            c = self.data['clips'][name]
            for side in ['L', 'R']:
                prefix = 'lead' if side == c['lead'] else 'trail'
                for start, end in [(0, c[prefix+'_lift']), (c[prefix+'_land'], c['duration'])]:
                    points = []
                    for t in np.linspace(start, end, 19):
                        g = self.globals(name, t/c['duration'])
                        root = np.asarray(direction)*DODGE_DISTANCE*dodge_progress(t/c['duration'])
                        points.append(g[r.index['foot.'+side], :3, 3]+root)
                    self.assertLess(np.ptp(points, axis=0).max(), .003, (name, side, start))


if __name__ == '__main__':
    unittest.main(verbosity=2)
