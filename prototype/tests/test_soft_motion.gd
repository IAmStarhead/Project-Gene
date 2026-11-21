## Small secondary motion: bounded, stable, local and shared with the fitted suit.
extends SceneTree
const Soft := preload("res://scripts/soft_motion.gd")
const Main := preload("res://scenes/main.tscn")
var checks := 0
var failures := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	for fps in [30, 60, 120]:
		var sim := Soft.new()
		var peak := 0.0
		for i in fps * 3:
			var t: float = float(i) / fps
			var height := .025 * sin(TAU * 2.0 * t) if t < 1.0 else 0.0
			sim.advance(1.0/fps, Vector3(0, height, 0), Vector3(0, height, 0))
			peak = maxf(peak, absf(sim.chest))
			check(absf(sim.chest) <= 1.0 and absf(sim.hip) <= 1.0, "motion stays bounded")
		check(peak > .01, "acceleration has a visible response at %d Hz" % fps)
		check(absf(sim.chest) < .002 and absf(sim.hip) < .002, "motion settles at %d Hz" % fps)
		sim.advance(1.0/fps, Vector3(0, 20, 0), Vector3(0, 20, 0))
		check(sim.chest == 0 and sim.hip == 0, "teleport resets")
		sim.advance(.2, Vector3.ZERO, Vector3.ZERO)
		check(sim.chest == 0 and sim.hip == 0, "long frame resets")
	var main := Main.instantiate()
	root.add_child(main)
	for character in [main.player.character, main.clone.character, main.cut_manikin.character]:
		var a = character.appearance
		check(character.skeleton.find_bone("chest") >= 0 and character.skeleton.find_bone("hips") >= 0, "driver bones exist")
		for mesh_node in [a.body, a.suit]:
			check(mesh_node.mesh.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED, "absolute targets preserve normals in Compatibility")
			check(mesh_node.find_blend_shape_by_name("SoftChestUp") >= 0 and mesh_node.find_blend_shape_by_name("SoftHipsUp") >= 0, "both meshes have shapes")
			if mesh_node == a.body:
				var arrays: Array = mesh_node.mesh.surface_get_arrays(0)
				var target: Array = mesh_node.mesh.surface_get_blend_shape_arrays(0)[mesh_node.find_blend_shape_by_name("RelaxedHands")]
				var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var hand_normals: PackedVector3Array = target[Mesh.ARRAY_NORMAL]
				var worst := 0.0
				for i in points.size():
					if points[i].y < .59:
						worst = maxf(worst, normals[i].distance_to(hand_normals[i]))
				check(worst < .0001, "opening hands does not modify leg normals")
			for shape in ["SoftChestUp", "SoftChestDown", "SoftHipsUp", "SoftHipsDown"]:
				var idx: int = mesh_node.find_blend_shape_by_name(shape)
				var magnitudes := 0.0
				for s in mesh_node.mesh.get_surface_count():
					var blends: Array = mesh_node.mesh.surface_get_blend_shape_arrays(s)[idx]
					var verts: PackedVector3Array = blends[Mesh.ARRAY_VERTEX]
					var arrays: Array = mesh_node.mesh.surface_get_arrays(s)
					var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var base_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
					var shape_normals: PackedVector3Array = blends[Mesh.ARRAY_NORMAL]
					var worst_normal := 0.0
					for i in verts.size():
						magnitudes = maxf(magnitudes, (verts[i] - base[i]).length())
						worst_normal = maxf(worst_normal, shape_normals[i].distance_to(base_normals[i]))
					check(worst_normal < .0001, "secondary shape preserves surface normals everywhere")
				check(magnitudes > .0001 and magnitudes <= .00801, "%s mask active and small: %f" % [shape, magnitudes])
		a.reset_soft_motion()
		a.update_soft_motion(1.0/60)
		character.position.y += .01
		a.update_soft_motion(1.0/60)
		var cb: int = a.body.find_blend_shape_by_name("SoftChestUp")
		var cs: int = a.suit.find_blend_shape_by_name("SoftChestUp")
		var db: int = a.body.find_blend_shape_by_name("SoftChestDown")
		var ds: int = a.suit.find_blend_shape_by_name("SoftChestDown")
		check(a.body.get_blend_shape_value(cb) + a.body.get_blend_shape_value(db) > .001, "actual actor movement drives chest")
		check(is_equal_approx(a.body.get_blend_shape_value(cb), a.suit.get_blend_shape_value(cs)) and is_equal_approx(a.body.get_blend_shape_value(db), a.suit.get_blend_shape_value(ds)), "skin and outfit use same values")
		a.soft_motion.chest = -0.5
		a._apply_soft_motion()
		check(a.body.get_blend_shape_value(cb) == 0.0 and a.suit.get_blend_shape_value(cs) == 0.0
			and is_equal_approx(a.body.get_blend_shape_value(a.body.find_blend_shape_by_name("SoftChestDown")), .25)
			and is_equal_approx(a.suit.get_blend_shape_value(a.suit.find_blend_shape_by_name("SoftChestDown")), .25), "negative response uses positive down-target weights")
		a.reset_soft_motion()
		check(a.body.get_blend_shape_value(cb) == 0 and a.suit.get_blend_shape_value(cs) == 0, "reset clears both")
	# Exercise the actual per-physics-tick animation entry point, not just the spring.
	for character in [main.player.character, main.clone.character]:
		character.reset_motion(false)
		var a = character.appearance
		var peak := 0.0
		for i in 120:
			character.position.y = .025 * sin(TAU * 2.0 * i / 60.0)
			character.update_motion(1.0/60.0, Vector3(0, 0, 2), "", 0.0, "R",
				{"grounded": true, "combat": false, "distance": 2.0/60.0})
			peak = maxf(peak, absf(a.soft_motion.chest))
		check(peak > .01, "runtime animation updates secondary motion")
		character.reset_motion(false)
		check(a.soft_motion.chest == 0 and a.soft_motion.hip == 0, "animation reset clears secondary motion")
	main.free()
	await process_frame
	print("Secondary motion suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
