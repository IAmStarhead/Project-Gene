## Клон героини — тренировочный противник.
##
## Два режима по клавише T:
##   • бой ВЫКЛ — стоит спокойно в центре зала (удобно проверять свет, захват цели и дистанцию);
##   • бой ВКЛ — сближается (умеет подниматься по ступенькам), наносит читаемый удар и отходит.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")
const HitCheck := preload("res://scripts/hit_check.gd")

enum Mode { OFF, ON }

const MODE_NAMES := {
	Mode.OFF: "бой ВЫКЛ",
	Mode.ON: "бой ВКЛ",
}

@onready var character: Node3D = $Character

var mode: int = Mode.OFF
var health: float = T.CLONE_HEALTH

var _spawn_pos := Vector3(0.0, 0.08, -2.2)
var _spawn_recorded := false
var _attack_time: float = -1.0
var _attack_hit_done := false
var _attack_side := "R"
var _cooldown: float = 0.0
var _recover: float = 0.0
var _flash: float = 0.0
var _player: Node3D
var _label: Label3D
var _last_label_text := ""
var _last_label_active := false
var _last_deal: float = 0.0
var _idle_awake: float = 0.8

var _step_params := PhysicsTestMotionParameters3D.new()
var _step_result := PhysicsTestMotionResult3D.new()


func _ready() -> void:
	add_to_group("damageable")
	add_to_group("clone")
	_player = get_tree().get_first_node_in_group("player") as Node3D
	_make_label()
	if character != null and character.has_method("reset_motion"):
		character.reset_motion(false)
	if character != null and character.appearance != null:
		character.appearance.set_variant(true)
	_update_label()


func _make_label() -> void:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.layers = 2
	l.no_depth_test = false
	l.fixed_size = true
	l.pixel_size = 0.00072
	l.font_size = 42
	l.outline_size = 14
	l.modulate = Color(0.92, 0.95, 1.0, 0.90)
	l.outline_modulate = Color(0.06, 0.08, 0.13, 0.92)
	l.position = Vector3(0.0, 1.98, 0.0)
	add_child(l)
	_label = l


func is_alive() -> bool:
	return health > 0.0


func is_passive() -> bool:
	return mode == Mode.OFF


func cycle_mode() -> void:
	mode = Mode.ON if mode == Mode.OFF else Mode.OFF
	if mode == Mode.OFF:
		velocity = Vector3.ZERO
	_attack_time = -1.0
	_attack_hit_done = false
	_recover = 0.0
	_cooldown = 0.35
	_idle_awake = 0.8
	_update_label()


func mode_name() -> String:
	return String(MODE_NAMES.get(mode, "?"))


func _physics_process(delta: float) -> void:
	if not _spawn_recorded:
		_spawn_pos = global_position
		_spawn_recorded = true

	var previous_position := global_position
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D

	_cooldown = maxf(0.0, _cooldown - delta)
	_recover = maxf(0.0, _recover - delta)
	if _last_deal > 0.0:
		_last_deal = maxf(0.0, _last_deal - delta)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 3.5)

	var on_floor := is_on_floor()
	if not on_floor:
		velocity.y -= T.GRAVITY * delta
	else:
		velocity.y = 0.0

	match mode:
		Mode.OFF:
			_slow_down(delta, 18.0)
		Mode.ON:
			_fight(delta)

	var stepped_up := false
	if mode == Mode.ON and _attack_time < 0.0 and on_floor:
		stepped_up = _try_step_up(delta)

	move_and_slide()
	if stepped_up:
		apply_floor_snap()

	_face(delta)

	if character != null and character.has_method("update_motion"):
		var displacement := global_position - previous_position
		var grounded_now := is_on_floor()
		var need_anim := true
		if mode == Mode.OFF and grounded_now and displacement.length_squared() < 0.000004:
			if _idle_awake > 0.0:
				_idle_awake = maxf(0.0, _idle_awake - delta)
			else:
				# Выключенный неподвижный клон не пересобирает меш ткани юбки 60 раз/с на i3-7100U.
				need_anim = false
		else:
			_idle_awake = 0.8
		if need_anim:
			var planar := Vector3(displacement.x, 0.0, displacement.z)
			var local_velocity := character.global_basis.inverse() * (planar / maxf(delta, 0.001))
			var action := "attack" if _attack_time >= 0.0 else ""
			character.update_motion(delta, local_velocity, action, maxf(_attack_time, 0.0), _attack_side, {
				"distance": planar.length(),
				"grounded": grounded_now,
				"vertical_speed": velocity.y,
				"combat": mode == Mode.ON,
				"directional": mode == Mode.ON,
				"attack_timing": Vector3(T.CLONE_WINDUP, T.CLONE_ACTIVE, T.CLONE_RECOVER),
			})

	_update_label()


