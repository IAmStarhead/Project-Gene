## Заглушка противника: столб с «головой», по которому можно бить.
##
## Нужна, чтобы проверить конус попадания, урон и ощущение дистанции до того,
## как появится настоящий враг и анимации. Потом заменяется на клон героини.
extends StaticBody3D

const T := preload("res://scripts/tuning.gd")

var health: float = T.DUMMY_HEALTH
var _flash: float = 0.0
var _base_color: Color = Color(0.72, 0.76, 0.86)

@onready var mesh: MeshInstance3D = $Body
@onready var health_bar: Node3D = $HealthBar


func _ready() -> void:
	add_to_group("damageable")
	_set_bar(1.0)


func take_damage(amount: float, from_dir: Vector3) -> void:
	health = max(0.0, health - amount)
	_flash = 1.0
	_set_bar(health / T.DUMMY_HEALTH)
	if health <= 0.0:
		health = T.DUMMY_HEALTH
		_set_bar(1.0)
		# «возврат врагов после отдыха» — простая проверка идеи
		global_position = Vector3(3.5, 1.0, -2.0)


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = max(0.0, _flash - delta * 4.0)
		var mat := mesh.get_active_material(0)
		if mat is StandardMaterial3D:
			mat.albedo_color = _base_color.lerp(Color(1.0, 0.35, 0.35), _flash)


func _set_bar(ratio: float) -> void:
	if health_bar:
		health_bar.scale.x = max(0.02, ratio)
		health_bar.position.x = -(1.0 - health_bar.scale.x) * 0.5
