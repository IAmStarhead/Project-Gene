"""New target-facing cycles, independent of the frozen 18-clip regressions."""
import json
import unittest
import numpy as np
from build_motion_set import MODEL, OUTPUT
from rig_math import Rig
from test_motion_set import sample
from combat_locomotion import DIRECTIONS, TIERS


class DirectionalGaitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.clips = json.loads((OUTPUT/'motion_set.json').read_text())['clips']

    def test_all_headings_tiers_have_real_distinct_tracks_and_calibrated_metres(self):
        payloads = set()
        r = self.rig
        for direction in DIRECTIONS:
            for tier in TIERS:
                name = f'combat_{direction}_{tier}'
                c = self.clips[name]
                self.assertTrue(c['loop'])
                self.assertEqual(c['direction'], direction)
                self.assertEqual(c['tier'], tier)
                self.assertAlmostEqual(c['stride']/c['duration'], c['speed'])
                payloads.add(json.dumps(c['rotations']))
                for phase in np.linspace(0, 1, 51):
                    q, h = sample(c, phase*c['duration'])
                    g = r.globals(q, h)
                    self.assertGreater(h[1], .80, name+' is not a deep continuous crouch')
                    # Never rotate/reverse an ordinary run for a side step.
                    forward = g[0, :3, :3]@r.rest_world[0, :3, :3].T@np.array([0, 0, 1])
                    self.assertGreater(forward[2], .98)
                    left, right = [g[r.index['foot.'+s], :3, 3] for s in ['L', 'R']]
                    self.assertGreater(left[0]-right[0], .10, name+' crosses the feet')
                    for side in ['L', 'R']:
                        self.assertGreater(g[r.index['hand.'+side], 1, 3], 1.1)
        self.assertEqual(len(payloads), 12)

    def test_support_tracks_cancel_actual_travel_in_every_direction(self):
        r = self.rig
        for direction, (x, z) in DIRECTIONS.items():
            for tier in TIERS:
                name = f'combat_{direction}_{tier}'
                c = self.clips[name]
                for side, offset in [('L', 0), ('R', .5)]:
                    points = []
                    for phase in np.linspace(c['duty']*.20, c['duty']*.75, 20):
                        t = ((phase-offset) % 1)*c['duration']
                        g = r.globals(*sample(c, t))
                        point = g[r.index['foot.'+side], :3, 3].copy()
                        point += np.array([x, 0, z])*c['speed']*t
                        points.append(point[[0, 2]])
                    self.assertLess(np.ptp(points, axis=0).max(), .002, (name, side))

    def test_common_phase_does_not_swap_the_support_leg_on_a_diagonal(self):
        # At phase .04 L supports in ALL headings; R is recovered at +.5.
        # A lead-foot phase flip on right/back would blend a stance leg with
        # an airborne one and cancel the step on each diagonal.
        r = self.rig
        for tier in TIERS:
            for direction in DIRECTIONS:
                c = self.clips[f'combat_{direction}_{tier}']
                g = r.globals(*sample(c, .04*c['duration']))
                left = g[r.index['foot.L'], :3, 3]
                right = g[r.index['foot.R'], :3, 3]
                if tier != 'walk':
                    self.assertGreater(right[1]-left[1], .06, (direction, tier))


if __name__ == '__main__':
    unittest.main()
