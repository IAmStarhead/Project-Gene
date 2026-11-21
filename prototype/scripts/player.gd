## Героиня: отзывчивое движение от третьего лица (3 темпа + ступеньки), прыжок с буфером
## и coyote-time, направленный уворот с кадрами неуязвимости, удары левой/правой рукой,
## захват цели (Tab / СКМ) и честная диагностика FPS + видеокарты по F3.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")
const CameraRigScene := preload("res://scenes/camera_rig.tscn")
const LockOn := preload("res://scripts/lock_on.gd")
const HitCheck := preload("res://scripts/hit_check.gd")
const Foley := preload("res://scripts/actor_foley.gd")
const TrainingSword := preload("res://scripts/training_sword.gd")
const StrikeAir := preload("res://scripts/strike_air.gd")
const Moves := preload("res://scripts/move_catalog.gd")

@onready var character: Node3D = $Character
@onready var label: Label = $UI/DebugLabel
@onready var hud: CanvasLayer = get_node_or_null("HUD")

## Отдельная камера в корне сцены: не наследует поворот тела героини.
var rig: Node3D
var foley: Node3D
var yaw: float = 0.0        ## рыскание камеры, радианы
var pitch: float = -13.0    ## наклон камеры, градусы

var health: float = T.MAX_HEALTH
var stamina: float = T.MAX_STAMINA

# Видимый тестовый меч по-прежнему действует ТОЛЬКО на подготовленный манекен.
var training_sword: RefCounted
var strike_air: MeshInstance3D
var _strike_hand_indices := {"L": -1, "R": -1}
var training_blade := false
var training_limb := 0
var training_special := false
var _attack_blade := false
var _attack_blade_limb := 0
var _attack_blade_special := false
const TRAINING_LIMB_NAMES := ["левая рука", "правая рука", "левая нога", "правая нога"]
const TRAINING_BLADE_REACH := 1.60


## Стойка игрока (переключается R); бой клона живёт отдельно на клавише T.
var combat_mode := false

var _stamina_cooldown: float = 0.0
var _health_cooldown: float = 0.0
var _spawn_pos := Vector3(0.0, 0.08, 5.4)
var _spawn_recorded := false

# Состояние действия: "" | "attack" | "dodge"
var _action: String = ""
var _action_time: float = 0.0
var _hit_done := false
var _miss_logged := false

# Буфер ввода: сколько секунд назад нажата кнопка (BUF_NEVER = не нажимали).
const BUF_NEVER := 999.0
var _buf_dodge: float = BUF_NEVER
var _buf_attack: float = BUF_NEVER
var _buf_secondary: float = BUF_NEVER
var _buf_hook: float = BUF_NEVER
var selected_attack_slot := 0 # 1..9,0 select; LMB executes, default remains left jab.
var _buf_primary_slot := -1 # Snapshot at the click, not after a later number press.
var _attack_kind := "straight"
var _attack_side: String = "L"
# New kicks only: a moving start first brakes through the real gait using
# UNCHANGED DECELERATION. Their authored weight transfer starts after stop,
# not while a planted foot visibly skids under a sprinting CharacterBody.
var _kick_planting := false
var _buf_dir: Vector3 = Vector3.ZERO

var _dodge_local_dir := Vector3(0, 0, 1)
var _dodge_dir: Vector3 = Vector3.ZERO
var _invulnerable: bool = false
var _coyote: float = 0.0
var _jump_buffer: float = BUF_NEVER
var _jump_started := false

var _targets: Array = []
var lock := LockOn.new()
var _last_hit: String = ""
var _last_received_hit := ""
var show_details := false

# Переиспользуемые структуры для автоподъёма по ступенькам (0 аллокаций в кадре).
var _step_params := PhysicsTestMotionParameters3D.new()
var _step_result := PhysicsTestMotionResult3D.new()

# Время между кадрами измеряем системными монотонными часами, не игровым delta.
# Godot уменьшает delta при превышении лимита физических шагов за кадр.
var _gpu_name := ""
var _gpu_is_integrated := false
var _perf_accum: float = 0.0
var _perf_frames: int = 0
var _perf_previous_usec: int = -1
var _perf_worst: float = 0.0
var _fps: float = 0.0
var _avg_ms: float = 0.0
var _worst_ms: float = 0.0


