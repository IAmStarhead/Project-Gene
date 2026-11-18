"""Tailored lab-gown bodice derived from the existing, corrected body surface.

The old independent elliptical shoulder/sleeve charts gave a balloon silhouette
and an empty cuff.  This uses the body's continuous shoulder/axilla topology and
weights, a modest eased torso, and real turned cuff/neck facings.  No DCC needed.
"""
from __future__ import annotations

from collections import Counter

import numpy as np
from scipy.interpolate import PchipInterpolator


FABRIC = [.82, .835, .85]
BINDING = [.67, .69, .71]


def bodice(rig, waist, next_row):
    source = rig.mesh_data()
    p, j, w = [source[key] for key in ['POSITION', 'JOINTS_0', 'WEIGHTS_0']]
    dense = np.zeros((len(p), len(rig.names)))
    for k in range(4):
        dense[np.arange(len(p)), j[:, k]] += w[:, k]
    # Weld the existing UV seams before cutting: a textile is one continuous
    # surface, not coincident patches which separate under arm rotation.
    unique, first, inverse = np.unique(np.round(p, 6), axis=0, return_index=True, return_inverse=True)
    normal = np.zeros_like(unique)
    np.add.at(normal, inverse, source['NORMAL'])
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-10)
    p, dense = p[first].astype(float), dense[first]
    triangles = inverse[source['indices']]
    roots = {side: rig.rest_world[rig.index['upper_arm.'+side]] for side in ['L', 'R']}

    def fields(point, weights):
        values = [point[1]-1.045, 1.433-point[1]]
        for side, sign in [('L', 1), ('R', -1)]:
            root = roots[side]
            along = np.dot(point-root[:3, 3], root[:3, 1])
            arm = sum(weights[rig.index[name+'.'+side]] for name in ['upper_arm', 'forearm', 'hand'])
            values.append(max(.158-along, (.45-arm)*.20))
        return np.asarray(values)

    vertices, bone_weights, normals, tri = [], [], [], []
    lookup = {}

    def add(point, weights, n):
        key = tuple(np.round(point, 7))
        if key not in lookup:
            lookup[key] = len(vertices)
            vertices.append(point)
            bone_weights.append(weights)
            normals.append(n)
        return lookup[key]

    for face in triangles:
        polygon = [(p[i], dense[i], normal[i], fields(p[i], dense[i])) for i in face]
        for plane in range(4):
            clipped = []
            for a, b in zip(polygon, polygon[1:]+polygon[:1]):
                inside_a, inside_b = a[3][plane] >= 0, b[3][plane] >= 0
                if inside_a:
                    clipped.append(a)
                if inside_a != inside_b:
                    u = a[3][plane]/(a[3][plane]-b[3][plane])
                    clipped.append(tuple(x*(1-u)+y*u for x, y in zip(a, b)))
            polygon = clipped
            if len(polygon) < 3:
                break
        if len(polygon) < 3:
            continue
        ids = [add(*v[:3]) for v in polygon]
        for k in range(1, len(ids)-1):
            if len(set([ids[0], ids[k], ids[k+1]])) == 3:
                tri.append([ids[0], ids[k], ids[k+1]])

    rest = np.asarray(vertices)
    vertices = rest.copy()
    weights = np.asarray(bone_weights)
    normals = np.asarray(normals)
    arm_weights = np.sum(weights[:, [rig.index[name+'.'+side]
        for name in ['upper_arm', 'forearm', 'hand'] for side in ['L', 'R']]], axis=1)
    # Ease, not anatomical detail: the front bridges the chest and the cloth
    # hangs off the waist.  Shoulder/axilla and sleeve shapes stay body-derived.
    profile = [(1.045, .147, .160, -.055),
               (1.08, .143, .163, -.050), (1.15, .149, .176, -.055),
               (1.22, .161, .190, -.073), (1.27, .173, .157, -.084),
               (1.32, .182, .126, -.084)]
    curves = [PchipInterpolator([r[0] for r in profile], [r[k] for r in profile], extrapolate=False) for k in [1, 2, 3]]
    for i, point in enumerate(rest):
        normal = normals[i]/max(np.linalg.norm(normals[i]), 1e-10)
        side = 'L' if point[0] >= 0 else 'R'
        root = roots[side]
        along = np.dot(point-root[:3, 3], root[:3, 1])
        taper = np.clip(along/.158, 0, 1)
        taper = taper*taper*(3-2*taper)
        sleeve_ease = .018-.012*taper
        ease = .012*(1-arm_weights[i])+sleeve_ease*arm_weights[i]
        result = point+normal*ease
        y = point[1]
        rx, front, back = [float(curve(np.clip(y, profile[0][0], profile[-1][0]))) for curve in curves]
        center = (front+back)/2
        theta = np.arctan2(point[0]/rx, (point[2]-center)/((front-back)/2))
        sn, cs = np.sin(theta), np.cos(theta)
        eased = np.array([rx*sn, y, center+(front-back)/2*cs])
        blend = np.clip((1.33-y)/.065, 0, 1)
        blend = blend*blend*(3-2*blend)
        blend *= np.clip((.10-arm_weights[i])/.08, 0, 1)
        vertices[i] = result*(1-blend)+eased*blend

    # Extract real boundary loops (waist, neck, two cuffs) from the welded mesh.
    edges = Counter(tuple(sorted((a, b))) for t in tri for a, b in zip(t, np.roll(t, -1)))
    boundary = [edge for edge, count in edges.items() if count == 1]
    adjacency = {}
    for a, b in boundary:
        adjacency.setdefault(a, []).append(b)
        adjacency.setdefault(b, []).append(a)
    if any(len(neighbours) != 2 for neighbours in adjacency.values()):
        raise ValueError('Body-derived textile has a non-manifold cut boundary')
    loops = []
    unseen = set(adjacency)
    while unseen:
        start = min(unseen)
        loop, previous, current = [], -1, start
        while current not in loop:
            loop.append(current); unseen.discard(current)
            a, b = adjacency[current]
            previous, current = current, b if a == previous else a
        if current != start:
            raise ValueError('Open textile boundary')
        loops.append(loop)
    if len(loops) != 4:
        raise ValueError(f'Expected waist, neckline and two cuffs, got {list(map(len, loops))}')

    # Fair the small source-mesh irregularities without shrinking the outline.
    neighbours = [set() for _ in vertices]
    for a, b in edges:
        neighbours[a].add(b); neighbours[b].add(a)
    fixed = set(adjacency)
    for _ in range(5):
        for strength in [.38, -.39]:
            delta = np.asarray([vertices[list(n)].mean(axis=0)-vertices[i] if n and i not in fixed else np.zeros(3) for i, n in enumerate(neighbours)])
            vertices += strength*delta
    colors = [FABRIC]*len(vertices)
    vertices = vertices.tolist()
    weights = weights.tolist()
    waist_ids, waist_at, waist_upper, cuff_edges, neck_edges = [], [], [], [], []

    def append(point, values, color=FABRIC):
        vertices.append(np.asarray(point).tolist()); weights.append(np.asarray(values).tolist()); colors.append(color)
        return len(vertices)-1

    def join(previous, ring):
        # Preserve source-body winding along every boundary.
        directed = {(a, b) for t in tri for a, b in zip(t, np.roll(t, -1))}
        for k, a in enumerate(previous):
            b, c, d = previous[(k+1)%len(previous)], ring[k], ring[(k+1)%len(previous)]
            tri.extend([[b, a, c], [b, c, d]] if (a, b) in directed else [[a, b, c], [b, d, c]])

    for loop in loops:
        center = rest[loop].mean(axis=0)
        if center[1] < 1.10:
            # Adapter shares exactly the pinned cloth polygon, including its
            # nonuniform sample angles; no overlapping/z-fighting waist rings.
            waist_upper = loop
            for index in loop:
                point = np.asarray(vertices[index])
                theta = np.arctan2(point[0], point[2]-.02) % (2*np.pi)
                angles = np.unwrap(np.arctan2(waist[:, 0], waist[:, 2]-.02))
                angles = np.r_[angles, angles[0]+2*np.pi]
                theta = (theta-angles[0]) % (2*np.pi)+angles[0]
                lo = int(np.searchsorted(angles, theta, side='right')-1)
                u = (theta-angles[lo])/(angles[lo+1]-angles[lo])
                pos = waist[lo%len(waist)]*(1-u)+waist[(lo+1)%len(waist)]*u
                values = np.zeros(len(rig.names)); values[rig.index['hips']] = 1
                waist_ids.append(append(pos, values)); waist_at.append(lo+u)
            join(loop, waist_ids)
        else:
            if center[1] > 1.40:
                label = neck_edges
                for i in loop:
                    vertices[i][1] = 1.436
                # Light 3 mm binding, then an inward turned neckline facing.
                inward = np.array([0., -.005, 0.])
            else:
                side = 'L' if center[0] > 0 else 'R'
                label = cuff_edges
                inward = -roots[side][:3, 1]*.022
                for i in loop:
                    v = np.asarray(vertices[i])
                    vertices[i] = (v+roots[side][:3, 1]*(.158-np.dot(v-roots[side][:3, 3], roots[side][:3, 1]))).tolist()
            label.extend([[loop[k], loop[(k+1)%len(loop)]] for k in range(len(loop))])
            for i in loop:
                colors[i] = BINDING
            ring = []
            for i in loop:
                n = normals[i]/max(np.linalg.norm(normals[i]), 1e-10)
                if center[1] > 1.40:
                    n[1] = 0
                    n /= max(np.linalg.norm(n), 1e-10)
                ring.append(append(np.asarray(vertices[i])-n*.0025, weights[i], BINDING))
            join(loop, ring)
            facing = [append(np.asarray(vertices[i])+inward, weights[i]) for i in ring]
            join(ring, facing)

    # Preserve the small lab identification patch on the eased fabric.
    def front_z(x, y):
        positions = np.asarray(vertices)
        faces = positions[np.asarray(tri)]
        ab, ac = faces[:, 1, :2]-faces[:, 0, :2], faces[:, 2, :2]-faces[:, 0, :2]
        rel = np.array([x, y])-faces[:, 0, :2]
        det = ab[:, 0]*ac[:, 1]-ab[:, 1]*ac[:, 0]
        good = abs(det) > 1e-12
        u = np.divide(rel[:, 0]*ac[:, 1]-rel[:, 1]*ac[:, 0], det, out=np.zeros(len(det)), where=good)
        v = np.divide(ab[:, 0]*rel[:, 1]-ab[:, 1]*rel[:, 0], det, out=np.zeros(len(det)), where=good)
        good &= (u >= 0) & (v >= 0) & (u+v <= 1)
        return np.max(faces[good, 0, 2]+u[good]*(faces[good, 1, 2]-faces[good, 0, 2])+v[good]*(faces[good, 2, 2]-faces[good, 0, 2]))

    for x0, x1, y0, y1, color, lift in [(.055, .105, 1.235, 1.267, [.26, .29, .31], .002),
                                      (.061, .099, 1.253, 1.259, [.48, .76, .72], .003),
                                      (.061, .083, 1.242, 1.246, FABRIC, .003)]:
        values = np.zeros(len(rig.names)); values[rig.index['chest']] = 1
        base = len(vertices)
        width, height = 8, 4
        for y in np.linspace(y0, y1, height+1):
            for x in np.linspace(x0, x1, width+1):
                append([x, y, front_z(x, y)+lift], values, color)
        for row in range(height):
            for k in range(width):
                a = base+row*(width+1)+k; b = a+1; c = a+width+1; d = c+1
                tri.extend([[a, b, c], [b, d, c]])

    # Keep the pinned waist first for the native seam test and compact weights.
    order = waist_ids+[i for i in range(len(vertices)) if i not in set(waist_ids)]
    remap = np.empty(len(order), dtype=int); remap[order] = np.arange(len(order))
    vertices = np.asarray(vertices)[order]
    dense = np.asarray(weights)[order]
    joints = np.argsort(-dense, axis=1, kind='stable')[:, :4]
    weights = np.take_along_axis(dense, joints, axis=1)
    weights /= weights.sum(axis=1, keepdims=True)
    tri = remap[np.asarray(tri)]
    normals = np.zeros_like(vertices)
    face_normals = np.cross(vertices[tri[:, 1]]-vertices[tri[:, 0]], vertices[tri[:, 2]]-vertices[tri[:, 0]])
    for k in range(3):
        np.add.at(normals, tri[:, k], face_normals)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-10)
    # Both meshes must agree in LIGHTING as well as position at their pinned
    # seam. Independent one-sided normal estimates made the short adapter
    # look like a hard grey belt. Estimate across the seam, periodically
    # sampling the nonuniform upper cut onto the 32 cloth pins. These normal
    # values are consumed by both runtimes; the pins and adapter use hips=1.
    samples = np.asarray(waist_at)
    sort = np.argsort(samples)
    at = samples[sort]
    upper = vertices[remap[np.asarray(waist_upper)]][sort]
    xp = np.r_[at[-1]-len(waist), at, at[0]+len(waist)]
    upper = np.vstack([upper[-1], upper, upper[0]])
    above = np.column_stack([np.interp(np.arange(len(waist)), xp, upper[:, k]) for k in range(3)])
    seam_normals = np.cross(next_row-above, np.roll(waist, -1, axis=0)-np.roll(waist, 1, axis=0))
    seam_normals /= np.linalg.norm(seam_normals, axis=1, keepdims=True)
    for i, sample in enumerate(samples):
        lo = int(sample) % len(waist)
        u = sample-int(sample)
        n = seam_normals[lo]*(1-u)+seam_normals[(lo+1)%len(waist)]*u
        n /= np.linalg.norm(n)
        normals[i] = n
        index = remap[waist_upper[i]]
        n = normals[index]*.6+n*.4
        normals[index] = n/np.linalg.norm(n)
    return {'waist_vertices': len(waist_ids), 'waist_cloth_samples': np.round(waist_at, 8).tolist(),
            'waist_normals': np.round(seam_normals, 7).tolist(),
            'armhole_edges': [], 'cuff_edges': remap[np.asarray(cuff_edges)].tolist(),
            'neck_edges': remap[np.asarray(neck_edges)].tolist(),
            'positions': np.round(vertices, 7).tolist(), 'normals': np.round(normals, 7).tolist(),
            'joints': joints.tolist(), 'weights': np.round(weights, 7).tolist(),
            'uv': np.round(vertices[:, [0, 1]], 6).tolist(),
            'colors': np.asarray(colors)[order].tolist(), 'indices': tri.ravel().tolist()}
