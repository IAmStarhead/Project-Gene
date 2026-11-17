## Процедурная анимация героини.
##
## В файле female_A_rigged_safe.glb есть скелет из 21 кости, но НЕТ клипов
## ходьбы, бега, удара и уворота — их никто не делал, а взять негде. Поэтому
## поза считается кодом: углы задаются формулами от скорости, фазы шага и
## текущего действия.
##
## ── Главное правило, на котором всё держится ──────────────────────────────
## В Godot поза кости — это ПОЛНЫЙ поворот кости относительно родителя, а не
## добавка к позе покоя. Документация Skeleton3D: «Bone rest defines the
## initial transform of the bone pose».
##
## Поэтому «повернуть кость на 30° вокруг её оси X» в терминах Godot значит
## не «поставить поворот 30°», а «взять поворот покоя и домножить на 30°»:
##
##     pose = rest * bend          (bend — изгиб в осях покоя кости)
##     поставить(pose)
##
## Если поставить просто bend, кость потеряет наклон покоя и скелет
## складывается сам в себя. Именно это и произошло в первой версии.
##
## ── Оси и знаки ───────────────────────────────────────────────────────────
## Проверено расчётом по матрицам покоя модели:
##   бедро, голень, стопа, предплечье: поворот вокруг локальной X качает
##     конечность вперёд-назад. Для ГОЛЕНИ плюс — это переразгибание,
##     поэтому колено всегда сгибается отрицательным углом.
##   плечо: вокруг X — мах вперёд-назад, вокруг Z — отведение в сторону
##     (у правой руки знак Z противоположен левой).
##   предплечье: плюс вокруг X — локоть сгибается вперёд, кисть идёт вперёд.

extends Node3D

const T := preload("res://scripts/tuning.gd")

## Версия модели без blend shapes и без анимаций: на исходной редактор Godot
## падал при импорте. Геометрия, скелет и веса в ней те же.
const MODEL_PATH := "res://assets/heroine/female_A_rigged_safe.glb"

var skeleton: Skeleton3D

var _idx: Dictionary = {}       ## имя кости -> индекс в скелете
var _rest_rot: Dictionary = {}  ## имя кости -> поворот покоя
var _rest_pos: Dictionary = {}  ## имя кости -> положение покоя
var _bend: Dictionary = {}      ## имя кости -> сглаженный изгиб, градусы

var _fallback: Node3D
var _loaded := false
var _clock := 0.0
var _phase := 0.0


func _ready() -> void:
	_fallback = get_node_or_null("Fallback")
	if not load_character(MODEL_PATH):
		push_warning("Модель героини не загрузилась — остаётся заглушка-капсула")