func _ready() -> void:
	add_to_group("player")
	var headless := DisplayServer.get_name() == "headless"
	if not headless:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_gpu_name = RenderingServer.get_video_adapter_name().strip_edges()
		var low := _gpu_name.to_lower()
		_gpu_is_integrated = (
			low.contains("intel")
			or low.contains("hd graphics")
			or low.contains("uhd")
			or low.contains("microsoft basic")
			or low.contains("llvmpipe")
		)

	rig = CameraRigScene.instantiate()
	rig.setup(self, yaw, pitch)
	var host := get_tree().current_scene if get_tree().current_scene != null else get_parent()
	if host != null:
		host.add_child(rig)

	foley = Foley.new()
	foley.name = "Foley"
	add_child(foley)
	_refresh_targets()
	lock.setup(self)
	if hud != null and hud.has_method("setup"):
		hud.setup(self, lock)
	_style_debug_label()
	if character != null and character.has_method("reset_motion"):
		character.reset_motion(combat_mode)
	if character != null and character.skeleton != null:
		training_sword = TrainingSword.new()
		if not training_sword.setup(character.skeleton):
			training_sword = null
		for side in ["L", "R"]:
			_strike_hand_indices[side] = character.skeleton.find_bone("hand." + side)
		strike_air = StrikeAir.new()
		strike_air.name = "StrikeAir"
		character.add_child(strike_air)


func _style_debug_label() -> void:
	if label == null:
		return
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.07, 0.11, 0.82)
	box.border_color = Color(0.55, 0.65, 0.78, 0.48)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 11.0
	box.content_margin_right = 11.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	label.add_theme_stylebox_override("normal", box)
	label.visible = show_details


func _exit_tree() -> void:
	if is_instance_valid(rig):
		rig.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_V:
			training_blade = not training_blade
			_sync_training_sword()
			_sync_training_selection()
			get_viewport().set_input_as_handled()
			return
		if training_blade:
			if key >= KEY_1 and key <= KEY_4:
				training_limb = key - KEY_1
				_sync_training_selection()
				get_viewport().set_input_as_handled()
				return
			if key == KEY_N:
				training_special = not training_special
				get_viewport().set_input_as_handled()
				return
			if key == KEY_K:
				for manikin in get_tree().get_nodes_in_group("cut_manikin"):
					manikin.restore_all()
				get_viewport().set_input_as_handled()
				return
		# Left Alt is the existing WALK modifier, not a reason to disable
		# number selection while moving. Shift/AZERTY text is also irrelevant.
		if not training_blade and not event.ctrl_pressed and not event.meta_pressed:
			var digits := [KEY_1,KEY_2,KEY_3,KEY_4,KEY_5,KEY_6,KEY_7,KEY_8,KEY_9,KEY_0]
			var keypad := [KEY_KP_1,KEY_KP_2,KEY_KP_3,KEY_KP_4,KEY_KP_5,KEY_KP_6,KEY_KP_7,KEY_KP_8,KEY_KP_9,KEY_KP_0]
			var slot := digits.find(key)
			if slot < 0: slot = keypad.find(key)
			if slot >= 0:
				selected_attack_slot = slot
				get_viewport().set_input_as_handled()
				return
	if lock != null and lock.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			yaw = wrapf(yaw - event.relative.x * T.MOUSE_SENSITIVITY, -PI, PI)
			pitch = clampf(
				pitch - event.relative.y * T.MOUSE_SENSITIVITY * 60.0,
				T.CAMERA_PITCH_MIN,
				T.CAMERA_PITCH_MAX
			)
	elif event.is_action_pressed("toggle_debug_details"):
		show_details = not show_details
		_set_clone_profiling(show_details)
		if label != null:
			label.visible = show_details
		if show_details:
			_reset_perf_counter()
			_write_debug_label()
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		var headless := DisplayServer.get_name() == "headless"
		# Если окно было не в фокусе — первый клик только возвращает захват мыши без случайного удара.
		if not headless and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_buffer_primary_attack()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_buf_secondary = 0.0
	elif event.is_action_pressed("attack"):
		_buffer_primary_attack()
	elif event.is_action_pressed("attack_secondary"):
		_buf_secondary = 0.0
	elif event.is_action_pressed("attack_hook"):
		_buf_hook = 0.0
	elif event.is_action_pressed("dodge"):
		_buf_dodge = 0.0
		_buf_dir = _input_direction()
	elif event.is_action_pressed("jump"):
		_jump_buffer = 0.0
	elif event.is_action_pressed("toggle_stance"):
		toggle_combat_mode()


func _buffer_primary_attack() -> void:
	_buf_attack = 0.0
	_buf_primary_slot = selected_attack_slot


