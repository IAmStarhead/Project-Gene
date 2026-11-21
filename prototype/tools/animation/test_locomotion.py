"""Whole-body motion, three distinct tiers, real soles and anchored evasion.

These are specific regressions against the rejected stiff/wide shuffle. They
are not an automated claim that a human will find the resulting motion good.
"""
import hashlib
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
            # A forward gaze is not a world-space lock. Require a quiet but
            # nonzero response, rather than the former <1.2° test which
            # rewarded freezing the head independently of the moving neck.
            self.assertLess(abs(head[:, 1]).max(), 2.2, 'No looking away on each step')
            self.assertLess(abs(head[:, 2]).max(), 1.2, 'No exaggerated head bobble')
            self.assertLess(abs(head[:, 0]).max(), 6)
            self.assertGreater(np.ptp(head[:, 0]), 1.8, name)
            self.assertGreater(np.ptp(head[:, 1]), 1.8, name)
            self.assertLess(np.ptp(head[:, 1]), np.ptp(euler[:, 1, 1])*.35)

    def test_accepted_pelvis_legs_and_other_clips_are_unchanged(self):
        # User accepted the legs at 326bb48 and has not reviewed the dodges.
        # Protect their exact KEYS / timing, not just a loose range of motion.
        # Hashes are of the named lower-body payload, not the whole asset;
        # no old binary or duplicated animation fixture is needed in Git.
        expected = {
            'idle_relaxed': 'f6f8d5873757d40cc802a41a61dc2763946193bfe672bc4f81aa5ed9b13802af',
            'walk_relaxed': 'fa5f8dbf6a94c82eb95e91fbc6f0d699ca53e4961d6c31220e6efc073012b233',
            'run_relaxed': 'dee6739c44e8bf738b81e4b77eca06efaa865b0f45e8640f72cb93560c68fb68',
            'sprint_relaxed': '9605c15cbb433e014969ad958434ed058c45fbc4521a48991a07d2362d7f13ce',
        }
        def digest(payload):
            return hashlib.sha256(json.dumps(payload, separators=(',', ':'), sort_keys=True).encode()).hexdigest()
        lower = [i for i, bone in enumerate(self.rig.names) if bone == 'hips'
                 or bone.startswith(('thigh.', 'shin.', 'foot.', 'toe.'))]
        for name, sha in expected.items():
            c = self.data['clips'][name]
            payload = {key: c[key] for key in ['hips', 'times', 'duration', 'loop']}
            payload['rotations'] = [[frame[i] for i in lower] for frame in c['rotations']]
            self.assertEqual(digest(payload), sha, name)
        # The later user handoff explicitly rejects the jog arm carriage and
        # four air clips. All other old keys, including walk/sprint arms,
        # Q, reactions, directional clips and all dodges, are now protected
        # individually against the PRE-EDIT c9d24b1 manifest.
        from test_subject_and_kicks import assert_protected_motion
        assert_protected_motion(self, self.data)

    def test_dodge_hands_follow_the_chest_without_folding_into_the_shoulder(self):
        r = self.rig
        for name in ['dodge', 'dodge_back', 'dodge_left', 'dodge_right']:
            for phase in np.linspace(0, 1, 121):
                g = self.globals(name, phase)
                inverse = np.linalg.inv(g[r.index['chest']])
                for side in ['L', 'R']:
                    shoulder, elbow, wrist = [g[r.index[b+'.'+side], :3, 3]
                                               for b in ['upper_arm', 'forearm', 'hand']]
                    upper, fore = elbow-shoulder, wrist-elbow
                    bend = np.rad2deg(np.arccos(np.clip(np.dot(upper, fore)/np.linalg.norm(upper)/np.linalg.norm(fore), -1, 1)))
                    self.assertLess(bend, 140, (name, phase, side))
                    self.assertGreater(np.linalg.norm(wrist-shoulder), .185, 'Former ~4 cm near-singular fold')
                    tip = wrist+g[r.index['hand.'+side], :3, 1]*.075
                    self.assertGreater((inverse@np.r_[tip, 1])[2], .18, 'Fist must stay in FRONT of the shoulder/chest')


    def test_elbows_fold_forward_and_hands_return_towards_the_hip(self):
        r = self.rig
        for name in ['walk_relaxed', 'run_relaxed', 'sprint_relaxed']:
            matrices = np.asarray([self.globals(name, phase) for phase in np.linspace(0, 1, 241, endpoint=False)])
            chest = matrices[:, r.index['chest'], :3, :3]
            for side, sign in [('L', 1), ('R', -1)]:
                shoulder, elbow, wrist = [matrices[:, r.index[bone+'.'+side], :3, 3]
                                           for bone in ['upper_arm', 'forearm', 'hand']]
                upper, fore = elbow-shoulder, wrist-elbow
                angle = np.rad2deg(np.arctan2(upper[:, 2], -upper[:, 1]))
                bend = np.rad2deg(np.arccos(np.clip(np.einsum('ij,ij->i', upper, fore)
                     / np.linalg.norm(upper, axis=1) / np.linalg.norm(fore, axis=1), -1, 1)))
                # Old arms opened on the forward swing and folded on the
                # backward one (correlation < -.9). The hand stayed ahead.
                self.assertGreater(np.corrcoef(angle, bend)[0, 1], .80, (name, side))
                # R57 explicitly lowers jog from 91+/-13 to 80+/-10. Its
                # separate tighter 68..92 deg 3D envelope is tested in
                # test_subject_and_kicks, not silently applied to sprint.
                self.assertGreater(bend.min(), 14 if name == 'walk_relaxed' else 68 if name == 'run_relaxed' else 72)
                self.assertLess(bend.max(), 35 if name == 'walk_relaxed' else 115)
                self.assertLess((wrist-shoulder)[:, 2].max(), .32, (name, side))
                if name != 'walk_relaxed':
                    self.assertLess((wrist-shoulder)[:, 2].min(), .025 if name == 'run_relaxed' else -.045)
                    self.assertGreater(np.ptp(upper[:, 2]), .22 if name == 'run_relaxed' else .30)
                    # Front hands may move slightly inward; always-outward
                    # forearms recreate the rejected carrying-a-bag pose.
                    lateral = sign*np.einsum('ij,ij->i', fore, chest[:, :, 0])
                    self.assertLess(lateral.min(), -.025, (name, side))
                    self.assertGreater((wrist[:, 0]*sign).min(), .09)

    def test_real_hand_axes_stay_neutral_without_wrist_only_twisting(self):
        r = self.rig
        for name in ['idle_relaxed', 'walk_relaxed', 'run_relaxed', 'sprint_relaxed']:
            matrices = np.asarray([self.globals(name, phase) for phase in np.linspace(0, 1, 193, endpoint=False)])
            chest = matrices[:, r.index['chest'], :3, :3]
            for side, sign in [('L', 1), ('R', -1)]:
                fore = matrices[:, r.index['forearm.'+side], :3, :3]
                hand = matrices[:, r.index['hand.'+side], :3, :3]
                # Verified model-specific palm axis: +/-X, not Z (the hand's
                # width / thumb direction). A 90° axis mixup penetrates hips.
                inward = -sign*chest[:, :, 0]
                palm = sign*hand[:, :, 0]
                self.assertGreater(np.einsum('ij,ij->i', palm, inward).min(), .92, (name, side))
                relative = np.swapaxes(fore, 1, 2)@hand
                self.assertLess(np.rad2deg(Rotation.from_matrix(relative).magnitude()).max(), 2)

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
