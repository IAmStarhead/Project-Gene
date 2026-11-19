## Отдельный тренировочный манекен, не модель героини.
## Заранее подготовленные конечности и закрытые срезы; без runtime-разрезания мешей.
extends StaticBody3D

const LIMBS := ["arm_left", "arm_right", "leg_left", "leg_right"]
const LABELS := ["левая рука", "правая рука", "левая нога", "правая нога"]
const GROW_TIME := 12.0 # Ускоренная лабораторная проверка, не игровой баланс.

enum LimbState { INTACT, GROWING, BLOCKED }
var parts: Array[Dictionary] = []
var _body_material: StandardMaterial3D
var _cut_material: StandardMaterial3D
var _selected_material: StandardMaterial3D
var _label: Label3D


func _ready() -> void:
	add_to_group("cut_manikin")
	add_to_group("damageable") # Разрешаем обычный захват цели.
	collision_layer = 4
	collision_mask = 0
	_body_material = _mat(Color(.43, .57, .62))
	_cut_material = _mat(Color(.55, .13, .11))
	_selected_material = _mat(Color(.96, .70, .20))
	var base := _mat(Color(.18, .27, .30))
	var joint := _mat(Color(.74, .63, .39))
	var collision := CollisionShape3D.new()
	var collision_shape := CapsuleShape3D.new()
	collision_shape.radius = .28
	collision_shape.height = 1.70
	collision.shape = collision_shape
	collision.position.y = .85
	add_child(collision)
	_capsule(self, .25, .66, Vector3(0, 1.13, 0), _body_material)
	_capsule(self, .15, .30, Vector3(0, 1.70, 0), base)
	_box(self, Vector3(.40, .18, .22), Vector3(0, .77, 0), base)
	# Верхняя точка каждой детали — фиксированное место будущего среза.
	_add_limb(Vector3(-.36, 1.46, 0), .69, .083, joint)
	_add_limb(Vector3(.36, 1.46, 0), .69, .083, joint)
	_add_limb(Vector3(-.14, .76, 0), .73, .095, joint)
	_add_limb(Vector3(.14, .76, 0), .73, .095, joint)
	_make_label()
	_update_label()


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = .72
	return m


func _capsule(parent: Node3D, radius: float, height: float, pos: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.0)
	mesh.radial_segments = 12
	mesh.rings = 4
	node.mesh = mesh
	node.position = pos
	node.material_override = material
	node.layers = 2
	parent.add_child(node)
	return node


func _box(parent: Node3D, size: Vector3, pos: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = pos
	node.material_override = material
	node.layers = 2
	parent.add_child(node)
	return node


func _add_limb(origin: Vector3, length: float, radius: float, joint: Material) -> void:
	var whole := Node3D.new()
	whole.position = origin
	add_child(whole)
	_capsule(whole, radius, length, Vector3(0, -length / 2.0, 0), _body_material)
	# Культя создана до удара и скрыта внутри целой конечности.
	var stump := Node3D.new()
	stump.position = origin
	add_child(stump)
	_box(stump, Vector3(radius * 1.9, .025, radius * 1.9), Vector3(0, -.012, 0), _cut_material)
	var stages: Array[Node3D] = []
	for fraction in [.25, .60, .85]:
		var stage := Node3D.new()
		stage.position = origin
		add_child(stage)
		var stage_length: float = length * fraction
		var r := minf(radius, stage_length * .45)
		_capsule(stage, r, stage_length, Vector3(0, -stage_length / 2.0, 0), _body_material)
		_box(stage, Vector3(r * 1.8, .02, r * 1.8), Vector3(0, -stage_length, 0), _cut_material)
		stages.append(stage)
	# Золотистое крепление визуально показывает, что это учебный манекен.
	_capsule(self, radius * 1.12, radius * 2.24, origin + Vector3(0, .02, 0), joint)
	parts.append({"origin": origin, "length": length, "radius": radius, "whole": whole,
		"stump": stump, "stages": stages, "state": LimbState.INTACT, "time": 0.0, "debris": null})
	_update_part(parts.size() - 1)


func _make_label() -> void:
	_label = Label3D.new()
	_label.text = "МАНЕКЕН ДЛЯ КЛИНКА [V]"
	_label.position = Vector3(0, 1.98, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = .0007
	_label.font_size = 36
	_label.outline_size = 12
	_label.layers = 2
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_label)


func _update_label() -> void:
	var blocked := 0
	var growing := 0
	for part in parts:
		blocked += 1 if part.state == LimbState.BLOCKED else 0
		growing += 1 if part.state == LimbState.GROWING else 0
	_label.text = "МАНЕКЕН [V]  ·  рост: %d  ·  блок: %d" % [growing, blocked]


func highlight_limb(index: int) -> void:
	for i in parts.size():
		var node: MeshInstance3D = parts[i].whole.get_child(0)
		node.material_override = _selected_material if i == index else _body_material


func is_alive() -> bool:
	return true


func take_damage(_amount: float, _from: Vector3) -> void:
	# Кулаки не отрубают части манекена.
	pass


func limb_point(index: int) -> Vector3:
	var part: Dictionary = parts[index]
	return to_global(part.origin + Vector3(0, -float(part.length) * .3, 0))


func sever(index: int, blocked: bool, direction: Vector3) -> bool:
	if index < 0 or index >= parts.size():
		return false
	var part: Dictionary = parts[index]
	if part.state != LimbState.INTACT:
		return false
	part.state = LimbState.BLOCKED if blocked else LimbState.GROWING
	part.time = 0.0
	_spawn_piece(index, direction)
	_update_part(index)
	_update_label()
	return true


func _spawn_piece(index: int, direction: Vector3) -> void:
	var part: Dictionary = parts[index]
	var piece := RigidBody3D.new()
	piece.name = "CutPiece_" + LIMBS[index]
	piece.collision_layer = 0
	piece.collision_mask = 1 # Только пол и окружение, не толкает героиню.
	var length: float = part.length
	var radius: float = part.radius
	_capsule(piece, radius, length, Vector3.ZERO, _body_material)
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = length
	collider.shape = shape
	piece.add_child(collider)
	get_parent().add_child(piece)
	piece.global_transform = global_transform * Transform3D(Basis.IDENTITY, part.origin + Vector3(0, -length * .5, 0))
	piece.linear_velocity = direction.normalized() * .65 + Vector3.UP * .25
	part.debris = piece


func _physics_process(delta: float) -> void:
	for i in parts.size():
		var part: Dictionary = parts[i]
		if part.state != LimbState.GROWING:
			continue
		part.time = minf(GROW_TIME, float(part.time) + delta)
		if part.time >= GROW_TIME:
			part.state = LimbState.INTACT
			_clear_piece(part)
			_update_label()
		_update_part(i)


func restore_all() -> void:
	for i in parts.size():
		var part: Dictionary = parts[i]
		part.state = LimbState.INTACT
		part.time = 0.0
		_clear_piece(part)
		_update_part(i)
	_update_label()


func _clear_piece(part: Dictionary) -> void:
	if is_instance_valid(part.debris):
		part.debris.queue_free()
	part.debris = null


func _exit_tree() -> void:
	for part in parts:
		_clear_piece(part)


func _update_part(index: int) -> void:
	var part: Dictionary = parts[index]
	var alive: bool = part.state == LimbState.INTACT
	part.whole.visible = alive
	var stage_index := -1
	if part.state == LimbState.GROWING:
		stage_index = clampi(int(float(part.time) / GROW_TIME * 4.0) - 1, -1, 2)
	part.stump.visible = not alive and stage_index == -1
	for i in part.stages.size():
		part.stages[i].visible = i == stage_index
