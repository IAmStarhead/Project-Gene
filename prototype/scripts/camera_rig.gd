## Отдельная камера от третьего лица на «пружинной руке» (SpringArm3D).
##
## Живёт в корне сцены и не наследует поворот героини:
##   • быстро и плавно доворачивает визуальные углы к yaw/pitch игрока;
##   • плавно следует за позицией (раздельно по горизонтали и высоте — ступеньки не трясут экран);
##   • сталкивается ТОЛЬКО со статикой зала (слой 1), не цепляясь за героиню и клона;
##   • сферический зонд SpringArm3D не даёт камере заглядывать сквозь углы стен и капсул.
extends Node3D

const T := preload("res://scripts/tuning.gd")

const HIDE_HERO_DIST := 0.54
const SHOW_HERO_DIST := 0.64

var target: Node3D
var spring: SpringArm3D
var shoulder_probe: ShapeCast3D
var camera: Camera3D

var _pos_smooth := Vector3.ZERO
var _initialized := false
var _kick_deg := 0.0
var _hero_hidden := false
var _last_frame_usec := -1


func setup(follow: Node3D, init_yaw: float, pitch_deg: float) -> void:
	target = follow

	var probe := SphereShape3D.new()
	probe.radius = 0.16
	# The spring protects the backwards segment. A separate sweep protects
	# the sideways shoulder segment so its origin cannot cross a nearby wall.
	shoulder_probe = ShapeCast3D.new()
	shoulder_probe.shape = probe
	shoulder_probe.target_position = Vector3(T.CAMERA_SHOULDER, 0, 0)
	shoulder_probe.collision_mask = 1
	shoulder_probe.margin = 0.04
	shoulder_probe.enabled = false
	add_child(shoulder_probe)
	spring = SpringArm3D.new()
	spring.spring_length = T.CAMERA_DISTANCE
	spring.position.x = T.CAMERA_SHOULDER
	spring.collision_mask = 1
	spring.margin = 0.08
	spring.shape = probe
	if is_instance_valid(follow) and follow is CollisionObject3D:
		spring.add_excluded_object((follow as CollisionObject3D).get_rid())
		shoulder_probe.add_exception(follow as CollisionObject3D)
	add_child(spring)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 68.0
	camera.near = 0.08
	camera.far = 64.0
	spring.add_child(camera)

	rotation = Vector3(deg_to_rad(pitch_deg), init_yaw, 0.0)
	_initialized = false


func snap_now() -> void:
	if not is_instance_valid(target):
		return
	var want := target.global_position + Vector3(0.0, T.CAMERA_HEIGHT, 0.0)
	_pos_smooth = want
	global_position = want
	_initialized = true
	_sync_angles(0.0, true)
	_last_frame_usec = -1


func add_kick(deg_amount: float) -> void:
	## Короткий тактильный отклик камеры на удар (гаснет за ~0.12 с, не укачивает).
	if T.CAMERA_DYNAMIC:
		_kick_deg = clampf(_kick_deg + deg_amount, -1.2, 1.2)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target) or shoulder_probe == null:
		return
	shoulder_probe.force_shapecast_update()
	var fraction := shoulder_probe.get_closest_collision_safe_fraction() if shoulder_probe.is_colliding() else 1.0
	var safe_offset := T.CAMERA_SHOULDER * clampf(fraction, 0.0, 1.0)
	# Retreat immediately for safety; gently move out again when clear.
	if absf(safe_offset) < absf(spring.position.x):
		spring.position.x = safe_offset
	else:
		spring.position.x = lerpf(spring.position.x, safe_offset, 1.0 - exp(-12.0 * delta))


func _process(delta: float) -> void:
	# At very low FPS Godot may cap process delta when physics steps are
	# capped. Use monotonic real time for presentation only, not movement.
	_advance_camera(_camera_frame_delta(Time.get_ticks_usec(), delta))


