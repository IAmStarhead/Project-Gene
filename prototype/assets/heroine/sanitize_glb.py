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
    write_glb(dst, gltf, binary)
    print(f"убрано: анимаций {report['animations']}, "
          f"морф-таргетов {report['morph_targets']}")
    print(f"записано: {dst} ({dst.stat().st_size / 1024 / 1024:.2f} МБ)")


if __name__ == "__main__":
    main()
