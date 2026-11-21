"""Fitted test-subject jumpsuit, cut from the original continuous body surface.

One sewn shell, five turned openings, original 21-bone / four-weight LBS.
No loose square torso, separate floating badge, overlapping waist, new rig,
textures or external costume assets. Petrol/sage textile with an original
small ochre 07 print evokes a test subject, not medical laboratory staff.
This is skinned textile geometry, NOT simulated cloth or a collision promise.
"""
from collections import Counter
import numpy as np
from scipy.sparse import coo_matrix

FABRIC = np.array([.10,.28,.30])
SAGE = np.array([.70,.74,.71])
SIGNAL = np.array([.80,.61,.22])
SEAM = [.16,.23,.24]


def coverage(rig):
    # Same neck/wrist inventory and retained 20 mm skin overlap as the old
    # suit. The ankle cut is 20 mm higher: LESS skin is removed, not more.
    return {'ankle':.145,'neck':1.44,'skin_overlap':.020,
            'wrists':[{'origin':rig.rest_world[rig.index['forearm.'+s],:3,3].tolist(),
                       'axis':rig.rest_world[rig.index['forearm.'+s],:3,1].tolist(),
                       'end':float(np.linalg.norm(rig.positions[rig.index['hand.'+s]])-.012),
                       'side':s} for s in ['L','R']]}


