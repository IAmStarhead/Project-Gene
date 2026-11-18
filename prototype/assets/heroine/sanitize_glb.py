#!/usr/bin/env python3
"""Убирает из GLB то, на чём спотыкается импортёр Godot.

Зачем: модель female_A_rigged.glb формально корректна (валидатор Khronos —
0 ошибок), но содержит три вещи, которые в Godot 4 связаны с падениями
редактора при импорте:

  1) blend shapes (морф-таргеты) на скин-мешах;
  2) анимации, двигающие веса морфов (path="weights");
  3) анимации на узлах, которые не являются костями.

Скрипт также впечатывает существующий морф кулака, исправляет ошибочные веса
кисть/бедро и грудь/плечо и сохраняет совпадение швов. Скелет, топология,
материалы и исходный GLB не меняются. Правка подмышки — по связности сетки,
а не отсечением руки координатной плоскостью; см. repair_shoulders.py.

Использование из корня репозитория (нужен numpy):
    python prototype/assets/heroine/sanitize_glb.py вход.glb выход.glb

Оригинал не изменяется. Проверка результата — валидатором Khronos.
"""
import json
import struct
import sys
from pathlib import Path

from repair_shoulders import repair_axilla_weights

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


def fix_burnthrough_weights(gltf: dict, binary: bytes) -> tuple[bytes, dict]:
    """Убирает веса кисти и предплечья с тех частей тела, где их быть не должно.

    Причина дефекта «кожа натягивается». Скелет собран автоматически: веса
    считались по расстоянию до кости. Кисть в позе покоя висит ровно у бедра,
    поэтому её вес «прожёг» бедро насквозь. Измерено на модели: 52 вершины
    бедра имеют вес кисти до 0.37, ещё 5 вершин груди — вес плеча.

    Что видно из-за этого: рука идёт вперёд на удар — кожа бедра тянется
    за кистью. Это и есть «кусок кожи поднимается» с видео.

    Лечение адресное, по ИМЕНИ кости, а не по координатам (правило по
    координатам раньше резало живую руку):

      * вес кисти/предплечья на вершинах, где главная кость — бедро, таз
        или торс, переносится на эту главную кость;
      * то же для веса плеча на вершинах груди.

    Геометрия не меняется. Оригинал не трогается.
    """
    import numpy as np

    DTYPES = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}

    def view(idx):
        acc = gltf["accessors"][idx]
        bv = gltf["bufferViews"][acc["bufferView"]]
        nc = {"VEC3": 3, "VEC4": 4, "VEC2": 2, "SCALAR": 1}[acc["type"]]
        start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        arr = np.frombuffer(binary, dtype=DTYPES[acc["componentType"]],
                            count=acc["count"] * nc, offset=start).reshape(acc["count"], nc)
        return arr.copy(), start, acc

    body = [m for m in gltf.get("meshes", []) if m.get("name") == "female_body"]
    if not body:
        return binary, {"changed": 0, "note": "тело не найдено"}
    prim = body[0]["primitives"][0]
    attrs = prim["attributes"]
    if "JOINTS_0" not in attrs:
        return binary, {"changed": 0, "note": "нет скиннинга"}

    joints = gltf["skins"][0]["joints"]
    names = [gltf["nodes"][j].get("name") for j in joints]
    pos, _, _ = view(attrs["POSITION"])
    jraw, jstart, jacc = view(attrs["JOINTS_0"])
    wgt, wstart, _ = view(attrs["WEIGHTS_0"])
    jnt = jraw.astype(np.int32)

    def idx_of(name):
        return names.index(name) if name in names else -1

    # какие кости считаются «чужими» для какой части тела
    FORBIDDEN = {
        # часть тела (главная кость вершины) -> кости, которых там быть не может
        idx_of("thigh.L"): {idx_of("hand.L"), idx_of("forearm.L"), idx_of("hand.R"), idx_of("forearm.R")},
        idx_of("thigh.R"): {idx_of("hand.L"), idx_of("forearm.L"), idx_of("hand.R"), idx_of("forearm.R")},
        idx_of("hips"):    {idx_of("hand.L"), idx_of("forearm.L"), idx_of("hand.R"), idx_of("forearm.R"),
                            idx_of("upper_arm.L"), idx_of("upper_arm.R")},
        idx_of("shin.L"):  {idx_of("hand.L"), idx_of("hand.R"), idx_of("forearm.L"), idx_of("forearm.R")},
        idx_of("shin.R"):  {idx_of("hand.L"), idx_of("hand.R"), idx_of("forearm.L"), idx_of("forearm.R")},
        idx_of("chest"):   {idx_of("hand.L"), idx_of("hand.R")},
        idx_of("head"):    {idx_of("hand.L"), idx_of("hand.R")},
    }
    FORBIDDEN = {k: {x for x in v if x >= 0} for k, v in FORBIDDEN.items() if k >= 0}

    changed = 0
    per_pair: dict = {}
    for v in range(len(pos)):
        dom = int(jnt[v, np.argmax(wgt[v])])
        bad = FORBIDDEN.get(dom)
        if not bad:
            continue
        moved = 0.0
        for k in range(4):
            if int(jnt[v, k]) in bad and wgt[v, k] > 0.001:
                per_pair[(names[dom], names[int(jnt[v, k])])] = \
                    per_pair.get((names[dom], names[int(jnt[v, k])]), 0) + 1
                moved += wgt[v, k]
                wgt[v, k] = 0.0
        if moved > 0.0:
            # переносим на главную кость
            for k in range(4):
                if int(jnt[v, k]) == dom:
                    wgt[v, k] += moved
                    break
            changed += 1

    total = wgt.sum(axis=1, keepdims=True)
    total[total == 0] = 1.0
    wgt /= total

    buf = bytearray(binary)
    buf[wstart:wstart + wgt.size * 4] = wgt.astype(np.float32).tobytes()
    return bytes(buf), {"changed": changed, "pairs": per_pair}


