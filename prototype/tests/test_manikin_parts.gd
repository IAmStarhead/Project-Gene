## Fixed mannequin partition invariants; not a visual or performance approval.
extends SceneTree
const Partition := preload("res://scripts/manikin_parts.gd")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func triangle_key(arrays: Array, i: int) -> String:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var result := ""
	for j in 3:
		var v := indices[i + j]
		result += str(points[v]) + ":" + str(bones.slice(v * 4, v * 4 + 4)) + ":" + str(weights.slice(v * 4, v * 4 + 4)) + ";"
	return result

func _run() -> void:
	var clone = load("res://scenes/clone.tscn").instantiate()
	root.add_child(clone)
	clone.set_physics_process(false)
	clone.character.seek_clip("idle_relaxed", 0.0)
	var appearance = clone.character.appearance
	for source: MeshInstance3D in [appearance.body, appearance.gown]:
		var original: Mesh = source.mesh
		var groups := Partition.prepare(original, source.skin)
		var reference := {}
		var original_vertices := 0
		for surface in original.get_surface_count():
			var arrays := original.surface_get_arrays(surface)
			original_vertices += arrays[Mesh.ARRAY_VERTEX].size()
			for i in range(0, arrays[Mesh.ARRAY_INDEX].size(), 3):
				var key := triangle_key(arrays, i)
				reference[key] = int(reference.get(key, 0)) + 1
		var group_vertices := 0
		for mesh: ArrayMesh in groups:
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				group_vertices += arrays[Mesh.ARRAY_VERTEX].size()
				for i in range(0, arrays[Mesh.ARRAY_INDEX].size(), 3):
					var key := triangle_key(arrays, i)
					reference[key] = int(reference.get(key, 0)) - 1
		var preserved := true
		for count in reference.values():
			if count != 0:
				preserved = false
				break
		check(preserved, source.name + ": no triangle or skin influences lost or duplicated")
		check(group_vertices < original_vertices * 1.20,
			source.name + ": compact pieces do not retain five full vertex buffers")
		check(groups[1].get_surface_count() > 0 and groups[2].get_surface_count() > 0,
			source.name + ": both arms have prepared geometry")
		if source == appearance.body:
			check(groups[3].get_surface_count() > 0 and groups[4].get_surface_count() > 0,
				"both legs have prepared geometry")
			var part := MeshInstance3D.new()
			part.mesh = groups[1]
			part.skin = source.skin
			part.skeleton = source.skeleton
			source.get_parent().add_child(part)
			part.set_blend_shape_value(0, 1.0)
			var origin := Vector3(5, 2, 3)
			var frozen := Partition.freeze_mesh(part, clone.character.skeleton, origin)
			var a := part.mesh.surface_get_arrays(0)
			var out := frozen.surface_get_arrays(0)
			var delta: PackedVector3Array = part.mesh.surface_get_blend_shape_arrays(0)[0][Mesh.ARRAY_VERTEX]
			var vertices: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var points: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
			var sk: Skeleton3D = clone.character.skeleton
			var max_error := 0.0
			for j in range(0, indices.size(), maxi(1, indices.size() / 30)):
				var v := indices[j]
				var expected := Vector3.ZERO
				for k in 4:
					var bind := bones[v * 4 + k]
					var b := sk.find_bone(part.skin.get_bind_name(bind))
					var transform := sk.global_transform * sk.get_bone_global_pose(b) * part.skin.get_bind_pose(bind)
					expected += (transform * (vertices[v] + delta[v])) * weights[v * 4 + k]
				max_error = maxf(max_error, points[v].distance_to(expected - origin))
			check(max_error < .0001, "detached mesh follows current bone pose and open-hand blend")
	clone.queue_free()
	await process_frame
	var previous_outfit: String = T.OUTFIT
	T.OUTFIT = "suit"
	var mannequin = load("res://scenes/clone_manikin.tscn").instantiate()
	root.add_child(mannequin)
	await physics_frame
	check(mannequin.character.appearance.outfit == "suit" and not mannequin.character.appearance.gown.visible
		and mannequin.character.appearance.suit.visible,
		"mannequin wears the cuttable subject outfit")
	check(mannequin.sever(0, true, Vector3.FORWARD) and not mannequin.parts[0].nodes[0].visible,
		"the arm is actually removed after entering from the suit state")
	mannequin.queue_free()
	T.OUTFIT = previous_outfit
	await process_frame
	print("Manikin partition suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
