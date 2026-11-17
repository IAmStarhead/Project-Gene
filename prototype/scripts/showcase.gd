## ВИТРИНА: отдельная сцена, чтобы отрабатывать анимации до добавления в игру.
##
## Зачем она нужна. В игре на позу смотришь с одной камеры, за спиной
## персонажа, в бою, где всё мелькает. Оценить, правильно ли движется локоть
## или как выглядит удар в профиль, там невозможно — и мы раз за разом
## спорили о позах по одному кадру из-за спины.
##
## Здесь: одна героиня, нейтральный серый фон (не белая стена — на белом
## не видно силуэта), камера вращается мышью, и главное — СПИСОК ПОЗ,
## которые можно листать клавишами и смотреть с любого ракурса.
##
## Управление:
##   мышь          — вращать камеру
##   колесо        — приблизить / отдалить
##   1 … 9, 0      — выбрать позу (список ниже)
##   ← →           — листать позы
##   Пробел        — проиграть анимацию удара целиком (замах → удар → возврат)
##   L             — листать скорость проигрывания (0.25x / 0.5x / 1x)
##   G             — селлшейдинг вкл/выкл
##   R             — сбросить камеру
extends Node3D

const T := preload("res://scripts/tuning.gd")
const CharacterScript := preload("res://scripts/character_anim.gd")
const BuildScene := preload("res://scripts/build_scene.gd")

