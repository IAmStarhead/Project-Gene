## Shared lab gown, body-safe lightweight skirt and relaxed hands.
## Imported GLB stays morph-free: the hand shape is added to an ArrayMesh
## AFTER import, using the source model's existing fist/correction targets.
## 112 cloth points, fixed 60 Hz steps, two constraint passes, body capsules.
extends Node3D

const DATA_PATH := "res://assets/heroine/appearance/lab_uniform.json"
const STEP := 1.0/60.0
static var _data: Dictionary = {}
static var _hand_grid: Dictionary = {}
static var _body_cache: Dictionary = {}
static var _gown_mesh: ArrayMesh

var actor: Node3D
var skeleton: Skeleton3D
var body: MeshInstance3D
var gown: MeshInstance3D
var skirt: MeshInstance3D
var hand_open := 0.0
var clone_variant := false
var collision_count := 0
var _hips := -1
var _hips_inverse_bind: Transform3D
var _rest := PackedVector3Array()
var _points := PackedVector3Array()
var _previous := PackedVector3Array()
var _edge_a := PackedInt32Array()
var _edge_b := PackedInt32Array()
var _edge_length := PackedFloat32Array()
var _edge_strength := PackedFloat32Array()
var _goals := PackedVector3Array()
var _hips_transform: Transform3D
var _hips_inverse: Transform3D
var _thickness := .018
var _max_secondary := .07
var _capsules: Array = []
var _capsule_world: Array = []
var _segments := 16
var _rings := 7
var _iterations := 2
var _accumulator := 0.0
var _last_origin := Vector3.ZERO
var _material: StandardMaterial3D
var _skirt_indices := PackedInt32Array()
var _skirt_colors := PackedColorArray()
var _skirt_mesh := ArrayMesh.new()


func install(owner_actor: Node3D, rig: Skeleton3D, model: Node) -> void:
	actor = owner_actor
	skeleton = rig
	if _data.is_empty():
		_data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		_build_hand_grid()
	body = _find_body(model)
	if body == null:
		push_error("Lab uniform: imported body mesh not found")
		return
	var key := body.mesh.get_instance_id()
	if not _body_cache.has(key):
		_body_cache[key] = _body_with_relaxed_hands(body.mesh)
	body.mesh = _body_cache[key]
	body.custom_aabb = AABB(Vector3(-1, -.3, -1), Vector3(2, 2.6, 2.3))
	if _gown_mesh == null:
		_gown_mesh = _build_gown_mesh()
	_material = StandardMaterial3D.new()
	_material.resource_name = "Laboratory textile"
	_material.vertex_color_use_as_albedo = true
	_material.roughness = .96
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	gown = MeshInstance3D.new()
	gown.name = "LabGown"
	gown.mesh = _gown_mesh
	gown.skin = body.skin
	gown.skeleton = body.skeleton
	gown.transform = body.transform
	gown.material_override = _material
	gown.set_meta("textile", true)
	body.get_parent().add_child(gown)
	gown.custom_aabb = body.custom_aabb

	skirt = MeshInstance3D.new()
	skirt.name = "LabGownSkirt"
	skirt.mesh = _skirt_mesh
	skirt.material_override = _material
	skirt.set_meta("textile", true)
	add_child(skirt)
	var cloth: Dictionary = _data["cloth"]
	_segments = int(cloth["segments"])
	_rings = int(cloth["rings"])
	_iterations = int(cloth["iterations"])
	for value in cloth["positions"]:
		_rest.append(_vector(value))
	for edge in cloth["edges"]:
		_edge_a.append(int(edge[0]))
		_edge_b.append(int(edge[1]))
		_edge_length.append(float(edge[2]))
		_edge_strength.append(float(edge[3]))
	_thickness = float(cloth["thickness"])
	_max_secondary = float(cloth["max_secondary_offset"])
	for item in cloth["capsules"]:
		_capsules.append([skeleton.find_bone(item[0]), skeleton.find_bone(item[1]), float(item[2])])
	_hips = skeleton.find_bone("hips")
	# Bind transforms come from the same source as the animation author, not
	# an assumption about Godot's imported rest normalization.
	var bind: Array = _data["hips_inverse_bind"]
	_hips_inverse_bind = Transform3D(Basis(_vector(bind[0]), _vector(bind[1]), _vector(bind[2])).transposed(), _vector(bind[3]))
	for row in range(_rings-1):
		for k in _segments:
			var a := row*_segments+k
			var b := row*_segments+(k+1)%_segments
			_skirt_indices.append_array(PackedInt32Array([a, b, a+_segments, b, b+_segments, a+_segments]))
	for i in _rest.size():
		_skirt_colors.append(Color(_data["cloth"]["binding"][0], _data["cloth"]["binding"][1], _data["cloth"]["binding"][2]) if i/_segments == _rings-1 else Color(_data["cloth"]["fabric"][0], _data["cloth"]["fabric"][1], _data["cloth"]["fabric"][2]))
	reset_cloth()


