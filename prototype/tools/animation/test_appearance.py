"""Regressions for the generated outfit and the real existing hand shape."""
import hashlib
import json
import unittest

import numpy as np

from build_appearance import OUTPUT, build
from build_motion_set import MODEL, ROOT
from rig_math import Rig, accessor, read_glb


class AppearanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(OUTPUT.read_text())
        cls.rig = Rig(MODEL)

    def test_generated_appearance_is_reproducible_and_matches_the_model(self):
        self.assertEqual(self.data, build())
        self.assertEqual(self.data['model_sha256'], hashlib.sha256(MODEL.read_bytes()).hexdigest())

    def test_relaxed_fingers_really_come_from_the_existing_source(self):
        source, binary = read_glb(ROOT/'models/heroine/female_A_rigged.glb')
        mesh = source['meshes'][0]
        primitive = mesh['primitives'][0]
        names = mesh['extras']['targetNames']
        q = self.data['hands']['curl']
        expected = accessor(source, binary, primitive['attributes']['POSITION'])
        for name, amount in [('Fists', q), ('FistQuarterCorrection', q*4)]:
            expected += amount*accessor(source, binary, primitive['targets'][names.index(name)]['POSITION'])
        body = self.rig.mesh_data()
        opened = body['POSITION'].copy()
        rows = np.asarray(self.data['hands']['rows'])
        indices = rows[:, 12].astype(int)
        self.assertEqual(len(np.unique(indices)), len(indices))
        self.assertGreaterEqual(len(indices), 3400)
        np.testing.assert_allclose(rows[:, :3], opened[indices], atol=1e-7)
        opened[indices] += rows[:, 6:9]
        np.testing.assert_allclose(opened, expected, atol=1e-7)
        delta = np.linalg.norm(opened-body['POSITION'], axis=1)
        self.assertGreater(delta.max(), .07, 'Lowered wrists cannot satisfy actual opening of the fingers')
        for side in ['L', 'R']:
            influence = (body['WEIGHTS_0']*(body['JOINTS_0'] == self.rig.index['hand.'+side])).sum(axis=1)
            selected = influence > .99
            closed_length = np.ptp(body['POSITION'][selected, 1])
            opened_length = np.ptp(opened[selected, 1])
            self.assertGreater(opened_length-closed_length, .025)
        normal = rows[:, 9:12]
        np.testing.assert_allclose(np.linalg.norm(normal, axis=1), 1, atol=1e-6)

    def test_gown_is_geometry_with_normalized_skeleton_weights(self):
        gown = self.data['gown']
        p, n, j, w = [np.asarray(gown[k]) for k in ['positions', 'normals', 'joints', 'weights']]
        self.assertGreater(len(p), 800)
        self.assertTrue(np.isfinite(p).all() and np.isfinite(n).all())
        self.assertGreaterEqual(w.min(), 0)
        self.assertLess(j.max(), len(self.rig.names))
        self.assertGreaterEqual(j.min(), 0)
        np.testing.assert_allclose(w.sum(axis=1), 1, atol=2e-7)
        np.testing.assert_allclose(np.linalg.norm(n, axis=1), 1, atol=1e-6)
        self.assertEqual(np.asarray(gown['indices']).ndim, 1, 'Godot and Three require flat index arrays')
        triangles = np.asarray(gown['indices']).reshape(-1, 3)
        self.assertLess(triangles.max(), len(p))
        area = np.linalg.norm(np.cross(p[triangles[:, 1]]-p[triangles[:, 0]],
                                      p[triangles[:, 2]]-p[triangles[:, 0]]), axis=1)
        self.assertGreater(area.min(), 1e-7)

    def test_bodice_and_cloth_have_the_same_pinned_waist_seam(self):
        gown, cloth = self.data['gown'], self.data['cloth']
        n, segments = gown['waist_vertices'], cloth['segments']
        rim = np.asarray(cloth['positions'])[:segments]
        bodice = np.asarray(gown['positions'])[:n]
        for k in range(n):
            at = k/n*segments
            lo = int(at)
            expected = rim[lo]*(1-(at-lo))+rim[(lo+1)%segments]*(at-lo)
            np.testing.assert_allclose(bodice[k], expected, atol=1e-7)
        np.testing.assert_allclose(np.asarray(gown['weights'])[:n, 0], 1)
        self.assertTrue(np.all(np.asarray(gown['joints'])[:n, 0] == self.rig.index['hips']))

    def test_cloth_is_small_finite_and_has_real_body_colliders(self):
        cloth = self.data['cloth']
        p = np.asarray(cloth['positions'])
        self.assertEqual(p.shape, (112, 3))
        self.assertEqual(len(p), cloth['rings']*cloth['segments'])
        self.assertLessEqual(cloth['max_secondary_offset'], .07)
        self.assertEqual(cloth['iterations'], 2)
        for a, b, length, stiffness in cloth['edges']:
            self.assertGreater(length, .001)
            self.assertGreater(stiffness, 0)
            self.assertLessEqual(stiffness, 1)
            self.assertAlmostEqual(length, np.linalg.norm(p[a]-p[b]), places=6)
        self.assertEqual(len(cloth['capsules']), 4)
        for a, b, radius in cloth['capsules']:
            self.assertIn(a, self.rig.names)
            self.assertIn(b, self.rig.names)
            self.assertGreater(radius, .05)


if __name__ == '__main__':
    unittest.main(verbosity=2)
