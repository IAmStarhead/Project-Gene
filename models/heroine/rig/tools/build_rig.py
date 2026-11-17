#!/usr/bin/env python3
"""
Сборка игрового скелета для модели героини без Blender.

Вход:  models/heroine/female_A_ears_refined.glb  (НЕ изменяется)
Выход: models/heroine/female_A_rigged.glb        (новый файл)
       models/heroine/female_A_rigged.info.json  (отчёт о костях и весах)

Принцип: исходный двоичный блок GLB не перекодируется. Новые данные
(JOINTS_0, WEIGHTS_0, обратные матрицы привязки) дописываются в конец
буфера, поэтому существующие смещения остаются верными.

Требования: numpy, pygltflib не нужен — GLB пишется напрямую.
"""

import json
import struct
import sys
from pathlib import Path

import numpy as np

SRC = Path("models/heroine/female_A_ears_refined.glb")
DST = Path("models/heroine/female_A_rigged.glb")
INFO = Path("models/heroine/female_A_rigged.info.json")

# ---------------------------------------------------------------- скелет
# Координаты выведены из геометрии модели: рост 1.675 м, лицо смотрит в +Z.
# .L = сторона +X (левая рука и нога персонажа при взгляде сзади).
BONES = [
    # имя, родитель, начало (x,y,z), конец (x,y,z)
    ("hips",        None,      (0.000, 0.900, 0.020), (0.000, 1.020, 0.020)),
    ("spine",       "hips",    (0.000, 1.020, 0.020), (0.000, 1.180, 0.000)),
    ("chest",       "spine",   (0.000, 1.180, 0.000), (0.000, 1.360, 0.000)),
    ("neck",        "chest",   (0.000, 1.390, 0.020), (0.000, 1.480, 0.030)),
    ("head",        "neck",    (0.000, 1.480, 0.030), (0.000, 1.660, 0.030)),

    ("shoulder.L",  "chest",   (0.030, 1.355, 0.000), (0.170, 1.350, 0.000)),
    ("upper_arm.L", "shoulder.L", (0.170, 1.350, 0.000), (0.200, 1.080, 0.010)),
    ("forearm.L",   "upper_arm.L", (0.200, 1.080, 0.010), (0.210, 0.850, 0.020)),
    ("hand.L",      "forearm.L", (0.210, 0.850, 0.020), (0.210, 0.690, 0.020)),

    ("shoulder.R",  "chest",   (-0.030, 1.355, 0.000), (-0.170, 1.350, 0.000)),
    ("upper_arm.R", "shoulder.R", (-0.170, 1.350, 0.000), (-0.200, 1.080, 0.010)),
    ("forearm.R",   "upper_arm.R", (-0.200, 1.080, 0.010), (-0.210, 0.850, 0.020)),
    ("hand.R",      "forearm.R", (-0.210, 0.850, 0.020), (-0.210, 0.690, 0.020)),

    ("thigh.L",     "hips",    (0.090, 0.900, 0.020), (0.100, 0.470, 0.010)),
    ("shin.L",      "thigh.L", (0.100, 0.470, 0.010), (0.100, 0.080, 0.000)),
    ("foot.L",      "shin.L",  (0.100, 0.080, 0.000), (0.100, 0.020, 0.120)),
    ("toe.L",       "foot.L",  (0.100, 0.020, 0.120), (0.100, 0.020, 0.170)),

    ("thigh.R",     "hips",    (-0.090, 0.900, 0.020), (-0.100, 0.470, 0.010)),
    ("shin.R",      "thigh.R", (-0.100, 0.470, 0.010), (-0.100, 0.080, 0.000)),
    ("foot.R",      "shin.R",  (-0.100, 0.080, 0.000), (-0.100, 0.020, 0.120)),
    ("toe.R",       "foot.R",  (-0.100, 0.020, 0.120), (-0.100, 0.020, 0.170)),
]

MAX_INFLUENCES = 4  # столько поддерживает и Godot, и большинство движков

# Радиус влияния каждой кости (капсула). Не даёт рукам «захватывать» торс,
# а торсу — тянуться за руками. Значения подобраны по обхвату модели.
RADIUS = {
    "hips": 0.17, "spine": 0.15, "chest": 0.17, "neck": 0.075, "head": 0.135,
    "shoulder": 0.075, "upper_arm": 0.070, "forearm": 0.055, "hand": 0.060,
    "thigh": 0.095, "shin": 0.075, "foot": 0.065, "toe": 0.055,
}


def bone_radius(name):
    base = name.split(".")[0]
    return RADIUS.get(base, RADIUS.get(name, 0.07))


