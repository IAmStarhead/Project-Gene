## Отдельная камера от третьего лица на «пружинной руке» (SpringArm3D).
##
## Живёт в корне сцены и не наследует поворот героини:
##   • вращается мгновенно по углам yaw/pitch игрока (без задержки в кадр);
##   • плавно следует за позицией (раздельно по горизонтали и высоте — ступеньки не трясут экран);
##   • сталкивается ТОЛЬКО со статикой зала (слой 1), не цепляясь за героиню и клона;
##   • сферический зонд SpringArm3D не даёт камере заглядывать сквозь углы стен и капсул.
extends Node3D

const T := preload("res://scripts/tuning.gd")

var target: Node3D
var spring: SpringArm3D
var camera: Camera3D

var _pos_smooth := Vector3.ZERO
var _initialized := false
var _kick_deg := 0.0


func setup(follow: Node3D, init_yaw: float, pitch_deg: float) -> void:
	target = follow

	spring = SpringArm3D.new()
	spring.spring_length = T.CAMERA_DISTANCE
	spring.collision_mask = 1
	spring.margin = 0.08
	var probe := SphereShape3D.new()
	probe.radius = 0.16
	spring.shape = probe
	if is_instance_valid(follow) and follow is CollisionObject3D:
		spring.add_excluded_object((follow as CollisionObject3D).get_rid())
	add_child(spring)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 72.0
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
	_sync_angles()


func add_kick(deg_amount: float) -> void:
	## Короткий тактильный отклик камеры на удар (гаснет за ~0.12 с, не укачивает).
	_kick_deg = clampf(_kick_deg + deg_amount, -2.4, 2.4)


func _process(delta: float) -> void:
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
	_kick_deg *= exp(-20.0 * delta)
	_sync_angles()


func _sync_angles() -> void:
	var y_val: Variant = target.get("yaw")
	var p_val: Variant = target.get("pitch")
	if y_val != null:
		rotation.y = float(y_val)
	if p_val != null:
		var p_clamped := clampf(float(p_val) + _kick_deg, T.CAMERA_PITCH_MIN, T.CAMERA_PITCH_MAX)
		rotation.x = deg_to_rad(p_clamped)