func _sync_training_selection() -> void:
	for manikin in get_tree().get_nodes_in_group("cut_manikin"):
		manikin.highlight_limb(training_limb if training_blade else -1)


func _sword_active() -> bool:
	# The cut mode is captured when the attack starts. A V press mid-swing
	# cannot make a non-cutting punch appear to be a sword strike or vice versa.
	return _attack_blade if _action == "attack" else training_blade


func _sync_training_sword() -> void:
	if training_sword != null:
		var hand: String = _attack_side if _action == "attack" and _attack_blade else String(training_sword.side)
		training_sword.set_display(_sword_active(), hand)


func toggle_combat_mode() -> void:
	combat_mode = not combat_mode


func stance_name() -> String:
	return "боевой" if combat_mode else "обычный"


func is_alive() -> bool:
	return health > 0.0


## Горизонтальное направление взгляда камеры (для WASD и захвата цели).
func aim_forward() -> Vector3:
	var f := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return f.normalized()


func _input_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input.length() < 0.1:
		return Vector3.ZERO
	var basis_yaw := Basis(Vector3.UP, yaw)
	return (basis_yaw * Vector3(input.x, 0.0, input.y)).normalized()


func _set_clone_profiling(enabled: bool) -> void:
	var clone := get_tree().get_first_node_in_group("clone")
	if is_instance_valid(clone):
		clone.set_profiling(enabled)


func _notification(what: int) -> void:
	# Не включать проведённое в меню время в длительность первого кадра.
	if what == NOTIFICATION_UNPAUSED:
		_reset_perf_counter()


func _reset_perf_counter() -> void:
	_perf_previous_usec = -1
	_perf_accum = 0.0
	_perf_frames = 0
	_perf_worst = 0.0
	_fps = 0.0
	_avg_ms = 0.0
	_worst_ms = 0.0


func _record_perf_time(now_usec: int) -> bool:
	if _perf_previous_usec < 0 or now_usec <= _perf_previous_usec:
		_perf_previous_usec = now_usec
		return false
	var elapsed := float(now_usec - _perf_previous_usec) / 1000000.0
	_perf_previous_usec = now_usec
	_perf_accum += elapsed
	_perf_frames += 1
	_perf_worst = maxf(_perf_worst, elapsed)
	if _perf_accum < 0.25:
		return false
	_fps = float(_perf_frames) / _perf_accum
	_avg_ms = 1000.0 * _perf_accum / float(_perf_frames)
	_worst_ms = 1000.0 * _perf_worst
	_perf_accum = 0.0
	_perf_frames = 0
	_perf_worst = 0.0
	return true


func _process(_delta: float) -> void:
	if show_details and _record_perf_time(Time.get_ticks_usec()):
		_write_debug_label()

func _physics_process(delta: float) -> void:
	if not _spawn_recorded:
		_spawn_pos = global_position
		_spawn_recorded = true

	var previous_position := global_position
	_jump_started = false
	if lock != null:
		lock.update(delta)
	_update_buffers(delta)
	_update_stamina(delta)
	_update_health_regen(delta)

	if _action == "dodge":
		_process_dodge(delta)
	elif _action == "attack":
		_process_attack(delta)
	else:
		_process_move(delta)
		_try_start_actions()

	var on_floor := is_on_floor()
	if on_floor:
		if _action != "dodge" and velocity.y <= 0.0:
			velocity.y = 0.0
	else:
		var g := T.PLAYER_JUMP_GRAVITY if velocity.y > 0.0 else T.GRAVITY_FALL
		velocity.y -= g * delta

	if _jump_buffer <= T.INPUT_BUFFER and _action != "dodge" and not (_action == "attack" and Moves.is_kick(_attack_kind)) and _coyote > 0.0:
		_try_jump()

	var stepped_up := false
	if _action == "" and on_floor and not _jump_started and velocity.y <= 0.0:
		stepped_up = _try_step_up(delta)

	move_and_slide()
	if stepped_up:
		apply_floor_snap()

	var displacement := global_position - previous_position
	_sync_training_sword()
	_update_character_anim(delta, displacement)
	_update_strike_air(delta)
	if character != null and foley != null:
		var phase: Variant = character.get("_phase")
		if phase != null:
			foley.update_motion(delta, float(phase), is_on_floor(), Vector2(displacement.x, displacement.z).length(), "" if _kick_planting else _action)
	_update_camera_lock(delta)