static func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _find_body(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and node.name.to_lower().contains("body"):
		return node
	for child in node.get_children():
		var found := _find_body(child)
		if found != null:
			return found
	return null


static func _grid_key(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x*1000), floori(point.y*1000), floori(point.z*1000))


static func _build_hand_grid() -> void:
	for row in _data["hands"]["rows"]:
		var key := _grid_key(Vector3(row[0], row[1], row[2]))
		if not _hand_grid.has(key):
			_hand_grid[key] = []
		_hand_grid[key].append(row)


static func _hand_row(point: Vector3, normal: Vector3) -> Array:
	if point.y < .60 or point.y > .88:
		return []
	var cell := _grid_key(point)
	var found: Array = []
	var best := .0002*.0002
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				for row in _hand_grid.get(cell+Vector3i(x, y, z), []):
					var distance := point.distance_squared_to(Vector3(row[0], row[1], row[2]))
					# Pick the matching normal on a UV seam, not another copy.
					if distance < best or (not found.is_empty() and distance < best+1e-12
							and normal.dot(Vector3(row[3], row[4], row[5])) > normal.dot(Vector3(found[3], found[4], found[5]))):
						found = row
						best = distance
	return found


static func covered(point: Vector3, bones: PackedInt32Array, weights: PackedFloat32Array,
		index: int, names: Array) -> bool:
	if point.y < .78 or point.y > 1.355:
		return false
	var axial := 0.0
	for k in 4:
		var name: String = names[bones[index*4+k]]
		if name in ["hips", "spine", "chest", "neck"] or name.begins_with("thigh."):
			axial += weights[index*4+k]
	return axial > .80


func _body_with_relaxed_hands(source: Mesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	result.add_blend_shape("RelaxedHands")
	result.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	var names: Array = []
	for i in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(i))
	var matched := 0
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var deltas := PackedVector3Array()
		var normal_deltas := PackedVector3Array()
		var hide := PackedByteArray()
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		for i in vertices.size():
			var row := _hand_row(vertices[i], normals[i])
			deltas.append(Vector3.ZERO if row.is_empty() else Vector3(row[6], row[7], row[8]))
			normal_deltas.append(Vector3.ZERO if row.is_empty() else Vector3(row[9], row[10], row[11])-normals[i])
			matched += 0 if row.is_empty() else 1
			hide.append(1 if covered(vertices[i], bones, weights, i, names) else 0)
		var old_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		for i in range(0, old_indices.size(), 3):
			if not (hide[old_indices[i]] and hide[old_indices[i+1]] and hide[old_indices[i+2]]):
				kept.append_array(old_indices.slice(i, i+3))
		arrays[Mesh.ARRAY_INDEX] = kept
		var blend: Array = []
		blend.resize(Mesh.ARRAY_MAX)
		blend[Mesh.ARRAY_VERTEX] = deltas
		blend[Mesh.ARRAY_NORMAL] = normal_deltas
		if arrays[Mesh.ARRAY_TANGENT] != null:
			var tangents := PackedFloat32Array()
			tangents.resize(vertices.size()*4)
			blend[Mesh.ARRAY_TANGENT] = tangents
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [blend])
		result.surface_set_material(surface, source.surface_get_material(surface))
	if matched < 2500:
		push_error("RelaxedHands: only %d imported hand vertices matched" % matched)
	result.set_meta("hand_vertices", matched)
	return result