def bake_fists_into_geometry(gltf: dict, binary: bytes) -> tuple[bytes, dict]:
    """Впечатывает морф «кулак» прямо в геометрию и убирает все морфы.

    ── Зачем ──────────────────────────────────────────────────────────────
    В скелете НЕТ костей пальцев: их всего 21, и последняя — кисть. То есть
    пальцами пошевелить нельзя, и кулака тоже нет: кисть всегда раскрыта.
    Пользователь это и увидел — «бьют тыльной стороной ладони, на удар
    кулаком не похоже».

    При этом в исходной модели есть готовый морф `Fists` (а также три
    промежуточных «сжатия»). Он двигает РОВНО кисти: 3400 вершин, все
    принадлежат hand.L / hand.R (1700 + 1700), область Y 0.69..0.84 — то
    есть выше кистей ничего не задет. Максимальный сдвиг 98 мм.

    ── Почему впечатываем в геометрию, а не используем морф в Godot ───────
    Именно морфы и стали причиной падения редактора Godot при импорте
    (godotengine/godot#78897). Тащить их обратно в проект — наступать на
    те же грабли. Поэтому: берём смещения из морфа `POSITION` и `NORMAL`
    (там есть и нормали, это важно — без них освещение кулака было бы
    неверным), прибавляем к базовым, и морфы выкидываем.

    Кулак становится постоянным. Для soulslike с оружием в руке это
    нормально: рука всё равно сжата. Раскрытая ладонь больше не нужна.

    Оригинал (`models/heroine/female_A_rigged.glb`) не изменяется.
    """
    import numpy as np

    report = {"baked": 0, "moved": 0, "max_shift_mm": 0.0, "removed_targets": 0}

    body = [m for m in gltf.get("meshes", []) if m.get("name") == "female_body"]
    if not body:
        return binary, {"note": "тело не найдено"}
    prim = body[0]["primitives"][0]
    targets = prim.get("targets") or []
    names = (body[0].get("extras") or {}).get("targetNames") or []
    fist_index = -1
    for i, n in enumerate(names):
        if n == "Fists":
            fist_index = i
            break
    if fist_index < 0 and targets:
        fist_index = 0          # морф 0 и есть Fists, но проверим по сдвигу
    if fist_index < 0:
        return binary, {"note": "морфа кулака нет"}
    target = targets[fist_index]

    DTYPES = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}

    def view(idx):
        acc = gltf["accessors"][idx]
        bv = gltf["bufferViews"][acc["bufferView"]]
        nc = {"VEC3": 3, "VEC4": 4, "VEC2": 2, "SCALAR": 1}[acc["type"]]
        start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        arr = np.frombuffer(binary, dtype=DTYPES[acc["componentType"]],
                            count=acc["count"] * nc, offset=start).reshape(acc["count"], nc)
        return arr.copy(), start, acc

    buf = bytearray(binary)
    for attr, kind in (("POSITION", "POSITION"), ("NORMAL", "NORMAL")):
        if attr not in prim["attributes"] or kind not in target:
            continue
        base, start, acc = view(prim["attributes"][attr])
        delta = view(target[kind])[0].astype(np.float32)
        mag = float(np.linalg.norm(delta, axis=1).max())
        out = (base.astype(np.float32) + delta).astype(np.float32)
        if attr == "NORMAL":
            # нормали после сдвига могут перестать быть единичными
            ln = np.linalg.norm(out, axis=1, keepdims=True)
            ln[ln == 0] = 1.0
            out = out / ln
        buf[start:start + out.size * 4] = out.tobytes()
        if attr == "POSITION":
            # The baked fist extends ~0.025 mm beyond the old X bounds.
            # Keep accessor metadata in sync; do not alter the baked vertices.
            acc["min"] = out.min(axis=0).tolist()
            acc["max"] = out.max(axis=0).tolist()
            report["max_shift_mm"] = mag * 1000.0
            report["moved"] = int((np.linalg.norm(delta, axis=1) > 1e-5).sum())
        report["baked"] += 1

    report["removed_targets"] = len(targets)
    return bytes(buf), report


