## Reproducible cloth/upper-body review of every actual native library clip.
## GEN_GARMENT_OUTPUT=/absolute/file.json godot --headless --path prototype \
##     --script res://tests/record_garment.gd
## Diagnostic data, NOT a GPU recording or a target-laptop FPS benchmark.
extends SceneTree

const Character := preload("res://scripts/character_anim.gd")
const FPS := 60


func vector(point: Vector3) -> Array:
	return [point.x, point.y, point.z]


func frame(character: Node3D, time: float) -> Dictionary:
	var rig: Skeleton3D = character.skeleton
	var rotations: Array = []
	for i in rig.get_bone_count():
		var q := rig.get_bone_pose_rotation(i)
		rotations.append([q.x, q.y, q.z, q.w])
	var cloth: Array = []
	for point in character.appearance.cloth_vertices():
		cloth.append(vector(point))
	return {"time": time, "rotations": rotations,
		"hips": vector(rig.get_bone_pose_position(rig.find_bone("hips"))),
		"hand_open": character.appearance.hand_open, "cloth": cloth,
		"cloth_gap": character.appearance.collision_gap()}


func _initialize() -> void:
	call_deferred("_record")


func _record() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var character := Node3D.new()
	character.set_script(Character)
	world.add_child(character)
	var result := {"fps": FPS, "source": "Godot seek_clip + actual appearance update, all 18 clips",
		"native_version": Engine.get_version_info()["string"],
		"appearance_sha256": FileAccess.get_sha256("res://assets/heroine/appearance/lab_uniform.json"),
		"motion_set_sha256": FileAccess.get_sha256("res://assets/heroine/animations/motion_set.json"),
		"takes": {}, "seeks": {}}
	var timings: Array[int] = []
	for name in character.MOTIONS.get_animation_list():
		var duration: float = character.clip_duration(name)
		var count := ceili(duration*FPS)
		character.seek_clip(name, 0.0)
		# Warm one full cycle, exactly as looping the native animation showcase.
		for i in count:
			character.seek_clip(name, duration*float(i)/count, 1.0/FPS)
		var frames: Array = []
		for i in count:
			var time := duration*float(i)/count
			character.seek_clip(name, time, -1.0)
			var started := Time.get_ticks_usec()
			character.appearance.update_pose(1.0/FPS)
			timings.append(Time.get_ticks_usec()-started)
			frames.append(frame(character, time))
		result["takes"][name] = frames
		print("Garment clip %s: %d native frames" % [name, count])
	for item in [["cross-frame10", "attack_right", .163], ["dodge-frame5", "dodge", .090],
			["sprint-frame8", "sprint_relaxed", .136], ["jog-frame23", "run_relaxed", .388]]:
		character.seek_clip(item[1], item[2])
		result["seeks"][item[0]] = frame(character, item[2])
	timings.sort()
	result["profile"] = {"samples": timings.size(), "median_us": timings[timings.size()/2],
		"p95_us": timings[int(timings.size()*.95)], "max_us": timings[-1],
		"note": "headless sandbox CPU only, no GPU/FPS claim"}
	print("Garment update profile (sandbox CPU, not GPU FPS): ", result["profile"])
	var path := OS.get_environment("GEN_GARMENT_OUTPUT")
	if path.is_empty():
		path = "user://garment-trace.json"
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write garment trace: " + path)
		quit(1)
		return
	output.store_string(JSON.stringify(result))
	output.close()
	world.free()
	print("GEN recorded %d clips and %d exact feedback seeks: %s" % [
		result["takes"].size(), result["seeks"].size(), ProjectSettings.globalize_path(path)])
	quit()
