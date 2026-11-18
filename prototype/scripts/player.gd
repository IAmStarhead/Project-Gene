## Героиня: отзывчивое движение от третьего лица (3 темпа + ступеньки), прыжок с буфером
## и coyote-time, направленный уворот с кадрами неуязвимости, удары левой/правой рукой,
## захват цели (Tab / СКМ) и честная диагностика FPS + видеокарты по F3.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")
const CameraRigScene := preload("res://scenes/camera_rig.tscn")
const LockOn := preload("res://scripts/lock_on.gd")
const HitCheck := preload("res://scripts/hit_check.gd")

@onready var character: Node3D = $Character
@onready var label: Label = $UI/DebugLabel
@onready var hud: CanvasLayer = get_node_or_null("HUD")

## Отдельная камера в корне сцены: не наследует поворот тела героини.
var rig: Node3D
var yaw: float = 0.0        ## рыскание камеры, радианы
var pitch: float = -13.0    ## наклон камеры, градусы

var health: float = T.MAX_HEALTH
var stamina: float = T.MAX_STAMINA

## Стойка игрока (переключается R); бой клона живёт отдельно на клавише T.
var combat_mode := false

var _stamina_cooldown: float = 0.0
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
var _attack_side: String = "L"
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
var show_details := false

# Переиспользуемые структуры для автоподъёма по ступенькам (0 аллокаций в кадре).
var _step_params := PhysicsTestMotionParameters3D.new()
var _step_result := PhysicsTestMotionResult3D.new()

# Честная телеметрия рендера в _process (не ограничена шагом физики 60 Гц).
var _gpu_name := ""
var _gpu_is_integrated := false
var _perf_accum: float = 0.0
var _perf_frames: int = 0
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

	_refresh_targets()
	lock.setup(self)
	if hud != null and hud.has_method("setup"):
		hud.setup(self, lock)
	_style_debug_label()
	if character != null and character.has_method("reset_motion"):
		character.reset_motion(combat_mode)


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
		if label != null:
			label.visible = show_details
		if show_details:
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
			_buf_attack = 0.0
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_buf_secondary = 0.0
	elif event.is_action_pressed("attack"):
		_buf_attack = 0.0
	elif event.is_action_pressed("attack_secondary"):
		_buf_secondary = 0.0
	elif event.is_action_pressed("dodge"):
		_buf_dodge = 0.0
		_buf_dir = _input_direction()
	elif event.is_action_pressed("jump"):
		_jump_buffer = 0.0
	elif event.is_action_pressed("toggle_stance"):
		toggle_combat_mode()


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


func _process(delta: float) -> void:
	# Считаем реальное время отрисованного кадра и обновляем текст только при открытом F3.
	if not show_details:
		return
	_perf_accum += delta
	_perf_frames += 1
	if delta > _perf_worst:
		_perf_worst = delta
	if _perf_accum >= 0.25:
		_fps = float(_perf_frames) / _perf_accum
		_avg_ms = (_perf_accum / float(_perf_frames)) * 1000.0
		_worst_ms = _perf_worst * 1000.0
		_perf_accum = 0.0
		_perf_frames = 0
		_perf_worst = 0.0
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
		var g := T.GRAVITY if velocity.y > 0.0 else T.GRAVITY_FALL
		velocity.y -= g * delta

	if _jump_buffer <= T.INPUT_BUFFER and _action != "dodge" and _coyote > 0.0:
		_try_jump()

	var stepped_up := false
	if _action == "" and on_floor and not _jump_started and velocity.y <= 0.0:
		stepped_up = _try_step_up(delta)

	move_and_slide()
	if stepped_up:
		apply_floor_snap()

	_update_character_anim(delta, global_position - previous_position)
	_update_camera_lock(delta)


func _try_jump() -> void:
	velocity.y = sqrt(2.0 * T.GRAVITY * T.JUMP_HEIGHT)
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
		character.update_motion(delta, local_velocity, _action, _action_time, _attack_side, {
			"distance": planar.length(),
			"grounded": is_on_floor(),
			"vertical_speed": velocity.y,
			"jump_started": _jump_started,
			"floor_distance": floor_distance,
			"combat": combat_mode,
			"dodge_direction": _dodge_local_dir,
			"walk_speed": T.WALK_SPEED,
			"jog_speed": T.JOG_SPEED,
			"sprint_speed": T.RUN_SPEED,
			"attack_timing": Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY),
		})


func _update_buffers(delta: float) -> void:
	_buf_dodge += delta
	_buf_attack += delta
	_buf_secondary += delta
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
	if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_attack_side = "L"
		_start_attack()
		_buf_attack = BUF_NEVER
	elif _buf_secondary <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_attack_side = "R"
		_start_attack()
		_buf_secondary = BUF_NEVER


func _start_dodge() -> void:
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
		if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
			_attack_side = "L"
			_start_attack()
			_buf_attack = BUF_NEVER
		elif _buf_secondary <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
			_attack_side = "R"
			_start_attack()
			_buf_secondary = BUF_NEVER


func _start_attack() -> void:
	combat_mode = true
	_action = "attack"
	_action_time = 0.0
	_hit_done = false
	_miss_logged = false
	_last_hit = ""
	# При захвате цели доворачиваем корпус прямо к противнику перед выбросом руки.
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			var fwd: Vector3 = face[0]
			rotation.y = atan2(-fwd.x, -fwd.z)