func _try_step_up(delta: float) -> bool:
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	var spd := horiz.length()
	if spd < 0.2:
		return false
	var rid := get_rid()
	var probe := (horiz / spd) * maxf(spd * delta, 0.09)
	_step_params.from = global_transform
	_step_params.motion = probe
	_step_params.margin = 0.004
	_step_params.recovery_as_collision = false
	if not PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		return false
	if _step_result.get_collision_count() <= 0 or not (_step_result.get_collider(0) is StaticBody3D):
		return false
	if absf(_step_result.get_collision_normal(0).y) > 0.35:
		return false
	_step_params.from = global_transform
	_step_params.motion = Vector3.UP * T.STEP_UP
	var max_up := T.STEP_UP
	if PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		max_up = _step_result.get_travel().y
	if max_up < 0.02:
		return false
	var lifted := global_transform.translated(Vector3.UP * max_up)
	_step_params.from = lifted
	_step_params.motion = probe
	var fwd := probe
	if PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		fwd = _step_result.get_travel()
	if Vector2(fwd.x, fwd.z).length() < 0.03:
		return false
	_step_params.from = lifted.translated(fwd)
	_step_params.motion = Vector3.DOWN * max_up
	if not PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		return false
	if _step_result.get_collision_count() <= 0 or _step_result.get_collision_normal(0).y < 0.78:
		return false
	var step_h := max_up + _step_result.get_travel().y
	if step_h < 0.015 or step_h > T.STEP_UP:
		return false
	global_position.y += step_h + 0.004
	return true


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
		var want := (d / dist) * speed
		velocity.x = move_toward(velocity.x, want.x, T.CLONE_ACCEL * delta)
		velocity.z = move_toward(velocity.z, want.z, T.CLONE_ACCEL * delta)
	else:
		_slow_down(delta, 16.0)


func _fight(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	var to_p := _dir_to_player()
	var dist := to_p.length()
	var dy := absf(_player.global_position.y - global_position.y)

	if _attack_time >= 0.0:
		var prev := _attack_time
		_attack_time += delta
		_slow_down(delta, 26.0)
		var active_end := T.CLONE_WINDUP + T.CLONE_ACTIVE
		var total := active_end + T.CLONE_RECOVER
		var in_active := _attack_time >= T.CLONE_WINDUP and _attack_time <= active_end
		var crossed := prev < active_end and _attack_time >= T.CLONE_WINDUP
		if not _attack_hit_done and (in_active or crossed):
			if _deal_damage(dist):
				_attack_hit_done = true
		if _attack_time >= total:
			_attack_time = -1.0
			_attack_hit_done = false
			_attack_side = "L" if _attack_side == "R" else "R"
			_cooldown = T.CLONE_COOLDOWN
			_recover = T.CLONE_RECOVER
		return

	if _recover > 0.0:
		if dist > 0.01:
			var away := -(to_p / dist)
			velocity.x = move_toward(velocity.x, away.x * T.CLONE_WALK, T.CLONE_ACCEL * delta)
			velocity.z = move_toward(velocity.z, away.z * T.CLONE_WALK, T.CLONE_ACCEL * delta)
		return

	if dist <= T.CLONE_RANGE and dy < 0.55 and _cooldown <= 0.0:
		_attack_time = 0.0
		_attack_hit_done = false
		return

	_move_toward_player(delta, T.CLONE_KEEP_DISTANCE, T.CLONE_RUN)


func _deal_damage(_dist: float) -> bool:
	if not is_instance_valid(_player):
		_last_deal = 0.0
		return false
	var dir := _dir_to_player()
	if dir.length_squared() < 0.0001:
		_last_deal = 0.0
		return false
	dir = dir.normalized()
	var forward := -global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	if rad_to_deg(forward.angle_to(dir)) > T.ATTACK_ANGLE:
		_last_deal = 0.0
		return false
	if not HitCheck.overlaps(self, _player, forward, T.CLONE_REACH, _attack_side, false):
		_last_deal = 0.0
		return false
	_last_deal = 1.2
	if _player.has_method("take_damage"):
		_player.take_damage(T.CLONE_DAMAGE, dir)
	return true


func _face(delta: float) -> void:
	var look := velocity
	if mode == Mode.ON:
		if _attack_time >= T.CLONE_WINDUP:
			return
		look = _dir_to_player()
	elif look.length_squared() < 0.0025 and is_instance_valid(_player):
		look = _dir_to_player()
	if look.length_squared() < 0.0025:
		return
	var want := atan2(-look.x, -look.z)
	rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-10.0 * delta))


func take_damage(amount: float, _from_dir: Vector3) -> void:
	if mode == Mode.OFF:
		# В мирном режиме только мигаем подписью (подтверждая контакт кулака), но не тратим ХП.
		_flash = 0.65
		return
	health = maxf(0.0, health - amount)
	_flash = 1.0
	if character != null and character.has_method("play_hit"):
		character.play_hit()
	if health <= 0.0:
		health = T.CLONE_HEALTH
		global_position = _spawn_pos
		mode = Mode.OFF
		_attack_time = -1.0
		_attack_hit_done = false
		_recover = 0.0
		_idle_awake = 0.8
		velocity = Vector3.ZERO
		if character != null and character.has_method("reset_motion"):
			character.reset_motion(false)
	_update_label()


func _update_label() -> void:
	if _label == null:
		return
	var text := ""
	if mode == Mode.OFF:
		text = "Клон · бой ВЫКЛ [T]"
	else:
		var extra := ""
		if _last_deal > 0.0:
			extra = " · удар!"
		elif _attack_time >= 0.0 and _attack_time < T.CLONE_WINDUP:
			extra = " · замах"
		text = "Клон  %.0f/%.0f%s" % [ceili(health), T.CLONE_HEALTH, extra]

	# Не пересоздаём раскладку шрифта Label3D 60 раз в секунду, если строка не менялась.
	if text != _last_label_text:
		_label.text = text
		_last_label_text = text

	var active_col := Color(0.96, 0.34, 0.36, 0.96) if mode == Mode.ON else Color(0.90, 0.94, 0.99, 0.86)
	if _flash > 0.0:
		_label.modulate = active_col.lerp(Color(1.0, 0.88, 0.55, 1.0), _flash)
		_last_label_active = true
	elif _last_label_active or _label.modulate != active_col:
		_label.modulate = active_col
		_last_label_active = false
