## Floor appearance settings only; headless does not validate rendered reflections.
extends SceneTree
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func _run() -> void:
	var old_quality: int = T.QUALITY
	var old_brightness: int = T.BRIGHTNESS
	var room = load("res://scenes/room.tscn").instantiate()
	root.add_child(room)
	await process_frame
	var mat: StandardMaterial3D = room._floor_mat
	check(mat != null and is_equal_approx(mat.metallic, 0.0), "floor remains a non-metal")
	check(is_equal_approx(mat.roughness, .20) and is_equal_approx(mat.metallic_specular, .72),
		"finish has the chosen PBR roughness and reflectivity")
	check(mat.clearcoat_enabled and is_equal_approx(mat.clearcoat, .24), "thin topcoat enabled")
	check(room._probe.update_mode == ReflectionProbe.UPDATE_ONCE and room._probe.cull_mask == 1,
		"probe captures world once and excludes character layer")
	check(is_equal_approx(room._probe.intensity, .75), "static environment reflection intensity")
	for quality in [0, 1, 2]:
		T.QUALITY = quality
		room.apply_quality()
		check(room._floor_mat == mat and is_equal_approx(mat.roughness, .20),
			"quality %d preserves the floor material" % quality)
		check(is_equal_approx(room._probe.intensity, .75), "quality %d preserves probe tuning" % quality)
		if quality == 0:
			check(not room._probe.visible, "low quality keeps probe disabled")
	T.BRIGHTNESS = 0
	room.rebuild_lighting()
	check(room._floor_mat == mat and mat.clearcoat_enabled, "lighting switch keeps floor finish")
	T.QUALITY = old_quality
	T.BRIGHTNESS = old_brightness
	room.queue_free()
	await process_frame
	print("Floor finish suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
