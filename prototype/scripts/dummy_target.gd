## Тренировочная мишень-заглушка: принимает урон, вспыхивает и пружинит от удара.
extends StaticBody3D

const T := preload("res://scripts/tuning.gd")

var health: float = T.DUMMY_HEALTH
var _flash: float = 0.0
var _nudge := Vector3.ZERO
var _base_color: Color = Color(0.72, 0.76, 0.86)
var _own_mat: StandardMaterial3D

@onready var mesh: MeshInstance3D = $Body
@onready var health_bar: Node3D = $HealthBar


func _ready() -> void:
	add_to_group("damageable")
	if mesh != null and mesh.material_override is StandardMaterial3D:
		_own_mat = (mesh.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
		mesh.material_override = _own_mat
	_set_bar(1.0)


func is_alive() -> bool:
	return health > 0.0


func take_damage(amount: float, from_dir: Vector3) -> void:
	health = maxf(0.0, health - amount)
	_flash = 1.0
	var flat := Vector3(from_dir.x, 0.0, from_dir.z)
	if flat.length_squared() > 0.0001:
		_nudge = flat.normalized() * T.DUMMY_KNOCKBACK
	_set_bar(health / T.DUMMY_HEALTH)
	if health <= 0.0:
		health = T.DUMMY_HEALTH
		_set_bar(1.0)
		global_position = Vector3(3.5, 1.0, -2.0)


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 4.0)
		if _own_mat != null:
			_own_mat.albedo_color = _base_color.lerp(Color(0.95, 0.30, 0.30), _flash)
	if _nudge.length_squared() > 0.00001:
		_nudge = _nudge.lerp(Vector3.ZERO, 1.0 - exp(-12.0 * delta))
		if mesh != null:
			mesh.position = _nudge


func _set_bar(ratio: float) -> void:
	if health_bar != null:
		health_bar.scale.x = maxf(0.02, ratio)
		health_bar.position.x = -(1.0 - health_bar.scale.x) * 0.5