func _camera_frame_delta(now_usec: int, fallback: float) -> float:
	var elapsed := clampf(fallback, 0.0, .25)
	if _last_frame_usec >= 0 and now_usec >= _last_frame_usec:
		elapsed = clampf(float(now_usec - _last_frame_usec) / 1000000.0, 0.0, .25)
	_last_frame_usec = now_usec
	return elapsed


func _advance_camera(delta: float) -> void:
	if not is_instance_valid(target):
		return

	var want := target.global_position + Vector3(0.0, T.CAMERA_HEIGHT, 0.0)
	if not _initialized or _pos_smooth.distance_squared_to(want) > 36.0:
		_pos_smooth = want
		_initialized = true
	else:
		var kh := 1.0 - exp(-T.CAMERA_FOLLOW_SPEED * delta)
		var ky := 1.0 - exp(-T.CAMERA_FOLLOW_SPEED_Y * delta)
		_pos_smooth.x = lerpf(_pos_smooth.x, want.x, kh)
		_pos_smooth.z = lerpf(_pos_smooth.z, want.z, kh)
		_pos_smooth.y = lerpf(_pos_smooth.y, want.y, ky)

	global_position = _pos_smooth
	# A small speed-dependent pullback and FOV keep a close idle framing while
	# showing more of the room in a sprint. Input and movement remain unfiltered.
	var speed := 0.0
	if target is CharacterBody3D:
		var v: Vector3 = (target as CharacterBody3D).velocity
		speed = Vector2(v.x, v.z).length()
	var motion := clampf(speed / T.RUN_SPEED, 0.0, 1.0) if T.CAMERA_DYNAMIC else 0.0
	var smoothing := 1.0 - exp(-3.5 * delta)
	spring.spring_length = lerpf(spring.spring_length, T.CAMERA_DISTANCE + 0.30 * motion, smoothing)
	camera.fov = lerpf(camera.fov, 68.0 + 4.0 * motion, smoothing)
	if not T.CAMERA_DYNAMIC:
		_kick_deg = 0.0
	_kick_deg *= exp(-20.0 * delta)
	_sync_angles(delta)
	_update_near_hide()


func _exit_tree() -> void:
	if _hero_hidden:
		_set_hero_visible(true)


func _update_near_hide() -> void:
	# Если стена или колонна прижала камеру вплотную к голове, аккуратно скрываем меш героини,
	# чтобы камера никогда не показывала череп, глазные яблоки и рот изнутри.
	if camera == null or DisplayServer.get_name() == "headless":
		return
	var head_pos: Vector3 = target.global_position + Vector3(0.0, 1.48, 0.0)
	var dist: float = camera.global_position.distance_to(head_pos)
	if not _hero_hidden and dist < HIDE_HERO_DIST:
		_hero_hidden = true
		_set_hero_visible(false)
	elif _hero_hidden and dist >= SHOW_HERO_DIST:
		_hero_hidden = false
		_set_hero_visible(true)


func _set_hero_visible(vis: bool) -> void:
	if not is_instance_valid(target):
		return
	var ch: Node3D = target.get_node_or_null("Character") as Node3D
	if ch != null:
		ch.visible = vis


func _sync_angles(delta: float, immediate: bool = false) -> void:
	var y_val: Variant = target.get("yaw")
	var p_val: Variant = target.get("pitch")
	var weight := 1.0 if immediate else 1.0 - exp(-T.CAMERA_TURN_SPEED * maxf(delta, 0.0))
	if y_val != null:
		# Shortest path over the -PI / PI seam, never a full revolution.
		rotation.y = lerp_angle(rotation.y, float(y_val), weight)
	if p_val != null:
		var p_clamped := clampf(float(p_val) + _kick_deg, T.CAMERA_PITCH_MIN, T.CAMERA_PITCH_MAX)
		rotation.x = lerpf(rotation.x, deg_to_rad(p_clamped), weight)
