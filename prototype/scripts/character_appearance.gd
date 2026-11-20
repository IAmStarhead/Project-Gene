## Shared lab gown, body-safe lightweight skirt and relaxed hands.
## Imported GLB stays morph-free: the hand shape is added to an ArrayMesh
## AFTER import, using the source model's existing fist/correction targets.
## Tailored continuous shoulders; 32-sided local-contact cloth at fixed 60 Hz.
## Reuse the dynamic mesh surface instead of recreating it every frame.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const DATA_PATH := "res://assets/heroine/appearance/lab_uniform.json"
const STEP := 1.0/60.0
static var _data: Dictionary = {}
static var _hand_grid: Dictionary = {}
static var _body_cache: Dictionary = {}
static var _gown_mesh: ArrayMesh
static var _suit_mesh: ArrayMesh

var actor: Node3D
var skeleton: Skeleton3D
var body: MeshInstance3D
var gown: MeshInstance3D
var skirt: MeshInstance3D
var suit: MeshInstance3D
var outfit := "dress"
var _source_body: Mesh
var hand_open := 0.0
var clone_variant := false
var collision_count := 0
var _hips := -1
var _hips_inverse_bind: Transform3D
var _rest := PackedVector3Array()
var _waist_normals := PackedVector3Array()
var _points := PackedVector3Array()
var _previous := PackedVector3Array()
var _radial := PackedVector3Array()
var _rest_radius := PackedFloat32Array()
var _goal_radii := PackedFloat32Array()
var _cell_centers := PackedVector3Array()
var _cells := PackedInt32Array()
var _sample_heights := PackedFloat32Array()
var _sample_directions := PackedVector2Array()
var _sample_base := PackedFloat32Array()
var _sample_rest := PackedVector3Array()
var _drape_rest := PackedVector3Array()
var _drape_directions := PackedVector2Array()
var _meridian_lengths := PackedFloat32Array()
var _goal_local := PackedVector3Array()
var _curve_points := PackedVector3Array()
var _curve_distances := PackedFloat32Array()
var _circumferences := PackedFloat32Array()
var _circumference_coordinates := PackedFloat32Array()
var _surface_relaxations := 3
var _angular_relaxations := 2
var _circumference_limit := 1.45
var _min_drape_fraction := .86
var _goals := PackedVector3Array()
var _hips_transform: Transform3D
var _hips_inverse: Transform3D
var _thickness := .004
var _surface_margin := .014
var _max_secondary := .025
var _capsules: Array = []
var _capsule_local: Array = []
var _segments := 32
var _rings := 10
var _accumulator := 0.0
var _last_origin := Vector3.ZERO
var _material: StandardMaterial3D
var _skirt_indices := PackedInt32Array()
var _skirt_colors := PackedColorArray()
var _skirt_mesh := ArrayMesh.new()
var _vertex_bytes := PackedByteArray()
var _normal_offset := 0
var _normal_stride := 0
var _tangent_offset := 0
var _floor_points := PackedVector3Array()
var _floor_joints := PackedInt32Array()
var _floor_weights := PackedFloat32Array()
var _floor_binds: Dictionary = {}
var _floor_bones: Dictionary = {}


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
	_source_body = body.mesh
	var key := str(_source_body.get_instance_id())+":dress"
	if not _body_cache.has(key):
		_body_cache[key] = _body_with_relaxed_hands(_source_body)
	body.mesh = _body_cache[key]
	_install_floor_probes()
	body.custom_aabb = AABB(Vector3(-1, -.3, -1), Vector3(2, 2.6, 2.3))
	if _gown_mesh == null:
		_gown_mesh = _build_gown_mesh(_data["gown"])
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
	if _suit_mesh == null:
		_suit_mesh = _build_gown_mesh(_data["suit"])
	suit = MeshInstance3D.new()
	suit.name = "LabTopAndTrousers"
	suit.mesh = _suit_mesh
	suit.skin = body.skin
	suit.skeleton = body.skeleton
	suit.transform = body.transform
	suit.material_override = _material
	suit.set_meta("textile", true)
	body.get_parent().add_child(suit)
	suit.custom_aabb = body.custom_aabb
	suit.visible = false

	skirt = MeshInstance3D.new()
	skirt.name = "LabGownSkirt"
	skirt.mesh = _skirt_mesh
	skirt.material_override = _material
	skirt.set_meta("textile", true)
	skirt.custom_aabb = AABB(Vector3(-1, -.3, -1), Vector3(2, 2.6, 2.3))
	add_child(skirt)
	for normal in _data["gown"]["waist_normals"]:
		_waist_normals.append(_vector(normal))
	var cloth: Dictionary = _data["cloth"]
	_segments = int(cloth["segments"])
	_rings = int(cloth["rings"])
	for value in cloth["positions"]:
		var point := _vector(value)
		_rest.append(point)
		var radial := Vector3(point.x, 0, point.z-.02)
		_rest_radius.append(radial.length())
		_radial.append(radial.normalized())
	_thickness = float(cloth["thickness"])
	_surface_margin = float(cloth["surface_margin"])
	_max_secondary = float(cloth["max_secondary_offset"])
	for item in cloth["capsules"]:
		_capsules.append([skeleton.find_bone(item[0]), skeleton.find_bone(item[1]), float(item[2]), float(item[3]), float(item[4])])
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
			_cells.append_array(PackedInt32Array([a, b, a+_segments, b+_segments]))
			_cell_centers.append((_rest[a]+_rest[b]+_rest[a+_segments]+_rest[b+_segments])*.25)
	for i in _rest.size():
		_skirt_colors.append(Color(_data["cloth"]["binding"][0], _data["cloth"]["binding"][1], _data["cloth"]["binding"][2]) if i/_segments == _rings-1 else Color(_data["cloth"]["fabric"][0], _data["cloth"]["fabric"][1], _data["cloth"]["fabric"][2]))
	# Fine support chart includes circumferential half samples. Material
	# meridians are later resampled by length, so rows are FREE TO RISE.
	for value in cloth["sample_heights"]:
		_sample_heights.append(float(value))
	for value in cloth["sample_positions"]:
		var point := _vector(value)
		_sample_rest.append(point)
		_sample_directions.append(Vector2(point.x, point.z-.02).normalized())
		_sample_base.append(0.0)
	for value in cloth["drape_positions"]:
		var point:=_vector(value)
		_drape_rest.append(point)
		_drape_directions.append(Vector2(point.x,point.z-.02).normalized())
	_circumferences = PackedFloat32Array(cloth["circumferences"])
	_surface_relaxations = int(cloth["surface_relaxations"])
	_angular_relaxations = int(cloth["angular_relaxations"])
	for row in _rings:
		var distance := 0.0
		for k in _segments:
			_circumference_coordinates.append(distance/_circumferences[row])
			distance += _rest[row*_segments+k].distance_to(_rest[row*_segments+(k+1)%_segments])
	_circumference_limit = float(cloth["circumference_soft_limit"])
	_min_drape_fraction = float(cloth["min_drape_fraction"])
	for row in cloth["meridian_lengths"]:
		for value in row:
			_meridian_lengths.append(float(value))
	reset_cloth()
	set_outfit(T.OUTFIT)


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
	# Keep continuous shoulder/arm skin UNDER the tailored sleeve. The old
	# cylinder mask cut a real hole visible through its wide open cuff.
	# Only the closed proximal axilla is culled. Its cutoff is 53 mm INSIDE
	# the cuff, not the former broad .14 m shoulder/arm amputation cylinder.
	for core in _data["coverage"]["underarm_cores"]:
		var relative := point-_vector(core["origin"])
		var axis := _vector(core["axis"])
		var along := relative.dot(axis)
		if along >= float(core["start"]) and along <= float(core["end"]) \
				and (relative-axis*along).length() < float(core["radius"]):
			return true
	if point.y < .74 or point.y > 1.355:
		return false
	var axial := 0.0
	var arm := 0.0
	for k in 4:
		var name: String = names[bones[index*4+k]]
		var weight := weights[index*4+k]
		if name in ["hips", "spine", "chest", "neck"] or name.begins_with("thigh."):
			axial += weight
		if name.begins_with("upper_arm.") or name.begins_with("forearm.") \
				or name.begins_with("hand.") or name.begins_with("shoulder."):
			arm += weight
	return axial > .80 and arm < float(_data["coverage"]["arm_weight_threshold"])



