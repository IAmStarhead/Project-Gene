## Experimental stationary clone-shaped cutting dummy.
## The whole body falls as ONE rigid body: this is NOT an articulated ragdoll.
## Limbs are prepared once on spawn; no arbitrary runtime mesh slicing.
extends StaticBody3D

const PartMesh := preload("res://scripts/manikin_parts.gd")
const CharacterScript := preload("res://scripts/clone_anim.gd")
const LIMBS := ["arm_left", "arm_right", "leg_left", "leg_right"]
const TARGET_BONES := ["forearm.L", "forearm.R", "shin.L", "shin.R"]
const STUMP_BONES := ["upper_arm.L", "upper_arm.R", "thigh.L", "thigh.R"]
const GROW_TIME := 12.0
const FALL_TIME := 0.85
const STAND_TIME := 0.55
const STRONG_HIT := 30.0

enum LimbState { INTACT, GROWING, BLOCKED }
enum FallState { STANDING, FALLING, RISING }
var parts: Array[Dictionary] = []
var character: Node3D
var body_physics: RigidBody3D
var state := FallState.STANDING
var _fall_time := 0.0
var _rise_from := Transform3D.IDENTITY
var _standing_transform := Transform3D(Basis.IDENTITY, Vector3(0, .85, 0))
var _collision: CollisionShape3D
var _highlight_index := -2
var _cut_material: StandardMaterial3D
var _selected_material: StandardMaterial3D


func _ready() -> void:
	add_to_group("cut_manikin")
	add_to_group("damageable")
	collision_layer = 4
	collision_mask = 0
	_collision = CollisionShape3D.new()
	var standing_shape := CapsuleShape3D.new()
	standing_shape.radius = .28
	standing_shape.height = 1.70
	_collision.shape = standing_shape
	_collision.position.y = .85
	add_child(_collision)

	body_physics = RigidBody3D.new()
	body_physics.name = "FallingBody"
	body_physics.transform = _standing_transform
	body_physics.freeze = true
	body_physics.collision_layer = 0
	body_physics.collision_mask = 1
	body_physics.mass = 18.0
	body_physics.linear_damp = 1.0
	body_physics.angular_damp = 1.2
	var physical_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = .24
	capsule.height = 1.65
	physical_shape.shape = capsule
	body_physics.add_child(physical_shape)
	add_child(body_physics)

	character = Node3D.new()
	character.name = "Character"
	character.position = Vector3(0, -.85, 0)
	character.rotation.y = PI
	character.set_script(CharacterScript)
	body_physics.add_child(character)
	character.appearance.set_variant(true)
	# Манекен тоже носит форму; детали формы разбиваются для отсечения ниже.
	character.appearance.set_outfit("suit")
	character.seek_clip("idle_relaxed", 0.0)
	character.skeleton.force_update_all_bone_transforms()

	_cut_material = StandardMaterial3D.new()
	_cut_material.albedo_color = Color(.39, .09, .085)
	_cut_material.roughness = .9
	_selected_material = StandardMaterial3D.new()
	_selected_material.albedo_color = Color(1.0, .74, .2, .45)
	_selected_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_selected_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in 4:
		parts.append({"state": LimbState.INTACT, "time": 0.0, "debris": null,
			"nodes": [], "stump": null, "growth": null})
	_prepare_visual_parts(character.appearance.body)
	_prepare_visual_parts(character.appearance.suit)
	for i in 4:
		_add_stump(i)


