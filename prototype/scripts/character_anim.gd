## Процедурная анимация героини.
##
## В файле female_A_rigged.glb есть скелет из 21 кости, но НЕТ клипов ходьбы,
## бега, удара и уворота. Скачать их негде — модель собрана с нуля, анимаций
## к ней никто не делал. Поэтому поза считается кодом: углы поворотов костей
## задаются формулами от скорости, фазы шага и текущего действия.
##
## Плюс такого подхода: анимацию можно менять числами в tuning.gd и сразу
## чувствовать разницу. Минус: она «механическая» — настоящие клипы плавнее.
##
## Оси: у всех костей локальная Y направлена вдоль кости (вниз для рук и ног),
## поэтому поворот вокруг локальной X качает конечность вперёд-назад,
## вокруг Y — скручивает, вокруг Z — разводит в стороны.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const MODEL_PATH := "res://assets/heroine/female_A_rigged.glb"

var skeleton: Skeleton3D

var _idx: Dictionary = {}       ## имя кости -> индекс
var _smooth: Dictionary = {}    ## имя кости -> сглаженные углы, градусы
var _fallback: Node3D

var _loaded := false
var _clock := 0.0
var _phase := 0.0


func _ready() -> void:
	_fallback = get_node_or_null("Fallback")
	if not load_character(MODEL_PATH):
		push_warning("Не удалось загрузить модель героини, остаётся заглушка-капсула")