func _attack_phase() -> String:
	if _action_time < T.ATTACK_WINDUP:
		return "замах"
	if _action_time < T.ATTACK_WINDUP + T.ATTACK_ACTIVE:
		return "удар"
	return "возврат"


func _process_attack(delta: float) -> void:
	var previous_time := _action_time
	_action_time += delta
	velocity.x = move_toward(velocity.x, 0.0, T.DECELERATION * delta)
	velocity.z = move_toward(velocity.z, 0.0, T.DECELERATION * delta)

	var active_end := T.ATTACK_WINDUP + T.ATTACK_ACTIVE
	var total := active_end + T.ATTACK_RECOVERY

	# Проверяем попадание на всём активном участке (а также если длинный кадр перескочил окно),
	# но наносим урон строго один раз за удар.
	var in_window := _action_time >= T.ATTACK_WINDUP and _action_time <= active_end
	var crossed_window := previous_time < active_end and _action_time >= T.ATTACK_WINDUP
	if not _hit_done and (in_window or crossed_window):
		if _do_hit(in_window):
			_hit_done = true
	if not _hit_done and not _miss_logged and _action_time >= active_end:
		_miss_logged = true
		_last_hit = _miss_reason()

	# Отмена восстановления уворотом (в пределах ATTACK_CANCEL_WINDOW до конца удара).
	var cancel_start := maxf(active_end, total - T.ATTACK_CANCEL_WINDOW)
	if _action_time >= cancel_start and _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return

	if _action_time >= total:
		_action = ""


func _do_hit(use_live_bone: bool) -> bool:
	_refresh_targets()
	var forward := -global_transform.basis.z
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			forward = face[0]
	var hit := HitCheck.find_hit(
		self,
		_targets,
		forward,
		T.ATTACK_REACH,
		T.ATTACK_ANGLE,
		_attack_side,
		use_live_bone
	)
	if hit.is_empty():
		return false
	var victim := hit["target"] as Node3D
	var zone_name := HitCheck.zone_label(String(hit.get("zone", "torso")))
	if victim.has_method("is_passive") and bool(victim.call("is_passive")):
		_last_hit = "%s (%s — бой ВЫКЛ, нажмите T)" % [victim.name, zone_name]
	else:
		_last_hit = "%s (%s, -%.0f)" % [victim.name, zone_name, T.ATTACK_DAMAGE]
	if victim.has_method("take_damage"):
		victim.take_damage(T.ATTACK_DAMAGE, forward)
	if is_instance_valid(rig) and rig.has_method("add_kick"):
		rig.call("add_kick", -0.8)
	return true


func _miss_reason() -> String:
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


func take_damage(amount: float, _from_dir: Vector3) -> void:
	if _invulnerable:
		_last_hit = "уворот (неуязвимость)"
		return
	combat_mode = true
	health = maxf(0.0, health - amount)
	if is_instance_valid(rig) and rig.has_method("add_kick"):
		rig.call("add_kick", 1.3)
	if character != null and character.has_method("play_hit"):
		character.play_hit()
	if health <= 0.0:
		health = T.MAX_HEALTH
		stamina = T.MAX_STAMINA
		global_position = _spawn_pos
		rotation = Vector3.ZERO
		yaw = 0.0
		_action = ""
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


func _write_debug_label() -> void:
	if label == null:
		return
	var state_text := "движение"
	if _action == "attack":
		state_text = "удар (%s): %s" % ["правая" if _attack_side == "R" else "левая", _attack_phase()]
	elif _action == "dodge":
		state_text = "уворот" + (" [i-frames]" if _invulnerable else "")

	var engine_fps := Engine.get_frames_per_second()
	var shown_fps := _fps if _fps > 0.1 else engine_fps
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var q_name: String = T.QUALITY_NAMES[clampi(T.QUALITY, 0, T.QUALITY_NAMES.size() - 1)]
	var b_name: String = T.BRIGHTNESS_NAMES[clampi(T.BRIGHTNESS, 0, T.BRIGHTNESS_NAMES.size() - 1)]
	var style_name := "селлшейдинг" if T.TOON_ENABLED else "полуреализм"
	var lock_name := String(lock.target.name) if (lock != null and lock.active()) else "нет"

	var lines := PackedStringArray([
		"FPS: %.0f  ·  кадр: %.1f мс (пик %.1f)  ·  физ: %.1f мс" % [shown_fps, _avg_ms, _worst_ms, phys_ms],
		"Видеокарта: %s" % (_gpu_name if not _gpu_name.is_empty() else "—"),
	])
	if _gpu_is_integrated:
		lines.append("[!] Встроенная графика! Выберите NVIDIA GeForce 940MX")
	lines.append("Отрисовка: %d вызовов  ·  %d примитивов" % [draws, prims])
	lines.append("Графика [F4]: %s  ·  свет [B]: %s  ·  стиль [G]: %s" % [q_name, b_name, style_name])
	lines.append("Режим [R]: %s  ·  %s  ·  захват: %s" % [stance_name(), state_text, lock_name])
	lines.append("Здоровье: %.0f/%.0f  ·  стамина: %.0f/%.0f" % [health, T.MAX_HEALTH, stamina, T.MAX_STAMINA])
	lines.append("Последний контакт: %s" % (_last_hit if not _last_hit.is_empty() else "—"))
	label.text = "\n".join(lines)
