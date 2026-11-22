"""Traversal-specific checks; not a replacement for rendered motion review."""
import json
import unittest
import numpy as np
from build_motion_set import MODEL, OUTPUT
from rig_math import Rig
from test_motion_set import sample


def smooth(u):
    u = np.clip(u, 0, 1)
    return u*u*(3-2*u)


class TraversalMotionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.mesh = cls.rig.mesh_data()
        cls.clips = json.loads((OUTPUT/'motion_set.json').read_text())['clips']

    def test_roll_skin_stays_near_the_floor(self):
        clip = self.clips['roll']
        self.assertEqual(clip['duration'], .8)
        for t in np.linspace(0, clip['duration'], 97):
            skin = self.rig.skin(*sample(clip,t), self.mesh)
            self.assertGreater(skin[:,1].min(), -.015, t)
            self.assertLess(skin[:,1].min(), .07, t)

    def test_hanging_and_early_pull_keep_wrists_near_the_lip(self):
        for name in ['ledge_hang','ledge_climb']:
            clip = self.clips[name]
            for phase in np.linspace(0, 1 if name == 'ledge_hang' else .65, 21):
                transforms = self.rig.globals(*sample(clip,phase*clip['duration']))
                root_y = .38 + (1.66*smooth(phase/.65) if name == 'ledge_climb' else 0)
                for side in ['L','R']:
                    hand = transforms[self.rig.index['hand.'+side],:3,3]
                    self.assertLess(abs(hand[1]+root_y-2.0), .035, (name,phase,side))
                    self.assertLess(abs(hand[2]-.32), .035, (name,phase,side))


if __name__ == '__main__':
    unittest.main()
