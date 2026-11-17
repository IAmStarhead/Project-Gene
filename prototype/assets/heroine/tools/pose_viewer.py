#!/usr/bin/env python3
"""Рендер поз скелета без Blender и без Godot.

Зачем: правки весов и углов нельзя проверять «на глаз по числам». Этот
скрипт деформирует меш ровно той же формулой скиннинга, что и Godot
(взвешенная сумма матриц костей), и рисует результат растеризатором с
буфером глубины. Так видно, тянется ли кожа за рукой и не проходит ли
рука сквозь тело.

Использование:
    python tools/pose_viewer.py                 # набор тестовых поз
    python tools/pose_viewer.py --pose attack   # одна поза
    python tools/pose_viewer.py --yaw 90 --pitch 0 --out side.png

Зависимости: numpy, Pillow.
"""
import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

GLB = Path(__file__).resolve().parent.parent / "female_A_rigged_safe.glb"
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


# ─────────────────────────────────────────────────────────── чтение GLB
def read_glb(path: Path):
    data = path.read_bytes()
    off = 12
    gltf, binary = None, b""
    while off < len(data):
        ln, typ = struct.unpack("<II", data[off:off + 8])
        chunk = data[off + 8:off + 8 + ln]
        off += 8 + ln
        if typ == JSON_CHUNK:
            gltf = json.loads(chunk)
        elif typ == BIN_CHUNK:
            binary = chunk
    return gltf, binary


DTYPES = {5120: np.int8, 5121: np.uint8, 5122: np.int16,
          5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def accessor(gltf, binary, index):
    acc = gltf["accessors"][index]
    bv = gltf["bufferViews"][acc["bufferView"]]
    nc = NCOMP[acc["type"]]
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    arr = np.frombuffer(binary, dtype=DTYPES[acc["componentType"]],
                        count=acc["count"] * nc, offset=start)
    return arr.reshape(acc["count"], nc)


# ─────────────────────────────────────────────────────────── кватернионы
def qmul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
                     w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
                     w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2])


def qaxis(axis, deg):
    r = np.deg2rad(deg) / 2.0
    return np.array([np.cos(r), *(np.sin(r) * np.array(axis, float))])


def qmat(q):
    w, x, y, z = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def bend(v):
    """Изгиб в осях кости: X — вперёд-назад, Z — в стороны, Y — скрутка."""
    q = np.array([1.0, 0, 0, 0])
    for axis, ang in (((1, 0, 0), v[0]), ((0, 0, 1), v[2]), ((0, 1, 0), v[1])):
        if abs(ang) > 1e-12:
            q = qmul(q, qaxis(axis, ang))
    return q


# ─────────────────────────────────────────────────────────── скелет
class Rig:
    def __init__(self, path: Path):
        self.gltf, self.bin = read_glb(path)
        g = self.gltf
        self.skin = g["skins"][0]
        self.joints = self.skin["joints"]
        self.names = [g["nodes"][j].get("name") for j in self.joints]
        self.index = {n: i for i, n in enumerate(self.names)}

        self.parent = {}
        for i, n in enumerate(g["nodes"]):
            for c in n.get("children", []):
                self.parent[int(c)] = i

        # локальные трансформации узлов (поза покоя)
        self.loc_rot, self.loc_pos = [], []
        for n in g["nodes"]:
            r = n.get("rotation")
            if r is None:
                self.loc_rot.append(np.array([1.0, 0, 0, 0]))
            else:
                x, y, z, w = r
                self.loc_rot.append(np.array([w, x, y, z]))
            self.loc_pos.append(np.array(n.get("translation", [0, 0, 0]), float))

        # обратные матрицы привязки
        ibm = accessor(g, self.bin, self.skin["inverseBindMatrices"]).astype(float)
        self.inv_bind = ibm.reshape(-1, 4, 4).transpose(0, 2, 1)

    def bone_world(self, node, pose):
        chain = [node]
        j = node
        while j in self.parent:
            j = self.parent[j]
            chain.append(j)
        chain.reverse()
        R = np.array([1.0, 0, 0, 0])
        T = np.zeros(3)
        for b in chain:
            T = T + qmat(R) @ self.loc_pos[b]
            R = qmul(R, qmul(self.loc_rot[b], bend(pose.get(b, np.zeros(3)))))
        M = np.eye(4)
        M[:3, :3] = qmat(R)
        M[:3, 3] = T
        return M

    def skin_matrices(self, pose):
        out = []
        for i, node in enumerate(self.joints):
            W = self.bone_world(node, pose)
            out.append(W @ self.inv_bind[i])
        return np.stack(out)

    def mesh(self, pose, mesh_index=0):
        g = self.gltf
        prim = g["meshes"][mesh_index]["primitives"][0]
        at = prim["attributes"]
        pos = accessor(g, self.bin, at["POSITION"]).astype(float)
        nrm = accessor(g, self.bin, at["NORMAL"]).astype(float)
        idx = accessor(g, self.bin, prim["indices"]).ravel().astype(int)
        J = accessor(g, self.bin, at["JOINTS_0"]).astype(int)
        W = accessor(g, self.bin, at["WEIGHTS_0"]).astype(float)

        S = self.skin_matrices(pose)
        ph = np.concatenate([pos, np.ones((len(pos), 1))], axis=1)
        nh = np.concatenate([nrm, np.zeros((len(nrm), 1))], axis=1)
        out = np.zeros((len(pos), 3))
        outn = np.zeros((len(nrm), 3))
        for k in range(4):
            Mk = S[J[:, k]]
            w = W[:, k][:, None]
            out += w * np.einsum("nij,nj->ni", Mk, ph)[:, :3]
            outn += w * np.einsum("nij,nj->ni", Mk, nh)[:, :3]
        outn /= np.linalg.norm(outn, axis=1, keepdims=True) + 1e-9
        return out, outn, idx

    def pose_from_names(self, spec):
        """spec: {"upper_arm.R": (x, y, z) в градусах} -> поза по ИНДЕКСАМ УЗЛОВ.

        Важно: bone_world() ходит по дереву узлов glTF, поэтому ключи позы
        должны быть индексами узлов, а не порядковыми номерами костей в скине.
        В первой версии здесь стоял self.index (номер в скине) — из-за этого
        повороты применялись к чужим костям.
        """
        out = {}
        for name, v in spec.items():
            if name not in self.index:
                raise SystemExit(f"нет кости {name}")
            out[self.joints[self.index[name]]] = np.array(v, float)
        return out


