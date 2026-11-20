"""Authoring regressions for a real closed, switchable laboratory outfit."""
from collections import Counter
import json
import unittest
import numpy as np
from build_appearance import OUTPUT
from build_motion_set import MODEL, OUTPUT as MOTIONS
from rig_math import Rig
from test_motion_set import sample


class LabSuitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.suit = json.loads(OUTPUT.read_text())['suit']
        cls.clips = json.loads((MOTIONS/'motion_set.json').read_text())['clips']

    def test_closed_top_long_trousers_are_a_small_real_skinned_mesh(self):
        s = self.suit
        p, n, w, j = [np.asarray(s[key]) for key in ['positions', 'normals', 'weights', 'joints']]
        self.assertGreater(len(p), 6000)
        self.assertLess(len(p), 14000)
        self.assertTrue(np.isfinite(p).all())
        self.assertTrue(np.isfinite(n).all())
        np.testing.assert_allclose(np.linalg.norm(n, axis=1), 1, atol=1e-6)
        np.testing.assert_allclose(w.sum(axis=1), 1, atol=2e-7)
        self.assertGreaterEqual(w.min(), 0)
        self.assertGreaterEqual(j.min(), 0)
        self.assertLess(j.max(), 21)
        self.assertLess(p[:, 1].min(), .14, 'long trousers, not shorts')
        self.assertGreater(p[:, 1].max(), 1.43, 'closed neckline, not an open sports top')
        self.assertEqual(len(s['face_groups']), len(s['indices'])//3)
        self.assertEqual(len(s['boundaries']), 7, 'neck, wrists, hem, waist and two ankles only')
        self.assertGreater(np.asarray(s['colors']).mean(), .70, 'matte light workwear, not black armour')

    def test_inseam_and_armholes_are_sewn_not_open_independent_tubes(self):
        s = self.suit
        tri = np.asarray(s['indices']).reshape(-1, 3)
        edges = Counter(tuple(sorted((a, b))) for t in tri for a, b in zip(t, np.roll(t, -1)))
        self.assertTrue(all(n in [1, 2] for n in edges.values()))
        for boundary in s['boundaries']:
            loop = boundary['vertices']
            for a, b in zip(loop, loop[1:]+loop[:1]):
                self.assertEqual(edges[tuple(sorted((a, b)))], 2, 'turned binding is actually joined to the shell')
        p = np.asarray(s['positions'])
        area = np.linalg.norm(np.cross(p[tri[:, 1]]-p[tri[:, 0]], p[tri[:, 2]]-p[tri[:, 0]]), axis=1)
        self.assertGreater(area.min(), 1e-11)

    def test_neck_wrist_ankle_masks_leave_explicit_skin_overlap(self):
        c = self.suit['coverage']
        self.assertGreaterEqual(c['skin_overlap'], .020)
        self.assertGreater(c['waist']-c['hem'], .08, 'top and trouser waist overlap while bending')
        self.assertEqual(len(c['wrists']), 2)
        for cuff in c['wrists']:
            self.assertAlmostEqual(np.linalg.norm(cuff['axis']), 1, places=6)
            self.assertLess(cuff['end'], .23)
            self.assertGreater(cuff['end'], .20)

    def test_waist_layers_and_cuff_openings_do_not_reintroduce_known_seams(self):
        s, r = self.suit, self.rig
        p, j, w = [np.asarray(s[k]) for k in ['positions', 'joints', 'weights']]
        hem = next(b['vertices'] for b in s['boundaries'] if abs(b['center'][1]-s['coverage']['hem']) < .005)
        np.testing.assert_allclose(p[hem, 1], s['coverage']['hem'], atol=1e-7)
        thighs = (w[hem]*np.isin(j[hem], [r.index['thigh.L'], r.index['thigh.R']])).sum(axis=1)
        self.assertGreater(thighs.max(), .25,
                           'A hips-only top hem was pierced by the raised trouser leg during dodge')
        for boundary in s['boundaries']:
            if abs(boundary['center'][1]-s['coverage']['ankle']) > .005:
                continue
            ids = boundary['vertices']
            side = 'L' if np.mean(p[ids, 0]) > 0 else 'R'
            hip, ankle = [r.rest_world[r.index[n+'.'+side], :3, 3] for n in ['thigh', 'foot']]
            u = (s['coverage']['ankle']-ankle[1])/(hip[1]-ankle[1])
            center = ankle*(1-u)+hip*u
            radius = np.linalg.norm(p[ids][:, [0, 2]]-center[[0, 2]], axis=1)
            self.assertGreater(radius.min(), .075, 'not the old tight 58 mm ankle tube pierced at sprint toe-off')
            self.assertLess(radius.max(), .085, 'straight workwear opening, not a baggy oversized calf')
        # At a common waist section the top must actually be OUTSIDE the
        # trousers, not just called an overlapping sewn panel. 32 rays.
        faces = np.asarray(s['indices']).reshape(-1, 3)
        groups = np.asarray(s['face_groups'])
        arm_ids = [i for i,n in enumerate(r.names) if n.startswith(('shoulder.', 'upper_arm.', 'forearm.', 'hand.'))]
        arms = (w*np.isin(j,arm_ids)).sum(axis=1)
        waist_faces = faces[(groups == 'top') & (arms[faces].mean(axis=1) < .15)]
        def radius_at(tri, direction):
            a, b, c = tri[:, 0], tri[:, 1], tri[:, 2]
            ab, ac = b-a, c-a
            cross = np.cross(np.broadcast_to(direction, ac.shape), ac)
            det = np.einsum('ij,ij->i', ab, cross)
            good = abs(det) > 1e-10
            inv = np.divide(1, det, out=np.zeros(len(det)), where=good)
            rel = np.array([0, .942, .02])-a
            u = np.einsum('ij,ij->i', rel, cross)*inv
            q = np.cross(rel, ab)
            v = q@direction*inv
            length = np.einsum('ij,ij->i', ac, q)*inv
            good &= (u >= 0) & (v >= 0) & (u+v <= 1) & (length >= 0)
            self.assertTrue(good.any(), 'closed panel at the actual waist section')
            # First exit from the torso shell. A lowered sleeve can lie
            # farther along the SAME ray; it is not extra waist inflation.
            return length[good].min()
        for angle in np.linspace(0, 2*np.pi, 32, endpoint=False):
            direction = np.array([np.sin(angle), 0, np.cos(angle)])
            gap = radius_at(p[waist_faces], direction)-radius_at(p[faces[groups == 'trousers']], direction)
            self.assertGreater(gap, .004, 'previous suit had negative waist gap / visible jagged trouser burnthrough')
            self.assertLess(gap, .025, 'local layered ease, not global inflation')

    def test_every_motion_keeps_the_suit_finite_and_attached(self):
        s, r = self.suit, self.rig
        mesh = {key: np.asarray(s[value]) for key, value in [
            ('POSITION', 'positions'), ('JOINTS_0', 'joints'), ('WEIGHTS_0', 'weights')]}
        # Bounds catch wrong bind transforms / indices, not arbitrary-pose
        # collision freedom. FCL and actual rendered inspection are separate.
        for name, clip in self.clips.items():
            for phase in [0, .19, .5, .83, 1]:
                q, h = sample(clip, phase*clip['duration'])
                p = r.skin(q, h, mesh)
                self.assertTrue(np.isfinite(p).all(), name)
                self.assertLess(abs(p[:, 0]).max(), 1.2, name)
                self.assertGreater(p[:, 1].min(), -.03, name)
                self.assertLess(p[:, 1].max(), 2.0, name)


if __name__ == '__main__':
    unittest.main()
