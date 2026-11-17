## Сборка тестовой комнаты кодом, при запуске проекта.
##
## Сделано намеренно так, а не сценой .tscn: в тексте Python/Godot-скрипта
## легко проверить ошибки, а .tscn — это длинный текстовый формат, где опечатка
## ломает файл целиком. Когда комната станет сложной, перенесём в сцену.
extends Node3D

const T := preload("res://scripts/tuning.gd")

var _white: StandardMaterial3D
var _floor_mat: StandardMaterial3D


func _ready() -> void:
	_make_materials()
	_make_light()
	_make_room()
	_make_props()


func _make_materials() -> void:
	_white = StandardMaterial3D.new()
	_white.albedo_color = Color(0.93, 0.945, 0.96)
	_white.roughness = 0.62
	_white.metallic = 0.0

	_floor_mat = StandardMaterial3D.new()
	_floor_mat.albedo_color = Color(0.88, 0.90, 0.93)
	_floor_mat.roughness = 0.28   # пол блестит — как в белой лаборатории
	_floor_mat.metallic = 0.05


func _make_light() -> void:
	# Свет переделан 17.11. Проблема была не в яркости, а в том, что её
	# слишком много сразу: ambient 1.15 + sun 1.5 + две лампы + тональная
	# компрессия FILMIC. Кожа (её собственная яркость 0.77) уходила в белое,
	# и на теле не оставалось ни одного теневого перехода — «зашакалено».
	#
	# Теперь: мягкий рассеянный свет, один направленный с тенью, и снизу
	# подхват, чтобы под подбородком не было чёрной дыры. Суммарная
	# освещённость примерно втрое ниже прежней.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.66, 0.72)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.60, 0.68)
	e.ambient_light_energy = 0.45
	# LINEAR вместо FILMIC: без двойного сжатия яркости, цвета предсказуемее
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	env.environment = e
	add_child(env)

	# основной свет: жёстче и под углом, чтобы читался объём
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -34, 0)
	sun.light_color = Color(1.0, 0.97, 0.93)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30.0
	sun.shadow_bias = 0.03
	add_child(sun)

	# заполняющий свет сверху: мягкий, без тени — чтобы тени не были чёрными
	var fill := OmniLight3D.new()
	fill.position = Vector3(0, 4.2, 2.0)
	fill.light_color = Color(0.85, 0.90, 1.0)
	fill.light_energy = 0.35
	fill.omni_range = 16.0
	fill.shadow_enabled = false
	add_child(fill)


func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _static_box(size: Vector3, pos: Vector3, mat: Material, parent: Node = self) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	_box(size, Vector3.ZERO, mat, body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)
	return body


func _make_room() -> void:
	var w := T.ROOM_WIDTH
	var d := T.ROOM_DEPTH
	var h := T.ROOM_HEIGHT
	var t := 0.3

	# пол и потолок
	_static_box(Vector3(w, t, d), Vector3(0, -t * 0.5, 0), _floor_mat)
	_static_box(Vector3(w, t, d), Vector3(0, h + t * 0.5, 0), _white)
	# стены
	_static_box(Vector3(t, h, d), Vector3(-w * 0.5 - t * 0.5, h * 0.5, 0), _white)
	_static_box(Vector3(t, h, d), Vector3(w * 0.5 + t * 0.5, h * 0.5, 0), _white)
	_static_box(Vector3(w, h, t), Vector3(0, h * 0.5, -d * 0.5 - t * 0.5), _white)
	_static_box(Vector3(w, h, t), Vector3(0, h * 0.5, d * 0.5 + t * 0.5), _white)

	# световые панели в потолке — просто яркие плоскости, без источников света
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = Color(1, 1, 1)
	panel_mat.emission_enabled = true
	panel_mat.emission = Color(1, 1, 1)
	panel_mat.emission_energy_multiplier = 1.6
	for x in [-5.0, 0.0, 5.0]:
		for z in [-5.0, 0.0, 5.0]:
			_box(Vector3(2.6, 0.06, 2.6), Vector3(x, h - 0.06, z), panel_mat)

	# ступени в дальнем конце — проверка, что персонаж переступает
	for i in 3:
		var y := 0.2 * (i + 1)
		_static_box(Vector3(4.0, y, 1.0), Vector3(0, y * 0.5, -7.0 + i * 1.0), _floor_mat)


func _make_props() -> void:
	# «колбы»: статичные цилиндры. Половина целая, половина разбита.
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.75, 0.88, 0.95, 0.30)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.08
	glass.metallic = 0.0

	var pods := [
		[Vector3(-6.0, 1.4, -3.0), false],
		[Vector3(-3.0, 1.4, -5.0), false],
		[Vector3(6.0, 1.4, -3.0), true],
		[Vector3(3.0, 1.4, -5.0), true],
	]
	for pod in pods:
		var pos: Vector3 = pod[0]
		var broken: bool = pod[1]
		if broken:
			# низ колбы остался, верх «разбит» — короткий осколок
			var mi := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.62
			cyl.bottom_radius = 0.7
			cyl.height = 0.7
			mi.mesh = cyl
			mi.material_override = glass
			mi.position = pos - Vector3(0, 0.9, 0)
			add_child(mi)
		else:
			var mi := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.62
			cyl.bottom_radius = 0.7
			cyl.height = 2.8
			mi.mesh = cyl
			mi.material_override = glass
			mi.position = pos
			add_child(mi)
		var base := _static_box(Vector3(1.5, 0.2, 1.5), pos - Vector3(0, 1.4, 0), _white)
		base.name = "PodBase"


## Точка появления игрока.
func spawn_point() -> Vector3:
	return Vector3(0, 1.0, 6.0)