## Позы витрины. Значения — те же углы, что в character_anim.gd: это одна и
## та же система координат, поэтому подобранное здесь переносится в игру
## один в один, без пересчёта.
var poses: Array = [
	{"name": "покой (стойка)", "spec": {}},
	{"name": "замах правой", "spec": {
		"upper_arm.R": Vector3(14.0, 20.0, -18.0), "forearm.R": Vector3(150.0, 0.0, 0.0),
		"hand.R": Vector3(0.0, 0.0, -6.0), "chest": Vector3(4.0, -16.0, 0.0),
		"spine": Vector3(2.0, -7.0, 0.0), "head": Vector3(0.0, 11.0, 0.0),
		"upper_arm.L": Vector3(10.0, 0.0, 16.0), "forearm.L": Vector3(112.0, 0.0, 0.0)}},
	{"name": "удар правой", "spec": {
		"upper_arm.R": Vector3(72.0, 20.0, -12.0), "forearm.R": Vector3(20.0, 0.0, 0.0),
		"hand.R": Vector3(0.0, 0.0, -4.0), "chest": Vector3(6.0, 16.0, 0.0),
		"spine": Vector3(4.0, 8.0, 0.0), "head": Vector3(0.0, -9.0, 0.0),
		"upper_arm.L": Vector3(14.0, 0.0, -12.0), "forearm.L": Vector3(108.0, 0.0, 0.0)}},
	{"name": "удар левой", "spec": {
		"upper_arm.L": Vector3(72.0, 20.0, 12.0), "forearm.L": Vector3(20.0, 0.0, 0.0),
		"hand.L": Vector3(0.0, 0.0, 4.0), "chest": Vector3(6.0, -16.0, 0.0),
		"spine": Vector3(4.0, -8.0, 0.0), "head": Vector3(0.0, 9.0, 0.0),
		"upper_arm.R": Vector3(14.0, 0.0, 12.0), "forearm.R": Vector3(108.0, 0.0, 0.0)}},
	{"name": "шаг (фаза 1)", "spec": {
		"thigh.L": Vector3(24.0, 0.0, 0.0), "thigh.R": Vector3(-18.0, 0.0, 0.0),
		"shin.L": Vector3(-10.0, 0.0, 0.0), "shin.R": Vector3(-34.0, 0.0, 0.0),
		"upper_arm.L": Vector3(-14.0, 0.0, -5.0), "upper_arm.R": Vector3(14.0, 0.0, 5.0)}},
	{"name": "бег (наклон)", "spec": {
		"spine": Vector3(9.0, 0.0, 0.0), "chest": Vector3(6.0, 0.0, 0.0),
		"thigh.L": Vector3(30.0, 0.0, 0.0), "thigh.R": Vector3(-22.0, 0.0, 0.0),
		"shin.L": Vector3(-12.0, 0.0, 0.0), "shin.R": Vector3(-42.0, 0.0, 0.0),
		"upper_arm.L": Vector3(-20.0, 0.0, -5.0), "upper_arm.R": Vector3(20.0, 0.0, 5.0)}},
	{"name": "уворот (присед)", "spec": {
		"thigh.L": Vector3(50.0, 0.0, 3.0), "thigh.R": Vector3(44.0, 0.0, -3.0),
		"shin.L": Vector3(-70.0, 0.0, 0.0), "shin.R": Vector3(-64.0, 0.0, 0.0),
		"foot.L": Vector3(20.0, 0.0, 0.0), "foot.R": Vector3(18.0, 0.0, 0.0),
		"spine": Vector3(26.0, 0.0, 0.0), "chest": Vector3(8.0, 0.0, 0.0),
		"head": Vector3(-20.0, 0.0, 0.0),
		"upper_arm.L": Vector3(26.0, 0.0, -10.0), "upper_arm.R": Vector3(26.0, 0.0, 10.0),
		"forearm.L": Vector3(60.0, 0.0, 0.0), "forearm.R": Vector3(60.0, 0.0, 0.0)}},
	{"name": "полёт (прыжок)", "spec": {
		"thigh.L": Vector3(26.0, 0.0, 2.0), "thigh.R": Vector3(-14.0, 0.0, -2.0),
		"shin.L": Vector3(-42.0, 0.0, 0.0), "shin.R": Vector3(-18.0, 0.0, 0.0),
		"foot.L": Vector3(16.0, 0.0, 0.0), "foot.R": Vector3(10.0, 0.0, 0.0),
		"upper_arm.L": Vector3(20.0, 0.0, 20.0), "upper_arm.R": Vector3(20.0, 0.0, -20.0),
		"forearm.L": Vector3(110.0, 0.0, 0.0), "forearm.R": Vector3(110.0, 0.0, 0.0),
		"hand.L": Vector3(0.0, 0.0, 8.0), "hand.R": Vector3(0.0, 0.0, -8.0),
		"spine": Vector3(8.0, 0.0, 0.0), "head": Vector3(-4.0, 0.0, 0.0)}},
	{"name": "руки вверх (проверка)", "spec": {
		"upper_arm.L": Vector3(0.0, 0.0, -95.0), "upper_arm.R": Vector3(0.0, 0.0, 95.0),
		"forearm.L": Vector3(20.0, 0.0, 0.0), "forearm.R": Vector3(20.0, 0.0, 0.0)}},
	{"name": "поворот корпуса (проверка)", "spec": {
		"chest": Vector3(0.0, 40.0, 0.0), "spine": Vector3(0.0, 20.0, 0.0),
		"head": Vector3(0.0, 25.0, 0.0)}},
]

var character: Node3D
var cam: Camera3D
var _yaw := 25.0
var _pitch := -8.0
var _dist := 3.1
var _focus := Vector3(0.0, 1.0, 0.0)
var _pose_index := 0
var _playing := false
var _play_time := 0.0
var _speed_index := 2
const SPEEDS := [0.25, 0.5, 1.0]
var _hud: Label
var _world: Node3D


func _ready() -> void:
	var room := Node3D.new()
	room.set_script(BuildScene)
	add_child(room)          # комната строит свет и пол
	_world = room
	# На витрине свет должен показывать ФОРМУ, а не стерильность лаборатории:
	# белая стена съедает силуэт. Поэтому фон темнее, а контраст выше.
	if room.has_method("showcase_lighting"):
		room.showcase_lighting()

	# Героиня стоит в центре сцены, без физики: на витрине двигать её незачем.
	character = Node3D.new()
	character.set_script(CharacterScript)
	add_child(character)

	cam = Camera3D.new()
	cam.fov = 42.0
	add_child(cam)
	_make_hud()
	if T.TOON_ENABLED and _world != null and _world.has_method("apply_toon"):
		_world.apply_toon(character)
	_apply_pose(0)


