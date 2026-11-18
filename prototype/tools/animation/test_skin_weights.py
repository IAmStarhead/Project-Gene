"""Regress the real axilla fin and relaxed hand/hip clearance, not just bones."""
import hashlib
import sys
import unittest

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

from build_motion_set import MODEL, ROOT
from rig_math import Rig
from test_motion_set import sample

sys.path.insert(0, str(MODEL.parent))
from sanitize_glb import (read_glb, bake_fists_into_geometry, strip,
                          fix_burnthrough_weights, weld_seam_weights)
from repair_shoulders import repair_axilla_weights


class SkinWeightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import json
        cls.rig = Rig(MODEL)
        cls.mesh = cls.rig.mesh_data()
        cls.data = json.loads((MODEL.parent / 'animations/motion_set.json').read_text())
        cls.source = ROOT / 'models/heroine/female_A_rigged.glb'
        # Reconstruct the previous sanitization pipeline in memory. Do not
        # commit another binary model just to have a regression fixture.
        cls.gltf, binary = read_glb(cls.source)
        binary, _ = bake_fists_into_geometry(cls.gltf, binary)
        strip(cls.gltf)
        binary, _ = fix_burnthrough_weights(cls.gltf, binary)
        cls.before, _ = weld_seam_weights(cls.gltf, binary)

    def test_safe_model_is_reproducible_from_the_untouched_original(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(),
                         'e5f8d6cd051e42db2967f534f749cd5bf684a218e7e006ed8218ecb534ea06ed')
        result, report = repair_axilla_weights(self.gltf, self.before)
        self.assertEqual(result, self.rig.binary)
        self.assertEqual(self.gltf, self.rig.gltf)
        self.assertEqual(len(report['lobes']), 3)
        self.assertGreater(report['changed'], 1000)
        self.assertLess(report['changed'], 2000)

    def test_only_body_skin_weights_changed_not_geometry_or_materials(self):
        before, after = bytearray(self.before), bytearray(self.rig.binary)
        attrs = self.gltf['meshes'][0]['primitives'][0]['attributes']
        for name in ('JOINTS_0', 'WEIGHTS_0'):
            accessor = self.gltf['accessors'][attrs[name]]
            view = self.gltf['bufferViews'][accessor['bufferView']]
            start = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
            width = accessor['count'] * 4 * (2 if name == 'JOINTS_0' else 4)
            before[start:start+width] = bytes(width)
            after[start:start+width] = bytes(width)
        self.assertEqual(before, after,
                         'Positions, triangles, UVs, normals, eyes, fists and bind matrices must stay intact')
        weights = self.mesh['WEIGHTS_0']
        self.assertTrue(np.isfinite(weights).all() and (weights >= 0).all())
        np.testing.assert_allclose(weights.sum(axis=1), 1, atol=2e-7)
        # The old fist bake left stale bounds ~0.025 mm inside the hand.
        # Correct metadata, without moving a single vertex a second time.
        position = self.gltf['accessors'][attrs['POSITION']]
        np.testing.assert_array_equal(position['min'], self.mesh['POSITION'].min(axis=0))
        np.testing.assert_array_equal(position['max'], self.mesh['POSITION'].max(axis=0))

    def test_arm_and_torso_surface_lobes_do_not_pull_each_other_below_axilla(self):
        p, inverse = np.unique(self.mesh['POSITION'].round(6), axis=0, return_inverse=True)
        triangles = inverse[self.mesh['indices']]
        edges = np.concatenate([triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]])
        band = (p[:, 1] > 1.115) & (p[:, 1] < 1.235)
        edges = edges[band[edges].all(axis=1)]
        graph = coo_matrix((np.ones(len(edges)), edges.T), shape=(len(p), len(p)))
        _, labels = connected_components(graph, directed=False)
        lobes = [np.flatnonzero(labels == i) for i in np.flatnonzero(np.bincount(labels) > 30)]
        self.assertEqual(len(lobes), 3)
        # Label by each connected surface's centroid, NOT by slicing vertices
        # through the narrow air gap (the historical destructive shortcut).
        lobes.sort(key=lambda lobe: p[lobe, 0].mean())
        arm_bones = [self.rig.index[bone+'.'+side] for side in ('L', 'R')
                     for bone in ('upper_arm', 'forearm', 'hand')]
        amount = (self.mesh['WEIGHTS_0'] * np.isin(self.mesh['JOINTS_0'], arm_bones)).sum(axis=1)
        for i, lobe in enumerate(lobes):
            values = amount[np.isin(inverse, lobe)]
            if i == 1:
                self.assertLess(values.max(), .00001, 'Chest skin is being dragged by an arm')
            else:
                self.assertGreater(values.min(), .9999, 'Upper arm is pinned to the chest again')

    def test_underarm_shaft_does_not_stretch_into_a_fin(self):
        p, triangles = self.mesh['POSITION'], self.mesh['indices']
        edges = np.concatenate([triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]])
        edges = np.unique(np.sort(edges, axis=1), axis=0)
        endpoints = p[edges]
        length = np.linalg.norm(endpoints[:, 1] - endpoints[:, 0], axis=1)
        # The inner upper-arm shaft, below the shoulder's necessary blend cap.
        selected = (endpoints[:, :, 1] > 1.13).all(axis=1) & (endpoints[:, :, 1] < 1.21).all(axis=1) \
            & (np.abs(endpoints[:, :, 0]) > .125).all(axis=1) \
            & (np.abs(endpoints[:, :, 0]) < .17).all(axis=1) & (length > .001)
        edges, length = edges[selected], length[selected]
        self.assertGreater(len(edges), 500)
        minimum, maximum = 1.0, 1.0
        for name, clip in self.data['clips'].items():
            for time in np.linspace(0, clip['duration'], 35):
                v = self.rig.skin(*sample(clip, time), self.mesh)
                ratio = np.linalg.norm(v[edges[:, 1]] - v[edges[:, 0]], axis=1) / length
                minimum, maximum = min(minimum, ratio.min()), max(maximum, ratio.max())
                self.assertLess(ratio.max(), 1.25, name)  # old attack: >9x
                self.assertGreater(ratio.min(), .75, name)
        print(f'\n  Inner upper-arm edge stretch: {minimum:.3f}–{maximum:.3f}x (all 14 clips)')

    def test_relaxed_hands_do_not_cut_through_the_hips(self):
        m, r = self.mesh, self.rig
        dominant = m['JOINTS_0'][np.arange(len(m['POSITION'])), m['WEIGHTS_0'].argmax(axis=1)]
        hand = np.isin(dominant, [r.index['hand.L'], r.index['hand.R']])
        torso = np.isin(dominant, [r.index[name] for name in ('hips', 'spine', 'chest', 'thigh.L', 'thigh.R')]) \
            & (m['POSITION'][:, 1] < 1.24)
        smallest_gap = 1.0
        for name in ('idle_relaxed', 'walk_relaxed', 'run_relaxed'):
            clip = self.data['clips'][name]
            for time in np.linspace(0, clip['duration'], 61):
                q, h = sample(clip, time)
                v = r.skin(q, h, m)
                distance, nearest = cKDTree(v[torso]).query(v[hand])
                smallest_gap = min(smallest_gap, distance.min())
                self.assertGreater(distance.min(), .004, (name, time, 'hand/hip clearance'))
                matrices = r.globals(q, h) @ r.inverse_bind
                normals = np.zeros_like(v)
                for k in range(4):
                    normals += m['WEIGHTS_0'][:, k, None] * np.einsum(
                        'nij,nj->ni', matrices[m['JOINTS_0'][:, k], :3, :3], m['NORMAL'])
                signed = np.einsum('ij,ij->i', v[hand] - v[torso][nearest], normals[torso][nearest])
                self.assertFalse(((signed < -.002) & (distance < .04)).any(), (name, time))
        # A local near-surface regression, NOT a proof of no self-intersection
        # anywhere on a soft skinned model or future clothing.
        print(f'\n  Relaxed hand/hip sampled surface gap: {smallest_gap*1000:.2f} mm')


if __name__ == '__main__':
    unittest.main(verbosity=2)
