"""Small, deterministic FK / two-bone IK toolkit for the existing 21-bone GLB.

No DCC application, auto-rigger, network service or mesh edits are involved.
Coordinates throughout authoring: metres, +Y up, +Z forward, .L on +X.
Rotations written to Godot are FULL parent-local poses, including the rest.
"""
from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation


def unit(v):
    v = np.asarray(v, dtype=float)
    return v / max(float(np.linalg.norm(v)), 1e-12)


def rotation(x=0.0, y=0.0, z=0.0):
    # Explicit composition, identical to Godot Basis(X) * Basis(Y) * Basis(Z).
    return Rotation.from_rotvec([np.deg2rad(x), 0, 0]).as_matrix() @ \
        Rotation.from_rotvec([0, np.deg2rad(y), 0]).as_matrix() @ \
        Rotation.from_rotvec([0, 0, np.deg2rad(z)]).as_matrix()


def read_glb(path):
    data = Path(path).read_bytes()
    magic, version, length = struct.unpack_from('<III', data)
    if magic != 0x46546C67 or version != 2 or length != len(data):
        raise ValueError(f'Invalid GLB: {path}')
    chunks, offset = {}, 12
    while offset < length:
        size, kind = struct.unpack_from('<II', data, offset)
        chunks[kind] = data[offset + 8:offset + 8 + size]
        offset += 8 + size
    return json.loads(chunks[0x4E4F534A]), chunks[0x004E4942]


def accessor(gltf, binary, index):
    a = gltf['accessors'][index]
    view = gltf['bufferViews'][a['bufferView']]
    types = {5121: 'u1', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
    components = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}
    dtype, nc = np.dtype(types[a['componentType']]), components[a['type']]
    start = view.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = view.get('byteStride', dtype.itemsize * nc)
    return np.ndarray((a['count'], nc), dtype=dtype, buffer=binary,
                      offset=start, strides=(stride, dtype.itemsize)).copy()


class Rig:
    def __init__(self, path):
        self.gltf, self.binary = read_glb(path)
        skin = self.gltf['skins'][0]
        self.nodes = skin['joints']
        self.names = [self.gltf['nodes'][i]['name'] for i in self.nodes]
        self.index = {name: i for i, name in enumerate(self.names)}
        parents = {child: i for i, n in enumerate(self.gltf['nodes'])
                   for child in n.get('children', [])}
        self.parents = [self.nodes.index(parents[node]) if parents.get(node) in self.nodes else -1
                        for node in self.nodes]
        self.positions = np.array([self.gltf['nodes'][i].get('translation', [0, 0, 0])
                                   for i in self.nodes], dtype=float)
        self.rotations = np.array([Rotation.from_quat(self.gltf['nodes'][i].get(
            'rotation', [0, 0, 0, 1])).as_matrix() for i in self.nodes])
        self.inverse_bind = accessor(self.gltf, self.binary, skin['inverseBindMatrices']) \
            .reshape(-1, 4, 4).transpose(0, 2, 1)
        self.rest_world = np.linalg.inv(self.inverse_bind)
        self.unreachable = []

    def pose(self):
        return Pose(self)

    def globals(self, quaternions, hip_position):
        matrices = Rotation.from_quat(quaternions).as_matrix()
        positions = self.positions.copy()
        positions[0] = hip_position
        out = np.repeat(np.eye(4)[None], len(self.names), axis=0)
        for i, parent in enumerate(self.parents):
            out[i, :3, :3], out[i, :3, 3] = matrices[i], positions[i]
            if parent >= 0:
                out[i] = out[parent] @ out[i]
        return out

    def mesh_data(self):
        p = self.gltf['meshes'][0]['primitives'][0]
        a = p['attributes']
        return {key: accessor(self.gltf, self.binary, a[key])
                for key in ('POSITION', 'NORMAL', 'JOINTS_0', 'WEIGHTS_0')} | {
                    'indices': accessor(self.gltf, self.binary, p['indices']).reshape(-1, 3)}

    def skin(self, quaternions, hip_position, mesh=None):
        mesh = self.mesh_data() if mesh is None else mesh
        mats = self.globals(quaternions, hip_position) @ self.inverse_bind
        p = np.c_[mesh['POSITION'], np.ones(len(mesh['POSITION']))]
        result = np.zeros((len(p), 3))
        for k in range(4):
            result += mesh['WEIGHTS_0'][:, k, None] * np.einsum(
                'nij,nj->ni', mats[mesh['JOINTS_0'][:, k]], p)[:, :3]
        return result