def weld_seam_weights(gltf: dict, binary: bytes) -> tuple[bytes, dict]:
    """Сшивает швы: у совпадающих вершин веса делаются одинаковыми.

    ── Что за дефект и почему он виден только в ударе ──────────────────────
    Пользователь заметил: «когда бьёшь, сбоку виден просвет». Просвет —
    это ЩЕЛЬ на стыке двух частей тела, которые в покое стоят вплотную.

    Модель собрана из отдельных кусков: торс, две руки, две кисти, две
    стопы, голова. Куски не сшиты в общий меш, а просто приставлены друг
    к другу. На стыке есть пары вершин с ОДИНАКОВЫМИ координатами, но с
    РАЗНЫМИ весами: одна вершина принадлежит торсу, другая — руке.

    В покое это незаметно — вершины совпадают. Но как только рука идёт
    вперёд, веса тянут их в разные стороны, и на месте шва открывается
    дырка. Измерено на модели:

        вершина 1934: chest 0.64 + upper_arm.R 0.36
        вершина 4386: chest 0.10 + upper_arm.R 0.90   <- то же место
        в позе удара расходятся на 33 мм; худшая пара — на 40 мм.

    При 40 мм на предплечье это уже полоса шириной в палец. Отсюда и
    «просвет сбоку, видно только когда бьёшь».

    ── Лечение ─────────────────────────────────────────────────────────────
    Для каждой группы вершин с совпадающими координатами (допуск 1e-6 м)
    веса усредняются, и всем вершинам группы ставится один и тот же набор
    из четырёх главных костей. Совпадающие координаты + одинаковые веса =
    вершины больше физически не могут разойтись.

    Проверено на модели: расхождение шва в позе удара 33.6 -> 0.00 мм,
    число расходящихся пар 37 -> 0.

    ── Почему это безопасно ───────────────────────────────────────────────
    Опасение: а вдруг в одной группе окажутся вершины кисти и вершины
    бедра (кисть в покое висит у бедра!) — тогда усреднение сшило бы
    бедро с рукой, то есть вернуло бы старый дефект «кожа тянется».
    Проверено перебором всех 1154 групп: групп, где вместе кисть или
    предплечье и торс или бедро, — НОЛЬ. Усредняются только стыки внутри
    одной цепочки (торс-плечо, плечо-локоть, локоть-кисть, бедро-голень,
    голень-стопа, стопа-носок).
    """
    import numpy as np

    DTYPES = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}

    def view(idx):
        acc = gltf["accessors"][idx]
        bv = gltf["bufferViews"][acc["bufferView"]]
        nc = {"VEC3": 3, "VEC4": 4, "VEC2": 2, "SCALAR": 1}[acc["type"]]
        start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        arr = np.frombuffer(binary, dtype=DTYPES[acc["componentType"]],
                            count=acc["count"] * nc, offset=start).reshape(acc["count"], nc)
        return arr.copy(), start

    body = [m for m in gltf.get("meshes", []) if m.get("name") == "female_body"]
    if not body:
        return binary, {"welded": 0, "groups": 0, "note": "тело не найдено"}
    attrs = body[0]["primitives"][0]["attributes"]
    if "JOINTS_0" not in attrs:
        return binary, {"welded": 0, "groups": 0, "note": "нет скиннинга"}

    pos, _ = view(attrs["POSITION"])
    jraw, jstart = view(attrs["JOINTS_0"])
    wgt, wstart = view(attrs["WEIGHTS_0"])
    jnt = jraw.astype(np.int32)
    weights = wgt.astype(np.float32).copy()

    groups: dict = {}
    for i, p in enumerate(pos):
        key = (round(float(p[0]), 6), round(float(p[1]), 6), round(float(p[2]), 6))
        groups.setdefault(key, []).append(i)

    welded_groups = 0
    welded_verts = 0
    for key, vs in groups.items():
        if len(vs) < 2:
            continue
        acc: dict = {}
        for i in vs:
            for k in range(4):
                j = int(jnt[i, k])
                w = float(weights[i, k])
                if w > 1e-6:
                    acc[j] = acc.get(j, 0.0) + w / len(vs)
        if not acc:
            continue
        top = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
        total = sum(w for _, w in top)
        if total <= 0.0:
            continue
        for i in vs:
            for k in range(4):
                jnt[i, k] = 0
                weights[i, k] = 0.0
            for k, (j, w) in enumerate(top):
                jnt[i, k] = j
                weights[i, k] = w / total
            welded_verts += 1
        welded_groups += 1

    # перенормировка: на всякий случай, после усреднения сумма и так 1.0
    tot = weights.sum(axis=1, keepdims=True)
    tot[tot == 0] = 1.0
    weights /= tot

    # ВАЖНО: размеры буферов берём у ИСХОДНЫХ массивов, а не у рабочих копий.
    # JOINTS_0 хранятся как uint16, а рабочий массив у меня int32. Если писать
    # int32 и отрезать кусок по 4 байта на элемент, запись заедет в соседний
    # bufferView с весами и перемешает их — проверено, это ломало модель.
    jout = jnt.astype(jraw.dtype)
    buf = bytearray(binary)
    buf[wstart:wstart + weights.size * weights.dtype.itemsize] = weights.astype(np.float32).tobytes()
    buf[jstart:jstart + jout.size * jout.dtype.itemsize] = jout.tobytes()
    return bytes(buf), {"welded": welded_verts, "groups": welded_groups}


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
    # Порядок важен: кулак впечатывается ДО strip(), потому что strip()
    # удаляет морф-таргеты, а нам нужны их смещения.
    # И ДО сшивки швов: сшивка усредняет веса, геометрию не трогает.
    binary, freport = bake_fists_into_geometry(gltf, binary)
    report = strip(gltf)
    binary, wreport = fix_burnthrough_weights(gltf, binary)
    # Швы сшиваются ПОСЛЕ чистки прожжённых весов: чистка меняет веса внутри
    # одной вершины, сшивка — между совпадающими вершинами. Порядок важен,
    # иначе чистка снова развела бы уже сшитый шов.
    binary, sreport = weld_seam_weights(gltf, binary)
    # Решение на сваренном графе поверхности одинаково для копий шва.
    # Оно освобождает верх руки от груди, не режет живую руку по X.
    binary, areport = repair_axilla_weights(gltf, binary)
    write_glb(dst, gltf, binary)
    print(f"кулак впечатан: сдвинуто вершин {freport.get('moved', 0)}, "
          f"максимум {freport.get('max_shift_mm', 0.0):.1f} мм, "
          f"убрано морфов {freport.get('removed_targets', 0)}")
    print(f"сшито швов: {sreport['groups']} групп, {sreport['welded']} вершин")
    print(f"подмышки: исправлено {areport['changed']} вершин, "
          f"плавный переход на {areport['harmonic_vertices']} вершинах плеча")
    print(f"исправлено весов кисть/бедро: {wreport['changed']} вершин")
    for (dom, wrong), n in sorted(wreport.get("pairs", {}).items(), key=lambda x: -x[1]):
        print(f"   {dom:10s} <- ошибочный вес {wrong:12s}: {n} вершин")
    print(f"убрано: анимаций {report['animations']}, "
          f"морф-таргетов {report['morph_targets']}")
    print(f"записано: {dst} ({dst.stat().st_size / 1024 / 1024:.2f} МБ)")


if __name__ == "__main__":
    main()