# ------------------------------------------------------------------ утилиты
def read_glb(path):
    data = path.read_bytes()
    magic, ver, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "не GLB"
    off, chunks = 12, {}
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        chunks[ctype] = data[off : off + clen]
        off += clen
    return json.loads(chunks[0x4E4F534A]), bytearray(chunks[0x004E4942]), ver


def write_glb(path, gltf, binc):
    while len(binc) % 4:
        binc += b"\x00"
    gltf["buffers"][0]["byteLength"] = len(binc)
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(binc)
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(binc), 0x004E4942) + binc
    path.write_bytes(out)


def accessor_array(gltf, binc, index):
    a = gltf["accessors"][index]
    bv = gltf["bufferViews"][a["bufferView"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    ctype = {
        5120: np.int8, 5121: np.uint8, 5122: np.int16,
        5123: np.uint16, 5125: np.uint32, 5126: np.float32,
    }[a["componentType"]]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
    stride = bv.get("byteStride") or ncomp * np.dtype(ctype).itemsize
    if stride == ncomp * np.dtype(ctype).itemsize:
        return (
            np.frombuffer(bytes(binc), dtype=ctype, count=a["count"] * ncomp, offset=start)
            .reshape(a["count"], ncomp)
            .copy()
        )
    out = np.zeros((a["count"], ncomp), dtype=ctype)
    for i in range(a["count"]):
        out[i] = np.frombuffer(bytes(binc), dtype=ctype, count=ncomp, offset=start + i * stride)
    return out


def append_view(gltf, binc, arr, target=34962):
    """Дописать массив в конец буфера. target=None для матриц привязки."""
    while len(binc) % 4:
        binc += b"\x00"
    raw = arr.tobytes()
    view = {"buffer": 0, "byteOffset": len(binc), "byteLength": len(raw)}
    if target is not None:
        view["target"] = target
    binc += raw
    gltf["bufferViews"].append(view)
    return len(gltf["bufferViews"]) - 1


def add_float_accessor(gltf, binc, arr, ncomp, ntype, minmax=False, target=34962):
    view = append_view(gltf, binc, arr.astype(np.float32), target=target)
    acc = {
        "bufferView": view,
        "componentType": 5126,
        "count": int(arr.shape[0]),
        "type": ntype,
    }
    if minmax:
        acc["min"] = arr.min(axis=0).astype(float).tolist()
        acc["max"] = arr.max(axis=0).astype(float).tolist()
    gltf["accessors"].append(acc)
    return len(gltf["accessors"]) - 1


def add_ushort_accessor(gltf, binc, arr):
    view = append_view(gltf, binc, arr.astype(np.uint16))
    acc = {"bufferView": view, "componentType": 5123, "count": int(arr.shape[0]), "type": "VEC4"}
    gltf["accessors"].append(acc)
    return len(gltf["accessors"]) - 1


def quat_from_axes(primary, secondary):
    """Матрица 3x3, где X = primary, Y = secondary (ортогонализованы)."""
    x = primary / (np.linalg.norm(primary) + 1e-12)
    y = secondary - x * np.dot(x, secondary)
    y /= np.linalg.norm(y) + 1e-12
    z = np.cross(x, y)
    return np.stack([x, y, z], axis=1)  # columns = axes


def mat_to_quat(m):
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = np.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (m[2, 1] - m[1, 2]) / s
        y = (m[0, 2] - m[2, 0]) / s
        z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        w = (m[2, 1] - m[1, 2]) / s
        x = 0.25 * s
        y = (m[0, 1] + m[1, 0]) / s
        z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        w = (m[0, 2] - m[2, 0]) / s
        x = (m[0, 1] + m[1, 0]) / s
        y = 0.25 * s
        z = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        w = (m[1, 0] - m[0, 1]) / s
        x = (m[0, 2] + m[2, 0]) / s
        y = (m[1, 2] + m[2, 1]) / s
        z = 0.25 * s
    q = np.array([x, y, z, w])
    return q / (np.linalg.norm(q) + 1e-12)


def allowed_mask(pos, names):
    """Какие кости в принципе могут влиять на вершину.

    Без этих ограничений кость руки «захватывает» бок грудной клетки (она
    проходит внутри плеча), и при повороте руки торс тянется за ней.
    """
    n = len(pos)
    m = np.ones((n, len(names)), dtype=bool)
    x, y, z = pos[:, 0], pos[:, 1], pos[:, 2]
    for bi, name in enumerate(names):
        base, _, side = name.partition(".")
        sign = 1.0 if side == "L" else (-1.0 if side == "R" else 0.0)
        if base in ("shoulder", "upper_arm", "forearm", "hand"):
            # только своя сторона и только снаружи от плечевого сустава
            limit = {"shoulder": 0.02, "upper_arm": 0.09, "forearm": 0.115, "hand": 0.125}[base]
            m[:, bi] = (x * sign > limit) & (y > 0.55) & (y < 1.45)
        elif base in ("thigh", "shin", "foot", "toe"):
            m[:, bi] = (x * sign > 0.005) & (y < 0.98)
        elif base == "head":
            m[:, bi] = y > 1.42
        elif base == "neck":
            m[:, bi] = y > 1.33
        elif base == "chest":
            m[:, bi] = (y > 1.02) & (np.abs(x) < 0.30)
        elif base == "spine":
            m[:, bi] = (y > 0.90) & (y < 1.32) & (np.abs(x) < 0.22)
        elif base == "hips":
            m[:, bi] = (y > 0.62) & (y < 1.22) & (np.abs(x) < 0.25)
    return m


def smooth_weights(w, tri_idx, iterations=6, keep=0.55):
    """Лапласово сглаживание весов по рёбрам треугольников.

    Убирает «швы», когда соседние вершины привязаны к разным костям и при
    повороте сустава поверхность рвётся. keep — доля собственного веса.
    """
    n = w.shape[0]
    e = np.concatenate([tri_idx[:, [0, 1]], tri_idx[:, [1, 2]], tri_idx[:, [2, 0]]])
    e = np.concatenate([e, e[:, ::-1]])
    a, b = e[:, 0], e[:, 1]
    deg = np.bincount(a, minlength=n).astype(np.float64)
    deg[deg == 0] = 1.0
    for _ in range(iterations):
        acc = np.zeros_like(w)
        for c in range(w.shape[1]):
            acc[:, c] = np.bincount(a, weights=w[b, c], minlength=n) / deg
        w = keep * w + (1.0 - keep) * acc
        w /= w.sum(axis=1, keepdims=True) + 1e-12
    return w


def dist_point_segment(points, a, b):
    ab = b - a
    denom = float(np.dot(ab, ab)) + 1e-12
    t = np.clip(((points - a) @ ab) / denom, 0.0, 1.0)
    closest = a[None, :] + t[:, None] * ab[None, :]
    return np.linalg.norm(points - closest, axis=1), t


# ------------------------------------------------------------------- сборка
def main():
    if not SRC.exists():
        sys.exit(f"нет исходной модели: {SRC}")
    gltf, binc, _ = read_glb(SRC)
    names = [b[0] for b in BONES]
    index_of = {n: i for i, n in enumerate(names)}
    head = {b[0]: np.array(b[2], dtype=np.float64) for b in BONES}
    tail = {b[0]: np.array(b[3], dtype=np.float64) for b in BONES}

    # --- кости как узлы
    # ВАЖНО: узлы в glTF задают ЛОКАЛЬНЫЕ трансформации, а они складываются по
    # иерархии. Поэтому сначала считаем мировую матрицу каждой кости, затем
    # переводим её в локальную относительно родителя.
    def bone_world(name):
        h = head[name]
        direction = tail[name] - h
        yv = direction / (np.linalg.norm(direction) + 1e-12)
        ref = np.array([0.0, 0.0, 1.0]) if abs(yv[2]) < 0.9 else np.array([0.0, 1.0, 0.0])
        xv = np.cross(yv, ref)
        xv /= np.linalg.norm(xv) + 1e-12
        zv = np.cross(xv, yv)
        m = np.eye(4)
        m[:3, :3] = np.stack([xv, yv, zv], axis=1)
        m[:3, 3] = h
        return m

    world = {name: bone_world(name) for name, _, _, _ in BONES}
    bone_nodes = {}
    base_node_count = len(gltf["nodes"])
    for i, (name, parent, h, t) in enumerate(BONES):
        local = world[name] if parent is None else np.linalg.inv(world[parent]) @ world[name]
        bone_nodes[name] = base_node_count + i
        node = {
            "name": name,
            "translation": local[:3, 3].astype(float).tolist(),
            "rotation": mat_to_quat(local[:3, :3]).astype(float).tolist(),
        }
        gltf["nodes"].append(node)

    for name, parent, _, _ in BONES:
        if parent:
            gltf["nodes"][bone_nodes[parent]].setdefault("children", []).append(bone_nodes[name])

    # корневой узел скелета
    rig_root = len(gltf["nodes"])
    root_bones = [bone_nodes[b[0]] for b in BONES if b[1] is None]
    gltf["nodes"].append({"name": "Armature", "children": sorted(root_bones)})
    # Armature — общий корень скелета. Меши остаются в корне сцены:
    # так их мировые трансформации не зависят от трансформаций скелета.
    scene = gltf["scenes"][gltf.get("scene", 0)]
    scene["nodes"] = sorted(scene["nodes"] + [rig_root])

    # --- обратные матрицы привязки (bind pose = текущая поза модели)
    inv_bind = np.zeros((len(BONES), 16), dtype=np.float32)
    for bi, name in enumerate(names):
        inv_bind[bi] = np.linalg.inv(world[name]).T.reshape(-1)  # glTF: столбцовый порядок

    ibm_acc = add_float_accessor(
        gltf, binc, inv_bind, 16, "MAT4", minmax=False, target=None
    )
    skin_index = len(gltf.get("skins", []))
    gltf.setdefault("skins", []).append(
        {
            "name": "HeroineRig",
            "joints": [bone_nodes[n] for n in names],
            "inverseBindMatrices": ibm_acc,
            "skeleton": rig_root,
        }
    )

    # --- веса по расстоянию до отрезка кости
    segments = [(head[n], tail[n]) for n in names]
    report = {"bones": [], "meshes": []}

    for mi, mesh in enumerate(gltf["meshes"]):
        mesh_name = mesh.get("name", f"mesh{mi}")
        for pi, prim in enumerate(mesh["primitives"]):
            pos = accessor_array(gltf, binc, prim["attributes"]["POSITION"]).astype(np.float64)
            nverts = len(pos)
            tri_idx = accessor_array(gltf, binc, prim["indices"]).ravel().astype(np.int64).reshape(-1, 3)
            idx_conn = tri_idx
            # 1) жёсткая сегментация: ближайшая ДОПУСТИМАЯ кость
            w = np.zeros((nverts, len(names)), dtype=np.float64)
            dist = np.zeros((nverts, len(names)), dtype=np.float64)
            for bi, (a, b) in enumerate(segments):
                d, _ = dist_point_segment(pos, a, b)
                dist[:, bi] = d / bone_radius(names[bi])
            allowed = allowed_mask(pos, names)
            BIG = 1e6
            masked = np.where(allowed, dist, BIG)
            hard = np.argmin(masked, axis=1)
            w[np.arange(nverts), hard] = 1.0

            # 2) размытие весов по рёбрам: даёт плавный переход в суставах,
            #    но не переносит вес через «перемычки» вроде подмышки.
            #    После сглаживания оставляем только 3 влияния на вершину: так у
            #    каждой вершины есть запасной слот для «добивки» суммы весов до 1.
            w = smooth_weights(w, idx_conn, iterations=14, keep=0.5)
            order = np.argsort(-w, axis=1)[:, :MAX_INFLUENCES]
            wsel = np.take_along_axis(w, order, axis=1).astype(np.float32)
            wsel /= wsel.sum(axis=1, keepdims=True)
            # сумма весов должна быть ровно 1 во float32 — этого требует валидатор
            wsel[:, 0] += (1.0 - wsel.sum(axis=1)).astype(np.float32)
            joints = order.astype(np.uint16)
            prim["attributes"]["JOINTS_0"] = add_ushort_accessor(gltf, binc, joints)
            prim["attributes"]["WEIGHTS_0"] = add_float_accessor(
                gltf, binc, wsel.astype(np.float32), 4, "VEC4"
            )
            report["meshes"].append(
                {
                    "mesh": mesh_name,
                    "vertices": int(nverts),
                    "dominant_bones": {
                        names[i]: int((order[:, 0] == i).sum()) for i in range(len(names))
                        if (order[:, 0] == i).sum() > 0
                    },
                }
            )

    # привязать все меши к скелету
    for node in gltf["nodes"]:
        if "mesh" in node:
            node["skin"] = skin_index

    for name in names:
        report["bones"].append(
            {
                "name": name,
                "head": head[name].tolist(),
                "tail": tail[name].tolist(),
            }
        )

    write_glb(DST, gltf, binc)
    INFO.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"записано: {DST}  ({DST.stat().st_size/1048576:.2f} МБ)")
    print(f"костей: {len(names)}  костей-вершинных влияний: до {MAX_INFLUENCES}")
    for m in report["meshes"]:
        top = sorted(m["dominant_bones"].items(), key=lambda kv: -kv[1])[:5]
        print(f"  {m['mesh']}: {m['vertices']} вершин, главные кости: {top}")


if __name__ == "__main__":
    main()