func _prepare_visual_parts(source: MeshInstance3D) -> void:
	var groups := PartMesh.prepare(source.mesh, source.skin)
	source.mesh = groups[0]
	if source.mesh.get_blend_shape_count() > 0:
		source.set_blend_shape_value(0, character.appearance.hand_open)
	for i in 4:
		var mesh: ArrayMesh = groups[i + 1]
		if mesh.get_surface_count() == 0:
			continue
		var node := MeshInstance3D.new()
		node.name = "Prepared_" + LIMBS[i] + "_" + source.name
		node.mesh = mesh
		node.skin = source.skin
		node.skeleton = source.skeleton
		node.transform = source.transform
		node.layers = source.layers
		node.material_override = source.material_override
		if source.has_meta("textile"):
			node.set_meta("textile", true)
		node.custom_aabb = source.custom_aabb
		source.get_parent().add_child(node)
		if mesh.get_blend_shape_count() > 0:
			node.set_blend_shape_value(0, character.appearance.hand_open)
		parts[i].nodes.append(node)


func _add_stump(index: int) -> void:
	var attachment := BoneAttachment3D.new()
	attachment.name = "PreparedStump_" + LIMBS[index]
	attachment.bone_name = STUMP_BONES[index]
	character.skeleton.add_child(attachment)
	var cap := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	var radius := .065 if index < 2 else .09
	sphere.radius = radius
	sphere.height = radius * 1.1
	cap.mesh = sphere
	# This rig's local bone Y points upward from the child towards the
	# parent, so positive local Y moves the cap down the limb in world space.
	cap.position.y = .04 if index < 2 else .12
	cap.material_override = _cut_material
	attachment.add_child(cap)
	attachment.visible = false
	parts[index].stump = attachment


func highlight_limb(index: int) -> void:
	if _highlight_index == index:
		return
	_highlight_index = index
	for i in parts.size():
		for node in parts[i].nodes:
			node.material_overlay = _selected_material if index == i else null


func refresh_cut_visibility() -> void:
	# The room's style pass changes MeshInstance visibility. Never let a
	# graphics-style toggle resurrect a severed limb.
	for i in parts.size():
		_update_part(i)


func is_alive() -> bool:
	return true


func receive_hit(amount: float, hit: Dictionary) -> bool:
	if state != FallState.STANDING:
		return false
	if amount >= STRONG_HIT:
		_knock_down(hit.get("direction_world", Vector3.FORWARD))
	return true


func take_damage(amount: float, direction: Vector3) -> void:
	receive_hit(amount, {"direction_world": direction})


func _knock_down(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0, direction.z).normalized()
	if flat.length_squared() < .01:
		flat = Vector3.FORWARD
	state = FallState.FALLING
	_fall_time = 0.0
	_collision.set_deferred("disabled", true)
	body_physics.freeze = false
	body_physics.apply_central_impulse(flat * 8.0)
	body_physics.angular_velocity = Vector3.UP.cross(flat) * 3.5


func limb_point(index: int) -> Vector3:
	if index < 0 or index >= parts.size():
		return global_position
	var sk: Skeleton3D = character.skeleton
	return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(TARGET_BONES[index])).origin


func sever(index: int, blocked: bool, direction: Vector3) -> bool:
	if index < 0 or index >= parts.size() or state != FallState.STANDING:
		return false
	var part: Dictionary = parts[index]
	if part.state != LimbState.INTACT:
		return false
	part.state = LimbState.BLOCKED if blocked else LimbState.GROWING
	part.time = 0.0
	_spawn_piece(index, direction)
	_update_part(index)
	return true