## The suit mask is a SEPARATE, garment-specific coverage inventory. The
## frozen dress mask above is unchanged. Leave overlap inside neck/cuffs/
## ankles, and never remove skin beyond the actual long-sleeve/trouser cut.
static func suit_covered(point: Vector3, bones: PackedInt32Array, weights: PackedFloat32Array,
		index: int, names: Array) -> bool:
	var arm := 0.0
	var forearms := Vector2.ZERO
	for k in 4:
		var name: String = names[bones[index*4+k]]
		var value := weights[index*4+k]
		if name.begins_with("shoulder.") or name.begins_with("upper_arm.") or name.begins_with("forearm.") or name.begins_with("hand."):
			arm += value
		if name in ["forearm.L", "hand.L"]:
			forearms.x += value
		if name in ["forearm.R", "hand.R"]:
			forearms.y += value
	var c: Dictionary = _data["suit"]["coverage"]
	var overlap := float(c["skin_overlap"])
	if arm < .15:
		return point.y > float(c["ankle"])+overlap and point.y < float(c["neck"])-overlap
	# Fully enclosed upper/lower arm only, with 20 mm retained at wrists.
	if arm < .85:
		return false
	for side in 2:
		var cuff: Dictionary = c["wrists"][side]
		if forearms[side] > .2 and (point-_vector(cuff["origin"])).dot(_vector(cuff["axis"])) > float(cuff["end"])-overlap:
			return false
	return true


func _body_with_relaxed_hands(source: Mesh, for_suit: bool = false) -> ArrayMesh:
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
			var hidden := suit_covered(vertices[i], bones, weights, i, names) if for_suit else covered(vertices[i], bones, weights, i, names)
			hide.append(1 if hidden else 0)
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


static func _build_gown_mesh(source: Dictionary) -> ArrayMesh:
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
	# Authoring/Three use GLTF CCW; native ArrayMesh front faces are CW.
	# Keep the OUTWARD normals, reverse winding only at this boundary.
	var indices := PackedInt32Array(source["indices"])
	for i in range(0, indices.size(), 3):
		var temp := indices[i+1]
		indices[i+1] = indices[i+2]
		indices[i+2] = temp
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func _install_floor_probes() -> void:
	var source: Dictionary = _data["floor_probes"]
	_floor_points.clear()
	_floor_joints.clear()
	_floor_weights.clear()
	_floor_binds.clear()
	_floor_bones.clear()
	var binds: Dictionary = {}
	for i in body.skin.get_bind_count():
		binds[str(body.skin.get_bind_name(i))] = i
	for i in source["positions"].size():
		_floor_points.append(_vector(source["positions"][i]))
		for k in 4:
			var name: String = source["bones"][int(source["joints"][i][k])]
			var weight: float = source["weights"][i][k]
			var bind: int = binds[name]
			_floor_joints.append(bind)
			_floor_weights.append(weight)
			if weight > 0.0:
				_floor_binds[bind] = body.skin.get_bind_pose(bind)
				_floor_bones[bind] = skeleton.find_bone(name)


