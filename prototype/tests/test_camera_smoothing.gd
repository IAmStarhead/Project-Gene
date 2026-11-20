## Deterministic camera smoothing tests: no claim about actual GPU FPS.
extends SceneTree
const RigScene := preload("res://scenes/camera_rig.tscn")
const T := preload("res://scripts/tuning.gd")

class TestTarget extends Node3D:
	var yaw := 0.0
	var pitch := -13.0

var checks := 0
var failures := 0
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func _run() -> void:
	var target := TestTarget.new()
	root.add_child(target)
	var rig = RigScene.instantiate()
	rig.setup(target, target.yaw, target.pitch)
	root.add_child(rig)
	rig.set_process(false)
	rig.snap_now()
	target.yaw = 1.0
	target.pitch = 15.0
	rig._advance_camera(1.0 / 60.0)
	check(rig.rotation.y > 0.35 and rig.rotation.y < 0.5, "turn starts promptly without an instant jump")
	check(rig.rotation.x > deg_to_rad(-13) and rig.rotation.x < deg_to_rad(15), "pitch is also smoothed")
	check(target.yaw == 1.0 and target.pitch == 15.0, "input angles are not filtered or overwritten")
	for i in 5:
		rig._advance_camera(1.0 / 60.0)
	check(absf(rig.rotation.y - target.yaw) < .05, "camera reaches within five percent in 100 ms")
	# The same real elapsed time gives the same result at 30 and 120 FPS.
	rig.rotation.y = 0.0
	for i in 3: rig._advance_camera(1.0 / 30.0)
	var at_30: float = rig.rotation.y
	rig.rotation.y = 0.0
	for i in 12: rig._advance_camera(1.0 / 120.0)
	check(absf(at_30 - rig.rotation.y) < .0001, "turn smoothing is frame-rate independent")
	rig.rotation.y = deg_to_rad(179)
	target.yaw = deg_to_rad(-179)
	rig._advance_camera(1.0 / 60.0)
	check(absf(angle_difference(deg_to_rad(179), rig.rotation.y)) < deg_to_rad(2.0), "yaw takes short path across wrap seam")
	check(absf(angle_difference(rig.rotation.y, target.yaw)) < deg_to_rad(2.0), "yaw approaches wrapped target")
	target.pitch = 90.0
	for i in 30: rig._advance_camera(1.0 / 60.0)
	check(rig.rotation.x <= deg_to_rad(T.CAMERA_PITCH_MAX) + .00001, "pitch limit preserved")
	target.yaw = -.7
	target.pitch = -22
	target.position = Vector3(3, 0, 4)
	rig.snap_now()
	check(absf(angle_difference(rig.rotation.y, target.yaw)) < .00001 and absf(rig.rotation.x - deg_to_rad(target.pitch)) < .00001,
		"snap immediately resets angles")
	check(rig.global_position.distance_to(target.global_position + Vector3.UP * T.CAMERA_HEIGHT) < .00001,
		"snap immediately resets follow position")
	check(absf(rig._camera_frame_delta(1000000, .016) - .016) < .0001, "first frame uses supplied delta")
	check(absf(rig._camera_frame_delta(1142857, .033) - .142857) < .00001,
		"low FPS uses wall time rather than capped physics delta")
	check(is_equal_approx(rig._camera_frame_delta(4000000, .016), .25), "long pause is clamped")
	rig.queue_free()
	target.queue_free()
	await process_frame
	print("Camera smoothing suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