## Загружает .glb и находит в нём скелет. Возвращает false, если не вышло.
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
		_idx[name] = i
		_smooth[name] = Vector3.ZERO

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
## speed_ratio — доля от максимальной скорости бега (0..1),
## action — "" | "attack" | "dodge", action_time — сколько длится действие.
func update_anim(delta: float, speed_ratio: float, action: String, action_time: float) -> void:
	_clock += delta
	if not _loaded:
		return

	var target: Dictionary = {}
	var hip_offset := Vector3.ZERO
	var w := clampf(speed_ratio, 0.0, 1.2)

	# ─────────────────────────────────────── шаг
	# Фаза крутится тем быстрее, чем быстрее бежит персонаж.
	_phase = fmod(_phase + delta * (3.0 + 6.5 * w), TAU)

	# ─────────────────────────────────────── покой: дыхание
	var breathe := sin(_clock * 1.7) * 1.6
	target["chest"] = Vector3(breathe, 0.0, 0.0)
	target["head"] = Vector3(-breathe * 0.4, 0.0, 0.0)

	# ─────────────────────────────────────── ходьба и бег
	if w > 0.02:
		var s := sin(_phase)
		var swing := 24.0 * w          # размах бедра
		var knee := 44.0 * w           # сгиб колена
		var arm := 28.0 * w            # размах рук

		target["thigh.L"] = Vector3(swing * s, 0.0, 0.0)
		target["thigh.R"] = Vector3(-swing * s, 0.0, 0.0)

		# Колено подгибается на переносе ноги, когда она идёт вперёд.
		var bend_l := maxf(0.0, sin(_phase - 1.2))
		var bend_r := maxf(0.0, sin(_phase - 1.2 + PI))
		target["shin.L"] = Vector3(-knee * bend_l, 0.0, 0.0)
		target["shin.R"] = Vector3(-knee * bend_r, 0.0, 0.0)

		# Стопа идёт следом за голенью, но слабее.
		target["foot.L"] = Vector3(-knee * bend_l * 0.35, 0.0, 0.0)
		target["foot.R"] = Vector3(-knee * bend_r * 0.35, 0.0, 0.0)

		# Руки качаются в противофазе с одноимённой ногой.
		target["upper_arm.L"] = Vector3(-arm * s, 0.0, 6.0)
		target["upper_arm.R"] = Vector3(arm * s, 0.0, -6.0)
		var elbow := -(14.0 + 12.0 * w)
		target["forearm.L"] = Vector3(elbow, 0.0, 0.0)
		target["forearm.R"] = Vector3(elbow, 0.0, 0.0)

		# наклон корпуса вперёд на бегу + подскок
		target["spine"] = Vector3(7.0 * w, 0.0, 0.0)
		target["hips"] = Vector3(0.0, 5.0 * w * s, 0.0)
		target["chest"] = Vector3(breathe + 3.0 * w, -5.0 * w * s, 0.0)
		target["head"] = Vector3(-4.0 * w - breathe * 0.4, 2.5 * w * s, 0.0)
		hip_offset = Vector3(0.0, -0.022 * w * absf(s), 0.0)

	# ─────────────────────────────────────── удар правой рукой
	if action == "attack":
		var windup := T.ATTACK_WINDUP
		var active_end := windup + T.ATTACK_ACTIVE
		var total := active_end + T.ATTACK_RECOVERY

		if action_time < windup:
			# замах: рука уходит назад и в сторону, корпус разворачивается вправо
			var u := smoothstep(0.0, 1.0, action_time / windup)
			_blend_into(target, {
				"upper_arm.R": Vector3(-58, 0, -22),
				"forearm.R": Vector3(-100, 0, 0),
				"chest": Vector3(0, -24, 0),
				"spine": Vector3(0, -10, 0),
				"head": Vector3(0, 12, 0),
			}, u)
		elif action_time < active_end:
			# сам удар: рука проходит вперёд, корпус разворачивается влево
			var u := smoothstep(0.0, 1.0, (action_time - windup) / T.ATTACK_ACTIVE)
			_blend_into(target, {
				"upper_arm.R": Vector3(-58, 0, -22),
				"forearm.R": Vector3(-100, 0, 0),
				"chest": Vector3(0, -24, 0),
				"spine": Vector3(0, -10, 0),
				"head": Vector3(0, 12, 0),
			}, 1.0 - u)
			_blend_into(target, {
				"upper_arm.R": Vector3(82, 0, 8),
				"forearm.R": Vector3(-14, 0, 0),
				"chest": Vector3(4, 26, 0),
				"spine": Vector3(3, 10, 0),
				"head": Vector3(0, -10, 0),
				"upper_arm.L": Vector3(-24, 0, 12),
			}, u)
		else:
			# возврат в стойку
			var u := smoothstep(0.0, 1.0, (action_time - active_end) / T.ATTACK_RECOVERY)
			_blend_into(target, {
				"upper_arm.R": Vector3(82, 0, 8),
				"forearm.R": Vector3(-14, 0, 0),
				"chest": Vector3(4, 26, 0),
				"spine": Vector3(3, 10, 0),
				"head": Vector3(0, -10, 0),
				"upper_arm.L": Vector3(-24, 0, 12),
			}, 1.0 - u)

	# ─────────────────────────────────────── уворот: присед и подбор ног
	elif action == "dodge":
		var u := clampf(action_time / T.DODGE_DURATION, 0.0, 1.0)
		var k := sin(u * PI)   # 0 -> 1 -> 0: плавно нарастает и гаснет
		_blend_into(target, {
			"thigh.L": Vector3(58, 0, 4),
			"thigh.R": Vector3(52, 0, -4),
			"shin.L": Vector3(-82, 0, 0),
			"shin.R": Vector3(-76, 0, 0),
			"spine": Vector3(28, 0, 0),
			"chest": Vector3(10, 0, 0),
			"head": Vector3(-22, 0, 0),
			"upper_arm.L": Vector3(30, 0, 14),
			"upper_arm.R": Vector3(30, 0, -14),
			"forearm.L": Vector3(-70, 0, 0),
			"forearm.R": Vector3(-70, 0, 0),
		}, k)
		hip_offset = Vector3(0.0, -0.30 * k, 0.0)

	_apply(target, hip_offset, delta)


## Смешивает дополнительные углы в цель: u=0 — ничего, u=1 — полностью.
func _blend_into(target: Dictionary, extra: Dictionary, u: float) -> void:
	for bone in extra:
		var add: Vector3 = extra[bone] * u
		target[bone] = target.get(bone, Vector3.ZERO) + add


func _apply(target: Dictionary, hip_offset: Vector3, delta: float) -> void:
	# Сглаживание: без него позы переключаются рывком.
	var rate := 1.0 - exp(-26.0 * delta)

	for name in _idx:
		var want: Vector3 = target.get(name, Vector3.ZERO)
		var cur: Vector3 = _smooth[name]
		cur = cur.lerp(want, rate)
		_smooth[name] = cur

		var q := Quaternion(Vector3.RIGHT, deg_to_rad(cur.x)) \
			* Quaternion(Vector3.UP, deg_to_rad(cur.y)) \
			* Quaternion(Vector3.BACK, deg_to_rad(cur.z))
		skeleton.set_bone_pose_rotation(_idx[name], q)

	# Смещение таза вниз — присед при увороте и подскок на бегу.
	# Поза кости задаётся ОТНОСИТЕЛЬНО положения покоя, поэтому прибавлять
	# положение покоя к смещению нельзя: получится двойное смещение.
	if _idx.has("hips"):
		skeleton.set_bone_pose_position(_idx["hips"], hip_offset)
