## Compares the real cached idle appearance against the full solver, at identical poses.
## CPU-only check; not a rendered visual review or target-machine FPS test.
extends SceneTree

const Character := preload("res://scripts/character_anim.gd")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: "+message)
func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	T.OUTFIT = "dress" # Exercise the retained solver although dress is disabled in UI.
	var a := Node3D.new()
	var b := Node3D.new()
	a.set_script(Character)
	b.set_script(Character)
	world.add_child(a)
	world.add_child(b)
	a.reset_motion(false)
	b.reset_motion(false)
	var max_distance := 0.0
	var worst_gap := INF
	var hits := 0
	var previous_goals := PackedVector3Array()
	var same_pose := true
	for i in 240:
		a.update_motion(1.0/60, Vector3.ZERO, "", 0, "R", {"grounded":true, "combat":false, "distance":0.0})
		b.update_motion(1.0/60, Vector3.ZERO, "", 0, "R", {"grounded":true, "combat":false, "distance":0.0, "cache_idle_cloth":false})
		var va: PackedVector3Array = a.appearance.cloth_vertices()
		var vb: PackedVector3Array = b.appearance.cloth_vertices()
		for j in va.size():
			max_distance = maxf(max_distance, va[j].distance_to(vb[j]))
		worst_gap = minf(worst_gap, a.appearance.collision_gap())
		if not previous_goals.is_empty() and previous_goals == a.appearance._idle_cache_goals:
			hits += 1
		previous_goals = a.appearance._idle_cache_goals.duplicate()
		for bone in a.skeleton.get_bone_count():
			var qa: Quaternion = a.skeleton.get_bone_pose_rotation(bone)
			var qb: Quaternion = b.skeleton.get_bone_pose_rotation(bone)
			same_pose = same_pose and absf(qa.dot(qb)) > .999999
	check(hits > 100, "idle cache reuses prior goal solutions")
	check(same_pose, "cached cloth never changes skeleton animation")
	check(max_distance < .002, "sampled cached idle vertices remain within 2 mm of full solver")
	check(worst_gap > -.0001, "current collision envelope remains clear during cached idle")
	# Moving and attacks must discard the idle cache and run the full solver.
	a.update_motion(1.0/60, Vector3(0,0,2.9), "", 0, "R", {"grounded":true, "distance":2.9/60})
	check(a.appearance._idle_cache_capsules.is_empty(), "movement invalidates the idle cloth cache")
	a.update_motion(1.0/60, Vector3.ZERO, "attack", .2, "R", {"grounded":true, "distance":0.0})
	check(a.appearance._idle_cache_capsules.is_empty(), "attack uses the full solver")
	a.appearance.set_outfit("suit")
	a.appearance.set_outfit("dress")
	check(a.appearance._idle_cache_capsules.is_empty(), "wardrobe round trip resets the cache")
	print("Idle cache comparison: max displayed vertex difference %.3f mm, min capsule gap %.3f mm" % [max_distance*1000, worst_gap*1000])
	world.free()
	print("GEN idle-cache suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
