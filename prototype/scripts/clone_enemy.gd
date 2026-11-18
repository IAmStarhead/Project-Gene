## Клон героини — тренировочный противник.
##
## Два режима по T: бой выключен / включён. При включении сближается,
## бьёт и отступает лицом к игроку. Подготовка длиннее, чем у героини.
##
## Модель и AnimationLibrary — те же, что у героини; scripts/clone_anim.gd
## наследует общий проигрыватель. Физика остаётся в CharacterBody3D.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")

## Два режима, а не три: пользователь просил «включение и выключение боя».
## Третий режим («следит, но не бьёт») на практике путал: непонятно, почему
## противник подошёл и не атакует.
enum Mode { OFF, ON }

const MODE_NAMES := {
	Mode.OFF: "бой ВЫКЛ",
	Mode.ON: "бой ВКЛ",
}

@onready var character: Node3D = $Character

var mode: int = Mode.OFF

var health: float = T.CLONE_HEALTH
var _attack_time: float = -1.0
var _cooldown: float = 0.0
var _recover: float = 0.0
var _flash: float = 0.0
var _player: Node3D
var _label: Label3D
var _last_deal: float = 0.0


func _ready() -> void:
	add_to_group("damageable")
	add_to_group("clone")
	_player = get_tree().get_first_node_in_group("player")
	_make_label()
	if character != null and character.has_method("reset_motion"):
		character.reset_motion(false)


func _make_label() -> void:
	# Подпись — Label3D над головой, а не Label в CanvasLayer.
	# Прошлый вариант рисовал текст в постоянной точке экрана (20, 74) и
	# наезжал на отладочный текст героини: было непонятно, чей это статус.
	# Теперь видно, к кому относится надпись, и она поворачивается к камере.
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0009
	l.font_size = 64
	l.outline_size = 20
	l.modulate = Color(0.85, 0.18, 0.22)
	l.outline_modulate = Color(0.06, 0.06, 0.08)
	l.position = Vector3(0.0, 2.05, 0.0)
	add_child(l)
	_label = l


## Переключение режима: вызывается из main.gd по клавише T.
func cycle_mode() -> void:
	mode = Mode.ON if mode == Mode.OFF else Mode.OFF
	if mode == Mode.OFF:
		velocity = Vector3.ZERO
	_attack_time = -1.0
	_recover = 0.0
	_cooldown = 0.35      # короткая пауза, чтобы не бить в ту же секунду


func mode_name() -> String:
	return MODE_NAMES.get(mode, "?")


func _physics_process(delta: float) -> void:
	var previous_position := global_position
	_cooldown = maxf(0.0, _cooldown - delta)
	_recover = maxf(0.0, _recover - delta)
	if _last_deal > 0.0:
		_last_deal = maxf(0.0, _last_deal - delta)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 3.0)

	if not is_on_floor():
		velocity.y -= T.GRAVITY * delta
	else:
		velocity.y = 0.0

	match mode:
		Mode.OFF:
			_slow_down(delta, 18.0)
		Mode.ON:
			_fight(delta)

	move_and_slide()

	# поворот к направлению движения или к игроку
	_face(delta)

	if character != null and character.has_method("update_motion"):
		var displacement := global_position - previous_position
		var planar := Vector3(displacement.x, 0.0, displacement.z)
		var local_velocity := character.global_basis.inverse() * (planar / maxf(delta, .001))
		var action := "attack" if _attack_time >= 0.0 else ""
		character.update_motion(delta, local_velocity, action, maxf(_attack_time, 0.0), "R", {
			"distance": planar.length(), "grounded": is_on_floor(),
			"vertical_speed": velocity.y, "combat": mode == Mode.ON,
			"attack_timing": Vector3(T.CLONE_WINDUP, T.CLONE_ACTIVE, T.CLONE_RECOVER),
		})

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
	var dir := _dir_to_player().normalized()
	var forward := -global_basis.z
	# Тот же прямой кулак, что у игрока: уход за спину должен быть промахом,
	# особенно после фиксации направления в момент контакта.
	if dist > T.CLONE_RANGE or dir.is_zero_approx() \
			or rad_to_deg(forward.angle_to(dir)) > T.ATTACK_ANGLE:
		_last_deal = 0.0
		return
	_last_deal = 1.4
	if is_instance_valid(_player) and _player.has_method("take_damage"):
		_player.take_damage(T.CLONE_DAMAGE, dir)


func _face(delta: float) -> void:
	var look := velocity
	if mode == Mode.ON:
		# Не доворачиваем уже вылетевший кулак вслед за целью.
		if _attack_time >= T.CLONE_WINDUP:
			return
		# При отходе сохраняем лицо к игроку: анимация шага идёт назад.
		look = _dir_to_player()
	if look.length() < 0.05 and is_instance_valid(_player):
		look = _dir_to_player()
	if look.length() < 0.05:
		return
	var want := atan2(-look.x, -look.z)
	rotation.y = lerp_angle(rotation.y, want, minf(1.0, delta * 10.0))


## Получает урон от героини.
func take_damage(amount: float, _from_dir: Vector3) -> void:
	if mode == Mode.OFF:
		return                      # выключенного не бьют: он для тестов
	health = maxf(0.0, health - amount)
	_flash = 1.0
	if character != null and character.has_method("play_hit"):
		character.play_hit()
	if health <= 0.0:
		health = T.CLONE_HEALTH
		global_position = Vector3(-3.0, 1.0, -6.0)
		mode = Mode.OFF
		_attack_time = -1.0
		_recover = 0.0
		velocity = Vector3.ZERO
		if character != null and character.has_method("reset_motion"):
			character.reset_motion(false)


func _update_label() -> void:
	if _label == null:
		return
	# Показываем и результат удара: если клон бьёт, но урона нет, видно, что
	# он промахнулся, а не что в коде дыра.
	var extra := ""
	if _last_deal > 0.0:
		extra = "   удар!"
	elif mode == Mode.ON and _attack_time < 0.0 and _cooldown > 0.0:
		extra = "   (перезаряд)"
	_label.text = "%s   %.0f/%.0f%s" % [mode_name(), health, T.CLONE_HEALTH, extra]