static func _build_gown_mesh() -> ArrayMesh:
	var source: Dictionary = _data["gown"]
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var joints := PackedInt32Array()
	var weights := PackedFloat32Array()
	for i in source["positions"].size():
		vertices.append(_vector(source["positions"][i]))
		normals.append(_vector(source["normals"][i]))
		var rgb: Array = source["colors"][i]
		colors.append(Color(rgb[0], rgb[1], rgb[2]))
		var tex: Array = source["uv"][i]
		uv.append(Vector2(tex[0], tex[1]))
		for k in 4:
			joints.append(int(source["joints"][i][k]))
			weights.append(float(source["weights"][i][k]))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_BONES] = joints
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(source["indices"])
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func set_variant(is_clone: bool) -> void:
	clone_variant = is_clone
	_material.albedo_color = Color(.78, .87, .93) if is_clone else Color.WHITE


func set_hands(amount: float) -> void:
	hand_open = clampf(amount, 0, 1)
	if body != null:
		body.set_blend_shape_value(0, hand_open)


func reset_cloth() -> void:
	_accumulator = 0
	_last_origin = actor.global_position
	_update_colliders()
	_fit_goals()
	_points = _goals.duplicate()
	_previous = _points.duplicate()
	_upload_skirt()


func _update_colliders() -> void:
	_hips_transform = actor.global_transform*skeleton.get_bone_global_pose(_hips)*_hips_inverse_bind
	_hips_inverse = _hips_transform.affine_inverse()
	_capsule_world.clear()
	for capsule in _capsules:
		var a := actor.global_transform*skeleton.get_bone_global_pose(capsule[0]).origin
		var b := actor.global_transform*skeleton.get_bone_global_pose(capsule[1]).origin
		var axis := b-a
		_capsule_world.append([a, b, axis, axis.length_squared(), capsule[2]+_thickness])


static func _sphere_far(origin: Vector3, direction: Vector3, center: Vector3, radius: float) -> float:
	var relative := origin-center
	var along := direction.dot(relative)
	var discriminant := along*along-relative.length_squared()+radius*radius
	return -along+sqrt(discriminant) if discriminant >= 0.0 else -1.0


static func _capsule_far(origin: Vector3, direction: Vector3, capsule: Array) -> float:
	var a: Vector3 = capsule[0]
	var axis: Vector3 = capsule[2]
	var length_squared: float = capsule[3]
	var radius: float = capsule[4]
	# Cheap vertical broad phase (the ray is near-horizontal even in a dodge).
	var allowance := radius+absf(direction.y)
	if origin.y < minf(a.y, (capsule[1] as Vector3).y)-allowance or origin.y > maxf(a.y, (capsule[1] as Vector3).y)+allowance:
		return -1.0
	var relative := origin-a
	var projected_direction := axis.dot(direction)
	var projected_origin := axis.dot(relative)
	var aa := length_squared-projected_direction*projected_direction
	var bb := length_squared*direction.dot(relative)-projected_origin*projected_direction
	var cc := length_squared*(relative.length_squared()-radius*radius)-projected_origin*projected_origin
	var determinant := bb*bb-aa*cc
	var result := maxf(_sphere_far(origin, direction, a, radius),
		_sphere_far(origin, direction, capsule[1], radius))
	if aa > .000001 and determinant >= 0.0:
		var far := (-bb+sqrt(determinant))/aa
		var at := projected_origin+far*projected_direction
		if at >= 0.0 and at <= length_squared:
			result = maxf(result, far)
	return result


func _collide(point: Vector3) -> Vector3:
	# Project OUTSIDE the whole body envelope, not to the nearer/inside side
	# of either thigh. Ordinary nearest-capsule projection can push a skirt
	# particle between the legs and let an entire knee poke through a face.
	var local := _hips_inverse*point
	var radial := Vector3(local.x, 0, local.z-.02)
	var distance := radial.length()
	if distance < .00001:
		radial = Vector3.FORWARD
	else:
		radial /= distance
	var origin := _hips_transform*Vector3(0, local.y, .02)
	var direction := _hips_transform.basis*radial
	var minimum := 0.0
	var dy := (local.y-.89)/.145
	if absf(dy) < 1.0:
		minimum = sqrt((1.0-dy*dy)/(radial.x*radial.x/(.202*.202)+radial.z*radial.z/(.137*.137)))
	for capsule in _capsule_world:
		minimum = maxf(minimum, _capsule_far(origin, direction, capsule))
	if distance < minimum:
		collision_count += 1
		return origin+direction*minimum
	return point


