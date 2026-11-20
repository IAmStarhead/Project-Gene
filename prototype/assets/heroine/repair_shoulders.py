"""Topology-aware axilla weights for this heroine's existing 21-bone skin.

Authoring helper for sanitize_glb.py; numpy/scipy, no DCC or runtime dependency.
The rest positions, triangles, normals, UVs, bind pose and original GLB stay
untouched. Crucially, an x-coordinate cut does NOT decide what is an arm.
"""
from __future__ import annotations

import numpy as np


def shoulder_weights(positions, triangles, joints, weights, names, pose_matrices=None):
    """Return four influences per vertex, with the arm/chest web released.

    Distance-to-bone weights pinned the INNER upper arm to the chest, while
    moving nearby chest skin with the arm. Raising the arm stretched this into
    a dark triangular fin. The two surfaces are close in Euclidean distance,
    but separate on the actual mesh below the axilla.

    Weld coincident seam vertices for the solve, identify the three surface
    lobes in a narrow upper-arm band by connectivity, and use the existing
    forearm influences to name the two arm lobes. Keep arm-chain proportions
    there, remove arm influence from the torso lobe, and minimise squared
    graph-Laplacian energy across the shoulder cap and its fixed one-ring.
    The graph never jumps across the air gap from the arm to the chest.
    The same result goes to every seam copy.

    Heights delimit the shoulder/elbow region of THIS model, not a generic
    auto-rig recipe. Fail loudly if its topology no longer has these lobes.
    """
    index = {name: i for i, name in enumerate(names)}
    p, inverse = np.unique(np.round(positions, 6), axis=0, return_inverse=True)
    tri = inverse[np.asarray(triangles).reshape(-1, 3)]
    edges = np.concatenate([tri[:, [0, 1]], tri[:, [1, 2]], tri[:, [2, 0]]])
    edges = np.unique(np.sort(edges, axis=1), axis=0)
    edges = edges[edges[:, 0] != edges[:, 1]]
    directed = np.concatenate([edges, edges[:, ::-1]])

    dense = np.zeros((len(positions), len(names)))
    for k in range(4):
        dense[np.arange(len(positions)), joints[:, k]] += weights[:, k]
    base = np.zeros((len(p), len(names)))
    np.add.at(base, inverse, dense)
    base /= np.bincount(inverse)[:, None]
    fixed = base.copy()

    band = (p[:, 1] > 1.05) & (p[:, 1] < 1.24)
    neighbors = [[] for _ in p]
    for a, b in edges[band[edges].all(axis=1)]:
        neighbors[a].append(b)
        neighbors[b].append(a)
    seen, lobes = set(), []
    for seed in np.flatnonzero(band):
        if seed in seen:
            continue
        stack, component = [int(seed)], []
        seen.add(seed)
        while stack:
            v = stack.pop()
            component.append(v)
            for neighbor in neighbors[v]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    stack.append(neighbor)
        if len(component) > 32:
            lobes.append(np.asarray(component))
    if len(lobes) != 3:
        raise ValueError(f'Expected torso and two arm lobes below axilla, got {len(lobes)}')

    arm_lobes = []
    for side in ('L', 'R'):
        which = max(range(3), key=lambda i: base[lobes[i], index['forearm.' + side]].sum())
        arm_lobes.append(which)
        vertices = lobes[which]
        chain = [index[bone + '.' + side] for bone in ('upper_arm', 'forearm', 'hand')]
        values = base[np.ix_(vertices, chain)]
        values /= values.sum(axis=1, keepdims=True)
        fixed[vertices] = 0
        fixed[np.ix_(vertices, chain)] = values
    if arm_lobes[0] == arm_lobes[1]:
        raise ValueError('Left and right arm unexpectedly share a surface lobe')
    torso = lobes[next(i for i in range(3) if i not in arm_lobes)]
    axial = [index[name] for name in ('hips', 'spine', 'chest', 'neck', 'head',
                                    'shoulder.L', 'shoulder.R')]
    values = base[np.ix_(torso, axial)]
    values /= values.sum(axis=1, keepdims=True)
    fixed[torso] = 0
    fixed[np.ix_(torso, axial)] = values

    # Fade back to the old elbow weights. Do not re-rig elbows, wrists, fingers
    # or any of the earlier hip/hand burnthrough repairs.
    u = np.clip((p[:, 1] - 1.05) / .06, 0, 1)
    u = (u*u*(3 - 2*u))[:, None]
    fixed = base*(1 - u) + fixed*u

    # Positive inverse-edge-length graph conductance. Include the collar /
    # lower trapezius in the SAME solve: the old 1.433 m / 55 mm anchors lay
    # across that moving transition and left a ridge at the neck in a cross.
    # Anchor the central neck and the upper neck instead; do not touch the
    # head, elbow or lower body, or change a rest vertex to hide the ridge.
    unknown = (p[:, 1] >= 1.24) & (p[:, 1] < 1.49) & (np.abs(p[:, 0]) > .035)
    active = np.bincount(directed[:, 0], minlength=len(p)) > 0
    unknown &= active
    vertices = np.flatnonzero(unknown)
    rows = np.full(len(p), -1, dtype=int)
    rows[vertices] = np.arange(len(vertices))
    # Fit the graph Laplacian over BOTH free vertices and their fixed one-ring.
    # Squared Laplacian energy gives a C1-like falloff at anchor boundaries;
    # the former harmonic solution had an abrupt weight derivative there.
    touch = unknown.copy()
    touch[directed[unknown[directed[:, 1]], 0]] = True
    row_ids = np.flatnonzero(touch)
    row_lookup = np.full(len(p), -1, dtype=int)
    row_lookup[row_ids] = np.arange(len(row_ids))
    links = directed[touch[directed[:, 0]]]
    conductance = 1 / np.maximum(np.linalg.norm(p[links[:, 0]] - p[links[:, 1]], axis=1), .001)
    totals = np.bincount(row_lookup[links[:, 0]],weights=conductance,minlength=len(row_ids))
    conductance /= totals[row_lookup[links[:, 0]]]
    operator = np.zeros((len(row_ids),len(p)))
    operator[np.arange(len(row_ids)),row_ids] = 1
    np.add.at(operator,(row_lookup[links[:, 0]],links[:, 1]),-conductance)
    free = operator[:,unknown]
    rhs = -operator[:,~unknown] @ fixed[~unknown]
    fixed[vertices] = np.linalg.lstsq(free, rhs, rcond=1e-9)[0]
    fixed = np.maximum(fixed, 0)
    # LAPACK may leave ~1e-12 weights on unrelated bones, varying with its
    # thread count / reduction order. Those tails can even reorder padding
    # joints. Canonicalise numerical zero BEFORE four-influence selection;
    # otherwise byte-exact regeneration fails despite identical deformation.
    fixed[fixed < 1e-10] = 0
    fixed /= fixed.sum(axis=1, keepdims=True)

    if pose_matrices is not None:
        fixed = fair_deformed_weights(p, edges, fixed, unknown & (np.max(np.abs(fixed-base), axis=1) > 1e-6), pose_matrices, index)

    # Ordinary glTF four-weight LBS, not an engine-specific skinning trick.
    top = np.argsort(-fixed, axis=1, kind='stable')[:, :4]
    values = np.take_along_axis(fixed, top, axis=1)
    values /= values.sum(axis=1, keepdims=True)
    result_joints = top[inverse].astype(joints.dtype)
    result_weights = values[inverse].astype(weights.dtype)
    new_dense = np.zeros_like(dense)
    for k in range(4):
        new_dense[np.arange(len(positions)), result_joints[:, k]] += result_weights[:, k]
    changed = np.max(np.abs(new_dense - dense), axis=1) > 1e-6
    # Zero-weight padding does not own a joint. Avoid adding validator
    # warnings on the repaired vertices; leave unrelated legacy rows alone.
    result_joints[changed[:, None] & (result_weights == 0)] = 0
    # Preserve byte-for-byte all unaffected influences, including their order.
    result_joints[~changed] = joints[~changed]
    result_weights[~changed] = weights[~changed]
    return result_joints, result_weights, {'changed': int(changed.sum()),
        'lobes': [int(len(lobe)) for lobe in lobes], 'harmonic_vertices': int(len(vertices))}