func sole_height() -> float:
	# Native imported Skin binds, real soft-weighted heel / ball / toe points.
	# Called after applying a BLENDED pose, before cloth and the next capture.
	var transforms: Dictionary = {}
	var to_actor := actor.global_transform.affine_inverse()*skeleton.global_transform
	for bind in _floor_binds:
		transforms[bind] = to_actor*skeleton.get_bone_global_pose(_floor_bones[bind])*(_floor_binds[bind] as Transform3D)
	var lowest := INF
	for i in _floor_points.size():
		var y := 0.0
		for k in 4:
			var weight := _floor_weights[i*4+k]
			if weight > 0.0:
				y += weight*((transforms[_floor_joints[i*4+k]] as Transform3D)*_floor_points[i]).y
		lowest = minf(lowest, y)
	return lowest


func set_outfit(value: String) -> void:
	var selected := "suit" if value == "suit" else "dress"
	if selected == outfit:
		return
	outfit = selected
	var key := str(_source_body.get_instance_id())+":"+outfit
	if not _body_cache.has(key):
		_body_cache[key] = _body_with_relaxed_hands(_source_body, outfit == "suit")
	body.mesh = _body_cache[key]
	body.set_blend_shape_value(0, hand_open)
	gown.visible = outfit == "dress"
	skirt.visible = outfit == "dress"
	suit.visible = outfit == "suit"
	if outfit == "dress":
		reset_cloth()


func set_variant(is_clone: bool) -> void:
	clone_variant = is_clone
	_material.albedo_color = Color(.94, .96, 1.0) if is_clone else Color.WHITE


func set_hands(amount: float) -> void:
	hand_open = clampf(amount, 0, 1)
	if body != null:
		body.set_blend_shape_value(0, hand_open)


func reset_cloth() -> void:
	if outfit == "suit":
		return
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
	_capsule_local.clear()
	for capsule in _capsules:
		var a := _hips_inverse*(actor.global_transform*skeleton.get_bone_global_pose(capsule[0]).origin)
		var b := _hips_inverse*(actor.global_transform*skeleton.get_bone_global_pose(capsule[1]).origin)
		var first := a.lerp(b, capsule[3])
		b = a.lerp(b, capsule[4])
		a = first
		var axis := b-a
		_capsule_local.append([a, b, axis, axis.length_squared(), capsule[2]+_thickness+_surface_margin])


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
	if aa > .000001:
		# The end spheres lie INSIDE the infinite cylinder. A ray missing
		# that cylinder cannot hit either sphere; most skirt rays miss.
		if determinant < 0.0:
			return -1.0
		var far := (-bb+sqrt(determinant))/aa
		if far <= 0.0:
			return -1.0
		var at := projected_origin+far*projected_direction
		if at >= 0.0 and at <= length_squared:
			return far
		return _sphere_far(origin, direction, a if at < 0.0 else capsule[1], radius)
	return maxf(_sphere_far(origin, direction, a, radius),
		_sphere_far(origin, direction, capsule[1], radius))


func _surface_minimum(local: Vector3) -> float:
	# All rays and colliders share HIP coordinates. In particular ray.y == 0:
	# no per-vertex world/inverse transform and a tight vertical broad phase.
	var radial := Vector3(local.x, 0, local.z-.02).normalized()
	var origin := Vector3(0, local.y, .02)
	var minimum := 0.0
	var dy := (local.y-.89)/.145
	if absf(dy) < 1.0:
		minimum = sqrt((1.0-dy*dy)/(radial.x*radial.x/(.187*.187)+radial.z*radial.z/(.124*.124)))
	for capsule in _capsule_local:
		var a: Vector3 = capsule[0]
		var b: Vector3 = capsule[1]
		var radius: float = capsule[4]
		if local.y < minf(a.y,b.y)-radius or local.y > maxf(a.y,b.y)+radius:
			continue
		var axis: Vector3 = capsule[2]
		var nearest := a+axis*clampf((local-a).dot(axis)/maxf(float(capsule[3]),.000001),0,1)
		var normal := local-nearest
		# Convex supporting-plane rejection: an outside point moving away
		# from its nearest capsule surface cannot hit that capsule farther
		# along this ray. Most fitted skirt points take this cheap branch.
		if normal.length_squared() >= radius*radius and normal.dot(radial) >= 0.0:
			continue
		minimum = maxf(minimum, _capsule_far(origin, radial, capsule))
	return minimum