func _try_jump() -> void:
	velocity.y = sqrt(2.0 * T.PLAYER_JUMP_GRAVITY * T.JUMP_HEIGHT)
	_jump_started = true
	_jump_buffer = BUF_NEVER
	_coyote = 0.0


func _air_control() -> float:
	return 1.0 if is_on_floor() else T.AIR_CONTROL


## Плавный автоподъём на ступеньки высотой до T.STEP_UP (0.30 м).
## Игнорирует стены, высокие платформы для прыжка (0.60+ м) и живых противников.
func _try_step_up(delta: float) -> bool:
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	var spd := horiz.length()
	if spd < 0.15:
		return false

	var rid := get_rid()
	var probe := (horiz / spd) * maxf(spd * delta, 0.09)

	_step_params.from = global_transform
	_step_params.motion = probe
	_step_params.margin = 0.004
	_step_params.recovery_as_collision = false
	if not PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		return false
	if _step_result.get_collision_count() <= 0:
		return false
	if not (_step_result.get_collider(0) is StaticBody3D):
		return false
	if absf(_step_result.get_collision_normal(0).y) > 0.35:
		return false

	# 1. Проверяем свободное место сверху.
	_step_params.from = global_transform
	_step_params.motion = Vector3.UP * T.STEP_UP
	var max_up := T.STEP_UP
	if PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		max_up = _step_result.get_travel().y
	if max_up < 0.02:
		return false

	# 2. Проверяем, свободен ли проход вперёд на поднятой высоте.
	var lifted := global_transform.translated(Vector3.UP * max_up)
	_step_params.from = lifted
	_step_params.motion = probe
	var fwd := probe
	if PhysicsServer3D.body_test_motion(rid, _step_params, _step_result):
		fwd = _step_result.get_travel()
	if Vector2(fwd.x, fwd.z).length() < 0.03:
		return false

	# 3. Опускаемся на горизонтальную проступь ступени.
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


func _update_character_anim(delta: float, displacement: Vector3) -> void:
	if character != null and character.has_method("update_motion"):
		var planar := Vector3(displacement.x, 0.0, displacement.z)
		var local_velocity := character.global_basis.inverse() * (planar / maxf(delta, 0.001))
		var floor_distance := -1.0
		if not is_on_floor() and velocity.y <= 0.0:
			var query := PhysicsRayQueryParameters3D.create(
				global_position + Vector3.UP * 0.06,
				global_position + Vector3.DOWN * 3.0,
				1,
				[get_rid()]
			)
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				floor_distance = maxf(0.0, global_position.y - (hit["position"] as Vector3).y)
		character.update_motion(delta, local_velocity, "" if _kick_planting else _action, _action_time, _attack_side, {
			"distance": planar.length(),
			"grounded": is_on_floor(),
			"vertical_speed": velocity.y,
			"jump_started": _jump_started,
			"floor_distance": floor_distance,
			"combat": combat_mode,
			"directional": lock != null and lock.active(),
			"dodge_direction": _dodge_local_dir,
			"walk_speed": T.WALK_SPEED,
			"jog_speed": T.JOG_SPEED,
			"sprint_speed": T.RUN_SPEED,
			"attack_timing": _attack_timing(),
			"attack_kind": _attack_kind,
			"hold_weapon": _sword_active(),
		})


func _update_strike_air(delta: float) -> void:
	if not is_instance_valid(strike_air) or character.skeleton == null:
		return
	if _action != "attack" and strike_air.points.is_empty():
		return
	var timing := _attack_timing()
	var sampling := _action == "attack" and not Moves.is_kick(_attack_kind) and _action_time >= timing.x - .035 \
		and _action_time <= timing.x + timing.y + .025
	var hand := Vector3.ZERO
	if sampling:
		var idx: int = _strike_hand_indices.get(_attack_side, -1)
		if idx < 0:
			sampling = false
		else:
			hand = character.skeleton.global_transform * character.skeleton.get_bone_global_pose(idx).origin
	var active_camera := get_viewport().get_camera_3d()
	var view: Vector3 = active_camera.global_position if is_instance_valid(active_camera) else global_position + Vector3(0, 1, 3)
	strike_air.advance(delta, hand, sampling, view)


func _update_buffers(delta: float) -> void:
	_buf_dodge += delta
	_buf_attack += delta
	_buf_secondary += delta
	_buf_hook += delta
	_jump_buffer += delta
	if is_on_floor():
		_coyote = T.COYOTE_TIME
	else:
		_coyote = maxf(0.0, _coyote - delta)


