"""Approved short Q hook + directional head/body reaction authoring."""
import json
import unittest
import numpy as np
from scipy.spatial.transform import Rotation
from build_motion_set import MODEL, OUTPUT
from rig_math import Rig
from test_motion_set import sample, flexion


class NewCombatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.clips = json.loads((OUTPUT/'motion_set.json').read_text())['clips']

    def test_hook_is_short_low_curved_left_and_returns_to_guard(self):
        r, c = self.rig, self.clips['attack_body_hook']
        self.assertEqual((c['duration'], c['windup'], c['impact'], c['active_end'], c['reach'], c['side']),
                         (.62, .22, .22, .32, .60, 'L'))
        for t in [0, .62]:
            np.testing.assert_allclose(r.globals(*sample(c, t)),
                                       r.globals(*sample(self.clips['guard'], 0)), atol=2e-7)
        fists, feet = [], []
        for t in np.linspace(0, .62, 125):
            g = r.globals(*sample(c, t))
            wrist = g[r.index['hand.L'], :3, 3]
            self.assertLess(np.linalg.norm(wrist[[0, 2]]+np.array([0, .07])), .60)
            self.assertGreater(g[r.index['hand.R'], 1, 3], 1.29)
            feet.append(g[[r.index['foot.L'], r.index['foot.R']], :3, 3])
            if .22 <= t <= .32:
                fists.append(wrist)
                self.assertGreater(wrist[1], 1.08)
                self.assertLess(wrist[1], 1.15)
                bend = flexion(*[g[r.index[n+'.L'], :3, 3] for n in ['upper_arm', 'forearm', 'hand']])
                self.assertGreater(bend, 45, 'hook must not become another extended straight punch')
                self.assertLess(bend, 135)
        self.assertGreater(np.ptp(fists, axis=0)[0], .15, 'lateral active arc, not a third straight punch')
        self.assertLess(np.ptp(feet, axis=0).max(), .002, 'planted support, no action root slide')

    def test_head_torso_are_distinct_directional_upper_body_reactions(self):
        r = self.rig
        base = r.globals(*sample(self.clips['guard'], 0))
        head = r.globals(*sample(self.clips['hit_head_front'], .055))
        torso = r.globals(*sample(self.clips['hit_torso_front'], .055))
        def angle(g, bone):
            i = r.index[bone]
            return np.rad2deg(Rotation.from_matrix(base[i, :3, :3].T@g[i, :3, :3]).magnitude())
        self.assertGreater(angle(head, 'head')-angle(torso, 'head'), 10)
        self.assertGreater(angle(torso, 'chest')-angle(head, 'chest'), 8)
        for zone in ['head', 'torso']:
            frames = []
            for direction in ['front', 'back', 'left', 'right']:
                c = self.clips[f'hit_{zone}_{direction}']
                g = r.globals(*sample(c, .055))
                frames.append(g)
                np.testing.assert_allclose(r.globals(*sample(c, .32)), base, atol=2e-7)
                # These are templates for additive UPPER-body overlays;
                # no authored root displacement, stun or leg replacement.
                np.testing.assert_allclose(g[[r.index[n] for n in ['hips', 'thigh.L', 'shin.R', 'foot.L']]],
                                           base[[r.index[n] for n in ['hips', 'thigh.L', 'shin.R', 'foot.L']]], atol=2e-7)
            for i, a in enumerate(frames):
                for b in frames[i+1:]:
                    self.assertGreater(abs(a-b).max(), .05)


if __name__ == '__main__':
    unittest.main()
