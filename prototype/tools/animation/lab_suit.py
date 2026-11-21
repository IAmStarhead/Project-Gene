"""Sleeveless light subject top and shorts cut from the original skinned body.

Separate fitted surfaces, not simulated cloth. Keeps the original rig and skin;
all cut edges are finished by a small inward-facing binding.
"""
from collections import Counter
import numpy as np
from scipy.sparse import coo_matrix

TOP = np.array([.84, .86, .88])
SHORTS = np.array([.72, .75, .78])
BINDING = [.65, .68, .71]
EASE = .011
MAX_OFFSET = .016


def coverage(rig):
    return {'top_low': 1.035, 'neck': 1.425, 'shorts_low': .69,
            'shorts_high': 1.01, 'skin_overlap': .018}


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
    c = coverage(rig)
    arm_info = []
    for side in ['L', 'R']:
        bone = rig.index['upper_arm.' + side]
        arm_info.append((side, rig.rest_world[bone, :3, 3], rig.rest_world[bone, :3, 1]))

    def fields(point, weights, region):
        if region == 'shorts':
            arm = sum(weights[rig.index[n+'.'+side]] for side in ['L', 'R']
                      for n in ['shoulder', 'upper_arm', 'forearm', 'hand'])
            return np.asarray([point[1]-c['shorts_low'], c['shorts_high']-point[1], (.20-arm)*.3])
        values = [point[1]-c['top_low'], c['neck']-point[1]]
        for side, origin, axis in arm_info:
            arm = sum(weights[rig.index[n+'.'+side]] for n in ['upper_arm', 'forearm', 'hand'])
            along = np.dot(point-origin, axis)
            values.append(max(.025-along, (.45-arm)*.3))
        return np.asarray(values)

    all_positions, all_weights, all_colors, all_tri, groups, boundaries = [], [], [], [], [], []
    all_rest, all_source_normals = [], []
    for region in ['top', 'shorts']:
        vertices, normals, weights, tri, lookup = [], [], [], [], {}
        def add(v, n, w):
            key = tuple(v.round(7))
            if key not in lookup:
                lookup[key] = len(vertices)
                vertices.append(v); normals.append(n); weights.append(w)
            return lookup[key]
        for face in triangles:
            poly = [(p[i], normal[i], dense[i], fields(p[i], dense[i], region)) for i in face]
            for plane in range(4 if region == 'top' else 3):
                out = []
                for a, b in zip(poly, poly[1:] + poly[:1]):
                    if a[3][plane] >= 0: out.append(a)
                    if (a[3][plane] >= 0) != (b[3][plane] >= 0):
                        u = a[3][plane] / (a[3][plane]-b[3][plane])
                        out.append(tuple(x*(1-u)+y*u for x, y in zip(a, b)))
                poly = out
                if len(poly) < 3: break
            if len(poly) < 3: continue
            ids = [add(*v[:3]) for v in poly]
            for k in range(1, len(ids)-1):
                if len(set([ids[0], ids[k], ids[k+1]])) == 3:
                    tri.append([ids[0], ids[k], ids[k+1]])
        rest, normals, weights = map(np.asarray, (vertices, normals, weights))
        normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
        vertices = rest + normals * EASE
        edges = Counter(tuple(sorted((a,b))) for t in tri for a,b in zip(t,np.roll(t,-1)))
        adjacency = {}
        for (a,b), count in edges.items():
            if count == 1:
                adjacency.setdefault(a, []).append(b); adjacency.setdefault(b, []).append(a)
        if any(len(v) != 2 for v in adjacency.values()):
            raise ValueError(region + ' cut has a non-manifold edge')
        loops, unseen = [], set(adjacency)
        while unseen:
            loop, previous, current = [], -1, min(unseen)
            while current not in loop:
                loop.append(current); unseen.discard(current)
                a,b = adjacency[current]
                previous,current = current,b if a == previous else a
            loops.append(loop)
        pairs = np.array(list(edges))
        directed = np.concatenate([pairs,pairs[:,::-1]])
        degree = np.bincount(directed[:,0], minlength=len(vertices))
        graph = coo_matrix((1/degree[directed[:,0]],directed.T),shape=(len(vertices),)*2).tocsr()
        free = np.ones(len(vertices)); free[list(adjacency)] = 0
        for _ in range(3):
            for strength in [.20, -.205]:
                vertices += strength*(graph@vertices-vertices)*free[:,None]
        gap = np.sum((vertices-rest)*normals,axis=1)
        vertices += np.maximum(0,EASE-.0005-gap)[:,None]*normals
        delta = vertices-rest
        length = np.linalg.norm(delta,axis=1)
        vertices = rest+delta*np.minimum(1,MAX_OFFSET/np.maximum(length,1e-12))[:,None]
        offset = len(all_positions)
        count = len(vertices)
        all_rest.extend(rest.tolist()); all_source_normals.extend(normals.tolist())
        verts = vertices.tolist(); ws = weights.tolist()
        colors = [(TOP if region == 'top' else SHORTS).tolist() for _ in verts]
        faces = [list(map(int,t)) for t in tri]
        face_groups = [region]*len(faces)
        source_edges = {(a,b) for face in tri for a,b in zip(face,np.roll(face,-1))}
        for loop in loops:
            center = rest[loop].mean(axis=0)
            if region == 'top':
                label = 'neck' if center[1] > 1.40 else 'top_hem' if center[1] < 1.08 else 'armhole'
            else:
                label = 'waist' if center[1] > .95 else 'leg_hem'
            boundaries.append({'vertices':[offset+int(i) for i in loop], 'center':center.round(7).tolist(), 'opening':label})
            ring=[]
            for i in loop:
                colors[i] = BINDING
                ring.append(len(verts))
                verts.append((np.asarray(verts[i])-normals[i]*.002).tolist())
                ws.append(ws[i]); colors.append(BINDING)
            for k,a in enumerate(loop):
                b,v,w = loop[(k+1)%len(loop)],ring[k],ring[(k+1)%len(loop)]
                faces.extend([[b,a,v],[b,v,w]] if (a,b) in source_edges else [[a,b,v],[b,w,v]])
                face_groups.extend([region+'_binding']*2)
        all_positions.extend(verts); all_weights.extend(ws); all_colors.extend(colors)
        all_tri.extend([[offset+i for i in face] for face in faces]); groups.extend(face_groups)
    positions, weights, colors, triangles = map(np.asarray,(all_positions,all_weights,all_colors,all_tri))
    face = np.cross(positions[triangles[:,1]]-positions[triangles[:,0]],positions[triangles[:,2]]-positions[triangles[:,0]])
    final_normals = np.zeros_like(positions)
    for k in range(3): np.add.at(final_normals,triangles[:,k],face)
    final_normals /= np.maximum(np.linalg.norm(final_normals,axis=1,keepdims=True),1e-12)
    joints = np.argsort(-weights,axis=1,kind='stable')[:,:4]
    weights = np.take_along_axis(weights,joints,axis=1)
    weights /= weights.sum(axis=1,keepdims=True)
    return {'positions':positions.round(7).tolist(),'normals':final_normals.round(7).tolist(),
            'joints':joints.tolist(),'weights':weights.round(8).tolist(),'colors':colors.round(6).tolist(),
            'uv':np.c_[positions[:,0]*2,positions[:,1]].round(7).tolist(),
            'indices':triangles.ravel().tolist(),'face_groups':groups,'boundaries':boundaries,'coverage':c,
            'fit':{'ease_m':EASE,'max_source_offset_m':MAX_OFFSET},
            'authoring':'two fitted light textile shells: sleeveless top and shorts; original LBS'}