## При активном захвате плавно доворачивает углы камеры к цели; саму позицию
## плавно ведёт CameraRig._process (без двойной перезаписи и дрожания).
func _update_camera_lock(delta: float) -> void:
	if lock == null or not lock.active():
		return
	var wanted_yaw: float = lock.camera_yaw(delta, yaw)
	if not is_nan(wanted_yaw):
		yaw = wanted_yaw
	var wanted_pitch: float = lock.camera_pitch(delta, pitch)
	if not is_nan(wanted_pitch):
		pitch = clampf(wanted_pitch, T.CAMERA_PITCH_MIN, T.CAMERA_PITCH_MAX)


func _update_stamina(delta: float) -> void:
	if _stamina_cooldown > 0.0:
		_stamina_cooldown -= delta
	elif stamina < T.MAX_STAMINA:
		stamina = minf(T.MAX_STAMINA, stamina + T.STAMINA_REGEN * delta)


func _spend_stamina(amount: float) -> bool:
	if stamina < amount:
		return false
	stamina -= amount
	_stamina_cooldown = T.STAMINA_REGEN_DELAY
	return true


func _process_move(delta: float) -> void:
	var dir := _input_direction()
	var locked := lock != null and lock.active()
	if locked:
		var flat := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var out: Array = []
		if lock.movement(flat, out):
			dir = out[0]

	# Приоритет модификаторов: Shift (быстрый бег) всегда перекрывает Left Alt (шаг).
	var speed := T.JOG_SPEED
	if Input.is_action_pressed("run"):
		speed = T.RUN_SPEED
	elif Input.is_action_pressed("walk_slow"):
		speed = T.WALK_SPEED

	var target := dir * speed
	var rate := (T.ACCELERATION if dir.length_squared() > 0.0 else T.DECELERATION) * _air_control()
	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)

	if dir.length_squared() > 0.0 and _buf_dodge > T.INPUT_BUFFER and not locked:
		var want := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, want, minf(1.0, delta * T.TURN_SPEED))

	if locked:
		var face: Array = []
		if lock.facing(face):
			var fwd: Vector3 = face[0]
			rotation.y = lerp_angle(
				rotation.y,
				atan2(-fwd.x, -fwd.z),
				1.0 - exp(-LockOn.TURN_RATE * delta)
			)


func _try_start_actions() -> void:
	if _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return
	_try_start_attacks()


func _try_start_attacks() -> void:
	if _buf_attack <= T.INPUT_BUFFER:
		# Blade is a visibly separate context: its legacy 1..4 limb selection
		# and LMB cut do NOT become kick damage or disappear into an empty slot.
		var slot := _buf_primary_slot if _buf_primary_slot >= 0 else selected_attack_slot
		var profile := Moves.profile("straight", "L") if training_blade else Moves.slot_profile(slot)
		if profile.is_empty():
			_buf_attack = BUF_NEVER
			_buf_primary_slot = -1
		elif (not profile.ground_only or is_on_floor()) and _spend_stamina(float(profile.stamina)):
			_attack_side = profile.side
			_start_attack(profile.kind)
			_buf_attack = BUF_NEVER
			_buf_primary_slot = -1
			return
	if _buf_secondary <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_attack_side = "R"
		_start_attack()
		_buf_secondary = BUF_NEVER
	elif _buf_hook <= T.INPUT_BUFFER and _spend_stamina(T.HOOK_STAMINA):
		_start_attack("hook")
		_buf_hook = BUF_NEVER


func _start_dodge() -> void:
	_kick_planting = false
	velocity.x = 0.0
	velocity.z = 0.0
	_action = "dodge"
	_action_time = 0.0
	_dodge_dir = _buf_dir if _buf_dir.length() > 0.0 else global_basis.z
	_dodge_dir.y = 0.0
	if _dodge_dir.length() < 0.1:
		_dodge_dir = _camera_forward()
	_dodge_dir = _dodge_dir.normalized()
	_dodge_local_dir = character.global_basis.inverse() * _dodge_dir
	_dodge_local_dir.y = 0.0
	_dodge_local_dir = _dodge_local_dir.normalized()
	_invulnerable = false


func _camera_forward() -> Vector3:
	var f := -Basis(Vector3.UP, yaw).z
	f.y = 0.0
	return f.normalized()


