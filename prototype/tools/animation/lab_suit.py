"""Closed lab top + long trousers on the original 21-bone skin.

Deterministic cut/sew surface authoring; no external outfit, DCC, new rig,
texture dependency or runtime cloth solver. Skin topology is welded before
cutting, with interpolated four-weight LBS and real turned neck/wrist/ankle
edges. This is a fitted textile prototype, not simulated trousers or armour.
"""
from collections import Counter
import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.sparse import coo_matrix

WHITE = [.86, .875, .89]
TROUSERS = [.74, .765, .79]
SEAM = [.63, .68, .71]


def coverage(rig):
    return {'hem': .935, 'waist': 1.025, 'neck': 1.44, 'ankle': .125,
            'skin_overlap': .020,
            'wrists': [{'origin': rig.rest_world[rig.index['forearm.'+s], :3, 3].tolist(),
                        'axis': rig.rest_world[rig.index['forearm.'+s], :3, 1].tolist(),
                        'end': float(np.linalg.norm(rig.positions[rig.index['hand.'+s]])-.012),
                        'side': s} for s in ['L', 'R']]}


def build_suit(rig):
    mesh = rig.mesh_data()
    source = mesh['POSITION']
    _, first, inverse = np.unique(source.round(6), axis=0, return_index=True, return_inverse=True)
    p = source[first].astype(float)
    normal = np.zeros_like(p)
    np.add.at(normal, inverse, mesh['NORMAL'])
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-12)
    dense = np.zeros((len(source), len(rig.names)))
    for k in range(4):
        dense[np.arange(len(source)), mesh['JOINTS_0'][:, k]] += mesh['WEIGHTS_0'][:, k]
    dense = dense[first]
    triangles = inverse[mesh['indices']]
    arm_ids = [rig.index[n+'.'+s] for n in ['shoulder', 'upper_arm', 'forearm', 'hand'] for s in ['L', 'R']]
    c = coverage(rig)
    parts = []
    for kind in ['top', 'trousers']:
        def fields(point, weights):
            arms = sum(weights[arm_ids])
            if kind == 'trousers':
                return np.array([point[1]-c['ankle'], c['waist']-point[1], .25-arms])
            values = [max(point[1]-c['hem'], (arms-.30)*.3), c['neck']-point[1]]
            for side, cuff in zip(['L', 'R'], c['wrists']):
                arm = sum(weights[rig.index[n+'.'+side]] for n in ['forearm', 'hand'])
                along = np.dot(point-cuff['origin'], cuff['axis'])
                values.append(max(cuff['end']-along, (.45-arm)*.3))
            return np.asarray(values)

        vertices, normals, weights, tri, lookup = [], [], [], [], {}
        def add(v, n, w):
            key = tuple(v.round(7))
            if key not in lookup:
                lookup[key] = len(vertices)
                vertices.append(v); normals.append(n); weights.append(w)
            return lookup[key]
        for face in triangles:
            poly = [(p[i], normal[i], dense[i], fields(p[i], dense[i])) for i in face]
            for plane in range(3 if kind == 'trousers' else 4):
                out = []
                for a, b in zip(poly, poly[1:]+poly[:1]):
                    if a[3][plane] >= 0:
                        out.append(a)
                    if (a[3][plane] >= 0) != (b[3][plane] >= 0):
                        u = a[3][plane]/(a[3][plane]-b[3][plane])
                        out.append(tuple(x*(1-u)+y*u for x, y in zip(a, b)))
                poly = out
                if len(poly) < 3:
                    break
            if len(poly) < 3:
                continue
            ids = [add(*v[:3]) for v in poly]
            for k in range(1, len(ids)-1):
                if len(set([ids[0], ids[k], ids[k+1]])) == 3:
                    tri.append([ids[0], ids[k], ids[k+1]])
        rest, normals, weights = map(np.asarray, (vertices, normals, weights))
        normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
        vertices = rest+normals*(.010 if kind == 'top' else .012)
        arms = weights[:, arm_ids].sum(axis=1)
        if kind == 'top':
            profile = [(.935, .168, .125, -.09), (1.02, .152, .155, -.07),
                       (1.08, .147, .163, -.055), (1.15, .149, .176, -.055),
                       (1.22, .161, .190, -.073), (1.27, .173, .157, -.084),
                       (1.32, .182, .126, -.084)]
            curves = [PchipInterpolator([r[0] for r in profile], [r[k] for r in profile]) for k in [1, 2, 3]]
            for i, point in enumerate(rest):
                y = point[1]
                rx, front, back = [float(f(np.clip(y, .935, 1.32))) for f in curves]
                center, rz = (front+back)/2, (front-back)/2
                theta = np.arctan2(point[0]/rx, (point[2]-center)/rz)
                sn, cs = np.sin(theta), np.cos(theta)
                chest = np.clip((y-1.10)/.075, 0, 1)*np.clip((1.35-y)/.05, 0, 1)
                upper = np.clip((y-1.23)/.10, 0, 1)
                upper = upper*upper*(3-2*upper)
                eased = [rx*np.sign(sn)*abs(sn)**(2/(2+2*chest*(1-upper))), y,
                         center+rz*np.sign(cs)*abs(cs)**(2/(2+2*chest))]
                u = np.clip((1.39-y)/.085, 0, 1)
                v = np.clip((arms[i]-.05)/.85, 0, 1)
                amount = u*u*(3-2*u)*(1-v*v*(3-2*v))
                vertices[i] = vertices[i]*(1-amount)+np.array(eased)*amount
        else:
            # Straighten calf/knee panels without baggy inflation at the
            # crotch. Continuous source topology retains the sewn inseam.
            for i, point in enumerate(rest):
                y = point[1]
                if y > .76:
                    continue
                side = 'L' if point[0] > 0 else 'R'
                hip, ankle = [rig.rest_world[rig.index[n+'.'+side], :3, 3] for n in ['thigh', 'foot']]
                u = np.clip((y-ankle[1])/(hip[1]-ankle[1]), 0, 1)
                center = ankle*(1-u)+hip*u
                radial = vertices[i, [0, 2]]-center[[0, 2]]
                desired = np.interp(y, [.125, .25, .47, .60, .76], [.058, .064, .073, .085, .100])
                radius = np.linalg.norm(radial)
                if radius > 1e-8:
                    vertices[i, [0, 2]] = center[[0, 2]]+radial*max(1., desired/radius)
        edges = Counter(tuple(sorted((a, b))) for t in tri for a, b in zip(t, np.roll(t, -1)))
        boundary = [edge for edge, count in edges.items() if count == 1]
        adjacency = {}
        for a, b in boundary:
            adjacency.setdefault(a, []).append(b); adjacency.setdefault(b, []).append(a)
        if any(len(v) != 2 for v in adjacency.values()):
            raise ValueError('Non-manifold suit cut: '+kind)
        loops, unseen = [], set(adjacency)
        while unseen:
            loop, previous, current = [], -1, min(unseen)
            while current not in loop:
                loop.append(current); unseen.discard(current)
                a, b = adjacency[current]
                previous, current = current, b if a == previous else a
            loops.append(loop)
        if len(loops) != (4 if kind == 'top' else 3):
            raise ValueError(f'{kind}: expected clean neck/wrist/hem or waist/ankle loops, got {list(map(len, loops))}')
        pairs = np.array(list(edges))
        directed = np.concatenate([pairs, pairs[:, ::-1]])
        degree = np.bincount(directed[:, 0], minlength=len(vertices))
        graph = coo_matrix((1/degree[directed[:, 0]], directed.T), shape=(len(vertices),)*2).tocsr()
        free = np.ones(len(vertices)); free[list(adjacency)] = 0
        for _ in range(8):
            for strength in [.35, -.36]:
                vertices += strength*(graph@vertices-vertices)*free[:, None]
        # Preserve source-surface clearance at shoulders, sleeve, crotch and
        # inner thigh. Torso panels may bridge anatomy, never mask more dress.
        gap = np.sum((vertices-rest)*normals, axis=1)
        vertices += np.maximum(0, .007-gap)[:, None]*normals
        colors = np.tile(WHITE if kind == 'top' else TROUSERS, (len(vertices), 1))
        # Subtle technological panel seams, not armour plates.
        if kind == 'top':
            marked = (abs(abs(rest[:, 0])-.11) < .0025) & (rest[:, 1] > 1.02) & (rest[:, 1] < 1.20) & (rest[:, 2] > .08) & (arms < .2)
            colors[marked] = [.73, .77, .79]
        else:
            outer = (abs(rest[:, 0]) > .13) & (abs(rest[:, 2]-.02) < .003) & (rest[:, 1] < .74)
            colors[outer] = [.65, .70, .74]
        # A sewn hem/waist is one continuous material ring, not the
        # slightly wavy source-body cut driven by several torso weights.
        for loop in loops:
            if arms[loop].mean() < .2 and rest[loop, 1].mean() < 1.10:
                y = c['hem'] if kind == 'top' else c['waist']
                if kind == 'top' or rest[loop, 1].mean() > .9:
                    vertices[loop, 1] = y
                    weights[loop] = 0
                    weights[loop, rig.index['hips']] = 1
        vertices, weights, colors = vertices.tolist(), weights.tolist(), colors.tolist()
        groups = [kind]*len(tri)
        # Turned 2 mm edges. Facings stay a short distance inside the actual
        # closed shell. No independent overlapping tube at wrists/crotch.
        boundary_info = []
        source_edges = {(a, b) for face in tri for a, b in zip(face, np.roll(face, -1))}
        for loop in loops:
            boundary_info.append({'vertices': loop, 'center': rest[loop].mean(axis=0).round(7).tolist()})
            ring = []
            for i in loop:
                colors[i] = SEAM
                ring.append(len(vertices))
                vertices.append((np.asarray(vertices[i])-normals[i]*.002).tolist())
                weights.append(weights[i]); colors.append(SEAM)
            for k, a in enumerate(loop):
                b, v, w = loop[(k+1)%len(loop)], ring[k], ring[(k+1)%len(loop)]
                source_directed = (a, b) in source_edges
                tri.extend([[b, a, v], [b, v, w]] if source_directed else [[a, b, v], [b, w, v]])
                groups.extend([kind+'_binding']*2)
        if kind == 'top':
            # Small reproducible lab-ID print; sample the actual panel and
            # interpolate its weights. No floating rigid badge at the chest.
            panel = np.asarray(vertices)
            faces = panel[np.asarray(tri)]
            ab, ac = faces[:, 1, :2]-faces[:, 0, :2], faces[:, 2, :2]-faces[:, 0, :2]
            det = ab[:, 0]*ac[:, 1]-ab[:, 1]*ac[:, 0]
            valid = abs(det) > 1e-12
            def front(x, y):
                rel = np.array([x, y])-faces[:, 0, :2]
                u = np.divide(rel[:, 0]*ac[:, 1]-rel[:, 1]*ac[:, 0], det, out=np.zeros(len(det)), where=valid)
                v = np.divide(ab[:, 0]*rel[:, 1]-ab[:, 1]*rel[:, 0], det, out=np.zeros(len(det)), where=valid)
                good = valid & (u >= 0) & (v >= 0) & (u+v <= 1)
                z = faces[:, 0, 2]+u*(faces[:, 1, 2]-faces[:, 0, 2])+v*(faces[:, 2, 2]-faces[:, 0, 2])
                at = np.flatnonzero(good)[np.argmax(z[good])]
                ids = tri[at]
                values = (np.asarray(weights[ids[0]])*(1-u[at]-v[at])+np.asarray(weights[ids[1]])*u[at]+np.asarray(weights[ids[2]])*v[at])
                return [x, y, float(z[at]+.0007)], values.tolist()
            for layer, (x0, y0, x1, y1, color) in enumerate([(.052, 1.235, .100, 1.268, [.36, .47, .51]),
                    (.057, 1.257, .095, 1.262, [.83, .91, .91]),
                    (.057, 1.246, .078, 1.249, [.92, .94, .95]),
                    (.057, 1.240, .087, 1.243, [.92, .94, .95])]):
                ids = []
                for x, y in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]:
                    point, value = front(x, y)
                    point[2] += .0003*layer
                    ids.append(len(vertices)); vertices.append(point); weights.append(value); colors.append(color)
                a, b, d, e = ids
                tri.extend([[a, b, d], [a, d, e]]); groups.extend(['top_badge']*2)
        parts.append((np.asarray(vertices), np.asarray(weights), np.asarray(colors), np.asarray(tri), groups, boundary_info))
    positions, weights, colors, triangles, groups, boundaries = [], [], [], [], [], []
    count = 0
    for v, w, col, tri, face_groups, loops in parts:
        positions.extend(v); weights.extend(w); colors.extend(col); triangles.extend(tri+count); groups.extend(face_groups)
        boundaries.extend([loop | {'vertices': [int(i+count) for i in loop['vertices']]} for loop in loops])
        count += len(v)
    positions, weights, colors, triangles = map(np.asarray, (positions, weights, colors, triangles))
    face = np.cross(positions[triangles[:, 1]]-positions[triangles[:, 0]], positions[triangles[:, 2]]-positions[triangles[:, 0]])
    normals = np.zeros_like(positions)
    for k in range(3):
        np.add.at(normals, triangles[:, k], face)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    joints = np.argsort(-weights, axis=1, kind='stable')[:, :4]
    weights = np.take_along_axis(weights, joints, axis=1)
    weights /= weights.sum(axis=1, keepdims=True)
    return {'positions': positions.round(7).tolist(), 'normals': normals.round(7).tolist(),
            'joints': joints.tolist(), 'weights': weights.round(8).tolist(), 'colors': colors.round(6).tolist(),
            'uv': np.c_[positions[:, 0]*2, positions[:, 1]].round(7).tolist(),
            'indices': triangles.ravel().tolist(), 'face_groups': groups, 'boundaries': boundaries,
            'coverage': c, 'authoring': 'body-derived welded/cut/eased/sewn top and trousers; original LBS rig'}