func _fit_goals() -> void:
	# Same analytic ray/capsule intersection as _capsule_far, batched by
	# horizontal row: no thousands of GDScript calls / temporary Vector3s.
	var samples := _sample_base.duplicate()
	for row in _sample_heights.size():
		var dy := (_sample_heights[row]-.89)/.145
		if absf(dy) < 1.0:
			for k in _segments:
				var i := row*_segments+k
				var d := _sample_directions[i]
				samples[i] = maxf(samples[i], sqrt((1.0-dy*dy)/(d.x*d.x/(.187*.187)+d.y*d.y/(.124*.124))))
	for capsule in _capsule_local:
		var a: Vector3 = capsule[0]
		var b: Vector3 = capsule[1]
		var axis: Vector3 = capsule[2]
		var length_squared: float = capsule[3]
		var radius: float = capsule[4]
		var ra_x := -a.x
		var ra_z := .02-a.z
		var rb_x := -b.x
		var rb_z := .02-b.z
		for row in _sample_heights.size():
			var y := _sample_heights[row]
			if y < minf(a.y, b.y)-radius or y > maxf(a.y, b.y)+radius:
				continue
			var ra_y := y-a.y
			var rb_y := y-b.y
			var projected_origin := ra_x*axis.x+ra_y*axis.y+ra_z*axis.z
			var sphere_a := radius*radius-ra_x*ra_x-ra_y*ra_y-ra_z*ra_z
			var sphere_b := radius*radius-rb_x*rb_x-rb_y*rb_y-rb_z*rb_z
			var cc := -length_squared*sphere_a-projected_origin*projected_origin
			for k in _segments:
				var i := row*_segments+k
				var d := _sample_directions[i]
				var projected_direction := axis.x*d.x+axis.z*d.y
				var along := ra_x*d.x+ra_z*d.y
				var aa := length_squared-projected_direction*projected_direction
				var bb := length_squared*along-projected_origin*projected_direction
				var far := -1.0
				if aa > .000001:
					var determinant := bb*bb-aa*cc
					if determinant < 0.0:
						continue
					far = (-bb+sqrt(determinant))/aa
					if far <= 0.0:
						continue
					var at := projected_origin+far*projected_direction
					if at < 0.0 or at > length_squared:
						if at > length_squared:
							along -= projected_direction
						var disc := along*along+(sphere_a if at < 0.0 else sphere_b)
						far = -along+sqrt(disc) if disc >= 0.0 else -1.0
				else:
					var disc_a := along*along+sphere_a
					var along_b := along-projected_direction
					var disc_b := along_b*along_b+sphere_b
					far = maxf(-along+sqrt(disc_a) if disc_a >= 0.0 else -1.0, -along_b+sqrt(disc_b) if disc_b >= 0.0 else -1.0)
				samples[i] = maxf(samples[i], far)
	var rows := _sample_heights.size()
	var radii := PackedFloat32Array()
	radii.resize(rows*_segments)
	var factor := 1.0/cos(PI/_segments)
	for row in rows:
		for k in _segments:
			var i := row*_segments+k
			var point := _drape_rest[i]
			var base := Vector2(point.x, point.z-.02).length()
			var minimum := samples[i]+.0001 if row%2 == 0 else maxf(samples[i],samples[row*_segments+(k+_segments-1)%_segments])*factor+.0015
			radii[i] = maxf(base,minimum) if row > 0 else base
			if radii[i] > base+.00001: collision_count+=1

	# Include the upper tangent of each capsule in every meridian plane.
	# A bent calf can enter a horizontal chart abruptly between two rows:
	# fixing only the final point then stretched a meridian by 24% in a
	# gameplay blend, despite the 18 isolated clips staying within 2%.
	# Raise the support on the immediately preceding chart row instead,
	# so the arc budget is spent ABOVE that calf, before final clearance.
	for capsule in _capsule_local:
		var a: Vector3 = capsule[0]
		var axis: Vector3 = capsule[2]
		var radius: float = capsule[4]
		var top: float = maxf(a.y,(capsule[1] as Vector3).y)+radius
		if top >= _sample_heights[0] or top <= _sample_heights[-1]: continue
		for k in _segments:
			var row := 0
			while row < rows-2 and _sample_heights[row+1] >= top: row+=1
			var along := -1.0
			for iteration in 2:
				var d := _drape_directions[row*_segments+k]
				var cross_a := a.x*d.y-(a.z-.02)*d.x
				var cross_axis := axis.x*d.y-axis.z*d.x
				var at := 1.0 if axis.y > 0.0 else 0.0
				if absf(cross_axis) > .000001:
					var target := radius*axis.y*signf(cross_axis)/sqrt(axis.y*axis.y+cross_axis*cross_axis)
					at = clampf((target-cross_a)/cross_axis,0,1)
				var transverse := cross_a+at*cross_axis
				if absf(transverse) >= radius:
					along=-1.0
					break
				var height := a.y+at*axis.y+sqrt(maxf(0,radius*radius-transverse*transverse))
				along = (a.x+at*axis.x)*d.x+(a.z-.02+at*axis.z)*d.y
				if along <= 0 or height <= _sample_heights[-1]:
					along=-1.0
					break
				row=0
				while row < rows-2 and _sample_heights[row+1] >= height: row+=1
			if row > 0 and along > 0:
				radii[row*_segments+k]=maxf(radii[row*_segments+k],along+.0015)

	# A small one-sided fairing of the SUPPORT curve. It never moves the
	# surface inward through a collider. Unlike the old projection it does
	# not stretch material rows: the next stage spends meridian length.
	for pass_index in 4:
		var source := radii.duplicate()
		for row in range(1, rows):
			for k in _segments:
				var i := row*_segments+k
				var angular := source[row*_segments+(k+_segments-1)%_segments]*.25+source[i]*.50+source[row*_segments+(k+1)%_segments]*.25
				var vertical := source[(row-1)*_segments+k]*.20+source[i]*.60+source[mini(row+1,rows-1)*_segments+k]*.20
				radii[i] = maxf(source[i], maxf(angular, vertical))
	_curve_points.resize(rows*_segments)
	_curve_distances.resize(rows*_segments)
	for k in _segments:
		for row in rows:
			var i := k*rows+row
			var d := _drape_directions[row*_segments+k]
			var radius := radii[row*_segments+k]
			_curve_points[i] = Vector3(d.x*radius, _sample_heights[row], .02+d.y*radius)
			_curve_distances[i] = _curve_distances[i-1]+_curve_points[i].distance_to(_curve_points[i-1]) if row > 0 else 0.0
	_goals.resize(_rest.size())
	_goal_local.resize(_rest.size())
	_goal_radii.resize(_rest.size())
	var previous_length := 0.0
	for row in _rings:
		var ring := PackedVector3Array()
		ring.resize(_segments)
		var length := _meridian_lengths[row*_segments]
		var fraction := 1.0
		for k in _segments:
			ring[k] = _drape_point(k, _meridian_lengths[row*_segments+k]) if row > 0 else _rest[k]
		var circumference := _ring_length(ring)
		var maximum := _circumferences[row]*_circumference_limit
		if row > 0 and circumference > maximum:
			# Woven fabric cannot double its circumference across an evasion.
			# Spend less downward arc: the MATERIAL ROW LIFTS over the thighs
			# instead. Compression here stands for unresolved small folds.
			var low := maxf(_min_drape_fraction, minf(previous_length/maxf(length,.000001),1.0))
			var high := 1.0
			for k in _segments:
				ring[k]=_drape_point(k,_meridian_lengths[row*_segments+k]*low)
			# Never compress an entire 48 cm skirt into a 12 cm mini to
			# satisfy a perimeter target. Retain at least 86% downward arc.
			if _ring_length(ring) <= maximum:
				for iteration in 5:
					var mid := (low+high)*.5
					for k in _segments:
						ring[k] = _drape_point(k, _meridian_lengths[row*_segments+k]*mid)
					if _ring_length(ring) > maximum: high=mid
					else: low=mid
			fraction=low
			for k in _segments:
				ring[k] = _drape_point(k, _meridian_lengths[row*_segments+k]*fraction)

		previous_length=length*fraction
		for k in _segments:
			var i:=row*_segments+k
			_goal_local[i] = ring[k]
			_goal_radii[i] = Vector2(ring[k].x,ring[k].z-.02).length()
			_goals[i] = _hips_transform*ring[k]

	# Round the hem's HEIGHT as well as its radius. Independent lifted
	# meridians otherwise left sharp downward arrowheads on lateral dodges.
	# Raise neighbouring material smoothly along the same supported curve;
	# never lower a contact point or push cloth through the leg.
	var hem_height:=PackedFloat32Array()
	for k in _segments: hem_height.append(_goal_local[(_rings-1)*_segments+k].y)
	var rounded:=hem_height.duplicate()
	for iteration in 8:
		var source:=rounded.duplicate()
		for k in _segments:
			# Bound a hanging tip's negative curvature, rather than merely
			# averaging its neighbours four times. Only LIFT along supported
			# meridians; never enlarge the capsule or push through a knee.
			var bridge := (source[(k+_segments-1)%_segments]+source[(k+1)%_segments])*.5-.0025
			rounded[k]=minf(hem_height[k]+.060,maxf(source[k],bridge))
	for k in _segments:
		var lift:=rounded[k]-hem_height[k]
		if lift < .000001: continue
		for row in range(1,_rings):
			var i:=row*_segments+k
			var u:=_meridian_lengths[i]/_meridian_lengths[(_rings-1)*_segments+k]
			var point:=_drape_at_height(k,_goal_local[i].y+lift*u*u)
			_goal_local[i]=point
			_goal_radii[i]=Vector2(point.x,point.z-.02).length()
			_goals[i]=_hips_transform*point

	# Arc interpolation can cut a round collider by a few millimetres.
	# Resolve the CURRENT analytic envelope, locally, after all length/hem
	# operations. This is not a wider garment or an increased skin mask.
	for i in range(_segments,_rest.size()):
		var point:=_goal_local[i]
		var minimum:=_surface_minimum(point)+.0001
		if minimum > _goal_radii[i]:
			var direction:=Vector3(point.x,0,point.z-.02).normalized()
			point=Vector3(direction.x*minimum,point.y,.02+direction.z*minimum)
			_goal_local[i]=point
			_goal_radii[i]=minimum
			_goals[i]=_hips_transform*point

	_redistribute_surface()
	_fillet_supported_surface()