## Загружает .glb и находит скелет. Возвращает false, если не вышло.
func load_character(path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var packed: Resource = load(path)
	if packed == null or not (packed is PackedScene):
		return false
	var inst: Node = (packed as PackedScene).instantiate()
	add_child(inst)

	skeleton = _find_skeleton(inst)
	if skeleton == null:
		inst.queue_free()
		return false

	for i in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(i)
		var rest: Transform3D = skeleton.get_bone_rest(i)
		_idx[name] = i
		_rest_rot[name] = rest.basis.get_rotation_quaternion()
		_rest_pos[name] = rest.origin
		_bend[name] = Vector3.ZERO

	if _fallback:
		_fallback.visible = false
	_loaded = true
	return true


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


## Вызывается каждый кадр из player.gd.
## speed_ratio — доля от скорости бега (0..1), action — "" | "attack" | "dodge".
func update_anim(delta: float, speed_ratio: float, action: String, action_time: float) -> void:
	_clock += delta
	if not _loaded:
		return

	var want: Dictionary = {}      # имя кости -> изгиб в градусах
	var hip_offset := Vector3.ZERO
	var w := clampf(speed_ratio, 0.0, 1.2)

	# ───────────────────────────────────────── покой: живая стойка
	# Руки чуть согнуты в локте и отведены от тела. Если поставить углы в ноль,
	# модель встаёт «парализованной»: руки висят вдоль туловища как палки.
	# Лёгкое покачивание в противофазе делает стойку живой.
	_breathe(want, 1.0)
	var idle_sway := sin(_clock * 1.15) * 2.2
	want["upper_arm.L"] = Vector3(4.0 + idle_sway, 0.0, -11.0)
	want["upper_arm.R"] = Vector3(4.0 - idle_sway, 0.0, 11.0)
	want["forearm.L"] = Vector3(26.0, 0.0, 0.0)
	want["forearm.R"] = Vector3(26.0, 0.0, 0.0)
	# кисти чуть внутрь — чтобы руки не торчали в стороны
	want["hand.L"] = Vector3(0.0, 0.0, 4.0)
	want["hand.R"] = Vector3(0.0, 0.0, -4.0)

	# ───────────────────────────────────────── шаг и бег
	_phase = fmod(_phase + delta * (2.6 + 6.0 * w), TAU)
	if w > 0.02:
		_walk(want, w)

	# ───────────────────────────────────────── удар
	if action == "attack":
		_attack(want, action_time)
	# ───────────────────────────────────────── уворот
	elif action == "dodge":
		hip_offset = _dodge(want, action_time)

	_apply(want, hip_offset, delta)


## Дыхание: еле заметное покачивание корпуса, чтобы модель не была статуей.
func _breathe(want: Dictionary, weight: float) -> void:
	var b := sin(_clock * 1.6) * 1.1 * weight
	want["chest"] = Vector3(b, 0.0, 0.0)
	want["head"] = Vector3(-b * 0.5, 0.0, 0.0)
	want["spine"] = Vector3(2.0, 0.0, 0.0)


## Шаг и бег. w — доля скорости: 0 стоит, 1 бежит на полную.
func _walk(want: Dictionary, w: float) -> void:
	var s := sin(_phase)
	var hip_swing := 15.0 * w        # бедро: вперёд-назад
	var knee := 8.0 + 26.0 * w       # колено гнётся ТОЛЬКО назад, поэтому минус
	var arm := 14.0 * w              # руки качаются в противофазе

	# ноги
	want["thigh.L"] = Vector3(hip_swing * s, 0.0, 0.0)
	want["thigh.R"] = Vector3(-hip_swing * s, 0.0, 0.0)

	# Колено подгибается, когда нога идёт назад-вверх (перенос).
	var bend_l := maxf(0.0, -s)
	var bend_r := maxf(0.0, s)
	want["shin.L"] = Vector3(-knee * bend_l, 0.0, 0.0)
	want["shin.R"] = Vector3(-knee * bend_r, 0.0, 0.0)

	# Стопа добирает часть подъёма, чтобы не «шаркать» носком.
	want["foot.L"] = Vector3(knee * bend_l * 0.30, 0.0, 0.0)
	want["foot.R"] = Vector3(knee * bend_r * 0.30, 0.0, 0.0)

	# руки: левая вперёд, когда правая нога впереди
	want["upper_arm.L"] = Vector3(arm * s, 0.0, -5.0)
	want["upper_arm.R"] = Vector3(-arm * s, 0.0, 5.0)
	want["forearm.L"] = Vector3(28.0 + 12.0 * w, 0.0, 0.0)
	want["forearm.R"] = Vector3(28.0 + 12.0 * w, 0.0, 0.0)

	# корпус: наклон вперёд на бегу, легкое покачивание плеч
	want["spine"] = Vector3(2.0 + 7.0 * w, 0.0, 0.0)
	want["chest"] = Vector3(3.0 + 3.0 * w, -4.0 * w * s, 0.0)
	want["hips"] = Vector3(0.0, 4.0 * w * s, 0.0)
	want["head"] = Vector3(-5.0 * w, 2.0 * w * s, 0.0)


## Удар правой рукой: замах, удар, возврат.
##
## Почему углы именно такие. В первой версии рука уходила махом через грудь
## на левую сторону. На модели это давало два видимых дефекта, которые
## пользователь и заметил:
##   1) кисть проходила СКВОЗЬ торс;
##   2) вершины груди, часть веса которых принадлежит плечу, тянулись за
##      рукой — «кусок кожи поднимался».
## Поэтому плечо отведено в СТОРОНУ (ось Z) и держится снаружи корпуса,
## а удар идёт вперёд (ось X), не пересекая среднюю линию тела.
func _attack(want: Dictionary, t: float) -> void:
	var windup := T.ATTACK_WINDUP
	var active_end := windup + T.ATTACK_ACTIVE
	var total := active_end + T.ATTACK_RECOVERY

	# Плечо R: отведение в сторону = ОТРИЦАТЕЛЬНЫЙ Z (проверено расчётом:
	# при z=-35 кисть уходит на X≈-0.45, то есть наружу от корпуса).
	var pose_back := {
		"upper_arm.R": Vector3(-62.0, 0.0, -32.0),
		"forearm.R": Vector3(102.0, 0.0, 0.0),
		"hand.R": Vector3(0.0, 0.0, -6.0),
		"chest": Vector3(4.0, -16.0, 0.0),
		"spine": Vector3(2.0, -7.0, 0.0),
		"head": Vector3(0.0, 12.0, 0.0),
	}
	var pose_hit := {
		"upper_arm.R": Vector3(70.0, 0.0, -14.0),
		"forearm.R": Vector3(34.0, 0.0, 0.0),
		"hand.R": Vector3(0.0, 0.0, -4.0),
		"chest": Vector3(6.0, 18.0, 0.0),
		"spine": Vector3(4.0, 8.0, 0.0),
		"head": Vector3(0.0, -10.0, 0.0),
		"upper_arm.L": Vector3(14.0, 0.0, -12.0),
	}

	if t < windup:
		_mix(want, pose_back, smoothstep(0.0, 1.0, t / windup))
	elif t < active_end:
		var u := smoothstep(0.0, 1.0, (t - windup) / T.ATTACK_ACTIVE)
		_mix(want, pose_back, 1.0 - u)
		_mix(want, pose_hit, u)
	elif t <= total:
		var u := smoothstep(0.0, 1.0, (t - active_end) / T.ATTACK_RECOVERY)
		_mix(want, pose_hit, 1.0 - u)


## Уворот: присед, подбор ног, наклон корпуса. Возвращает смещение таза.
func _dodge(want: Dictionary, t: float) -> Vector3:
	var u := clampf(t / T.DODGE_DURATION, 0.0, 1.0)
	var k := sin(u * PI)   # плавно нарастает и гаснет

	_mix(want, {
		"thigh.L": Vector3(50.0, 0.0, 3.0),
		"thigh.R": Vector3(44.0, 0.0, -3.0),
		"shin.L": Vector3(-70.0, 0.0, 0.0),
		"shin.R": Vector3(-64.0, 0.0, 0.0),
		"foot.L": Vector3(20.0, 0.0, 0.0),
		"foot.R": Vector3(18.0, 0.0, 0.0),
		"spine": Vector3(26.0, 0.0, 0.0),
		"chest": Vector3(8.0, 0.0, 0.0),
		"head": Vector3(-20.0, 0.0, 0.0),
		"upper_arm.L": Vector3(26.0, 0.0, -10.0),
		"upper_arm.R": Vector3(26.0, 0.0, 10.0),
		"forearm.L": Vector3(60.0, 0.0, 0.0),
		"forearm.R": Vector3(60.0, 0.0, 0.0),
	}, k)

	return Vector3(0.0, -0.22 * k, 0.0)


## Смешивает набор углов в цель: u=0 — ничего, u=1 — полностью.
func _mix(want: Dictionary, extra: Dictionary, u: float) -> void:
	if u <= 0.0:
		return
	for bone in extra:
		var add: Vector3 = extra[bone] * u
		want[bone] = want.get(bone, Vector3.ZERO) + add


## Переводит «изгиб в градусах» в позу кости и ставит её.
func _apply(want: Dictionary, hip_offset: Vector3, delta: float) -> void:
	# Сглаживание: без него поза переключается рывком за один кадр.
	var rate := 1.0 - exp(-22.0 * delta)

	for name in _idx:
		var target: Vector3 = want.get(name, Vector3.ZERO)
		var cur: Vector3 = _bend[name]
		cur = cur.lerp(target, rate)
		_bend[name] = cur

		# Изгиб вокруг осей кости: сначала X (вперёд-назад), затем Z (в стороны),
		# затем Y (скрутка).
		var bend := Quaternion(Vector3.RIGHT, deg_to_rad(cur.x)) \
			* Quaternion(Vector3.BACK, deg_to_rad(cur.z)) \
			* Quaternion(Vector3.UP, deg_to_rad(cur.y))

		# ГЛАВНОЕ: поза = поворот покоя * изгиб. Без поворота покоя скелет
		# складывается, и руки уезжают за голову.
		skeleton.set_bone_pose_rotation(_idx[name], _rest_rot[name] * bend)

	# Таз: положение позы тоже абсолютное, поэтому смещение прибавляется
	# к положению покоя.
	if _idx.has("hips"):
		skeleton.set_bone_pose_position(_idx["hips"], _rest_pos["hips"] + hip_offset)