def repair_axilla_weights(gltf, binary):
    """Apply shoulder_weights to the safe body's existing GLB buffer views."""
    body = next(mesh for mesh in gltf['meshes'] if mesh.get('name') == 'female_body')
    primitive = body['primitives'][0]
    attributes = primitive['attributes']
    types = {5123: '<u2', 5125: '<u4', 5126: '<f4'}

    def read(index):
        accessor = gltf['accessors'][index]
        view = gltf['bufferViews'][accessor['bufferView']]
        components = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[accessor['type']]
        dtype = np.dtype(types[accessor['componentType']])
        offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
        stride = view.get('byteStride', components * dtype.itemsize)
        array = np.ndarray((accessor['count'], components), dtype=dtype, buffer=binary,
                           offset=offset, strides=(stride, dtype.itemsize)).copy()
        return array, offset, stride

    positions, _, _ = read(attributes['POSITION'])
    triangles, _, _ = read(primitive['indices'])
    joints, joint_offset, joint_stride = read(attributes['JOINTS_0'])
    weights, weight_offset, weight_stride = read(attributes['WEIGHTS_0'])
    names = [gltf['nodes'][j]['name'] for j in gltf['skins'][0]['joints']]
    poses = fitting_matrices(gltf, read, names)
    joints, weights, report = shoulder_weights(positions, triangles, joints, weights, names, poses)
    result = bytearray(binary)
    for array, offset, stride in [(joints, joint_offset, joint_stride),
                                  (weights, weight_offset, weight_stride)]:
        width = array.shape[1] * array.dtype.itemsize
        if stride == width:
            result[offset:offset + array.nbytes] = array.tobytes()
        else:
            for i, row in enumerate(array):
                result[offset+i*stride:offset+i*stride+width] = row.tobytes()
    return bytes(result), report