func _spawn_piece(index: int, direction: Vector3) -> void:
	var part: Dictionary = parts[index]
	var sk: Skeleton3D = character.skeleton
	var origin: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(STUMP_BONES[index])).origin
	var piece := RigidBody3D.new()
	piece.name = "CutPiece_" + LIMBS[index]
	piece.collision_layer = 0
	piece.collision_mask = 1
	piece.mass = 1.5 if index < 2 else 3.0
	var bounds := AABB()
	var first := true
	var growth := Node3D.new()
	growth.name = "Regrowing_" + LIMBS[index]
	part.stump.add_child(growth)
	# The baked vertices use world axes. Preserve those axes at creation,
	# then follow the attached stump as the whole mannequin moves.
	growth.global_transform = Transform3D(Basis.IDENTITY, origin)
	growth.scale = Vector3.ONE * .001
	growth.visible = part.state == LimbState.GROWING
	part.growth = growth
	for source: MeshInstance3D in part.nodes:
		var baked := PartMesh.freeze_mesh(source, character.skeleton, origin)
		var visual := MeshInstance3D.new()
		visual.mesh = baked
		visual.material_override = source.material_override
		visual.layers = source.layers
		piece.add_child(visual)
		var growing_visual := MeshInstance3D.new()
		growing_visual.mesh = baked
		growing_visual.material_override = source.material_override
		growing_visual.layers = source.layers
		growth.add_child(growing_visual)
		for s in baked.get_surface_count():
			var a := baked.surface_get_arrays(s)
			var vertices: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			for vertex in indices:
				if first:
					bounds = AABB(vertices[vertex], Vector3.ZERO)
					first = false
				else:
					bounds = bounds.expand(vertices[vertex])
	# Prepared cap at the proximal end of the detached piece; no realtime
	# cutting or procedural capping at impact.
	var cut_end := MeshInstance3D.new()
	cut_end.mesh = (part.stump.get_child(0) as MeshInstance3D).mesh
	cut_end.position.y = -.04 if index < 2 else -.12
	cut_end.material_override = _cut_material
	piece.add_child(cut_end)
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = bounds.size.max(Vector3(.04, .04, .04))
	collider.shape = shape
	collider.position = bounds.get_center()
	piece.add_child(collider)
	get_parent().add_child(piece)
	piece.global_position = origin
	var push := Vector3(direction.x, 0, direction.z).normalized()
	if push.length_squared() < .01:
		push = Vector3.FORWARD
	piece.linear_velocity = push * 1.1 + Vector3.UP * .45
	piece.angular_velocity = Vector3.UP.cross(push) * 4.0
	part.debris = piece


func _physics_process(delta: float) -> void:
	for i in parts.size():
		var part: Dictionary = parts[i]
		if part.state != LimbState.GROWING:
			continue
		part.time = minf(GROW_TIME, float(part.time) + delta)
		if is_instance_valid(part.growth):
			part.growth.scale = Vector3.ONE * maxf(.001, float(part.time) / GROW_TIME)
		if part.time >= GROW_TIME:
			part.state = LimbState.INTACT
			_clear_piece(part)
			_update_part(i)
	match state:
		FallState.FALLING:
			_fall_time += delta
			if _fall_time >= FALL_TIME:
				_rise_from = body_physics.transform
				body_physics.freeze = true
				body_physics.linear_velocity = Vector3.ZERO
				body_physics.angular_velocity = Vector3.ZERO
				_fall_time = 0.0
				state = FallState.RISING
		FallState.RISING:
			_fall_time += delta
			var t := smoothstep(0.0, 1.0, clampf(_fall_time / STAND_TIME, 0.0, 1.0))
			body_physics.transform = _rise_from.interpolate_with(_standing_transform, t)
			if _fall_time >= STAND_TIME:
				body_physics.transform = _standing_transform
				state = FallState.STANDING
				_collision.set_deferred("disabled", false)


func restore_all() -> void:
	for i in parts.size():
		var part: Dictionary = parts[i]
		part.state = LimbState.INTACT
		part.time = 0.0
		_clear_piece(part)
		_update_part(i)


func _clear_piece(part: Dictionary) -> void:
	if is_instance_valid(part.debris):
		part.debris.queue_free()
	part.debris = null
	if is_instance_valid(part.growth):
		part.growth.queue_free()
	part.growth = null


func _exit_tree() -> void:
	for part in parts:
		_clear_piece(part)


func _update_part(index: int) -> void:
	var part: Dictionary = parts[index]
	var intact: bool = part.state == LimbState.INTACT
	for node in part.nodes:
		node.visible = intact
	part.stump.visible = not intact
