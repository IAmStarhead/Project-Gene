"""Проверка: не пробивает ли платье тело в анимациях.

Читает клипы из `motion_set.tres` (формат Godot AnimationLibrary), сэмплирует
их на 60 Гц, скинит тело и платье одной и той же формулой, что и Godot, и
ищет вершины платья, оказавшиеся внутри тела.

Тест намеренно консервативный: вершина считается пробившей, если её ближайшая
вершина тела «смотрит от неё» (то есть точка за поверхностью) и расстояние
меньше 6 см. Порог в 6 см отсекает случаи, когда юбка просто касается кожи.

Это оффлайн-проверка модели, а не запуск игры.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

INSIDE_DOT = -0.15     # косинус между нормалью тела и направлением к точке
NEAR_LIMIT = 0.06      # м, дальше этого «внутри» уже не считается пробитием


# ───────────────────────────────── чтение .tres и сэмплирование
def parse_motions(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    clips = {}
    for block in text.split('[sub_resource type="Animation"')[1:]:
        name = re.search(r'resource_name = "([^"]+)"', block)
        length = re.search(r"length = ([\d.]+)", block)
        if not name or not length:
            continue
        anim = {"length": float(length.group(1)), "rot": {}, "pos": {}}
        types = {m.group(1): m.group(2)
                 for m in re.finditer(r'tracks/(\d+)/type = "([^"]+)"', block)}
        names = {m.group(1): m.group(2)
                 for m in re.finditer(r'tracks/(\d+)/path = NodePath\("\.:([^"]+)"\)', block)}
        for m in re.finditer(r"tracks/(\d+)/keys = PackedFloat32Array\(([^)]*)\)", block):
            bone = names[m.group(1)]
            vals = np.array([float(v) for v in m.group(2).split(",")])
            if types.get(m.group(1)) == "rotation_3d":
                anim["rot"][bone] = vals.reshape(-1, 6)      # время, переход, x,y,z,w
            else:
                anim["pos"][bone] = vals.reshape(-1, 5)      # время, переход, x,y,z
        clips[name.group(1)] = anim
    return clips


def _slerp(a: np.ndarray, b: np.ndarray, u: float) -> np.ndarray:
    d = float(np.dot(a, b))
    if d < 0.0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + u * (b - a)
        return r / np.linalg.norm(r)
    th = np.arccos(max(-1.0, min(1.0, d)))
    s = np.sin(th)
    return (np.sin((1 - u) * th) / s) * a + (np.sin(u * th) / s) * b


def sample(anim: dict, t: float) -> dict:
    """Локальные кватернионы (w,x,y,z) по именам костей на момент t."""
    out = {}
    for bone, keys in anim["rot"].items():
        times = keys[:, 0]
        i = int(np.searchsorted(times, t, side="right") - 1)
        i = max(0, min(i, len(times) - 2))
        t0, t1 = times[i], times[i + 1]
        u = 0.0 if t1 <= t0 else float(np.clip((t - t0) / (t1 - t0), 0.0, 1.0))
        q = _slerp(keys[i, 2:6], keys[i + 1, 2:6], u)
        out[bone] = np.array([q[3], q[0], q[1], q[2]])
    return out


# ─────────────────────────────────────────────── прямая кинематика
def _qmul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
                     w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
                     w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2])


def _qmat(q):
    w, x, y, z = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def world_matrices(rig, local_over: dict) -> dict:
    """Мир-матрица каждой кости при подмене ЛОКАЛЬНЫХ поворотов."""
    node_of = {n: rig.joints[rig.index[n]] for n in rig.index}
    memo = {}

    def rec(node):
        if node in memo:
            return memo[node]
        name = rig.gltf["nodes"][node].get("name")
        own = local_over.get(name, rig.loc_rot[node])
        parent = rig.parent.get(node)
        if parent is None:
            R, T = own, np.zeros(3)
        else:
            Rp, Tp = rec(parent)
            T = Tp + _qmat(Rp) @ rig.loc_pos[node]
            R = _qmul(Rp, own)
        memo[node] = (R, T)
        return memo[node]

    return {n: rec(node_of[n]) for n in node_of}


def skin_matrices(rig, worlds) -> np.ndarray:
    out = []
    for i, node in enumerate(rig.joints):
        R, T = worlds[rig.names[i]]
        M = np.eye(4)
        M[:3, :3] = _qmat(R)
        M[:3, 3] = T
        out.append(M @ rig.inv_bind[i])
    return np.stack(out)


def skin_points(points, joints, weights, S) -> np.ndarray:
    ph = np.concatenate([points, np.ones((len(points), 1))], axis=1)
    out = np.zeros((len(points), 3))
    for k in range(4):
        out += weights[:, k][:, None] * np.einsum("nij,nj->ni", S[joints[:, k]], ph)[:, :3]
    return out


def skin_normals(normals, joints, weights, S) -> np.ndarray:
    ph = np.concatenate([normals, np.zeros((len(normals), 1))], axis=1)
    out = np.zeros((len(normals), 3))
    for k in range(4):
        out += weights[:, k][:, None] * np.einsum("nij,nj->ni", S[joints[:, k]], ph)[:, :3]
    return out / (np.linalg.norm(out, axis=1, keepdims=True) + 1e-9)


# ─────────────────────────────────────────────────────────── прогон
def run(dress_pos, dress_w, motions: Path, glb: Path, max_frames: int = 0) -> float:
    sys.path.insert(0, str(Path(glb).resolve().parent / "tools"))
    from pose_viewer import Rig, accessor

    rig = Rig(Path(glb))
    g = rig.gltf
    prim = g["meshes"][0]["primitives"][0]
    body_pos = accessor(g, rig.bin, prim["attributes"]["POSITION"]).astype(float)
    body_nrm = accessor(g, rig.bin, prim["attributes"]["NORMAL"]).astype(float)
    body_J = accessor(g, rig.bin, prim["attributes"]["JOINTS_0"]).astype(int)
    body_W = accessor(g, rig.bin, prim["attributes"]["WEIGHTS_0"]).astype(float)

    # веса платья: список пар (кость, вес) -> матрицы индексов и весов
    dJ = np.zeros((len(dress_pos), 4), dtype=int)
    dW = np.zeros((len(dress_pos), 4), dtype=float)
    for i, pairs in enumerate(dress_w):
        pairs = sorted(pairs, key=lambda p: -p[1])[:4]
        for k, (bone, w) in enumerate(pairs):
            dJ[i, k] = rig.index[bone]
            dW[i, k] = w
        dW[i] /= dW[i].sum()

    clips = parse_motions(motions)
    worst = 0.0
    worst_at = ""
    total = 0
    inside = 0
    for cname, anim in clips.items():
        step = max(1, max_frames // len(clips)) if max_frames else int(anim["length"] * 60)
        for t in np.linspace(0.0, anim["length"] - 1e-3, step):
            S = skin_matrices(rig, world_matrices(rig, sample(anim, float(t))))
            sp = skin_points(dress_pos, dJ, dW, S)
            bp = skin_points(body_pos, body_J, body_W, S)
            bn = skin_normals(body_nrm, body_J, body_W, S)
            d2 = ((sp[:, None, :] - bp[None, :, :]) ** 2).sum(2)
            near = d2.argmin(1)
            v = sp - bp[near]
            dist = np.linalg.norm(v, axis=1) + 1e-9
            dot = np.einsum("ij,ij->i", v / dist[:, None], bn[near])
            bad = (dot < INSIDE_DOT) & (dist < NEAR_LIMIT)
            frac = float(bad.mean())
            total += len(sp)
            inside += int(bad.sum())
            if frac > worst:
                worst, worst_at = frac, f"{cname} t={t:.2f}"
    print(f"  худший кадр: {worst * 100:.2f}% ({worst_at})")
    return inside / total * 100.0
