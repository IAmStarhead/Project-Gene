## Prepared, fixed training cuts. Partitions are made once from the mannequin's
## existing meshes on setup, never by slicing geometry at the moment of a hit.
## This is a prototype: boundaries follow original triangles, not closed cuts.
extends RefCounted

const BONE_GROUPS := {
	"upper_arm.L": 1, "forearm.L": 1, "hand.L": 1,
	"upper_arm.R": 2, "forearm.R": 2, "hand.R": 2,
	"thigh.L": 3, "shin.L": 3, "foot.L": 3, "toe.L": 3,
	"thigh.R": 4, "shin.R": 4, "foot.R": 4, "toe.R": 4,
}

static var _cache: Dictionary = {}


static func prepare(source: Mesh, skin: Skin) -> Array:
	var key := source.get_instance_id()
	if _cache.has(key):
		return _cache[key]
	var result: Array = []
	for i in 5:
		var mesh := ArrayMesh.new()
		for b in source.get_blend_shape_count():
			mesh.add_blend_shape(source.get_blend_shape_name(b))
		mesh.blend_shape_mode = source.blend_shape_mode
		result.append(mesh)
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var original: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var groups := [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
		for i in range(0, original.size(), 3):
			var score := [0.0, 0.0, 0.0, 0.0, 0.0]
			for vertex in [original[i], original[i + 1], original[i + 2]]:
				for influence in 4:
					var bind := bones[vertex * 4 + influence]
					var name := String(skin.get_bind_name(bind))
					var group: int = BONE_GROUPS.get(name, 0)
					if (group == 1 or group == 2) and positions[vertex].y > 1.30:
						group = 0
					if (group == 3 or group == 4) and positions[vertex].y > .76:
						group = 0
					score[group] += weights[vertex * 4 + influence]
			var group := 0
			for candidate in range(1, 5):
				if score[candidate] > score[group]:
					group = candidate
			groups[group].append_array(original.slice(i, i + 3))
		for group in 5:
			if groups[group].is_empty():
				continue
			var compact := _compact_surface(arrays, source.surface_get_blend_shape_arrays(surface), groups[group])
			result[group].add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, compact[0], compact[1])
			result[group].surface_set_material(result[group].get_surface_count() - 1, source.surface_get_material(surface))
	_cache[key] = result
	return result


## Share no unreferenced vertices between pieces. In particular, do not send
## five copies of the whole body buffer to the GPU on the target laptop.
static func _compact_surface(arrays: Array, blends: Array, indices: PackedInt32Array) -> Array:
	var vertex_count: int = arrays[Mesh.ARRAY_VERTEX].size()
	var lookup := PackedInt32Array()
	lookup.resize(vertex_count)
	lookup.fill(-1)
	var used := PackedInt32Array()
	var remapped := PackedInt32Array()
	for old in indices:
		if lookup[old] == -1:
			lookup[old] = used.size()
			used.append(old)
		remapped.append(lookup[old])
	var compact := _remap_attributes(arrays, used, vertex_count)
	compact[Mesh.ARRAY_INDEX] = remapped
	var compact_blends: Array[Array] = []
	for blend in blends:
		compact_blends.append(_remap_attributes(blend, used, vertex_count))
	return [compact, compact_blends]


static func _remap_attributes(source: Array, used: PackedInt32Array, vertex_count: int) -> Array:
	var result: Array = []
	result.resize(Mesh.ARRAY_MAX)
	for slot in range(Mesh.ARRAY_MAX):
		if slot == Mesh.ARRAY_INDEX or source[slot] == null:
			continue
		var values: Variant = source[slot]
		var stride: int = values.size() / vertex_count
		var subset: Variant = values.slice(0, 0)
		for old in used:
			subset.append_array(values.slice(old * stride, (old + 1) * stride))
		result[slot] = subset
	return result


## Freeze only the referenced vertices into world-space at the current pose.
## Called on an actual sever, not per frame; the source skin stays untouched.
static func freeze_mesh(source: MeshInstance3D, skeleton: Skeleton3D, origin: Vector3) -> ArrayMesh:
	var output := ArrayMesh.new()
	var skin := source.skin
	var transforms: Array[Transform3D] = []
	for bind in skin.get_bind_count():
		var bone := skeleton.find_bone(skin.get_bind_name(bind))
		transforms.append(skeleton.global_transform * skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(bind))
	for surface in source.mesh.get_surface_count():
		var a := source.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var blends := source.mesh.surface_get_blend_shape_arrays(surface)
		# The mannequin's hands use a relative blend shape. Freeze the same
		# visible hand rather than reverting to the source's closed fist.
		for blend_index in blends.size():
			var amount := source.get_blend_shape_value(blend_index)
			if is_zero_approx(amount):
				continue
			var blend: Array = blends[blend_index]
			var vertex_delta: PackedVector3Array = blend[Mesh.ARRAY_VERTEX]
			var normal_delta: PackedVector3Array = blend[Mesh.ARRAY_NORMAL]
			for i in vertices.size():
				vertices[i] += vertex_delta[i] * amount
				if not normal_delta.is_empty():
					normals[i] += normal_delta[i] * amount
		var used := PackedByteArray()
		used.resize(vertices.size())
		for index in indices:
			used[index] = 1
		for index in vertices.size():
			if not used[index]:
				continue
			var point := Vector3.ZERO
			var normal := Vector3.ZERO
			for k in 4:
				var w := weights[index * 4 + k]
				if w > 0:
					var t := transforms[bones[index * 4 + k]]
					point += (t * vertices[index]) * w
					normal += (t.basis * normals[index]) * w
			vertices[index] = point - origin
			normals[index] = normal.normalized()
		a[Mesh.ARRAY_VERTEX] = vertices
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_BONES] = null
		a[Mesh.ARRAY_WEIGHTS] = null
		# Tangents in the source are in bind space; omit them from this rough
		# untextured prototype rather than leave an incorrect skinned basis.
		a[Mesh.ARRAY_TANGENT] = null
		output.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		output.surface_set_material(output.get_surface_count() - 1, source.mesh.surface_get_material(surface))
	return output
