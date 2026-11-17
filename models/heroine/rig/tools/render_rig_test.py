#!/usr/bin/env python3
"""
Проверка скелета без Blender и Godot: собственный программный рендер
со скиннингом (linear blend skinning).

Читает models/heroine/female_A_rigged.glb, применяет тестовые позы
и рисует результат в PNG. Позволяет увидеть, как ведут себя веса:
не тянется ли торс за рукой, не рвётся ли плечо, работает ли колено.

Запуск:  python3 models/heroine/rig/tools/render_rig_test.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import build_rig as br

OUT_DIR = Path("reports/analysis")
BONE_ORDER = [b[0] for b in br.BONES]


# ------------------------------------------------------------------ математика
def quat_to_mat(q):
    x, y, z, w = q
    n = np.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def mat_to_quat_mul(q, axis, angle):
    """Умножить кватернион q на поворот вокруг локальной оси."""
    axis = np.asarray(axis, dtype=float)
    axis /= np.linalg.norm(axis)
    h = angle / 2
    dq = np.array([axis[0] * np.sin(h), axis[1] * np.sin(h), axis[2] * np.sin(h), np.cos(h)])
    x1, y1, z1, w1 = q
    x2, y2, z2, w2 = dq
    return np.array(
        [
            w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
            w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        ]
    )


class Rig:
    def __init__(self, glb_path):
        gltf, binc, _ = br.read_glb(glb_path)
        self.gltf, self.binc = gltf, binc
        skin = gltf["skins"][0]
        self.joints = skin["joints"]
        self.names = [gltf["nodes"][j].get("name", str(j)) for j in self.joints]
        self.parent = {}
        for i, n in enumerate(gltf["nodes"]):
            for c in n.get("children", []):
                self.parent[c] = i
        self.local_t = []
        self.local_q = []
        for j in self.joints:
            n = gltf["nodes"][j]
            self.local_t.append(np.array(n.get("translation", [0, 0, 0]), dtype=float))
            self.local_q.append(np.array(n.get("rotation", [0, 0, 0, 1]), dtype=float))
        ibm = br.accessor_array(gltf, binc, skin["inverseBindMatrices"]).astype(float)
        # glTF хранит матрицы по столбцам: reshape+транспонирование даёт мировую
        # матрицу привязки, обратную к ней (IBM уже содержит обращение)
        self.bind_world = np.array([m.reshape(4, 4).T for m in ibm])
        self.joint_index = {self.names[i]: i for i in range(len(self.names))}

    def world_matrices(self, pose):
        """pose: {имя: (ось, угол)} — повороты в локальном пространстве кости."""
        n = len(self.joints)
        world = [None] * n
        parent_i = []
        for j in self.joints:
            p = self.parent.get(j)
            parent_i.append(self.joints.index(p) if (p is not None and p in self.joints) else -1)
        q_local = list(self.local_q)
        for name, (axis, angle) in pose.items():
            i = self.joint_index[name]
            q_local[i] = mat_to_quat_mul(q_local[i], axis, angle)

        def get(i):
            if world[i] is not None:
                return world[i]
            R = quat_to_mat(q_local[i])
            m = np.eye(4)
            m[:3, :3] = R
            m[:3, 3] = self.local_t[i]
            if parent_i[i] >= 0:
                m = get(parent_i[i]) @ m
            world[i] = m
            return m

        return [get(i) for i in range(n)]

    def skin_matrices(self, pose):
        W = self.world_matrices(pose)
        return [W[i] @ self.bind_world[i] for i in range(len(W))]

    def mesh(self, mesh_index, pose):
        gltf = self.gltf
        prim = gltf["meshes"][mesh_index]["primitives"][0]
        at = prim["attributes"]
        pos = br.accessor_array(gltf, self.binc, at["POSITION"]).astype(float)
        nrm = br.accessor_array(gltf, self.binc, at["NORMAL"]).astype(float)
        idx = br.accessor_array(gltf, self.binc, prim["indices"]).ravel()
        J = br.accessor_array(gltf, self.binc, at["JOINTS_0"]).astype(int)
        Wt = br.accessor_array(gltf, self.binc, at["WEIGHTS_0"]).astype(float)
        S = np.stack(self.skin_matrices(pose))  # (B,4,4)
        ph = np.concatenate([pos, np.ones((len(pos), 1))], axis=1)
        nh = np.concatenate([nrm, np.zeros((len(nrm), 1))], axis=1)
        out = np.zeros((len(pos), 3))
        outn = np.zeros((len(nrm), 3))
        for k in range(4):
            Mk = S[J[:, k]]                      # (N,4,4)
            w = Wt[:, k][:, None]                # (N,1)
            out += w * np.einsum("nij,nj->ni", Mk, ph)[:, :3]
            outn += w * np.einsum("nij,nj->ni", Mk, nh)[:, :3]
        outn /= np.linalg.norm(outn, axis=1, keepdims=True) + 1e-9
        return out, outn, idx


def render(mesh_data, size=520, yaw=-28, pitch=-8, dist=3.4, target=(0, 0.95, 0)):
    pos, nrm, idx = mesh_data
    W, H = size, size
    img = np.full((H, W, 3), 18, dtype=np.float32)
    zbuf = np.full((H, W), 1e9)

    ty, tx = np.radians(yaw), np.radians(pitch)
    cy, sy = np.cos(ty), np.sin(ty)
    cp, sp = np.cos(tx), np.sin(tx)
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    ctr = np.array(target, dtype=float)
    V = (pos - ctr) @ Ry.T @ Rx.T
    N = nrm @ Ry.T @ Rx.T
    V = V + np.array([0, 0, dist])
    focal = size * 0.95
    zs = np.clip(V[:, 2], 0.05, None)
    sx = V[:, 0] / zs * focal + W / 2
    sy_ = -V[:, 1] / zs * focal + H / 2
    Nn = N / (np.linalg.norm(N, axis=1, keepdims=True) + 1e-9)

    light = np.array([0.30, 0.45, 0.85])
    light /= np.linalg.norm(light)
    shade = np.clip(Nn @ light, 0, 1) * 0.65 + 0.42

    for t in idx.reshape(-1, 3):
        x = sx[t]
        y = sy_[t]
        z = zs[t]
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
        sub = zbuf[miny : maxy + 1, minx : maxx + 1]
        better = mask & (zz < sub)
        if better.any():
            s = shade[t].mean()
            col = np.array([230.0, 190.0, 168.0]) * s
            sub[better] = zz[better]
            region = img[miny : maxy + 1, minx : maxx + 1]
            region[better] = col
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def main():
    rig = Rig(br.DST)
    body = rig.mesh(0, {})
    poses = [
        ("Поза покоя", {}, -28, -6),
        ("Левая рука вверх + локоть согнут", {"upper_arm.L": ((0, 0, 1), np.radians(-95)),
                                              "forearm.L": ((0, 0, 1), np.radians(-80))}, -28, -6),
        ("Правая рука вперёд (удар)", {"upper_arm.R": ((1, 0, 0), np.radians(-85)),
                                        "forearm.R": ((1, 0, 0), np.radians(-25))}, 55, -6),
        ("Колено согнуто (приседание)", {"thigh.L": ((1, 0, 0), np.radians(-55)),
                                         "shin.L": ((1, 0, 0), np.radians(85)),
                                         "thigh.R": ((1, 0, 0), np.radians(-55)),
                                         "shin.R": ((1, 0, 0), np.radians(85))}, -28, -6),
        ("Поворот головы", {"neck": ((0, 1, 0), np.radians(35)),
                            "head": ((0, 1, 0), np.radians(30))}, 0, -6),
        ("Наклон корпуса", {"spine": ((1, 0, 0), np.radians(30)),
                            "chest": ((1, 0, 0), np.radians(20))}, 55, -6),
    ]
    tiles = []
    for name, pose, yaw, pitch in poses:
        mdata = rig.mesh(0, pose) if pose else body
        tiles.append((name, render(mdata, yaw=yaw, pitch=pitch)))

    cols, rows = 3, 2
    ts = tiles[0][1].width
    pad, head = 12, 64
    canvas = Image.new("RGB", (cols * ts + pad * (cols + 1), head + rows * (ts + 46) + pad),
                       (16, 17, 22))
    d = ImageDraw.Draw(canvas)
    f_big = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 30)
    f_sm = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 20)
    d.text((pad, 14), "Проверка скелета: деформация в тестовых позах", font=f_big, fill=(240, 245, 255))
    for i, (name, im) in enumerate(tiles):
        c, r = i % cols, i // cols
        x = pad + c * (ts + pad)
        y = head + r * (ts + 46)
        d.text((x, y), name, font=f_sm, fill=(200, 210, 225))
        canvas.paste(im, (x, y + 26))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / "rig-pose-test.png"
    canvas.save(path)
    print("сохранено:", path, canvas.size)


if __name__ == "__main__":
    main()