func _redistribute_surface() -> void:
	# Fixed rays concentrated strain in one triangle beside a raised knee
	# (5.88x locally despite a 1.82x ring). Slide material along the EXISTING
	# surface, then spend its meridian lengths. No larger collision volumes.
	var arc := PackedFloat32Array()
	arc.resize(_rings)
	for iteration in _surface_relaxations:
		if iteration < _angular_relaxations:
			_redistribute_rings()
			# Keep an ordered chart through a steep knee's new arc allocation.
			for row in range(_rings-2, 0, -1):
				for k in _segments:
					var i := row*_segments+k
					_goal_local[i].y = maxf(_goal_local[i].y, _goal_local[i+_segments].y+.00001)
		var source := _goal_local.duplicate()
		for k in _segments:
			arc[0] = 0
			for row in range(1, _rings):
				arc[row] = arc[row-1]+source[row*_segments+k].distance_to(source[(row-1)*_segments+k])
			# Do not collapse the last rows when small folds use less length.
			var fraction := minf(1, arc[_rings-1]/_meridian_lengths[(_rings-1)*_segments+k])
			var at := 1
			for row in range(1, _rings):
				var length := _meridian_lengths[row*_segments+k]*fraction
				while at < _rings-1 and arc[at] < length: at += 1
				var u := clampf((length-arc[at-1])/maxf(arc[at]-arc[at-1], .000001), 0, 1)
				_goal_local[row*_segments+k] = source[(at-1)*_segments+k].lerp(source[at*_segments+k], u)
		# Interpolation can cut a convex capsule. Restore its unchanged
		# envelope after each pass, including the FINAL length-only pass.
		for i in range(_segments, _rest.size()):
			var point := _goal_local[i]
			var radius := Vector2(point.x, point.z-.02).length()
			var minimum := _surface_minimum(point)+.0001
			if minimum > radius:
				var factor := minimum/maxf(radius, .000001)
				_goal_local[i] = Vector3(point.x*factor, point.y, .02+(point.z-.02)*factor)
	for i in _rest.size():
		var point := _goal_local[i]
		_goal_radii[i] = Vector2(point.x, point.z-.02).length()
		_goals[i] = _hips_transform*point


