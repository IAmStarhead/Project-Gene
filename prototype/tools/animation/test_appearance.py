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
        self.assertGreater(len(p), 3000)
        self.assertLess(len(p), 5000, 'Tailored mesh stays small enough for both actors')
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
        # Cutting a dense source triangle at a plane can leave valid tiny
        # slivers. The former coarse-ring 1e-7 bound does not apply; retain
        # strict nonzero area plus unit-normal/manifold/boundary tests.
        self.assertGreater(area.min(), 1e-10)

    def test_bodice_and_cloth_have_the_same_pinned_waist_seam(self):
        gown, cloth = self.data['gown'], self.data['cloth']
        n, segments = gown['waist_vertices'], cloth['segments']
        rim = np.asarray(cloth['positions'])[:segments]
        seam_normals = np.asarray(gown['waist_normals'])
        self.assertEqual(seam_normals.shape, (segments, 3))
        np.testing.assert_allclose(np.linalg.norm(seam_normals, axis=1), 1, atol=1e-6)
        bodice = np.asarray(gown['positions'])[:n]
        for k, at in enumerate(gown['waist_cloth_samples']):
            lo = int(at)
            expected = rim[lo]*(1-(at-lo))+rim[(lo+1)%segments]*(at-lo)
            np.testing.assert_allclose(bodice[k], expected, atol=1e-7)
            normal = seam_normals[lo]*(1-(at-lo))+seam_normals[(lo+1)%segments]*(at-lo)
            normal /= np.linalg.norm(normal)
            np.testing.assert_allclose(gown['normals'][k], normal, atol=1e-6,
                                       err_msg='Pinned seam lighting must match, not read as a separate grey belt')
        np.testing.assert_allclose(np.asarray(gown['weights'])[:n, 0], 1)
        self.assertTrue(np.all(np.asarray(gown['joints'])[:n, 0] == self.rig.index['hips']))

    def test_continuous_shoulders_have_no_unsewn_armhole_edges(self):
        from collections import Counter
        from scipy.sparse import coo_matrix
        from scipy.sparse.csgraph import connected_components
        gown = self.data['gown']
        tri = np.asarray(gown['indices']).reshape(-1, 3)
        edges = Counter(tuple(sorted((a, b))) for t in tri for a, b in zip(t, np.roll(t, -1)))
        self.assertTrue(all(count in [1, 2] for count in edges.values()), 'No non-manifold textile edges')
        # Cuff/neck outer edges are sewn to turned facings, not left as
        # independent, open overlapping tubes. Their INNER ends remain open.
        self.assertGreater(len(gown['cuff_edges']), 60)
        for edge in gown['cuff_edges']+gown['neck_edges']:
            self.assertEqual(edges[tuple(sorted(edge))], 2)
        pairs = np.array(list(edges))
        graph = coo_matrix((np.ones(len(pairs)), pairs.T), shape=(len(gown['positions']),)*2)
        count, labels = connected_components(graph, directed=False)
        self.assertEqual((np.bincount(labels) > 1000).sum(), 1)
        self.assertEqual(count, 4, 'One connected bodice+sleeves and three small badge layers')
        boundary = np.array([edge for edge, count in edges.items() if count == 1])
        graph = coo_matrix((np.ones(len(boundary)), boundary.T), shape=(len(gown['positions']),)*2)
        _, labels = connected_components(graph, directed=False)
        self.assertEqual(len(np.unique(labels[boundary.ravel()])), 7,
                         'Only waist, neck facing, two cuff facings, and three badge outlines are open')
        fabric = np.asarray(self.data['cloth']['fabric'])
        self.assertGreater(fabric.min(), .75)
        self.assertLess(np.ptp(fabric), .04)
        self.assertGreater(min(self.data['cloth']['binding']), .60, 'No near-black collar/binding')

    def test_facing_contact_groups_are_explicit_and_do_not_enlarge_the_cuff(self):
        gown = self.data['gown']
        groups = gown['face_groups']
        tri = np.asarray(gown['indices']).reshape(-1, 3)
        self.assertEqual(len(groups), len(tri))
        self.assertEqual(set(groups), {'outer', 'binding', 'cuff_facing', 'neck_facing', 'waist_adapter', 'badge'})
        p = np.asarray(gown['positions'])
        for a, b in gown['cuff_edges']:
            for i in [a, b]:
                side = 'L' if p[i, 0] > 0 else 'R'
                root = self.rig.rest_world[self.rig.index['upper_arm.'+side]]
                self.assertAlmostEqual(np.dot(p[i]-root[:3, 3], root[:3, 1]), .158, places=6)
        self.assertGreater(groups.count('cuff_facing'), 100)
        self.assertGreater(groups.count('outer'), 5000)

    def test_underarm_mask_stops_well_inside_the_tailored_cuff(self):
        coverage = self.data['coverage']
        # Report 40 forbids hiding the shoulder repair with a larger mask.
        # Freeze the exact coverage parameters accepted in 2c9de18.
        self.assertEqual(hashlib.sha256(json.dumps(coverage, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                         '38b65962878c656020cedaeeaa125e272f7176ee7a129a553532db610d55d894')
        self.assertTrue(coverage['preserve_limbs'])
        self.assertEqual(coverage['sleeves'], [], 'The broad legacy sleeve cylinders must not be used')
        self.assertEqual(len(coverage['underarm_cores']), 2)
        for core in coverage['underarm_cores']:
            self.assertAlmostEqual(np.linalg.norm(core['axis']), 1)
            self.assertLessEqual(core['end'], .11)
            self.assertLessEqual(core['radius'], .085)
            self.assertGreaterEqual(core['cuff']-core['end'], .05,
                                    'At least 5 cm of real skin overlap behind the cuff, not an amputated edge')

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

    def test_cloth_spends_material_length_and_samples_surface_contacts(self):
        cloth = self.data['cloth']
        p = np.asarray(cloth['positions'])
        self.assertEqual(p.shape, (320, 3))
        self.assertEqual(len(p), cloth['rings']*cloth['segments'])
        self.assertEqual(cloth['segments'], 32, 'No old 16-sided umbrella')
        self.assertLessEqual(cloth['max_secondary_offset'], .025)
        self.assertEqual(cloth['solver'], 'arc_length_drape_v4')
        self.assertEqual(cloth['surface_relaxations'], 3)
        self.assertEqual(cloth['angular_relaxations'], 2)
        self.assertTrue(cloth['surface_samples'], 'Contact at half cells, not just particles')
        self.assertEqual(cloth['iterations'], 0, 'Do not solve then discard edge constraints in a radial shell')
        self.assertEqual(cloth['edges'], [])
        self.assertLessEqual(cloth['max_secondary_offset'], .012)
        self.assertGreaterEqual(cloth['min_drape_fraction'], .85)
        heights = np.asarray(cloth['sample_heights'])
        self.assertEqual(len(heights), cloth['rings']*2-1)
        self.assertTrue((np.diff(heights) < 0).all())
        sample = np.asarray(cloth['sample_positions']).reshape(len(heights), 32, 3)
        drape = np.asarray(cloth['drape_positions']).reshape(len(heights), 32, 3)
        np.testing.assert_allclose(sample[:, :, 1], np.broadcast_to(heights[:, None], sample[:, :, 1].shape), atol=1e-7)
        np.testing.assert_allclose(sample[::2], drape[::2], atol=1e-7)
        np.testing.assert_allclose(sample[1::2], (drape[1::2]+np.roll(drape[1::2],-1,axis=1))*.5, atol=1e-7)
        grid = p.reshape(cloth['rings'],32,3)
        lengths = np.vstack([np.zeros(32),np.cumsum(np.linalg.norm(np.diff(grid,axis=0),axis=2),axis=0)])
        np.testing.assert_allclose(cloth['meridian_lengths'],lengths,atol=1e-7)
        np.testing.assert_allclose(cloth['circumferences'],np.linalg.norm(np.roll(grid,-1,axis=1)-grid,axis=2).sum(axis=1),atol=1e-7)
        self.assertGreaterEqual(p[0, 1], 1.0, 'Waist must be above the flexed upper thigh / knee')
        self.assertAlmostEqual(p[-1, 1], .543)
        self.assertLess(np.max(np.linalg.norm(p[:, [0, 2]], axis=1)), .24)
        self.assertEqual(len(cloth['capsules']), 6)
        for a, b, radius, start, end in cloth['capsules']:
            self.assertIn(a, self.rig.names)
            self.assertIn(b, self.rig.names)
            self.assertGreater(radius, .05)
            self.assertGreaterEqual(start, 0)
            self.assertLess(start, end)
            self.assertLessEqual(end, 1)
        self.assertTrue(all(c[3] >= .15 for c in cloth['capsules'][:2]),
                        'No false hip-end sphere expanding the skirt into the idle forearms')


if __name__ == '__main__':
    unittest.main(verbosity=2)