def build_suit(rig):
    mesh = rig.mesh_data()
    source = mesh['POSITION']
    _,first,inverse = np.unique(source.round(6),axis=0,return_index=True,return_inverse=True)
    p = source[first].astype(float)
    normal = np.zeros_like(p)
    np.add.at(normal,inverse,mesh['NORMAL'])
    normal /= np.maximum(np.linalg.norm(normal,axis=1,keepdims=True),1e-12)
    dense = np.zeros((len(source),len(rig.names)))
    for k in range(4):
        dense[np.arange(len(source)),mesh['JOINTS_0'][:,k]] += mesh['WEIGHTS_0'][:,k]
    dense = dense[first]
    triangles = inverse[mesh['indices']]
    c = coverage(rig)

    def fields(point,weights):
        values = [point[1]-c['ankle'],c['neck']-point[1]]
        for side,cuff in zip(['L','R'],c['wrists']):
            arm = sum(weights[rig.index[n+'.'+side]] for n in ['forearm','hand'])
            along = np.dot(point-cuff['origin'],cuff['axis'])
            values.append(max(cuff['end']-along,(.45-arm)*.3))
        return np.asarray(values)

    vertices,normals,weights,tri,lookup = [],[],[],[],{}
    def add(v,n,w):
        key = tuple(v.round(7))
        if key not in lookup:
            lookup[key] = len(vertices)
            vertices.append(v); normals.append(n); weights.append(w)
        return lookup[key]
    for face in triangles:
        poly = [(p[i],normal[i],dense[i],fields(p[i],dense[i])) for i in face]
        for plane in range(4):
            out = []
            for a,b in zip(poly,poly[1:]+poly[:1]):
                if a[3][plane] >= 0: out.append(a)
                if (a[3][plane] >= 0) != (b[3][plane] >= 0):
                    u = a[3][plane]/(a[3][plane]-b[3][plane])
                    out.append(tuple(x*(1-u)+y*u for x,y in zip(a,b)))
            poly = out
            if len(poly) < 3: break
        if len(poly) < 3: continue
        ids = [add(*v[:3]) for v in poly]
        for k in range(1,len(ids)-1):
            if len(set([ids[0],ids[k],ids[k+1]])) == 3:
                tri.append([ids[0],ids[k],ids[k+1]])
    rest,normals,weights = map(np.asarray,(vertices,normals,weights))
    normals /= np.maximum(np.linalg.norm(normals,axis=1,keepdims=True),1e-12)
    # 6 mm tailored ease, not the former large, squared superellipse and
    # straight inflated trouser tubes. The sewn waist has no second layer.
    vertices = rest+normals*.006
    edges = Counter(tuple(sorted((a,b))) for t in tri for a,b in zip(t,np.roll(t,-1)))
    boundary = [edge for edge,count in edges.items() if count==1]
    adjacency = {}
    for a,b in boundary:
        adjacency.setdefault(a,[]).append(b); adjacency.setdefault(b,[]).append(a)
    if any(len(v)!=2 for v in adjacency.values()): raise ValueError('Non-manifold fitted suit cut')
    loops,unseen = [],set(adjacency)
    while unseen:
        loop,previous,current = [],-1,min(unseen)
        while current not in loop:
            loop.append(current); unseen.discard(current)
            a,b = adjacency[current]
            previous,current = current,b if a==previous else a
        loops.append(loop)
    if len(loops)!=5:
        raise ValueError('Expected neck, two wrists and two ankles, got '+str(list(map(len,loops))))
    pairs = np.array(list(edges))
    directed = np.concatenate([pairs,pairs[:,::-1]])
    degree = np.bincount(directed[:,0],minlength=len(vertices))
    graph = coo_matrix((1/degree[directed[:,0]],directed.T),shape=(len(vertices),)*2).tocsr()
    free = np.ones(len(vertices)); free[list(adjacency)] = 0
    for _ in range(3):
        for strength in [.20,-.205]:
            vertices += strength*(graph@vertices-vertices)*free[:,None]
    gap = np.sum((vertices-rest)*normals,axis=1)
    vertices += np.maximum(0,.0055-gap)[:,None]*normals
    # In-plane fairing also stays local: it must not turn 'fitted' back into
    # the rejected loose silhouette or an unseen clearance inflation.
    delta = vertices-rest
    length = np.linalg.norm(delta,axis=1)
    vertices = rest+delta*np.minimum(1,.009/np.maximum(length,1e-12))[:,None]
    # Matte continuous textile, not white/orange Portal costume colours.
    # The first render exposed sawtooth colour thresholds across coarse
    # original triangles. Use a broad, smoothly dyed shoulder yoke instead
    # of jagged dark breast-cup / crotch panels or a broken vertex stripe.
    yoke = np.clip((rest[:,1]-1.285)/.045,0,1)
    yoke = (yoke*yoke*(3-2*yoke))[:,None]
    colors = FABRIC[None,:]*(1-yoke)+SAGE[None,:]*yoke
    shell_count = len(vertices)
    vertices,weights,colors = vertices.tolist(),weights.tolist(),colors.tolist()
    groups = ['suit_shell']*len(tri)
    boundary_info = []
    source_edges = {(a,b) for face in tri for a,b in zip(face,np.roll(face,-1))}
    for loop in loops:
        center = rest[loop].mean(axis=0)
        label = 'neck' if center[1]>1.40 else 'ankle' if center[1]<.20 else 'wrist'
        boundary_info.append({'vertices':[int(i) for i in loop],'center':center.round(7).tolist(),'opening':label})
        ring = []
        for i in loop:
            colors[i] = SEAM
            ring.append(len(vertices))
            vertices.append((np.asarray(vertices[i])-normals[i]*.002).tolist())
            weights.append(weights[i]); colors.append(SEAM)
        for k,a in enumerate(loop):
            b,v,w = loop[(k+1)%len(loop)],ring[k],ring[(k+1)%len(loop)]
            tri.extend([[b,a,v],[b,v,w]] if (a,b) in source_edges else [[a,b,v],[b,w,v]])
            groups.extend(['suit_binding']*2)
    # A small 07 fabric print. Project onto the real curved front panel and
    # interpolate its skin weights, no staff-style rigid name badge.
    panel = np.asarray(vertices)
    faces = panel[np.asarray(tri)]
    ab,ac = faces[:,1,:2]-faces[:,0,:2],faces[:,2,:2]-faces[:,0,:2]
    det = ab[:,0]*ac[:,1]-ab[:,1]*ac[:,0]
    valid = abs(det)>1e-12
    def surface(x,y,back=False):
        rel = np.array([x,y])-faces[:,0,:2]
        u = np.divide(rel[:,0]*ac[:,1]-rel[:,1]*ac[:,0],det,out=np.zeros(len(det)),where=valid)
        v = np.divide(ab[:,0]*rel[:,1]-ab[:,1]*rel[:,0],det,out=np.zeros(len(det)),where=valid)
        good = valid&(u>=0)&(v>=0)&(u+v<=1)
        z = faces[:,0,2]+u*(faces[:,1,2]-faces[:,0,2])+v*(faces[:,2,2]-faces[:,0,2])
        at = np.flatnonzero(good)[np.argmin(z[good]) if back else np.argmax(z[good])]
        ids = tri[at]
        value = np.asarray(weights[ids[0]])*(1-u[at]-v[at])+np.asarray(weights[ids[1]])*u[at]+np.asarray(weights[ids[2]])*v[at]
        return [x,y,float(z[at]+(-.0006 if back else .0006))],value.tolist()

    def printed_patch(x0,y0,x1,y1,color,back=False):
        # Small curved textile patches follow the source panels and their
        # weights. Do NOT span a breast/back curve with one rigid long quad.
        xs = np.linspace(x0,x1,max(2,int(np.ceil((x1-x0)/.008))+1))
        ys = np.linspace(y0,y1,max(2,int(np.ceil((y1-y0)/.008))+1))
        ids = []
        for y in ys:
            row = []
            for x in xs:
                point,value = surface(x,y,back)
                row.append(len(vertices)); vertices.append(point); weights.append(value); colors.append(list(color))
            ids.append(row)
        for j in range(len(ys)-1):
            for i in range(len(xs)-1):
                a,b,c0,d = ids[j][i],ids[j][i+1],ids[j+1][i+1],ids[j+1][i]
                tri.extend([[a,c0,b],[a,d,c0]] if back else [[a,b,c0],[a,c0,d]])
                groups.extend(['subject_print']*2)

    for x0,y0,x1,y1 in [(-.045,1.247,-.041,1.278),(-.023,1.247,-.019,1.278),
                        (-.045,1.274,-.019,1.278),(-.045,1.247,-.019,1.251),
                        (-.009,1.274,.018,1.278),(.014,1.247,.018,1.278)]:
        printed_patch(x0,y0,x1,y1,SIGNAL)
    for back in [False,True]:
        printed_patch(.046,1.025,.054,1.275,SIGNAL,back)
        printed_patch(.061,1.025,.064,1.105,SAGE,back)
    positions,weights,colors,triangles = map(np.asarray,(vertices,weights,colors,tri))
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
            'indices':triangles.ravel().tolist(),'face_groups':groups,'boundaries':boundary_info,'coverage':c,
            'fit':{'ease_m':.006,'max_source_offset_m':.009,'shell_vertices':shell_count,
                   'source_positions':rest.round(7).tolist(),'source_normals':normals.round(7).tolist()},
            'authoring':'single continuous fitted subject shell; welded/cut/6 mm ease/turned edges; original LBS; original 07 print'}