func _redistribute_rings() -> void:
	var source := _goal_local.duplicate()
	var arc := PackedFloat32Array()
	arc.resize(_segments+1)
	for row in range(1, _rings):
		var base := row*_segments
		arc[0] = 0
		for k in _segments:
			arc[k+1] = arc[k]+source[base+k].distance_to(source[base+(k+1)%_segments])
		var at := 1
		for k in _segments:
			var length := _circumference_coordinates[base+k]*arc[_segments]
			while at < _segments and arc[at] < length: at += 1
			var u := clampf((length-arc[at-1])/maxf(arc[at]-arc[at-1], .000001), 0, 1)
			_goal_local[base+k] = source[base+at-1].lerp(source[base+at%_segments], u)


static func _ring_length(ring: PackedVector3Array) -> float:
	var length:=0.0
	for k in ring.size(): length+=ring[k].distance_to(ring[(k+1)%ring.size()])
	return length


func _drape_point(k: int, length: float) -> Vector3:
	var rows := _sample_heights.size()
	var base := k*rows
	var low:=1
	var high:=rows-1
	while low < high:
		var mid: int = (low+high)/2
		if _curve_distances[base+mid] < length: low=mid+1
		else: high=mid
	var at := base+low
	var u:=clampf((length-_curve_distances[at-1])/maxf(_curve_distances[at]-_curve_distances[at-1],.000001),0,1)
	return _curve_points[at-1].lerp(_curve_points[at],u)


func _drape_at_height(k: int, height: float) -> Vector3:
	var low:=1
	var high:=_sample_heights.size()-1
	while low < high:
		var mid: int = (low+high)/2
		if _sample_heights[mid] > height: low=mid+1
		else: high=mid
	var at:=k*_sample_heights.size()+low
	var u:=clampf((_sample_heights[low-1]-height)/maxf(_sample_heights[low-1]-_sample_heights[low],.000001),0,1)
	return _curve_points[at-1].lerp(_curve_points[at],u)


func update_pose(delta: float, grounded: bool = true) -> void:
	if outfit == "suit":
		return # ordinary GPU skinning only; no hidden skirt CPU simulation
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
			var velocity := (_points[i]-_previous[i])*.92
			_previous[i] = _points[i]
			_points[i] += velocity+((_goals[i]-_points[i])*65.0+Vector3.DOWN*3.0)*STEP*STEP
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
	# One coherent secondary amplitude per material meridian. Independent
	# offsets on a 12 mm hem band stretched it by >2x even with a 25 mm cap.
	# The smooth length ramp cannot make that old saw-toothed edge.
	for k in _segments:
		var hem:=(_rings-1)*_segments+k
		var local := _hips_inverse*_points[hem]
		var goal := _goal_local[hem]
		var radial := Vector3(goal.x,0,goal.z-.02).normalized()
		var amount:=clampf(Vector3(local.x,0,local.z-.02).dot(radial)-_goal_radii[hem],0,_max_secondary)
		amount = _safe_secondary(k, amount)
		for row in range(1,_rings):
			var i:=row*_segments+k
			var u:=_meridian_lengths[i]/_meridian_lengths[hem]
			goal=_goal_local[i]
			radial=Vector3(goal.x,0,goal.z-.02).normalized()
			var radius:=_goal_radii[i]+amount*u*u
			_points[i]=_hips_transform*Vector3(radial.x*radius,goal.y,.02+radial.z*radius)
			if grounded: _points[i].y=maxf(_points[i].y,actor.global_position.y+.025)


func collision_gap() -> float:
	var gap := INF
	for i in range(_segments, _points.size()):
		for capsule in _capsule_local:
			var a: Vector3 = capsule[0]
			var axis: Vector3 = capsule[2]
			var nearest := a+axis*clampf((_hips_inverse*_points[i]-a).dot(axis)/maxf(axis.length_squared(), .00001), 0, 1)
			gap = minf(gap, (_hips_inverse*_points[i]).distance_to(nearest)-float(capsule[4]))
	return gap


