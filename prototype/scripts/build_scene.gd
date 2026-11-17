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

// ── Селлшейдинг для персонажей, версия 2 ─────────────────────────────────
// ЧТО БЫЛО НЕ ТАК В ПЕРВОЙ ВЕРСИИ (пользователь: «выглядят как манекены»):
//
//   1. Я ЗАМЕНИЛ МАТЕРИАЛ МОДЕЛИ ЦЕЛИКОМ и потерял текстуру кожи. А в этой
//      текстуре лежит ВСЁ лицо: брови, ноздри, линия губ, румяна. Остался
//      ровный телесный цвет — отсюда кукла без черт лица.
//   2. Затенение было ступенчатым, но с очень низким контрастом: тень 0.30
//      при ambient 0.75 давала «серую заливку», ступеней не читалось.
//   3. Контровой контур шёл по всему силуэту белым — на белом фоне это
//      превращало фигуру в светлое пятно.
//
// Теперь: текстура сохраняется, ступени видны, контур узкий и тёплый.

// Текстура кожи из модели. Если её нет, работает base_color.
uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform bool use_texture = true;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Тёмный контур по краю силуэта. У светлого персонажа на светлом фоне
// именно ТЁМНЫЙ кант читается как обводка, а не белое свечение.
uniform vec4 rim_color : source_color = vec4(0.34, 0.27, 0.31, 1.0);
uniform float rim_strength = 0.55;
uniform float rim_power = 3.0;

// Мягкость границ между ступенями. 0.02 — почти жёсткие ступеньки.
uniform float softness = 0.02;

