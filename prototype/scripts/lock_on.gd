## Захват цели (lock-on) по мотивам Dark Souls 3 / Elden Ring / Sekiro:
##   • Tab или средняя кнопка мыши (СКМ) — захватить ближайшую цель в поле зрения / снять захват;
##   • колесо мыши вверх/вниз — переключить цель слева/справа на экране;
##   • учитывает преграды (не захватывает сквозь стены, мягко ждёт 0.85 с за колонной/капсулой);
##   • ведёт камеру по горизонтали и деликатно по наклону (удобно вплотную и на ступеньках);
##   • работает и по пассивному клону (для тренировки стрейфа и ударов), и в активном бою.
extends RefCounted

const T := preload("res://scripts/tuning.gd")

const RADIUS := 14.0
const BREAK_RADIUS := 15.5
const HALF_ANGLE := 65.0
const TURN_RATE := 11.0
const CAMERA_TURN_RATE := 7.5
const CAMERA_PITCH_RATE := 4.5
const OCCLUSION_GRACE := 0.85
const AIM_HEIGHT := 1.25

var target: Node3D = null
var _player: Node3D
var _occluded_time := 0.0


func setup(player: Node3D) -> void:
	_player = player


func clear() -> void:
	target = null
	_occluded_time = 0.0


func active() -> bool:
	return is_instance_valid(target) and target.is_inside_tree() and target.visible and not _is_dead(target)


func aim_point(node: Node3D = null) -> Vector3:
	var t := node if node != null else target
	if not is_instance_valid(t):
		return Vector3.ZERO
	return t.global_position + Vector3(0.0, AIM_HEIGHT, 0.0)


func update(delta: float = 0.0167) -> void:
	if target == null:
		return
	if not active():
		clear()
		return
	if _flat_distance() > BREAK_RADIUS:
		var previous := target
		clear()
		_try_acquire()
		if target == previous:
			clear()
		return
	if _has_line_of_sight(target):
		_occluded_time = 0.0
	else:
		_occluded_time += maxf(delta, 0.0)
		if _occluded_time >= OCCLUSION_GRACE:
			clear()


func handle_input(event: InputEvent) -> bool:
	if event.is_action_pressed("lock_on"):
		if active():
			clear()
		else:
			_try_acquire()
		return true
	if not active():
		return false
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle(-1)
			return true
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle(1)
			return true
	return false


func direction_to_target() -> Vector3:
	return _flat_direction() if active() else Vector3.ZERO


func facing(out: Array) -> bool:
	if not active() or not is_instance_valid(_player):
		return false
	var d := _flat_direction()
	if d.length_squared() < 0.0001:
		return false
	out.clear()
	out.append(d)
	return true


func movement(flat_input: Vector2, out: Array) -> bool:
	if not active() or not is_instance_valid(_player):
		return false
	var forward := _flat_direction()
	if forward.length_squared() < 0.0001:
		return false
	var right := forward.cross(Vector3.UP).normalized()
	var dir := right * flat_input.x - forward * flat_input.y
	out.clear()
	out.append(dir.normalized() if dir.length_squared() >= 0.0001 else Vector3.ZERO)
	return true


func camera_yaw(delta: float, current_yaw: float) -> float:
	if not active():
		return NAN
	var want := _flat_direction()
	if want.length_squared() < 0.0001:
		return NAN
	var desired := atan2(-want.x, -want.z)
	var w := 1.0 - exp(-CAMERA_TURN_RATE * delta)
	return lerp_angle(current_yaw, desired, w)


func camera_pitch(delta: float, current_pitch_deg: float) -> float:
	if not active() or not is_instance_valid(_player):
		return NAN
	var from := _player.global_position + Vector3(0.0, T.CAMERA_HEIGHT, 0.0)
	var to := aim_point(target) - from
	var flat_dist := maxf(Vector2(to.x, to.z).length(), 1.1)
	var slope_deg := rad_to_deg(atan2(to.y, flat_dist)) - 11.0
	var desired := clampf(slope_deg, -34.0, 14.0)
	var w := 1.0 - exp(-CAMERA_PITCH_RATE * delta)
	return lerpf(current_pitch_deg, desired, w)


