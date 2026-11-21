## Small, bounded secondary visual motion, not gameplay collision or soft-body simulation.
extends RefCounted

const CHEST_MAX := .004 # metres
const HIP_MAX := .003
const STEP := 1.0 / 120.0

var initialized := false
var previous_chest := Vector3.ZERO
var previous_hip := Vector3.ZERO
var previous_chest_velocity := 0.0
var previous_hip_velocity := 0.0
var chest := 0.0
var hip := 0.0
var chest_speed := 0.0
var hip_speed := 0.0


static func _falloff(distance: float) -> float:
	var t := clampf(1.0 - distance, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func shape_delta(p: Vector3, is_chest: bool) -> Vector3:
	# Smooth symmetric local regions shared by body and fitted outfit. The
	# max displacement is deliberately millimetres, not a loose soft body.
	var center := Vector3(.09, 1.21, .15) if is_chest else Vector3(.065, .91, -.075)
	var radius := Vector3(.105, .115, .105) if is_chest else Vector3(.14, .115, .085)
	var d := Vector3((absf(p.x)-center.x)/radius.x, (p.y-center.y)/radius.y, (p.z-center.z)/radius.z)
	return Vector3.UP * _falloff(d.length()) * (CHEST_MAX if is_chest else HIP_MAX)


func reset() -> void:
	initialized = false
	previous_chest_velocity = 0.0
	previous_hip_velocity = 0.0
	chest = 0.0
	hip = 0.0
	chest_speed = 0.0
	hip_speed = 0.0


func advance(delta: float, chest_position: Vector3, hip_position: Vector3) -> void:
	if delta <= 0.0 or not chest_position.is_finite() or not hip_position.is_finite():
		return
	if not initialized or delta > .10 or chest_position.distance_to(previous_chest) > .6 or hip_position.distance_to(previous_hip) > .6:
		reset()
		initialized = true
		previous_chest = chest_position
		previous_hip = hip_position
		return
	var cv := (chest_position.y - previous_chest.y) / delta
	var hv := (hip_position.y - previous_hip.y) / delta
	var chest_target := clampf(-(cv-previous_chest_velocity) / delta / 18.0, -1.0, 1.0)
	var hip_target := clampf(-(hv-previous_hip_velocity) / delta / 22.0, -1.0, 1.0)
	previous_chest = chest_position
	previous_hip = hip_position
	previous_chest_velocity = cv
	previous_hip_velocity = hv
	var remaining := delta
	while remaining > 0.000001:
		var dt := minf(STEP, remaining)
		# Near-critical damping: quickly settles, no prolonged jelly oscillation.
		chest_speed += ((chest_target-chest)*100.0 - chest_speed*20.0) * dt
		hip_speed += ((hip_target-hip)*144.0 - hip_speed*24.0) * dt
		chest = clampf(chest + chest_speed*dt, -1.0, 1.0)
		hip = clampf(hip + hip_speed*dt, -1.0, 1.0)
		remaining -= dt