func _make_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(18, 14)
	_hud.add_theme_color_override("font_color", Color(0.12, 0.14, 0.18))
	_hud.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.85))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(_hud)


func _apply_pose(index: int) -> void:
	_pose_index = posmod(index, poses.size())
	_playing = false
	_play_time = 0.0
	var spec: Dictionary = poses[_pose_index]["spec"]
	# Поза ставится напрямую, без сглаживания: на витрине нужен точный кадр.
	if character.has_method("set_pose_direct"):
		character.set_pose_direct(spec)


func _process(delta: float) -> void:
	if _playing:
		_play_time += delta * SPEEDS[_speed_index]
		var total: float = T.ATTACK_WINDUP + T.ATTACK_ACTIVE + T.ATTACK_RECOVERY
		if _play_time >= total:
			_playing = false
			_play_time = 0.0
			# Возврат в выбранную позу. Не update_anim(): та сглаживает позу
			# и застыла бы на середине перехода, потому что покадрового
			# вызова после этого нет.
			_apply_pose(_pose_index)
		else:
			character.update_anim(delta, 0.0, "attack", _play_time, "R")
	elif _pose_index == 0:
		# на позе «стойка» покачивание живое, на остальных стоит точный кадр
		character.update_anim(delta, 0.0, "", 0.0)

	# Орбита вокруг точки _focus: рыскание вокруг вертикали, наклон подъёмом.
	var b := Basis(Vector3.UP, deg_to_rad(_yaw)) * Basis(Vector3.RIGHT, deg_to_rad(_pitch))
	cam.global_position = _focus + b * Vector3(0.0, 0.0, _dist)
	cam.look_at(_focus, Vector3.UP)
	_update_hud()


func _update_hud() -> void:
	var lines := [
		"ВИТРИНА — отработка анимаций",
		"поза %d/%d: %s" % [_pose_index + 1, poses.size(), poses[_pose_index]["name"]],
		"скорость: %.2fx   селлшейдинг: %s   свет: %s" % [SPEEDS[_speed_index], "вкл" if T.TOON_ENABLED else "выкл", T.BRIGHTNESS_NAMES[clampi(T.BRIGHTNESS, 0, 2)]],
		"",
		"1…0 поза · ← → листать · Пробел — проиграть удар",
		"L скорость · G селлшейдинг · B яркость · R камера · Esc/H — в игру",
		"мышь — вращать",
	]
	_hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_yaw -= event.relative.x * 0.4
		_pitch = clampf(_pitch - event.relative.y * 0.3, -70.0, 40.0)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(1.2, _dist - 0.2)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(6.0, _dist + 0.2)
	elif event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.keycode
		if k >= KEY_1 and k <= KEY_9:
			_apply_pose(k - KEY_1)
		elif k == KEY_0:
			_apply_pose(9)
		elif k == KEY_LEFT:
			_apply_pose(_pose_index - 1)
		elif k == KEY_RIGHT:
			_apply_pose(_pose_index + 1)
		elif k == KEY_SPACE:
			_playing = true
			_play_time = 0.0
		elif k == KEY_L:
			_speed_index = (_speed_index + 1) % SPEEDS.size()
		elif k == KEY_ESCAPE or k == KEY_H:
			get_tree().change_scene_to_file("res://scenes/main.tscn")
		elif k == KEY_R:
			_yaw = 25.0
			_pitch = -8.0
			_dist = 3.1
		elif k == KEY_B:
			T.BRIGHTNESS = (T.BRIGHTNESS + 1) % 3
			if _world != null and _world.has_method("rebuild_lighting"):
				_world.rebuild_lighting(T.TOON_ENABLED)
		elif k == KEY_G:
			T.TOON_ENABLED = not T.TOON_ENABLED
			if _world.has_method("rebuild_lighting"):
				_world.rebuild_lighting(T.TOON_ENABLED)
			if T.TOON_ENABLED and _world != null and _world.has_method("apply_toon"):
				_world.apply_toon(character)
			elif _world.has_method("clear_toon"):
				_world.clear_toon(character)