## Actually DISPLAYED vertices in actor-local space, not the solver's world
## history. A passive clone can sleep its animator/cloth while its parent keeps
## facing the player. Re-inverting cached _points by that NEW parent transform
## then invented rotated triangles that were never uploaded to the renderer.
## This query is diagnostic only; do not wake the clone or resimulate the cloth.
func cloth_vertices() -> PackedVector3Array:
	var result := PackedVector3Array()
	# _upload_skirt writes this uncompressed float32 position prefix before
	# the normal/tangent stream. It is the exact buffer sent to the renderer.
	var displayed := _vertex_bytes.slice(0, _points.size()*12).to_float32_array()
	var to_actor := actor.global_transform.affine_inverse()*skirt.global_transform
	for i in _points.size():
		result.append(to_actor*Vector3(displayed[i*3], displayed[i*3+1], displayed[i*3+2]))
	return result


func _upload_skirt() -> void:
	var vertices := PackedVector3Array()
	var inverse := global_transform.affine_inverse()
	for point in _points:
		vertices.append(inverse*point)
	var normals := PackedVector3Array()
	var tangents := PackedVector3Array()
	normals.resize(vertices.size())
	tangents.resize(vertices.size())
	# Central differences on the fixed textile grid are smooth and O(vertices),
	# instead of accumulating every triangle in script on every frame.
	for row in _rings:
		for k in _segments:
			var i := row*_segments+k
			var tangent := vertices[row*_segments+(k+1)%_segments]-vertices[row*_segments+(k+_segments-1)%_segments]
			var vertical := vertices[mini(row+1, _rings-1)*_segments+k]-vertices[maxi(row-1, 0)*_segments+k]
			normals[i] = vertical.cross(tangent).normalized()
			if row == 0:
				# Identical to the hips-skinned bodice's pinned seam normal;
				# no independent lighting crease that reads as a grey belt.
				normals[i] = (inverse.basis*_hips_transform.basis*_waist_normals[k]).normalized()
			tangents[i] = tangent.slide(normals[i]).normalized()
	if _skirt_mesh.get_surface_count() == 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = _skirt_colors
		arrays[Mesh.ARRAY_INDEX] = _skirt_indices
		_skirt_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
		var format := _skirt_mesh.surface_get_format(0)
		_normal_offset = RenderingServer.mesh_surface_get_format_offset(format, vertices.size(), Mesh.ARRAY_NORMAL)
		_normal_stride = RenderingServer.mesh_surface_get_format_normal_tangent_stride(format, vertices.size())
		_tangent_offset = RenderingServer.mesh_surface_get_format_offset(format, vertices.size(), Mesh.ARRAY_TANGENT)
	# Godot automatically adds tangents when normals are present. Query its
	# actual offsets/stride: assuming a 4-byte normal-only stream corrupts
	# every second normal/tangent (the real normal+tangent stride is 8).
	_vertex_bytes = vertices.to_byte_array()
	_vertex_bytes.resize(_normal_offset+_normal_stride*vertices.size())
	for i in normals.size():
		var encoded := normals[i].octahedron_encode()
		_vertex_bytes.encode_u16(_normal_offset+i*_normal_stride, int(clampf(encoded.x*65535.0, 0, 65535)))
		_vertex_bytes.encode_u16(_normal_offset+i*_normal_stride+2, int(clampf(encoded.y*65535.0, 0, 65535)))
		var tangent := tangents[i].octahedron_encode()
		# Native octahedron_tangent_encode with positive handedness.
		tangent.y = maxf(tangent.y, 1.0/32767.0)*.5+.5
		var tx := int(clampf(tangent.x*65535.0, 0, 65535))
		var ty := int(clampf(tangent.y*65535.0, 0, 65535))
		if tx == 0 and ty == 65535:
			tx = 65535  # Godot's reserved compressed-tangent sentinel.
		_vertex_bytes.encode_u16(_tangent_offset+i*_normal_stride, tx)
		_vertex_bytes.encode_u16(_tangent_offset+i*_normal_stride+2, ty)
	_skirt_mesh.surface_update_vertex_region(0, 0, _vertex_bytes)


func _fillet_supported_surface() -> void:
	# Only the 32-point material boundary needs a fairing solve. Solving all
	# 320 points at every pass produced the same hem but cost six times the
	# old update. Transfer this boundary correction through the cloth ONCE.
	# A nearest-normal contact slides around a knee instead of re-creating
	# its sharp radial tip. Rest curvature preserves the idle circumference.
	var base := (_rings-1)*_segments
	var original := PackedVector3Array()
	var hem := PackedVector3Array()
	var rest_lap := PackedVector3Array()
	for k in _segments:
		original.append(_goal_local[base+k])
		hem.append(_goal_local[base+k])
		rest_lap.append((_rest[base+(k+_segments-1)%_segments]+_rest[base+(k+1)%_segments])*.5-_rest[base+k])
	for iteration in 24:
		var source := hem.duplicate()
		for k in _segments:
			var lap := (source[(k+_segments-1)%_segments]+source[(k+1)%_segments])*.5-source[k]
			hem[k] = _normal_clear(source[k]+(lap-rest_lap[k])*.5)
	for row in range(1, _rings):
		for k in _segments:
			var i := row*_segments+k
			var u := _meridian_lengths[i]/_meridian_lengths[base+k]
			_goal_local[i] += (hem[k]-original[k])*(u*u)
	_clear_filleted_surface()
	for iteration in 3:
		_resample_filleted_meridians()
	# Keep the thin binding below its preceding material row when the calf
	# is almost horizontal. Lift only offending neighbours; never lower a
	# contact point or enlarge a capsule/garment to obtain a green test.
	for iteration in 3:
		for row in range(_rings-2, 0, -1):
			for k in _segments:
				var i := row*_segments+k
				if _goal_local[i].y < _goal_local[i+_segments].y+.0002:
					var point := _goal_local[i]
					point.y = _goal_local[i+_segments].y+.0002
					_goal_local[i] = _normal_clear(point)
	for i in _rest.size():
		_goal_radii[i] = Vector2(_goal_local[i].x, _goal_local[i].z-.02).length()
		_goals[i] = _hips_transform*_goal_local[i]