class Pose:
    def __init__(self, rig):
        self.rig = rig
        self.rotations = rig.rotations.copy()
        self.positions = rig.positions.copy()
        self._world = None

    def world(self, name):
        if self._world is None:
            out = np.repeat(np.eye(4)[None], len(self.rig.names), axis=0)
            for i, parent in enumerate(self.rig.parents):
                out[i, :3, :3], out[i, :3, 3] = self.rotations[i], self.positions[i]
                if parent >= 0:
                    out[i] = out[parent] @ out[i]
            self._world = out
        return self._world[self.rig.index[name]]

    def bend(self, name, x=0.0, y=0.0, z=0.0):
        i = self.rig.index[name]
        self.rotations[i] = self.rig.rotations[i] @ rotation(x, y, z)
        self._world = None

    def orient(self, name, world_rotation):
        i = self.rig.index[name]
        parent = self.rig.parents[i]
        parent_rotation = np.eye(3) if parent < 0 else self.world(self.rig.names[parent])[:3, :3]
        self.rotations[i] = parent_rotation.T @ world_rotation
        self._world = None

    def limb(self, upper, lower, end, target, pole, knee=False, roll=0.0):
        """Analytic IK with an explicit bend plane; no Euler sign guessing."""
        root = self.world(upper)[:3, 3].copy()
        target = np.asarray(target, float)
        l1 = np.linalg.norm(self.rig.positions[self.rig.index[lower]])
        l2 = np.linalg.norm(self.rig.positions[self.rig.index[end]])
        distance = np.linalg.norm(target - root)
        if distance > l1 + l2 - 0.001:
            self.rig.unreachable.append((upper, float(distance - (l1 + l2 - 0.001))))
        d = np.clip(distance, abs(l1 - l2) + 0.001, l1 + l2 - 0.001)
        direction = unit(target - root)
        toward_pole = np.asarray(pole) - root
        plane = unit(toward_pole - direction * np.dot(toward_pole, direction))
        along = (l1 * l1 + d * d - l2 * l2) / (2 * d)
        joint = root + direction * along + plane * np.sqrt(max(0, l1 * l1 - along * along))
        end_point = root + direction * d
        y1, y2 = unit(joint - root), unit(end_point - joint)
        hinge = unit(np.cross(y1, y2)) * (-1 if knee else 1)
        upper_world = np.column_stack((hinge, y1, np.cross(hinge, y1)))
        lower_world = np.column_stack((hinge, y2, np.cross(hinge, y2))) @ rotation(y=roll)
        self.orient(upper, upper_world)
        self.orient(lower, lower_world)
        return lower_world

    def foot(self, side, position, pitch=0.0, yaw=0.0):
        name = 'foot.' + side
        foot_rotation = rotation(y=yaw) @ rotation(x=pitch) @ self.rig.rest_world[
            self.rig.index[name], :3, :3]
        position = np.array(position, float)
        # A toe-off pivots about the forefoot, not the ankle through the floor.
        toe_vector = rotation(y=yaw) @ rotation(x=pitch) @ np.array([0, -.06, .12])
        if pitch > 0:
            position[1] += -.06 - toe_vector[1]
            position[2] += .12 - toe_vector[2]
        self.limb('thigh.' + side, 'shin.' + side, name, position,
                  [position[0], .42, .70], knee=True)
        self.orient(name, foot_rotation)
        self.orient('toe.' + side, rotation(y=yaw) @ rotation(x=min(pitch, 0)) @
                    self.rig.rest_world[self.rig.index['toe.' + side], :3, :3])

    def arm(self, side, wrist, pole=None, roll=0.0):
        sign = 1 if side == 'L' else -1
        if pole is None:
            pole = [sign * .30, .99, .12]
        lower_rotation = self.limb('upper_arm.' + side, 'forearm.' + side, 'hand.' + side,
                                   wrist, pole, roll=roll)
        # Straight wrist, with pronation independent of the fist's trajectory.
        self.orient('hand.' + side, lower_rotation)

    def export(self):
        return Rotation.from_matrix(self.rotations).as_quat(), self.positions[0].copy()
