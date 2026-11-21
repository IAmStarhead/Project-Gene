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
        self.assertGreater(len(p), 5000)
        self.assertLess(len(p), 14000)
        self.assertTrue(np.isfinite(p).all())
        self.assertTrue(np.isfinite(n).all())
        np.testing.assert_allclose(np.linalg.norm(n, axis=1), 1, atol=1e-6)
        np.testing.assert_allclose(w.sum(axis=1), 1, atol=2e-7)
        self.assertGreaterEqual(w.min(), 0)
        self.assertGreaterEqual(j.min(), 0)
        self.assertLess(j.max(), 21)
        self.assertLess(p[:, 1].min(), .15, 'long legs, not shorts')
        self.assertGreater(p[:, 1].max(), 1.43, 'closed neckline, not an open sports top')
        self.assertEqual(len(s['face_groups']), len(s['indices'])//3)
        self.assertEqual(len(s['boundaries']), 5, 'one-piece: neck, two wrists, two ankles; no loose waist overlap')
        self.assertGreater(np.ptp(np.asarray(s['colors']), axis=0).min(), .35, 'petrol/sage/ochre textile palette')

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
        self.assertNotIn('hem', c, 'continuous fitted waist, not two floating overlapping shells')
        self.assertEqual(len(c['wrists']), 2)
        for cuff in c['wrists']:
            self.assertAlmostEqual(np.linalg.norm(cuff['axis']), 1, places=6)
            self.assertLess(cuff['end'], .23)
            self.assertGreater(cuff['end'], .20)

    def test_waist_and_crotch_are_one_connected_surface_not_overlapping_panels(self):
        s = self.suit
        p = np.asarray(s['positions'])
        tri = np.asarray(s['indices']).reshape(-1,3)[np.asarray(s['face_groups']) == 'suit_shell']
        count = s['fit']['shell_vertices']
        adjacency = [set() for _ in range(count)]
        for face in tri:
            for a,b in zip(face,np.roll(face,-1)):
                adjacency[a].add(b); adjacency[b].add(a)
        seen, todo = set(), [0]
        while todo:
            i = todo.pop()
            if i in seen: continue
            seen.add(i); todo.extend(adjacency[i]-seen)
        self.assertEqual(len(seen), count, 'neck / armholes / inseam are sewn into one shell')
        self.assertTrue(any(p[face,1].min() < 1.03 < p[face,1].max() for face in tri),
                        'actual triangles bridge the waist, not a gap hidden by a mask')
        for b in s['boundaries']:
            self.assertNotIn(b['opening'], ['waist','hem'])

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
