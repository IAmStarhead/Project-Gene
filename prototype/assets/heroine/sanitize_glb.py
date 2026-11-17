#!/usr/bin/env python3
"""Убирает из GLB то, на чём спотыкается импортёр Godot.

Зачем: модель female_A_rigged.glb формально корректна (валидатор Khronos —
0 ошибок), но содержит три вещи, которые в Godot 4 связаны с падениями
редактора при импорте:

  1) blend shapes (морф-таргеты) на скин-мешах;
  2) анимации, двигающие веса морфов (path="weights");
  3) анимации на узлах, которые не являются костями.

Для прототипа ни то, ни другое не нужно: позы считаются кодом
(prototype/scripts/character_anim.gd), а морфы «кулак» не используются.
Поэтому скрипт вырезает морфы и анимации, не трогая геометрию, скелет и веса.

Использование:
    python tools/sanitize_glb.py вход.glb выход.glb

Оригинал не изменяется. Проверка результата — валидатором Khronos.
"""
import json
import struct
import sys
from pathlib import Path

JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def read_glb(path: Path):
    data = path.read_bytes()
    magic, version, length = struct.unpack("<III", data[:12])
    if magic != 0x46546C67:
        raise SystemExit(f"{path}: это не GLB")
    offset = 12
    gltf = None
    binary = b""
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack("<II", data[offset:offset + 8])
        chunk = data[offset + 8:offset + 8 + chunk_len]
        offset += 8 + chunk_len
        if chunk_type == JSON_CHUNK:
            gltf = json.loads(chunk)
        elif chunk_type == BIN_CHUNK:
            binary = chunk
    if gltf is None:
        raise SystemExit(f"{path}: нет JSON-чанка")
    return gltf, binary


