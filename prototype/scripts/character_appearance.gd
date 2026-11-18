## Shared lab gown, body-safe lightweight skirt and relaxed hands.
## Imported GLB stays morph-free: the hand shape is added to an ArrayMesh
## AFTER import, using the source model's existing fist/correction targets.
## Tailored continuous shoulders; 32-sided local-contact cloth at fixed 60 Hz.
## Reuse the dynamic mesh surface instead of recreating it every frame.
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
	var key := body.mesh.get_instance_id()
	if not _body_cache.has(key):
		_body_cache[key] = _body_with_relaxed_hands(body.mesh)
	body.mesh = _body_cache[key]
	_install_floor_probes()
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
		_capsules.append([skeleton.find_bone(item[0]), skeleton.find_bone(item[1]), float(item[2]), float(item[3])])
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
	# Interleave node rows and half-cell rows; fixed ray directions are
	# cached once. Capsule coefficients then need computing only per ROW.
	for row in _rings*2-1:
		var source_row := row/2
		_sample_heights.append(_rest[source_row*_segments].y if row%2 == 0 else _cell_centers[source_row*_segments].y)
		for k in _segments:
			var point := _rest[source_row*_segments+k] if row%2 == 0 else _cell_centers[source_row*_segments+k]
			_sample_directions.append(Vector2(point.x, point.z-.02).normalized())
			_sample_base.append(0.0)
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


func set_variant(is_clone: bool) -> void:
	clone_variant = is_clone
	_material.albedo_color = Color(.94, .96, 1.0) if is_clone else Color.WHITE


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
	_capsule_local.clear()
	for capsule in _capsules:
		var a := _hips_inverse*(actor.global_transform*skeleton.get_bone_global_pose(capsule[0]).origin)
		var b := _hips_inverse*(actor.global_transform*skeleton.get_bone_global_pose(capsule[1]).origin)
		a = a.lerp(b, capsule[3])
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
	_goal_radii = _rest_radius.duplicate()
	for row in range(1, _rings):
		for k in _segments:
			var i := row*_segments+k
			_goal_radii[i] = maxf(_goal_radii[i], samples[row*2*_segments+k]+.0001)
			if _goal_radii[i] > _rest_radius[i]+.00001:
				collision_count += 1
	# Half-cell contact supports all corners of the displayed triangles.
	var factor := 1.0/cos(PI/_segments)
	for row in _rings-1:
		for k in _segments:
			var minimum := samples[(row*2+1)*_segments+k]*factor+.0015
			if row == 0:
				minimum = maxf(minimum, 2.0*minimum-(_rest_radius[k]+_rest_radius[(k+1)%_segments])*.5)
			var cell := row*_segments+k
			for corner in 4:
				var i := _cells[cell*4+corner]
				if i >= _segments:
					_goal_radii[i] = maxf(_goal_radii[i], minimum)
	# Local bend only: no max-dilation around half the skirt / down to the hem.
	for iteration in 2:
		var source := _goal_radii.duplicate()
		for row in range(1, _rings):
			for k in _segments:
				var i := row*_segments+k
				_goal_radii[i] = maxf(source[i], source[row*_segments+(k+_segments-1)%_segments]*.18+source[i]*.64+source[row*_segments+(k+1)%_segments]*.18)
	_goals.resize(_rest.size())
	for i in _rest.size():
		var radial := _radial[i]*_goal_radii[i]
		_goals[i] = _hips_transform*Vector3(radial.x, _rest[i].y, .02+radial.z)


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
	# A small radial textile shell, NOT an unconstrained flying sheet.
	# Preserve ring heights/angular order so a fast lateral quickstep cannot
	# turn two rows inside-out or wrap the hem twice around the same knee.
	for i in range(_segments, _points.size()):
		var local := _hips_inverse*_points[i]
		var radial := _radial[i]
		var minimum := _goal_radii[i]
		var radius := clampf(Vector3(local.x, 0, local.z-.02).dot(radial), minimum, minimum+_max_secondary)
		_points[i] = _hips_transform*Vector3(radial.x*radius, _rest[i].y, .02+radial.z*radius)
		if grounded:
			_points[i].y = maxf(_points[i].y, actor.global_position.y+.025)


func collision_gap() -> float:
	var gap := INF
	for i in range(_segments, _points.size()):
		for capsule in _capsule_local:
			var a: Vector3 = capsule[0]
			var axis: Vector3 = capsule[2]
			var nearest := a+axis*clampf((_hips_inverse*_points[i]-a).dot(axis)/maxf(axis.length_squared(), .00001), 0, 1)
			gap = minf(gap, (_hips_inverse*_points[i]).distance_to(nearest)-float(capsule[4]))
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