func _clear_filleted_surface() -> void:
	# Same nearest-normal projection as _normal_clear, batched by capsule.
	# Cache the six capsule records, not thousands of Variant-array reads.
	for i in range(_segments, _rest.size()):
		var point := _goal_local[i]
		var dy := (point.y-.89)/.145
		if absf(dy) >= 1.0: continue
		var radial := Vector2(point.x, point.z-.02)
		var radius := radial.length()
		var direction := radial/maxf(radius, .000001)
		var minimum := sqrt((1.0-dy*dy)/(direction.x*direction.x/(.187*.187)+direction.y*direction.y/(.124*.124)))
		if radius < minimum:
			_goal_local[i] = Vector3(direction.x*minimum, point.y, .02+direction.y*minimum)
	for capsule in _capsule_local:
		var a: Vector3 = capsule[0]
		var b: Vector3 = capsule[1]
		var axis: Vector3 = capsule[2]
		var inverse_length := 1.0/maxf(float(capsule[3]), .000001)
		var radius: float = capsule[4]+.00025
		var low := minf(a.y,b.y)-radius
		var high := maxf(a.y,b.y)+radius
		for i in range(_segments, _rest.size()):
			var point := _goal_local[i]
			if point.y < low or point.y > high: continue
			var nearest := a+axis*clampf((point-a).dot(axis)*inverse_length, 0, 1)
			var offset := point-nearest
			var squared := offset.length_squared()
			if squared < radius*radius:
				var distance := sqrt(squared)
				_goal_local[i] = point+offset*((radius-distance)/maxf(distance,.000001))


func _resample_filleted_meridians() -> void:
	var source := _goal_local.duplicate()
	var arc := PackedFloat32Array()
	arc.resize(_rings)
	for k in _segments:
		arc[0] = 0
		for row in range(1, _rings):
			arc[row] = arc[row-1]+source[row*_segments+k].distance_to(source[(row-1)*_segments+k])
		var fraction := minf(1, arc[_rings-1]/_meridian_lengths[(_rings-1)*_segments+k])
		var at := 1
		for row in range(1, _rings):
			var length := _meridian_lengths[row*_segments+k]*fraction
			while at < _rings-1 and arc[at] < length: at += 1
			var u := clampf((length-arc[at-1])/maxf(arc[at]-arc[at-1], .000001), 0, 1)
			_goal_local[row*_segments+k] = source[(at-1)*_segments+k].lerp(source[at*_segments+k], u)
	_clear_filleted_surface()


func _normal_clear(point: Vector3) -> Vector3:
	# Existing pelvis envelope; no new collider or larger safety volume.
	var dy := (point.y-.89)/.145
	if absf(dy) < 1.0:
		var radial := Vector2(point.x, point.z-.02)
		var radius := radial.length()
		var direction := radial/maxf(radius, .000001)
		var minimum := sqrt((1.0-dy*dy)/(direction.x*direction.x/(.187*.187)+direction.y*direction.y/(.124*.124)))
		if radius < minimum:
			point.x = direction.x*minimum
			point.z = .02+direction.y*minimum
	for capsule in _capsule_local:
		var a: Vector3 = capsule[0]
		var b: Vector3 = capsule[1]
		var radius: float = capsule[4]+.00025
		if point.y < minf(a.y,b.y)-radius or point.y > maxf(a.y,b.y)+radius:
			continue
		var axis: Vector3 = capsule[2]
		var nearest := a+axis*clampf((point-a).dot(axis)/maxf(float(capsule[3]), .000001), 0, 1)
		var offset := point-nearest
		var distance := offset.length()
		if distance < radius:
			point += offset*((radius-distance)/maxf(distance,.000001))
	return point


func _safe_secondary(k: int, amount: float) -> float:
	# Normal fillets need not be at the farthest radial ray intersection:
	# adding even an outward 12 mm drift can meet the bent calf again.
	# Limit the ONE coherent meridian amplitude, not separate vertex pushes
	# which would recreate a saw-tooth hem or exceed the secondary bound.
	if amount <= .000001 or _secondary_clear(k, amount):
		return amount
	var low := 0.0
	var high := amount
	for iteration in 8:
		var mid := (low+high)*.5
		if _secondary_clear(k, mid): low = mid
		else: high = mid
	return low


func _secondary_clear(k: int, amount: float) -> bool:
	for row in range(1, _rings):
		var i := row*_segments+k
		var point := _goal_local[i]
		var u := _meridian_lengths[i]/_meridian_lengths[(_rings-1)*_segments+k]
		var radial := Vector3(point.x, 0, point.z-.02).normalized()
		point += radial*(amount*u*u)
		for capsule in _capsule_local:
			var a: Vector3 = capsule[0]
			var b: Vector3 = capsule[1]
			var radius: float = capsule[4]+.00003
			if point.y < minf(a.y,b.y)-radius or point.y > maxf(a.y,b.y)+radius:
				continue
			var axis: Vector3 = capsule[2]
			var nearest := a+axis*clampf((point-a).dot(axis)/maxf(float(capsule[3]), .000001), 0, 1)
			if point.distance_squared_to(nearest) < radius*radius:
				return false
	return true