func _try_acquire() -> void:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return
	var cam_fwd := _camera_forward()
	var best: Node3D = null
	var best_score := INF

	for node in _player.get_tree().get_nodes_in_group("damageable"):
		if node == _player or not is_instance_valid(node) or not (node is Node3D):
			continue
		var cand := node as Node3D
		if not cand.visible or _is_dead(cand):
			continue
		var to := cand.global_position - _player.global_position
		to.y = 0.0
		var dist := to.length()
		if dist > RADIUS or dist < 0.05:
			continue
		var angle := rad_to_deg(cam_fwd.angle_to(to / dist))
		if angle > HALF_ANGLE:
			continue
		if not _has_line_of_sight(cand):
			continue
		# Приоритет — цель ближе к центру экрана, затем — ближайшая по расстоянию.
		var score := angle * 1.15 + dist * 2.2
		if score < best_score:
			best_score = score
			best = cand

	target = best
	_occluded_time = 0.0


## Переключение колесом мыши строго слева направо в координатах экрана камеры.
func _cycle(step: int) -> void:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return
	var cam_fwd := _camera_forward()
	var cam_right := cam_fwd.cross(Vector3.UP).normalized()
	var items: Array = []

	for node in _player.get_tree().get_nodes_in_group("damageable"):
		if node == _player or not is_instance_valid(node) or not (node is Node3D):
			continue
		var cand := node as Node3D
		if not cand.visible or _is_dead(cand):
			continue
		var to := cand.global_position - _player.global_position
		to.y = 0.0
		var dist := to.length()
		if dist > RADIUS or dist < 0.05:
			continue
		if not _has_line_of_sight(cand):
			continue
		var dir := to / dist
		var screen_ang := atan2(cam_right.dot(dir), cam_fwd.dot(dir))
		items.append({"node": cand, "ang": screen_ang})

	if items.size() < 2:
		return
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ang"]) < float(b["ang"]))

	var cur_idx := -1
	for i in range(items.size()):
		if items[i]["node"] == target:
			cur_idx = i
			break
	var next_idx := 0 if cur_idx < 0 else posmod(cur_idx + step, items.size())
	target = items[next_idx]["node"] as Node3D
	_occluded_time = 0.0


func _camera_forward() -> Vector3:
	var f := -_player.global_transform.basis.z
	if _player.has_method("aim_forward"):
		f = _player.call("aim_forward") as Vector3
	f.y = 0.0
	return f.normalized() if f.length_squared() > 0.0001 else Vector3.FORWARD


func _has_line_of_sight(cand: Node3D) -> bool:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return true
	var w3d := _player.get_world_3d()
	if w3d == null or w3d.direct_space_state == null:
		return true
	var from := _player.global_position + Vector3(0.0, 1.4, 0.0)
	var to := aim_point(cand)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return w3d.direct_space_state.intersect_ray(query).is_empty()


func _flat_direction() -> Vector3:
	if not is_instance_valid(target) or not is_instance_valid(_player):
		return Vector3.ZERO
	var d := target.global_position - _player.global_position
	d.y = 0.0
	return d.normalized() if d.length_squared() > 0.0001 else Vector3.ZERO


func _flat_distance() -> float:
	if not is_instance_valid(target) or not is_instance_valid(_player):
		return INF
	var d := target.global_position - _player.global_position
	d.y = 0.0
	return d.length()


func _is_dead(node: Node) -> bool:
	if node.has_method("is_alive"):
		return not bool(node.call("is_alive"))
	var v: Variant = node.get("health")
	if v != null and float(v) <= 0.0:
		return true
	return false
