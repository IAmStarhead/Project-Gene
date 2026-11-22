"""Authoring checks for the sleeveless top and short trousers; not visual acceptance."""
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

    def test_light_two_piece_sleeveless_geometry(self):
        s = self.suit
        p, n, w, j, colors = [np.asarray(s[key]) for key in ['positions','normals','weights','joints','colors']]
        self.assertGreater(len(p), 3000)
        self.assertTrue(np.isfinite(p).all() and np.isfinite(n).all())
        np.testing.assert_allclose(np.linalg.norm(n, axis=1), 1, atol=1e-6)
        np.testing.assert_allclose(w.sum(axis=1), 1, atol=2e-7)
        self.assertGreaterEqual(w.min(), 0)
        self.assertGreaterEqual(j.min(), 0)
        self.assertLess(j.max(), len(self.rig.names))
        self.assertGreater(p[:,1].min(), .68)
        self.assertGreater(p[:,1].max(), 1.42)
        self.assertEqual(Counter(b['opening'] for b in s['boundaries']),
                         {'neck':1,'armhole':2,'top_hem':1,'waist':1,'leg_hem':2})
        self.assertTrue({'top','shorts','top_binding','shorts_binding'}.issubset(s['face_groups']))
        self.assertGreater(colors.min(), .60)
        self.assertLess(np.ptp(colors, axis=1).max(), .061, 'neutral white/light grey')
        self.assertGreater(s['fit']['ease_m'], .006, 'some ease, not skin-tight')

    def test_bindings_and_skin_overlap(self):
        s = self.suit
        tri = np.asarray(s['indices']).reshape(-1, 3)
        edges = Counter(tuple(sorted((a,b))) for t in tri for a,b in zip(t,np.roll(t,-1)))
        self.assertTrue(all(n in [1,2] for n in edges.values()))
        for boundary in s['boundaries']:
            loop = boundary['vertices']
            for a,b in zip(loop,loop[1:]+loop[:1]):
                self.assertEqual(edges[tuple(sorted((a,b)))], 2)
        self.assertGreaterEqual(s['coverage']['skin_overlap'], .018)
        self.assertGreater(s['coverage']['top_low'],s['coverage']['shorts_high'])
        p = np.asarray(s['positions'])
        area = np.linalg.norm(np.cross(p[tri[:,1]]-p[tri[:,0]],p[tri[:,2]]-p[tri[:,0]]),axis=1)
        self.assertGreater(area.min(), 1e-11)

    def test_every_motion_keeps_suit_finite_and_attached(self):
        s, r = self.suit, self.rig
        mesh = {key: np.asarray(s[value]) for key,value in [
            ('POSITION','positions'),('JOINTS_0','joints'),('WEIGHTS_0','weights')]}
        for name, clip in self.clips.items():
            for phase in [0,.19,.5,.83,1]:
                q,h = sample(clip,phase*clip['duration'])
                p = r.skin(q,h,mesh)
                self.assertTrue(np.isfinite(p).all(),name)
                self.assertLess(abs(p[:,0]).max(),1.2,name)
                # Climb's authored pelvis offsets are relative to an elevated
                # controller; compare its suit to the world floor, not local 0.
                rise = np.clip(phase/.65, 0, 1)
                root_y = .38 + 1.66*rise*rise*(3-2*rise) if name == 'ledge_climb' else 0
                self.assertGreater(p[:,1].min()+root_y,-.03,name)
                self.assertLess(p[:,1].max(),2.0,name)


if __name__ == '__main__':
    unittest.main()
