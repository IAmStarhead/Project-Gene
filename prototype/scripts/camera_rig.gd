## Отдельная камера от третьего лица.
##
## Живёт в КОРНЕ сцены, а не внутри героини — это принципиально. Если камера
## внутри тела, а тело поворачивается к направлению движения, получается
## порочный круг: повернулся -> повернулась камера -> изменилось направление
## «вперёд». Именно из-за этого управление ощущалось как в играх 1990-х.
##
## Здесь камера:
##   - поворачивается ТОЛЬКО мышью;
##   - следует за героиней по позиции с небольшим отставанием;
##   - не наследует поворот героини;
##   - приближается, если между ней и героиней стена (SpringArm3D).
extends Node3D

const T := preload("res://scripts/tuning.gd")

var target: Node3D
var spring: SpringArm3D

var _pos_smooth := Vector3.ZERO
var _initialized := false


## Вызывается игроком при создании. yaw/pitch — начальные углы камеры.
func setup(follow: Node3D, _yaw: float, pitch_deg: float) -> void:
	target = follow

	spring = SpringArm3D.new()
	spring.spring_length = T.CAMERA_DISTANCE
	spring.margin = 0.2
	# камера не должна цепляться за саму героиню
	spring.add_excluded_object(follow.get_rid())
	add_child(spring)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.current = true
	cam.fov = 78.0
	cam.far = 120.0
	spring.add_child(cam)

	rotation.x = deg_to_rad(pitch_deg)
	_initialized = false


func _process(delta: float) -> void:
	if not is_instance_valid(target):
		return

	var want := target.global_position + Vector3(0.0, T.CAMERA_HEIGHT, 0.0)
	if not _initialized:
		# первый кадр: встаём на место без «подлёта» из нуля координат
		_pos_smooth = want
		_initialized = true
	else:
		var k := 1.0 - exp(-T.CAMERA_FOLLOW_SPEED * delta)
		_pos_smooth = _pos_smooth.lerp(want, k)

	global_position = _pos_smooth