func _process_dodge(delta: float) -> void:
	var before := T.dodge_progress(_action_time / T.DODGE_DURATION)
	_action_time += delta
	_invulnerable = _action_time >= T.DODGE_IFRAMES_START and _action_time <= T.DODGE_IFRAMES_END
	var after := T.dodge_progress(_action_time / T.DODGE_DURATION)
	var speed := T.DODGE_DISTANCE * (after - before) / maxf(delta, 0.000001)
	velocity.x = _dodge_dir.x * speed
	velocity.z = _dodge_dir.z * speed

	if _action_time >= T.DODGE_DURATION:
		_action = ""
		_invulnerable = false
		_try_start_attacks()


func _attack_timing() -> Vector3:
	return Moves.profile(_attack_kind, _attack_side).timing


func _start_attack(kind: String = "straight") -> void:
	if is_instance_valid(strike_air):
		strike_air.clear_trail()
	var profile := Moves.profile(kind, _attack_side)
	_attack_kind = profile.kind
	_attack_side = profile.side
	_kick_planting = Moves.is_kick(_attack_kind) and Vector2(velocity.x,velocity.z).length() > .35
	combat_mode = true
	_action = "attack"
	_action_time = 0.0
	_hit_done = false
	_miss_logged = false
	_last_hit = ""
	# Тип и выбор части фиксируются в начале замаха, а не в момент контакта.
	_attack_blade = training_blade and not Moves.is_kick(_attack_kind)
	_attack_blade_limb = training_limb
	_attack_blade_special = training_special
	_sync_training_sword()
	# При захвате цели доворачиваем корпус прямо к противнику перед выбросом руки.
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			var fwd: Vector3 = face[0]
			rotation.y = atan2(-fwd.x, -fwd.z)


func _attack_phase() -> String:
	if _kick_planting: return "постановка опоры"
	var timing := _attack_timing()
	if _action_time < timing.x:
		return "замах"
	if _action_time < timing.x+timing.y:
		return "удар"
	return "возврат"


func _process_attack(delta: float) -> void:
	var kick := Moves.is_kick(_attack_kind)
	# A grounded kick may not turn into an invisible airborne upper-body
	# punch after stepping off a platform. Existing air punches are unchanged.
	if kick and not is_on_floor():
		_action = ""
		_kick_planting = false
		return
	if kick and _kick_planting:
		velocity.x = move_toward(velocity.x,0.0,T.DECELERATION*delta)
		velocity.z = move_toward(velocity.z,0.0,T.DECELERATION*delta)
		# A clearly displayed preparation, not a delayed hit or changed
		# physics constant. Hand attacks / Q / clone timing are untouched.
		if Vector2(velocity.x,velocity.z).length_squared() < .0001:
			velocity.x = 0.0
			velocity.z = 0.0
			_kick_planting = false
		return
	var previous_time := _action_time
	_action_time += delta
	velocity.x = move_toward(velocity.x, 0.0, T.DECELERATION * delta)
	velocity.z = move_toward(velocity.z, 0.0, T.DECELERATION * delta)

	var timing := _attack_timing()
	if previous_time < timing.x and _action_time >= timing.x and foley != null:
		foley.swing()
	var active_end := timing.x+timing.y
	var total := active_end+timing.z

	# Проверяем попадание на всём активном участке (а также если длинный кадр перескочил окно),
	# но наносим урон строго один раз за удар.
	var in_window := _action_time >= timing.x and _action_time <= active_end
	var crossed_window := previous_time < active_end and _action_time >= timing.x
	if not _hit_done and (in_window or crossed_window):
		if (_do_kick_hit(previous_time, _action_time) if kick else _do_hit(in_window)):
			_hit_done = true
	if not _hit_done and not _miss_logged and _action_time >= active_end:
		_miss_logged = true
		_last_hit = _miss_reason()

	# Отмена восстановления уворотом (в пределах ATTACK_CANCEL_WINDOW до конца удара).
	var cancel_start := maxf(active_end, total - float(Moves.profile(_attack_kind, _attack_side).cancel_window))
	if _action_time >= cancel_start and _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return

	if _action_time >= total:
		_action = ""


func _do_kick_hit(previous_time: float, time: float) -> bool:
	if not is_on_floor() or _attack_blade:
		return false
	_refresh_targets()
	var hit := HitCheck.find_kick_hit(self, _targets, -global_basis.z, _attack_kind, previous_time, time)
	return _accept_contact(hit)


func _do_hit(use_live_bone: bool) -> bool:
	if Moves.is_kick(_attack_kind):
		return false # Never borrow the fist segment / fallback for a foot.
	_refresh_targets()
	var forward := -global_transform.basis.z
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			forward = face[0]
	if _attack_blade:
		return _do_training_cut(forward)
	var hit := HitCheck.find_hit(
		self,
		_targets,
		forward,
		T.HOOK_REACH if _attack_kind == "hook" else T.ATTACK_REACH,
		T.ATTACK_ANGLE,
		_attack_side,
		use_live_bone,
		_attack_kind
	)
	return _accept_contact(hit)


