#!/usr/bin/env python3
"""Сборка лабораторного платья для героини — без Blender.

Зачем генератор, а не готовый меш: одежду надо править числами (длина,
расклешение, сколько подола тянется за бедром) и каждый раз проверять, не
пробивается ли она ногами в анимациях. Поэтому крой описан таблицей, а
проверка считается по настоящим клипам из `motion_set.tres`.

Что делает скрипт:

1. Строит поверхность вращения по профилю (высота → радиус) с 28 сегментами.
2. Раздаёт веса костям: сверху таз, снизу передняя половина тянется бедром.
   Именно это спасает от пробития: в беге колено уходит почти на 30 см
   вперёд, и жёсткая юбка-колокол там обязательно проткнулась бы.
3. Считает UV (u по кругу, v сверху вниз) и гладкие нормали.
4. Рисует текстуру ткани 256×256: светлая основа, тонкая диагональная
   фактура, швы и тёмная кромка по подолу (низ текстуры = v 0).
5. Пишет `lab_dress.json` и `lab_dress.png` для Godot.
6. Проверяет пробитие по всем клипам и печатает сводку.

Запуск (нужны numpy и Pillow):

    python prototype/tools/garment/build_dress.py
    python prototype/tools/garment/build_dress.py --check   # только проверка
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]          # prototype/
ASSETS = ROOT / "assets" / "heroine"
GLB = ASSETS / "female_A_rigged_safe.glb"
MOTIONS = ASSETS / "animations" / "motion_set.tres"
OUT_JSON = ASSETS / "garments" / "lab_dress.json"
OUT_PNG = ASSETS / "garments" / "lab_dress.png"

# ── Крой. Высота в метрах от пола, радиус в метрах от вертикальной оси.
# Верхний край — на 1.045, выше талии: так платье не сползает при наклоне.
PROFILE = [
    (1.045, 0.148),
    (1.010, 0.152),
    (0.975, 0.161),
    (0.940, 0.172),
    (0.905, 0.192),
    (0.870, 0.202),
    (0.835, 0.214),
    (0.800, 0.228),
    (0.700, 0.270),
    (0.600, 0.330),     # подол: выше колена (колено на 0.47)
]
SEGMENTS = 28
SPLIT = 0.80            # ниже этой высоты подол начинает тянуться за бедром
THIGH_WEIGHT = 0.62     # доля бедра в весах подола (0 — жёстко, 1 — целиком)
SEAM_U = (0.0, 0.5)     # где рисовать боковые швы на текстуре

# Параметры ткани
CLOTH_RGB = (0.945, 0.952, 0.965)   # почти белый, чуть холодный
TRIM_RGB = (0.72, 0.77, 0.84)       # кромка по подолу и вороту


# ───────────────────────────────────────────────────────── геометрия
def build(profile=PROFILE, segments=SEGMENTS):
    ys = np.array([p[0] for p in profile])
    rs = np.array([p[1] for p in profile])
    n_rings = len(profile)
    ang = np.linspace(0.0, 2 * np.pi, segments, endpoint=False)
    sa, ca = np.sin(ang), np.cos(ang)

    pos = np.array([[r * s, y, r * c] for y, r in zip(ys, rs) for s, c in zip(sa, ca)])
    uv = np.array([[j / segments, 1.0 - i / (n_rings - 1)]
                   for i in range(n_rings) for j in range(segments)])

    idx = []
    for i in range(n_rings - 1):
        for j in range(segments):
            a = i * segments + j
            b = i * segments + (j + 1) % segments
            c = (i + 1) * segments + j
            d = (i + 1) * segments + (j + 1) % segments
            idx += [a, c, b, b, c, d]
    idx = np.array(idx, dtype=np.int32).reshape(-1, 3)

    nrm = _smooth_normals(pos, idx)
    # Нормали должны смотреть наружу. Проверяем по радиальному направлению и,
    # если перепутано, разворачиваем порядок вершин вместе с нормалями.
    radial = np.stack([pos[:, 0], np.zeros(len(pos)), pos[:, 2]], axis=1)
    radial /= np.linalg.norm(radial, axis=1, keepdims=True) + 1e-9
    if np.mean(np.einsum("ij,ij->i", nrm, radial)) < 0.0:
        idx = idx[:, ::-1].copy()
        nrm = -nrm
    return pos, idx, nrm, uv, ys


def _smooth_normals(pos, idx):
    tri = pos[idx]
    face = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    out = np.zeros_like(pos)
    for k in range(3):
        np.add.at(out, idx[:, k], face)
    return out / (np.linalg.norm(out, axis=1, keepdims=True) + 1e-9)


def weights(pos, ys, split=SPLIT, thigh_weight=THIGH_WEIGHT):
    """Веса по именам костей: список [(кость, вес), …] на вершину."""
    y_top = ys.max()
    out = []
    for x, y, z in pos:
        up = float(np.clip((y - split) / max(y_top - split, 1e-6), 0.0, 1.0))
        up = up * up * (3.0 - 2.0 * up)                 # сглаженный переход
        front = float(np.clip((z + 0.02) / 0.10, 0.0, 1.0))   # 0 сзади, 1 спереди
        t = (1.0 - up) * front * thigh_weight
        pairs = [("hips", 1.0 - t)]
        if t > 1e-4:
            pairs.append(("thigh.L" if x >= 0.0 else "thigh.R", t))
        out.append(pairs)
    return out


# ───────────────────────────────────────────────────────── текстура
def build_texture(path: Path, size: int = 256) -> None:
    from PIL import Image, ImageDraw

    rng = np.random.default_rng(7)
    base = np.zeros((size, size, 3), dtype=np.float64)
    base[:] = np.array(CLOTH_RGB) * 255.0

    v = np.linspace(0.0, 1.0, size)[:, None]        # строки: v=1 сверху текстуры
    u = np.linspace(0.0, 1.0, size)[None, :]
    # Диагональная фактура ткани: очень слабая, чтобы не рябило на 720p.
    weave = 0.5 + 0.5 * np.sin((u + v) * 2 * np.pi * 64.0)
    base *= (0.985 + 0.015 * weave)[..., None]
    # Мягкие переливы, чтобы плоское белое не выглядело пластиком.
    base *= (1.0 - 0.03 * (0.5 + 0.5 * np.sin(v * np.pi * 2.0)))[..., None]

    img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")
    draw = ImageDraw.Draw(img)
    trim = tuple(int(c * 255) for c in TRIM_RGB)
    # Кромка по подолу: v близко к 0 => низ текстуры.
    draw.rectangle([0, size - int(size * 0.07), size, size], fill=trim)
    # Ворот сверху.
    draw.rectangle([0, 0, size, int(size * 0.035)], fill=trim)
    # Боковые швы.
    for su in SEAM_U:
        x = int(su * size) % size
        draw.line([(x, 0), (x, size)], fill=trim, width=max(1, size // 128))
    # Две мягкие складки.
    for k, su in enumerate((0.25, 0.75)):
        x = int(su * size)
        for dy in range(size):
            t = dy / size
            shade = int(255 * (0.02 * np.sin(t * 6.0) + 0.01 * (k)))
            draw.point((x, dy), fill=tuple(max(0, min(255, c - shade)) for c in img.getpixel((x, dy))))

    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(f"текстура: {path}  {size}x{size}")


# ───────────────────────────────────────────────────────── запись
def write_json(path: Path, pos, idx, nrm, uv, wts) -> None:
    doc = {
        "name": "lab_dress",
        "note": ("Сгенерировано prototype/tools/garment/build_dress.py. "
                 "Править не вручную, а параметрами кроя и пересборкой."),
        "vertices": [
            {
                "p": [round(float(v), 5) for v in p],
                "n": [round(float(v), 4) for v in n],
                "uv": [round(float(v), 4) for v in uvq],
                "w": [[b, round(float(w), 4)] for b, w in ww],
            }
            for p, n, uvq, ww in zip(pos, nrm, uv, wts)
        ],
        "triangles": [int(i) for i in idx.ravel()],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"меш: {path}  вершин {len(pos)}, треугольников {len(idx)}")


# ───────────────────────────────────────────────────────── проверка
def check(pos, wts, frames: int = 0) -> float:
    """Доля вершин платья, оказавшихся внутри тела, по всем клипам.

    Требует motion_set.tres и pose_viewer.py; без них проверка пропускается.
    """
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import motion_check   # отдельный модуль, чтобы основной скрипт оставался коротким
    return motion_check.run(pos, wts, MOTIONS, GLB, max_frames=frames)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="только проверить пробитие")
    ap.add_argument("--motions", type=Path, default=MOTIONS,
                    help="путь к motion_set.tres (по умолчанию из assets)")
    args = ap.parse_args()

    pos, idx, nrm, uv, ys = build()
    wts = weights(pos, ys)
    if not args.check:
        build_texture(OUT_PNG)
        write_json(OUT_JSON, pos, idx, nrm, uv, wts)

    motions = args.motions
    if motions.exists():
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import motion_check
        print("проверка пробития по клипам:")
        bad = motion_check.run(pos, wts, motions, GLB)
        print(f"пробитие по клипам: {bad:.2f}% вершин")
    else:
        print("motion_set.tres нет — проверка пробития пропущена")


if __name__ == "__main__":
    main()