func _fit_goals() -> void:
	_goals.clear()
	for i in _rest.size():
		var point := _hips_transform*_rest[i]
		_goals.append(point if i < _segments else _collide(point))


func update_pose(delta: float, grounded: bool = true) -> void:
	if _points.is_empty() or actor.global_position.distance_to(_last_origin) > 2.0:
		reset_cloth()
	_last_origin = actor.global_position
	_update_colliders()
	_fit_goals()
	_accumulator += minf(delta, .05)
	var stepped := false
	while _accumulator >= STEP:
		stepped = true
		_accumulator -= STEP
		for i in _points.size():
			if i < _segments:
				_points[i] = _goals[i]
				_previous[i] = _goals[i]
				continue
			var velocity := (_points[i]-_previous[i])*.985
			_previous[i] = _points[i]
			_points[i] += velocity+((_goals[i]-_points[i])*65.0+Vector3.DOWN*3.0)*STEP*STEP
		for iteration in _iterations:
			for edge in _edge_a.size():
				var a := _edge_a[edge]
				var b := _edge_b[edge]
				var difference := _points[b]-_points[a]
				var length := difference.length()
				var error := length-_edge_length[edge]
				var correction := difference*(error/maxf(length, .00001))*_edge_strength[edge]
				if error < 0:
					correction *= .18
				var wa := 0.0 if a < _segments else 1.0
				var wb := 0.0 if b < _segments else 1.0
				if wa+wb > 0:
					_points[a] += correction*wa/(wa+wb)
					_points[b] -= correction*wb/(wa+wb)
		_project_points(grounded)
	if not stepped:
		# The body can change pose at 120/144 FPS even between 60 Hz cloth
		# steps. Resolve its CURRENT collision volumes on those frames too.
		_project_points(grounded)
	_upload_skirt()


func _project_points(grounded: bool) -> void:
	for i in _segments:
		_points[i] = _goals[i]
		_previous[i] = _goals[i]
	# Bound SECONDARY motion. Collision has priority when the body needs room.
	for i in range(_segments, _points.size()):
		var offset := _points[i]-_goals[i]
		if offset.length_squared() > _max_secondary*_max_secondary:
			_points[i] = _goals[i]+offset.normalized()*_max_secondary
		_points[i] = _collide(_points[i])
		if grounded:
			_points[i].y = maxf(_points[i].y, actor.global_position.y+.025)


func collision_gap() -> float:
	var gap := INF
	for i in range(_segments, _points.size()):
		for capsule in _capsule_world:
			var a: Vector3 = capsule[0]
			var axis: Vector3 = capsule[2]
			var nearest := a+axis*clampf((_points[i]-a).dot(axis)/maxf(axis.length_squared(), .00001), 0, 1)
			gap = minf(gap, _points[i].distance_to(nearest)-float(capsule[4]))
	return gap


func cloth_vertices() -> PackedVector3Array:
	var result := PackedVector3Array()
	var inverse := actor.global_transform.affine_inverse()
	for point in _points:
		result.append(inverse*point)
	return result


func _upload_skirt() -> void:
	var vertices := PackedVector3Array()
	var inverse := global_transform.affine_inverse()
	for point in _points:
		vertices.append(inverse*point)
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for i in range(0, _skirt_indices.size(), 3):
		var a := _skirt_indices[i]
		var b := _skirt_indices[i+1]
		var c := _skirt_indices[i+2]
		var normal := (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a])
		normals[a] += normal
		normals[b] += normal
		normals[c] += normal
	for i in normals.size():
		normals[i] = normals[i].normalized()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = _skirt_colors
	arrays[Mesh.ARRAY_INDEX] = _skirt_indices
	_skirt_mesh.clear_surfaces()
	_skirt_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
