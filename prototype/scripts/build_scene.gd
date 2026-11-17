## Сборка тестовой комнаты кодом, при запуске проекта.
##
## Сделано намеренно так, а не сценой .tscn: в тексте Python/Godot-скрипта
## легко проверить ошибки, а .tscn — это длинный текстовый формат, где опечатка
## ломает файл целиком. Когда комната станет сложной, перенесём в сцену.
extends Node3D

const T := preload("res://scripts/tuning.gd")

## Селлшейдинг (toon) для персонажей. Включается в tuning.gd, чтобы можно было
## сравнивать с обычным освещением, не переписывая код.
const TOON_SHADER := """
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled;

// ── Селлшейдинг для персонажей ────────────────────────────────────────────
// Зачем: обычное освещение на этой модели не даёт объёма. Кожа — почти
// ровная заливка (яркость 0.77, стандартное отклонение 0.09 по замеру из
// отчёта 19), нормал-карт нет. При плавном затенении лицо и тело выглядят
// плоским пятном, сколько ни подбирай лампы.
//
// Toon решает это иначе: вместо плавного градиента — ТРИ ступени (тень,
// полутень, свет). Границы между ними и создают объём, даже когда сама
// поверхность ровная. Плюс контровой контур по краю силуэта, чтобы
// персонаж не сливался с белой стеной лаборатории.

uniform vec4 base_color : source_color = vec4(0.95, 0.82, 0.76, 1.0);
uniform float light_amount = 1.0;

// Контровой свет по краю силуэта.
uniform vec4 rim_color : source_color = vec4(1.0, 0.98, 0.96, 1.0);
uniform float rim_strength = 0.5;
uniform float rim_power = 2.5;

// Мягкость границ между ступенями. 0 — жёсткие «ступеньки» (манга),
// 0.06 — почти незаметная плавность (мягкий toon, ближе к аниме).
uniform float softness = 0.02;

void fragment() {
	ALBEDO = base_color.rgb * light_amount;
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
	// Край силуэта: чем больше угол между нормалью и взглядом, тем ярче.
	// Считается во фрагменте, потому что во light() нет VIEW.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	EMISSION = rim_color.rgb * rim * rim_strength;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	// Три ступени: 0.30 (тень) -> 0.62 (полутень) -> 0.88 (свет) -> 1.0
	float s1 = smoothstep(0.0 - softness, 0.0 + softness, ndl);
	float s2 = smoothstep(0.45 - softness, 0.45 + softness, ndl);
	float s3 = smoothstep(0.80 - softness, 0.80 + softness, ndl);
	float amount = 0.30 + 0.32 * s1 + 0.26 * s2 + 0.12 * s3;
	DIFFUSE_LIGHT += amount * ATTENUATION * LIGHT_COLOR / PI;
	// Узкий ступенчатый блик: на коже он нужен только как намёк.
	SPECULAR_LIGHT += s3 * 0.10 * ATTENUATION * LIGHT_COLOR / PI;
}
"""

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


## Красит всех персонажей в сцене в селлейдинг. Вызывается из main.gd
## после спавна героини и клона: материалы уже импортированы, остаётся
## подменить их на шейдер.
func apply_toon(root: Node) -> void:
	if not T.TOON_ENABLED:
		return
	var shader := Shader.new()
	shader.code = TOON_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	# Тон кожи берём из модели: у неё текстура почти ровная (средняя яркость
	# 0.77 по замеру из отчёта 19), а цвет лица в палитре — тёплый бежевый.
	mat.set_shader_parameter("base_color", Color(0.95, 0.815, 0.765))
	for mesh in _find_meshes(root):
		var mi := mesh as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var base := mi.mesh.surface_get_material(i)
			# Глаза и линию века оставляем оригинальными: у них своя текстура
			# и они должны оставаться тёмными, иначе взгляд пропадает.
			if base != null and base.resource_name.contains("eye"):
				continue
			mi.set_surface_override_material(i, mat)


func _find_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_meshes(c))
	return out


func _make_light() -> void:
	# Свет, версия 3. История правок:
	#   v1: ambient 1.15 + sun 1.5 + 2 лампы + FILMIC — кожа уходила в белое,
	#       «зашакалено», ни одного теневого перехода.
	#   v2: ambient 0.45 + sun 1.0 + 1 лампа + LINEAR — объём появился, но
	#       стало ТУСКЛО: белая лаборатория должна быть яркой.
	#   v3 (это): ярко, но с контрастом.
	#
	# Секрет в том, что яркость и «плоскость» — разные вещи. Плоско бывает
	# не от большого света, а от РАВНОМЕРНОГО света: когда заполняющий свет
	# почти равен основному, тени исчезают. Поэтому поднимаем общую яркость,
	# но держим основной источник заметно сильнее заполняющего.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.78, 0.82, 0.88)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.72, 0.77, 0.86)
	e.ambient_light_energy = 0.75          # фон не чёрный, но и не «всё белое»
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	# мягкое свечение: белая лаборатория должна «дышать» светом
	e.glow_enabled = true
	e.glow_intensity = 0.35
	e.glow_bloom = 0.06
	e.glow_hdr_threshold = 1.1
	env.environment = e
	add_child(env)

	# Основной свет. Резкий угол и тень — именно он даёт объём на теле.
	# Разница с заполняющим должна быть ощутимой: 1.6 против 0.35.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -40, 0)
	sun.light_color = Color(1.0, 0.99, 0.97)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30.0
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 1.0
	add_child(sun)

	# Заполняющий свет: только чтобы тени не были чёрными. Слабый намеренно.
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.0, 4.0, 3.0)
	fill.light_color = Color(0.88, 0.93, 1.0)
	fill.light_energy = 0.35
	fill.omni_range = 18.0
	fill.shadow_enabled = false
	add_child(fill)

	# Подхват снизу: белый пол отражает свет вверх, в лаборатории это заметно.
	var bounce := OmniLight3D.new()
	bounce.position = Vector3(0.0, 0.35, 2.0)
	bounce.light_color = Color(0.95, 0.96, 1.0)
	bounce.light_energy = 0.20
	bounce.omni_range = 9.0
	bounce.shadow_enabled = false
	add_child(bounce)


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
