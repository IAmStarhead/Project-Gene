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

    def test_armpits_are_sewn_not_overlapping_unconnected_sleeves(self):
        from collections import Counter
        gown = self.data['gown']
        tri = np.asarray(gown['indices']).reshape(-1, 3)
        edges = Counter(tuple(sorted((a, b))) for t in tri for a, b in zip(t, np.roll(t, -1)))
        self.assertEqual(len(gown['armhole_edges']), 52)
        self.assertTrue(all(edges[tuple(sorted(edge))] == 2 for edge in gown['armhole_edges']),
                        'Each armhole edge must have a real sleeve face on the other side')
        # Both sleeves and the torso are one connected garment surface, not
        # three floating tubes. The remaining components are the badge layers.
        from scipy.sparse import coo_matrix
        from scipy.sparse.csgraph import connected_components
        pairs = np.array(list(edges))
        graph = coo_matrix((np.ones(len(pairs)), pairs.T), shape=(len(gown['positions']),)*2)
        count, labels = connected_components(graph, directed=False)
        sizes = np.bincount(labels)
        self.assertEqual((sizes > 100).sum(), 1)
        self.assertEqual(count, 4)
        fabric = np.asarray(self.data['cloth']['fabric'])
        self.assertGreater(fabric.min(), .75)
        self.assertLess(np.ptp(fabric), .04, 'Requested white/light grey, not the former blue gown')

    def test_underarm_occlusion_is_confined_inside_the_real_short_sleeves(self):
        for sleeve in self.data['coverage']['sleeves']:
            axis = np.asarray(sleeve['axis'])
            self.assertAlmostEqual(np.linalg.norm(axis), 1)
            self.assertLess(sleeve['start'], 0)
            self.assertLess(sleeve['end'], .16, 'Bare arm must begin inside, not beyond, the cuff')
            self.assertGreater(sleeve['end'], .12)
            self.assertLess(sleeve['radius'], .13)
            self.assertGreater(sleeve['radius'], .09)

    def test_reduced_sole_probes_are_real_mesh_vertices_and_cover_blends(self):
        from test_motion_set import sample
        from build_motion_set import OUTPUT as MOTIONS
        r = self.rig
        mesh = r.mesh_data()
        probes = self.data['floor_probes']
        ids = np.asarray(probes['source_indices'])
        self.assertGreater(len(ids), 20)
        self.assertLess(len(ids), 120, 'Small per-frame native contact support set')
        for source, key in [('POSITION', 'positions'), ('JOINTS_0', 'joints'), ('WEIGHTS_0', 'weights')]:
            np.testing.assert_allclose(mesh[source][ids], probes[key], atol=1e-7)
        floor = mesh['POSITION'][:, 1] < .09
        full = {k: v[floor] for k, v in mesh.items() if k != 'indices'}
        small = {k: v[ids] for k, v in mesh.items() if k != 'indices'}
        clips = json.loads((MOTIONS/'motion_set.json').read_text())['clips']
        largest_error = 0
        for a, b in [('walk_relaxed', 'run_relaxed'), ('run_relaxed', 'sprint_relaxed'),
                     ('walk_relaxed', 'sprint_relaxed'), ('walk_relaxed', 'walk'), ('run_relaxed', 'run')]:
            # Different phases/weights than the training grid; use baked
            # source keys, and check the WHOLE soft sole independently.
            for phase in np.linspace(.003, .997, 57):
                q0, h0 = sample(clips[a], phase*clips[a]['duration'])
                q1, h1 = sample(clips[b], phase*clips[b]['duration'])
                for u in [.31, .67]:
                    q1 = q1*np.where(np.sum(q0*q1, axis=1, keepdims=True) < 0, -1, 1)
                    angle = np.arccos(np.clip(np.sum(q0*q1, axis=1), -1, 1))
                    sine = np.maximum(np.sin(angle), 1e-10)
                    q = np.sin((1-u)*angle)[:, None]/sine[:, None]*q0+np.sin(u*angle)[:, None]/sine[:, None]*q1
                    same = angle < .0001
                    q[same] = (q0*(1-u)+q1*u)[same]
                    q /= np.linalg.norm(q, axis=1, keepdims=True)
                    hip = h0*(1-u)+h1*u
                    actual = r.skin(q, hip, full)[:, 1].min()
                    reduced = r.skin(q, hip, small)[:, 1].min()
                    largest_error = max(largest_error, reduced-actual)
        self.assertLess(largest_error, .0007, 'Runtime 1 mm lift must cover the full sole too')

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