void fragment() {
	vec3 tex = use_texture ? texture(albedo_tex, UV).rgb : vec3(1.0);
	// Локальный контраст: черты лица (брови, ноздри, линия губ) в текстуре
	// очень бледные. Без подтяжки при ступенчатом свете они пропадают, и
	// лицо становится пустым — это и была жалоба «манекены».
	vec3 grey = vec3(dot(tex, vec3(0.299, 0.587, 0.114)));
	tex = clamp(mix(grey, tex, 1.15) * 1.02, 0.0, 1.0);
	// затемняем всё, что заметно темнее среднего: это и есть черты лица
	float dark = smoothstep(0.86, 0.62, dot(tex, vec3(0.299, 0.587, 0.114)));
	tex *= 1.0 - 0.22 * dark;
	ALBEDO = tex * base_color.rgb;
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
	// Кант по силуэту: чем «боковее» фрагмент, тем темнее край. Затемняем
	// именно ALBEDO, а не добавляем EMISSION: свечение на светлом персонаже
	// даёт «ореол», а нужен тёмный контур, как обводка в рисунке.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	ALBEDO *= mix(vec3(1.0), rim_color.rgb, rim * rim_strength);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	// ЧЕТЫРЕ ступени с большим разбросом, чтобы их было видно на экране:
	// 0.18 (глубокая тень) -> 0.55 -> 0.80 -> 1.0
	float s1 = smoothstep(0.00 - softness, 0.00 + softness, ndl);
	float s2 = smoothstep(0.38 - softness, 0.38 + softness, ndl);
	float s3 = smoothstep(0.72 - softness, 0.72 + softness, ndl);
	// Подняты ВСЕ ступени, особенно нижняя: именно она давала «темновато».
	// Было 0.18 / 0.55 / 0.80 / 1.0 — тень слишком близко к чёрному.
	// Стало 0.42 / 0.68 / 0.86 / 1.0: разница между ступенями сохранена,
	// но провала в темноту нет.
	float amount = 0.42 + 0.26 * s1 + 0.18 * s2 + 0.14 * s3;
	DIFFUSE_LIGHT += amount * ATTENUATION * LIGHT_COLOR / PI;
	// Узкий ступенчатый блик — только намёк на коже.
	SPECULAR_LIGHT += s3 * 0.08 * ATTENUATION * LIGHT_COLOR / PI;
}
"""

var _white: StandardMaterial3D
var _floor_mat: StandardMaterial3D


var _env: WorldEnvironment
var _sun: DirectionalLight3D
var _fill: OmniLight3D
var _bounce: OmniLight3D


func _ready() -> void:
	add_to_group("world")
	_make_materials()
	_make_light()
	_make_room()
	_make_props()


## Пересобирает свет под текущий стиль. Вызывается клавишей G из player.gd.
## Нужна потому, что под toon заполняющий свет должен быть слабее, иначе
## ступени затенения размываются и снова получается «манекен».
func rebuild_lighting(_toon: bool) -> void:
	if is_instance_valid(_sun):
		_sun.queue_free()
	if is_instance_valid(_fill):
		_fill.queue_free()
	if is_instance_valid(_bounce):
		_bounce.queue_free()
	if is_instance_valid(_env):
		_env.queue_free()
	_make_light()


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
	# Headless-тесты используют Dummy renderer: GPU-материал там не нужен
	# и в Godot 4.7 вызывает ошибку при освобождении RID шейдера.
	if not T.TOON_ENABLED or DisplayServer.get_name() == "headless":
		return
	var shader := Shader.new()
	shader.code = TOON_SHADER
	for mesh in _find_meshes(root):
		var mi := mesh as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var base := mi.mesh.surface_get_material(i)
			# Глаза и линию века НЕ ТРОГАЕМ. У них своя текстура и свой
			# тёмный цвет; если перекрасить их в кожу — как раз и получится
			# взгляд манекена (два серых овала вместо глаз).
			if base != null and base.resource_name.contains("eye"):
				continue
			var mat := ShaderMaterial.new()
			mat.shader = shader
			# ГЛАВНОЕ: забираем текстуру у родного материала модели.
			# В ней брови, ноздри, линия губ. Без неё лицо пустое.
			var tex: Texture2D = null
			if base is BaseMaterial3D:
				var b3 := base as BaseMaterial3D
				if b3.albedo_texture != null:
					tex = b3.albedo_texture
			if tex != null:
				mat.set_shader_parameter("albedo_tex", tex)
				mat.set_shader_parameter("use_texture", true)
				mat.set_shader_parameter("base_color", Color(1, 1, 1))
			else:
				mat.set_shader_parameter("use_texture", false)
				mat.set_shader_parameter("base_color", Color(0.95, 0.82, 0.76))
			mi.set_surface_override_material(i, mat)


## Свет специально для витрины: нейтрально-серый фон и сильный контраст
## между светом и тенью. В игре нужен «стерильный» яркий свет, но на витрине
## задача другая — видеть, как легла складка и куда ушёл локоть.
func showcase_lighting() -> void:
	if is_instance_valid(_env):
		_env.queue_free()
	if is_instance_valid(_sun):
		_sun.queue_free()
	if is_instance_valid(_fill):
		_fill.queue_free()
	if is_instance_valid(_bounce):
		_bounce.queue_free()
	_make_light()
	if is_instance_valid(_env) and _env.environment != null:
		_env.environment.background_color = Color(0.30, 0.32, 0.36)
		_env.environment.ambient_light_color = Color(0.55, 0.58, 0.66)
		_env.environment.ambient_light_energy = 0.55
	if is_instance_valid(_sun):
		_sun.light_energy = 2.3
		_sun.rotation_degrees = Vector3(-38, -55, 0)


## Возвращает родные материалы модели (выключение селлшейдинга).
func clear_toon(root: Node) -> void:
	for mesh in _find_meshes(root):
		var mi := mesh as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, null)


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
	# Три уровня яркости. Заполняющий свет идёт ВВЕРХ сильнее, чем солнце:
	# именно он вытягивает тени из черноты, а солнце добавляет контраста.
	# 0: сумрачно (как было) / 1: средне / 2: ярко
	var b: int = clampi(T.BRIGHTNESS, 0, 2)
	var amb_table := [0.62, 0.95, 1.30]
	var sun_table := [1.35, 1.75, 2.10]
	var fill_table := [0.30, 0.55, 0.85]
	e.ambient_light_color = [Color(0.72, 0.77, 0.86), Color(0.82, 0.86, 0.93), Color(0.90, 0.93, 0.98)][b]
	e.background_color = [Color(0.78, 0.82, 0.88), Color(0.86, 0.89, 0.94), Color(0.93, 0.95, 0.98)][b]
	e.ambient_light_energy = amb_table[b] if T.TOON_ENABLED else amb_table[b] + 0.15
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	# мягкое свечение: белая лаборатория должна «дышать» светом
	e.glow_enabled = true
	e.glow_intensity = 0.35
	e.glow_bloom = 0.06
	e.glow_hdr_threshold = 1.1
	env.environment = e
	add_child(env)
	_env = env
	# Ничего не пишем в project.godot во время игры: сохранение настроек
	# проекта из кода — лишний побочный эффект, который потом удивляет.

	# Основной свет. Резкий угол и тень — именно он даёт объём на теле.
	# Разница с заполняющим должна быть ощутимой: 1.6 против 0.35.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -40, 0)
	sun.light_color = Color(1.0, 0.99, 0.97)
	sun.light_energy = sun_table[b] if T.TOON_ENABLED else sun_table[b] + 0.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30.0
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 1.0
	add_child(sun)
	_sun = sun

	# Заполняющий свет: только чтобы тени не были чёрными. Слабый намеренно.
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.0, 4.0, 3.0)
	fill.light_color = Color(0.88, 0.93, 1.0)
	fill.light_energy = fill_table[b]
	fill.omni_range = 18.0
	fill.shadow_enabled = false
	add_child(fill)
	_fill = fill

	# Подхват снизу: белый пол отражает свет вверх, в лаборатории это заметно.
	var bounce := OmniLight3D.new()
	bounce.position = Vector3(0.0, 0.35, 2.0)
	bounce.light_color = Color(0.95, 0.96, 1.0)
	bounce.light_energy = 0.20 + 0.15 * b
	bounce.omni_range = 9.0
	bounce.shadow_enabled = false
	add_child(bounce)
	_bounce = bounce


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