def fitting_matrices(gltf, read, names):
    """Frozen, provenance-stamped pose samples; no dependency on generated clips."""
    import json
    from pathlib import Path
    from scipy.spatial.transform import Rotation
    samples = json.loads(Path(__file__).with_name('shoulder_fit_poses.json').read_text())['poses']
    nodes = gltf['skins'][0]['joints']
    parents = {child: i for i, node in enumerate(gltf['nodes']) for child in node.get('children', [])}
    inverse = read(gltf['skins'][0]['inverseBindMatrices'])[0].reshape(-1, 4, 4).transpose(0, 2, 1)
    rest = np.array([gltf['nodes'][node].get('translation', [0, 0, 0]) for node in nodes], float)
    result = []
    for sample in samples:
        matrices = np.repeat(np.eye(4)[None], len(nodes), axis=0)
        matrices[:, :3, :3] = Rotation.from_quat(sample['rotations']).as_matrix()
        matrices[:, :3, 3] = rest
        matrices[0, :3, 3] = sample['hips']
        for i, node in enumerate(nodes):
            parent = parents.get(node)
            if parent in nodes:
                matrices[i] = matrices[nodes.index(parent)] @ matrices[i]
        result.append(matrices @ inverse)
    return np.asarray(result)


def fair_deformed_weights(p, edges, weights, eligible, matrices, index):
    """Fit positive four-bone LBS to locally fair, detail-preserving skin targets.

    A smooth weight field alone is not a smooth DEFORMED shoulder. Delta-mush
    targets across 15 frozen poses suppress the collar ridge without editing
    a rest vertex, adding a runtime morph, moving a bone or expanding a mask.
    Ordinary/air/dodge poses participate too, not only the favourable cross.
    """
    from scipy.sparse import coo_matrix, eye
    from scipy.optimize import nnls
    directed = np.concatenate([edges, edges[:, ::-1]])
    conductance = 1/np.maximum(np.linalg.norm(p[directed[:, 0]]-p[directed[:, 1]], axis=1), .001)
    conductance /= np.bincount(directed[:, 0], weights=conductance, minlength=len(p))[directed[:, 0]]
    graph = coo_matrix((conductance, directed.T), shape=(len(p), len(p))).tocsr()
    smoothing = eye(len(p), format='csr')*.5+graph*.5
    skin = np.einsum('nb,sbij->snij', weights, matrices[:, :, :3])
    posed = np.einsum('snij,nj->sni', skin, np.c_[p, np.ones(len(p))])
    rest_smooth = p.copy()
    smooth = posed.copy()
    for _ in range(160):
        rest_smooth = smoothing @ rest_smooth
        for j in range(len(matrices)):
            smooth[j] = smoothing @ smooth[j]
    u, _, vh = np.linalg.svd(skin[:, :, :3, :3])
    rotations = u @ vh
    target = smooth+np.einsum('snij,nj->sni', rotations, p-rest_smooth)
    result = weights.copy()
    for i in np.flatnonzero(eligible):
        side = 'L' if p[i, 0] >= 0 else 'R'
        candidates = np.unique(np.r_[np.flatnonzero(weights[i] > 1e-5),
            [index[n] for n in ['chest', 'head', 'shoulder.'+side, 'upper_arm.'+side]]])
        positions = np.einsum('sbij,j->sib', matrices[:, candidates, :3], np.r_[p[i], 1]).reshape(-1, len(candidates))
        regularizer = .010
        a = np.vstack([positions, np.ones((1, len(candidates)))*2, np.eye(len(candidates))*regularizer])
        b = np.r_[target[:, i].ravel(), 2., weights[i, candidates]*regularizer]
        solved, _ = nnls(a, b)
        keep = np.argsort(-solved, kind='stable')[:4]
        solved4, _ = nnls(a[:, keep], b)
        values = np.zeros(len(index)); values[candidates[keep]] = solved4/max(solved4.sum(), 1e-12)
        # C1 join to the fixed old elbow / head / central-neck boundaries.
        def fade(v):
            v = np.clip(v, 0, 1)
            return v*v*(3-2*v)
        amount = fade((p[i, 1]-1.24)/.035)*fade((1.49-p[i, 1])/.025)*fade((abs(p[i, 0])-.035)/.030)
        result[i] = weights[i]*(1-amount)+values*amount
    for _ in range(12):
        candidate = result*.4+(graph @ result)*.6
        result[eligible] = candidate[eligible]
    return result