def write_glb(path: Path, gltf: dict, binary: bytes) -> None:
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)          # выравнивание до 4 байт
    bn = binary + b"\x00" * ((4 - len(binary) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(bn)
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(js), JSON_CHUNK) + js
    out += struct.pack("<II", len(bn), BIN_CHUNK) + bn
    path.write_bytes(out)


def fix_armpit_weights(gltf: dict, binary: bytes) -> tuple[bytes, dict]:
    """Не даёт руке тянуть за собой бок туловища.

    У модели нет подмышечной впадины: поверхность торса и руки — одна
    непрерывная оболочка. В районе бока (|X| 0.13..0.15, Y 1.15..1.40)
    есть 192 вершины с весом плеча до 0.97. При ударе они уходят вместе
    с рукой и тянут за собой соседние вершины груди — на экране это
    выглядит как «кусок кожи поднимается».

    Правильное решение — переделать топологию (сделать впадину). Здесь
    делается дешёвое: вес плеча у вершин, лежащих близко к средней линии,
    ограничивается, остаток переходит к груди. Рука тогда «уходит под кожу»
    меньше, а бок остаётся на месте.

    Возвращает новые байты буфера и отчёт.

    ВНИМАНИЕ, функция не используется. Проверка показала: между рукой и
    торсом в модели НЕТ зазора ни на одной высоте (поверхность непрерывная,
    «сварено»), поэтому любое правило вида «вершины с |X| < 0.17 — это
    туловище» захватывает саму руку. Правку пришлось отклонить.
    Правильное решение — развести руку и торс в Blender (сделать впадину)
    или поднять локоть выше и не задирать плечо.
    """
    import numpy as np

    meshes = [m for m in gltf.get("meshes", []) if m.get("name") == "female_body"]
    if not meshes:
        return binary, {"changed": 0, "note": "тело не найдено"}
    prim = meshes[0]["primitives"][0]
    attrs = prim["attributes"]
    if "JOINTS_0" not in attrs or "WEIGHTS_0" not in attrs:
        return binary, {"changed": 0, "note": "нет скиннинга"}

    joints = gltf["skins"][0]["joints"]
    names = [gltf["nodes"][j].get("name") for j in joints]
    if "upper_arm.L" not in names or "chest" not in names:
        return binary, {"changed": 0, "note": "не те кости"}

    buf = bytearray(binary)

    # componentType важен: JOINTS_0 хранится как uint16, а WEIGHTS_0 — float32.
    # Первая версия читала всё как float32 и получала мусор вместо индексов.
    DTYPES = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}

    def view(acc_index: int):
        acc = gltf["accessors"][acc_index]
        bv = gltf["bufferViews"][acc["bufferView"]]
        nc = {"VEC3": 3, "VEC4": 4, "VEC2": 2, "SCALAR": 1}[acc["type"]]
        start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        dt = DTYPES[acc["componentType"]]
        arr = np.frombuffer(bytes(buf), dtype=dt,
                            count=acc["count"] * nc, offset=start).reshape(acc["count"], nc)
        return arr.copy(), start, acc, nc

    pos, _, _, _ = view(attrs["POSITION"])
    jnt_raw, j_start, j_acc, _ = view(attrs["JOINTS_0"])
    wgt, w_start, w_acc, _ = view(attrs["WEIGHTS_0"])
    jnt = jnt_raw.astype(np.uint16)

    li = names.index("upper_arm.L")
    ri = names.index("upper_arm.R")
    ci = names.index("chest")
    LIMIT = 0.45          # сколько веса плеча разрешено у бока туловища
    changed = 0

    for v in range(len(pos)):
        x, y = pos[v, 0], pos[v, 1]
        if abs(x) > 0.17 or y < 1.10 or y > 1.42:
            continue
        arm = li if x > 0 else ri
        for k in range(4):
            if jnt[v, k] == arm and wgt[v, k] > LIMIT:
                excess = wgt[v, k] - LIMIT
                wgt[v, k] = LIMIT
                # остаток — груди; если места у груди нет, добавляем в нулевой слот
                put = False
                for k2 in range(4):
                    if jnt[v, k2] == ci:
                        wgt[v, k2] += excess
                        put = True
                        break
                if not put:
                    for k2 in range(4):
                        if wgt[v, k2] == 0.0:
                            jnt[v, k2] = ci
                            wgt[v, k2] = excess
                            put = True
                            break
                if not put:
                    wgt[v, k] += excess   # некуда — оставляем как было
                changed += 1
                break

    # нормализация
    total = wgt.sum(axis=1, keepdims=True)
    total[total == 0] = 1.0
    wgt /= total

    buf[w_start:w_start + wgt.size * 4] = wgt.astype(np.float32).tobytes()
    jdt = DTYPES[j_acc["componentType"]]
    buf[j_start:j_start + jnt.size * np.dtype(jdt).itemsize] = \
        jnt.astype(jdt).tobytes()
    return bytes(buf), {"changed": changed, "limit": LIMIT}


def strip(gltf: dict) -> dict:
    report = {"animations": 0, "morph_targets": 0, "morph_names": 0}

    # 1) анимации целиком: все три клипа двигают только веса морфов
    report["animations"] = len(gltf.pop("animations", []))

    # 2) морф-таргеты у всех примитивов
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            targets = prim.pop("targets", None)
            if targets:
                report["morph_targets"] += len(targets)
        if "weights" in mesh:
            del mesh["weights"]
        extras = mesh.get("extras")
        if isinstance(extras, dict) and "targetNames" in extras:
            del extras["targetNames"]
            report["morph_names"] += 1
            if not extras:
                del mesh["extras"]

    # 3) защита: если на узел ссылается морфовое имя, оно уже не нужно
    for node in gltf.get("nodes", []):
        node.pop("weights", None)

    return report


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    gltf, binary = read_glb(src)
    report = strip(gltf)
    # fix_armpit_weights НЕ вызывается: геометрия модели не даёт отделить
    # бок туловища от руки (зазора между ними нет), поэтому любое правило
    # по координатам режет живую руку. Нужна переделка топологии в Blender.
    write_glb(dst, gltf, binary)
    print(f"убрано: анимаций {report['animations']}, "
          f"морф-таргетов {report['morph_targets']}")
    print(f"записано: {dst} ({dst.stat().st_size / 1024 / 1024:.2f} МБ)")


if __name__ == "__main__":
    main()
