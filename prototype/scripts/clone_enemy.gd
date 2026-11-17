## Клон героини — тренировочный противник.
##
## Три режима, переключаются клавишей T (и подписью в оверлее):
##
##   СПИТ    — стоит и не реагирует. Нужен, чтобы тестировать движение,
##             камеру, прыжок, свет, не отвлекаясь на драку.
##   СЛЕДИТ  — идёт за героиней, но НЕ бьёт. Можно смотреть, как он
##             двигается и держит дистанцию.
##   БЬЁТ     — сближается и атакует. Ведёт себя как противник из соулса:
##             подходит, держит дистанцию, бьёт, отходит после удара.
##
## Почему режимы, а не сразу «агрессивный»: на этапе прототипа нужен
## противник, которого можно включить и выключить. Иначе он убивает
## тестировщика в тот момент, когда тот смотрит на текстуру.
##
## Модель — та же female_A_rigged_safe.glb, что у героини. Движение
## считается кодом (scripts/clone_anim.gd), физика — CharacterBody3D.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")

enum Mode { SLEEP, FOLLOW, FIGHT }

const MODE_NAMES := {
	Mode.SLEEP: "спит",
	Mode.FOLLOW: "следит",
	Mode.FIGHT: "бьёт",
}

@onready var character: Node3D = $Character

var mode: int = Mode.SLEEP

var health: float = T.CLONE_HEALTH
var _attack_time: float = -1.0
var _cooldown: float = 0.0
var _recover: float = 0.0
var _flash: float = 0.0
var _player: Node3D
var _label: Label


func _ready() -> void:
	add_to_group("damageable")
	add_to_group("clone")
	_player = get_tree().get_first_node_in_group("player")
	_make_label()


func _make_label() -> void:
	# подпись над головой: режим и здоровье
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(20, 74)
	_label.add_theme_color_override("font_color", Color(0.55, 0.05, 0.10))
	_label.add_theme_font_size_override("font_size", 16)
	layer.add_child(_label)


## Переключение режима: вызывается из main.gd по клавише T.
func cycle_mode() -> void:
	mode = (mode + 1) % 3
	if mode == Mode.SLEEP:
		velocity = Vector3.ZERO
	_attack_time = -1.0
	_recover = 0.0


func mode_name() -> String:
	return MODE_NAMES.get(mode, "?")


func _physics_process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	_recover = maxf(0.0, _recover - delta)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 3.0)

	if not is_on_floor():
		velocity.y -= T.GRAVITY * delta
	else:
		velocity.y = 0.0

	match mode:
		Mode.SLEEP:
			_slow_down(delta, 18.0)
		Mode.FOLLOW:
			_move_toward_player(delta, T.CLONE_KEEP_DISTANCE + 0.8, T.CLONE_WALK)
		Mode.FIGHT:
			_fight(delta)

	move_and_slide()

	# поворот к направлению движения или к игроку
	_face(delta)

	if character != null and character.has_method("update_anim"):
		var planar := Vector2(velocity.x, velocity.z).length()
		var action := ""
		var atime := 0.0
		if _attack_time >= 0.0:
			action = "attack"
			atime = _attack_time
		character.update_anim(delta, planar / T.RUN_SPEED, action, atime)

	_update_label()


func _slow_down(delta: float, rate: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, rate * delta)
	velocity.z = move_toward(velocity.z, 0.0, rate * delta)


func _dir_to_player() -> Vector3:
	if not is_instance_valid(_player):
		return Vector3.ZERO
	var d := _player.global_position - global_position
	d.y = 0.0
	return d


func _move_toward_player(delta: float, keep: float, speed: float) -> void:
	var d := _dir_to_player()
	var dist := d.length()
	if dist < 0.01:
		_slow_down(delta, 14.0)
		return
	if dist > keep:
		var want := d.normalized() * speed
		velocity.x = move_toward(velocity.x, want.x, T.CLONE_ACCEL * delta)
		velocity.z = move_toward(velocity.z, want.z, T.CLONE_ACCEL * delta)
	else:
		_slow_down(delta, 16.0)


## Боевое поведение: подойти, ударить в радиусе, отойти на восстановлении.
func _fight(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	var dist := _dir_to_player().length()

	# идёт удар — стоим на месте, урон наносится в активной фазе
	if _attack_time >= 0.0:
		_attack_time += delta
		_slow_down(delta, 26.0)
		var total := T.CLONE_WINDUP + T.CLONE_ACTIVE + T.CLONE_RECOVER
		var was_before := _attack_time - delta < T.CLONE_WINDUP
		var now_after := _attack_time >= T.CLONE_WINDUP
		if was_before and now_after:
			_deal_damage(dist)
		if _attack_time >= total:
			_attack_time = -1.0
			_cooldown = T.CLONE_COOLDOWN
			_recover = T.CLONE_RECOVER
		return

	# недавно ударил — отходит, чтобы дать игроку окно
	if _recover > 0.0:
		var away := -_dir_to_player().normalized()
		velocity.x = move_toward(velocity.x, away.x * T.CLONE_WALK, T.CLONE_ACCEL * delta)
		velocity.z = move_toward(velocity.z, away.z * T.CLONE_WALK, T.CLONE_ACCEL * delta)
		return

	# можно бить — если игрок в радиусе и откат прошёл
	if dist <= T.CLONE_RANGE and _cooldown <= 0.0:
		_attack_time = 0.0
		return

	# иначе сближается
	_move_toward_player(delta, T.CLONE_KEEP_DISTANCE, T.CLONE_RUN)


func _deal_damage(dist: float) -> void:
	if dist > T.CLONE_RANGE + 0.35:
		return
	if is_instance_valid(_player) and _player.has_method("take_damage"):
		var dir := _dir_to_player().normalized()
		_player.take_damage(T.CLONE_DAMAGE, dir)


func _face(delta: float) -> void:
	var look := velocity
	if mode == Mode.FIGHT and _attack_time >= 0.0:
		look = _dir_to_player()
	if look.length() < 0.05 and is_instance_valid(_player):
		look = _dir_to_player()
	if look.length() < 0.05:
		return
	var want := atan2(-look.x, -look.z)
	rotation.y = lerp_angle(rotation.y, want, minf(1.0, delta * 10.0))


## Получает урон от героини.
func take_damage(amount: float, _from_dir: Vector3) -> void:
	if mode == Mode.SLEEP:
		return                      # спящего не бьют: он для тестов
	health = maxf(0.0, health - amount)
	_flash = 1.0
	if health <= 0.0:
		health = T.CLONE_HEALTH
		global_position = Vector3(-3.0, 1.0, -6.0)
		mode = Mode.SLEEP


func _update_label() -> void:
	if _label == null:
		return
	_label.text = "КЛОН: %s   здоровье %.0f / %.0f   [T — переключить режим]" % [
		mode_name(), health, T.CLONE_HEALTH,
	]