func _accept_contact(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var victim := hit["target"] as Node3D
	var zone_name := HitCheck.zone_label(String(hit.get("zone", "torso")))
	var damage := float(Moves.profile(_attack_kind, _attack_side).damage)
	if victim.has_method("is_passive") and bool(victim.call("is_passive")):
		_last_hit = "%s (%s — бой ВЫКЛ, нажмите T)" % [victim.name, zone_name]
	else:
		_last_hit = "%s (%s, -%.0f)" % [victim.name, zone_name, damage]
	var accepted := HitCheck.deliver_hit(victim, damage, hit)
	if foley != null and accepted:
		foley.impact()
	_last_hit += " ~"+String(hit.get("source", "reach_fallback"))
	if not accepted:
		_last_hit += " (отклонён/i-frames)"
	if is_instance_valid(rig) and rig.has_method("add_kick"):
		rig.call("add_kick", -0.8)
	return true


func _do_training_cut(forward: Vector3) -> bool:
	# Тестовый объём, не произвольный разрез и не трек настоящего меча.
	forward.y = 0.0
	if forward.length_squared() < .0001:
		return false
	forward = forward.normalized()
	for manikin in get_tree().get_nodes_in_group("cut_manikin"):
		if not is_instance_valid(manikin) or not manikin.is_inside_tree():
			continue
		var point: Vector3 = manikin.limb_point(_attack_blade_limb)
		var to := point - global_position
		if absf(to.y) > 1.9 or to.y < -.15:
			continue
		var flat := Vector3(to.x, 0, to.z)
		var distance := flat.length()
		if distance < .05 or distance > TRAINING_BLADE_REACH:
			continue
		if rad_to_deg(forward.angle_to(flat / distance)) > T.ATTACK_ANGLE:
			continue
		var from := global_position + Vector3(0, maxf(.2, to.y), 0)
		var query := PhysicsRayQueryParameters3D.create(from, point, 1)
		if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			continue
		if manikin.sever(_attack_blade_limb, _attack_blade_special, forward):
			_last_hit = "Манекен: " + TRAINING_LIMB_NAMES[_attack_blade_limb]
			if foley != null:
				foley.impact()
			return true
	return false


func _miss_reason() -> String:
	if _attack_blade:
		return "мимо: манекен далеко, вне угла или часть уже отсечена"
	var near := _nearest_target()
	if near == null:
		return "мимо (целей нет)"
	var gap: float = HitCheck.surface_gap(self, near, T.BODY_HIT_RADIUS)
	return "мимо (зазор %.2f м)" % gap


func _nearest_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for v in _targets:
		if not is_instance_valid(v) or not (v is Node3D):
			continue
		var d: Vector3 = (v as Node3D).global_position - global_position
		d.y = 0.0
		var dist := d.length()
		if dist < best_d:
			best_d = dist
			best = v as Node3D
	return best


func _refresh_targets() -> void:
	if not is_inside_tree():
		return
	var cleaned: Array = []
	for item in _targets:
		if is_instance_valid(item) and item != self:
			cleaned.append(item)
	for n in get_tree().get_nodes_in_group("damageable"):
		if n != self and is_instance_valid(n) and not cleaned.has(n):
			cleaned.append(n)
	_targets = cleaned


func _update_health_regen(delta: float) -> void:
	var healing_time := maxf(0.0, delta - _health_cooldown)
	_health_cooldown = maxf(0.0, _health_cooldown - delta)
	if health > 0.0:
		health = minf(T.MAX_HEALTH, health + T.HEALTH_REGEN * healing_time)


func take_damage(amount: float, from_dir: Vector3) -> void:
	receive_hit(amount, {"zone": "unknown", "direction_world": from_dir, "source": "legacy"})


## Confirmed-zone API; point_world is approximate, direction_world is
## attacker -> victim in WORLD axes. Legacy callers keep their two args.
func receive_hit(amount: float, hit: Dictionary) -> bool:
	if amount <= 0.0:
		return false
	if _invulnerable:
		_last_hit = "уворот (неуязвимость)"
		return false
	combat_mode = true
	if foley != null:
		foley.hurt()
	health = maxf(0.0, health - amount)
	_health_cooldown = T.HEALTH_REGEN_DELAY
	if is_instance_valid(rig) and rig.has_method("add_kick"):
		rig.call("add_kick", 1.3)
	if character != null and character.has_method("play_hit"):
		character.play_hit(String(hit.get("zone", "unknown")), hit.get("direction_world", Vector3.ZERO))
	_last_received_hit = "%s ~%s" % [HitCheck.zone_label(String(hit.get("zone", "unknown"))), hit.get("source", "legacy")]
	if health <= 0.0:
		health = T.MAX_HEALTH
		_health_cooldown = 0.0
		stamina = T.MAX_STAMINA
		global_position = _spawn_pos
		rotation = Vector3.ZERO
		yaw = 0.0
		_action = ""
		_action_time = 0.0
		_attack_kind = "straight"
		_kick_planting = false
		_hit_done = false
		_buf_attack = BUF_NEVER
		_buf_primary_slot = -1
		_buf_secondary = BUF_NEVER
		_buf_hook = BUF_NEVER
		_buf_dodge = BUF_NEVER
		_jump_buffer = BUF_NEVER
		_invulnerable = false
		velocity = Vector3.ZERO
		combat_mode = false
		if lock != null:
			lock.clear()
		if character != null and character.has_method("reset_motion"):
			character.reset_motion(combat_mode)
		if is_instance_valid(rig) and rig.has_method("snap_now"):
			rig.call("snap_now")
		_last_hit = "поражение → возрождение"
	return true


func _write_debug_label() -> void:
	if label == null:
		return
	var state_text := "движение"
	if _action == "attack":
		state_text = "%s: %s" % [Moves.profile(_attack_kind, _attack_side).title, _attack_phase()]
	elif _action == "dodge":
		state_text = "уворот" + (" [i-frames]" if _invulnerable else "")

	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var q_name: String = T.QUALITY_NAMES[clampi(T.QUALITY, 0, T.QUALITY_NAMES.size() - 1)]
	var b_name: String = T.BRIGHTNESS_NAMES[clampi(T.BRIGHTNESS, 0, T.BRIGHTNESS_NAMES.size() - 1)]
	var style_name := "селлшейдинг" if T.TOON_ENABLED else "полуреализм"
	var lock_name := String(lock.target.name) if (lock != null and lock.active()) else "нет"

	var frame_stats := "FPS: %.0f  ·  кадр: %.1f мс (пик %.1f)" % [_fps, _avg_ms, _worst_ms] if _fps > 0.0 else "FPS: собираем замеры…"
	var lines := PackedStringArray([
		"%s  ·  физ: %.1f мс" % [frame_stats, phys_ms],
		"Видеокарта: %s" % (_gpu_name if not _gpu_name.is_empty() else "—"),
	])
	if _gpu_is_integrated:
		lines.append("[!] Встроенная графика! Выберите NVIDIA GeForce 940MX")
	var clone := get_tree().get_first_node_in_group("clone")
	if is_instance_valid(clone):
		lines.append(str(clone.profile_text))
	lines.append("Отрисовка: %d вызовов  ·  %d примитивов" % [draws, prims])
	lines.append("Графика [F4]: %s  ·  свет [B]: %s  ·  стиль [G]: %s" % [q_name, b_name, style_name])
	lines.append("Режим [R]: %s  ·  %s  ·  захват: %s" % [stance_name(), state_text, lock_name])
	lines.append("Костюм [O]: %s" % T.OUTFIT_NAMES[T.OUTFIT])
	var selected := Moves.slot_profile(selected_attack_slot)
	lines.append("Выбор [1–0]: %d · %s → ЛКМ" % [(selected_attack_slot+1)%10,
		"пусто" if selected.is_empty() else String(selected.title)])
	lines.append("Здоровье: %.0f/%.0f  ·  стамина: %.0f/%.0f" % [health, T.MAX_HEALTH, stamina, T.MAX_STAMINA])
	lines.append("Последний контакт: %s" % (_last_hit if not _last_hit.is_empty() else "—"))
	lines.append("Получено: %s" % (_last_received_hit if not _last_received_hit.is_empty() else "—"))
	if character != null:
		lines.append("Реакция: %s · входящее local %s" % [character._hit_zone, character._hit_direction])
	if training_blade:
		var limb_names := ["левая рука", "правая рука", "левая нога", "правая нога"]
		lines.append("Манекен: %s · %s" % [limb_names[clampi(training_limb, 0, 3)], "рост заблокирован" if training_special else "рост включён"])
	label.text = "\n".join(lines)