# ─────────────────────────────────────────────────────────── растеризатор
def render(mesh, size=560, yaw=-30, pitch=-6, dist=3.2, target=(0, 0.95, 0),
           colour=(232, 192, 170)):
    pos, nrm, idx = mesh
    W = H = size
    img = np.full((H, W, 3), 250.0)
    zbuf = np.full((H, W), 1e9)

    ty, tx = np.radians(yaw), np.radians(pitch)
    cy, sy = np.cos(ty), np.sin(ty)
    cp, sp = np.cos(tx), np.sin(tx)
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    ctr = np.array(target, float)
    V = (pos - ctr) @ Ry.T @ Rx.T
    N = nrm @ Ry.T @ Rx.T
    V = V + np.array([0, 0, dist])

    focal = size * 0.95
    zs = np.clip(V[:, 2], 0.05, None)
    sx = V[:, 0] / zs * focal + W / 2
    syy = -V[:, 1] / zs * focal + H / 2

    light = np.array([0.30, 0.45, 0.85])
    light /= np.linalg.norm(light)
    shade = np.clip(N @ light, 0, 1) * 0.55 + 0.50
    base = np.array(colour, float)

    for t in idx.reshape(-1, 3):
        x, y, z = sx[t], syy[t], zs[t]
        minx, maxx = int(max(0, np.floor(x.min()))), int(min(W - 1, np.ceil(x.max())))
        miny, maxy = int(max(0, np.floor(y.min()))), int(min(H - 1, np.ceil(y.max())))
        if minx > maxx or miny > maxy:
            continue
        x0, x1, x2 = x
        y0, y1, y2 = y
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(den) < 1e-9:
            continue
        xs = np.arange(minx, maxx + 1) + 0.5
        ys = np.arange(miny, maxy + 1) + 0.5
        gx, gy = np.meshgrid(xs, ys)
        w0 = ((y1 - y2) * (gx - x2) + (x2 - x1) * (gy - y2)) / den
        w1 = ((y2 - y0) * (gx - x2) + (x0 - x2) * (gy - y2)) / den
        w2 = 1 - w0 - w1
        mask = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not mask.any():
            continue
        zz = w0 * z[0] + w1 * z[1] + w2 * z[2]
        sub = zbuf[miny:maxy + 1, minx:maxx + 1]
        better = mask & (zz < sub)
        if better.any():
            s = float(shade[t].mean())
            sub[better] = zz[better]
            img[miny:maxy + 1, minx:maxx + 1][better] = base * s
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


# ─────────────────────────────────────────────────────────── позы
POSES = {
    "idle": {},
    "attack_back": {"upper_arm.R": (-62, 0, -32), "forearm.R": (102, 0, 0), "hand.R": (0, 0, -6)},
    "attack_hit": {"upper_arm.R": (70, 0, -14), "forearm.R": (34, 0, 0), "hand.R": (0, 0, -4)},
    "arm_up": {"upper_arm.R": (0, 0, -95), "forearm.R": (0, 0, -70)},
    "arm_out": {"upper_arm.R": (0, 0, -80)},
    "arm_fwd_low": {"upper_arm.R": (55, 0, 0)},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pose", default=None, help="имя позы из набора или список через запятую")
    ap.add_argument("--yaw", type=float, default=-30)
    ap.add_argument("--pitch", type=float, default=-6)
    ap.add_argument("--size", type=int, default=560)
    ap.add_argument("--out", default="pose_render.png")
    args = ap.parse_args()

    if not GLB.exists():
        raise SystemExit(f"нет модели: {GLB}\nсначала запустите sanitize_glb.py")
    rig = Rig(GLB)

    if args.pose:
        names = [p.strip() for p in args.pose.split(",")]
        for n in names:
            if n not in POSES:
                raise SystemExit(f"нет позы {n}; есть: {', '.join(POSES)}")
        tiles = []
        for n in names:
            mesh = rig.mesh(rig.pose_from_names(POSES[n]))
            tiles.append((n, render(mesh, args.size, args.yaw, args.pitch)))
        w, h = tiles[0][1].size
        sheet = Image.new("RGB", (w * len(tiles), h))
        for i, (n, im) in enumerate(tiles):
            sheet.paste(im, (i * w, 0))
    else:
        tiles = []
        for n, spec in POSES.items():
            mesh = rig.mesh(rig.pose_from_names(spec))
            tiles.append((n, render(mesh, args.size, args.yaw, args.pitch)))
        cols = 3
        rows = (len(tiles) + cols - 1) // cols
        w, h = tiles[0][1].size
        sheet = Image.new("RGB", (w * cols, h * rows), (255, 255, 255))
        for i, (n, im) in enumerate(tiles):
            sheet.paste(im, ((i % cols) * w, (i // cols) * h))
    sheet.save(args.out)
    print(f"сохранено: {args.out} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()
