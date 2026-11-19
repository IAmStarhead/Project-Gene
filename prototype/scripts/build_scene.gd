## Сборка стерильного белого лабораторного зала в духе Mirror's Edge и концепта криокапсул.
##
## Ключевые архитектурные и технические решения (под i3-7100U + GeForce 940MX):
##   • Внешняя оболочка (потолок, 4 стены, световые панели, стекло) НЕ отбрасывает теней,
##     поэтому верхний ключевой свет свободно освещает зал и рисует мягкие тени от героини,
##     клона, опор капсул, ступеней и настенных пилястр.
##   • Кэшированные процедурные текстуры белой напольной плитки и стеновых панелей (256x256
##     с мипмапами) дают мгновенное ощущение масштаба и скорости почти без расхода видеопамяти.
##   • Серебристые плинтусы, верхний фриз, пилястры, заблокированная гермодверь, окантовка
##     ступеней, криокапсулы с честной коллизией и тёмно-алый след у разбитой колбы задают
##     атмосферу чистого биокомплекса без «молочной каши».
##   • По умолчанию персонажи используют лёгкий полуреалистичный PBR кожи с мягким переходом
##     света, сохраняя текстуру лица, тёмную линию верхних век, живой блеск глаз и ткань халата;
##     неиспользуемый дубль меша face_blink скрывается (-18 176 вершин скиннинга на персонажа).
extends Node3D

const T := preload("res://scripts/tuning.gd")
const ToonLight := preload("res://shaders/toon_light.gd")

const WORLD_LAYER := 1
const CHARACTER_VISUAL_LAYER := 2

# Опциональный мягкий селлшейдинг (включается только по клавише G для сравнения).
const TOON_SHADER := """
shader_type spatial;
render_mode diffuse_toon, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap;
uniform bool use_texture = true;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 rim_color : source_color = vec4(0.42, 0.36, 0.40, 1.0);
uniform float rim_strength : hint_range(0.0, 0.8) = 0.28;

void fragment() {
	vec3 tex = use_texture ? texture(albedo_tex, UV).rgb : vec3(1.0);
	ALBEDO = tex * base_color.rgb;
	ROUGHNESS = 0.62;
	SPECULAR = 0.22;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.2);
	ALBEDO *= mix(vec3(1.0), rim_color.rgb, rim * rim_strength);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float band = 0.0;
	if (ndl > 0.58) {
		band = 1.0;
	} else if (ndl > 0.20) {
		band = 0.68;
	} else if (ndl > -0.08) {
		band = 0.34;
	}
	DIFFUSE_LIGHT += band * ATTENUATION * LIGHT_COLOR / PI;
}
"""

static var _cached_floor_tex: ImageTexture = null
static var _cached_wall_tex: ImageTexture = null
static var _cached_toon_shader: Shader = null
# Keep immutable PBR AND toon overrides alive across main/showcase handoffs.
# The upstream renderer defaults to PBR, so carrying only the old toon cache
# would lose the GLES3 material-lifetime fix from repair 41. Never share/mutate
# the per-actor textile variant through these caches.
static var _cached_skin_materials: Dictionary = {}
static var _cached_toon_materials: Dictionary = {}

var _world_env: WorldEnvironment
var _env: Environment
var _sun: DirectionalLight3D
var _fill_a: OmniLight3D
var _fill_b: OmniLight3D
var _probe: ReflectionProbe
var _is_showcase := false

var _floor_mat: StandardMaterial3D
var _wall_mat: StandardMaterial3D
var _ceiling_mat: StandardMaterial3D
var _trim_mat: StandardMaterial3D
var _dark_detail_mat: StandardMaterial3D
var _housing_mat: StandardMaterial3D
var _panel_mat: StandardMaterial3D
var _glass_mat: StandardMaterial3D
var _pod_core_mat: StandardMaterial3D
var _status_cyan_mat: StandardMaterial3D
var _status_lock_mat: StandardMaterial3D
var _blood_mat: StandardMaterial3D


func _ready() -> void:
	add_to_group("world")
	_make_materials()
	_make_light()
	_make_room()
	_make_trim_and_door()
	_make_props()
	_make_stairs_and_deck()
	apply_quality()


func _make_materials() -> void:
	var headless := DisplayServer.get_name() == "headless"

	# Белый эпоксидный пол с тонкими швами: отражает световые панели, даёт чёткое чувство скорости.
	_floor_mat = StandardMaterial3D.new()
	if not headless:
		_floor_mat.albedo_color = Color.WHITE
		_floor_mat.albedo_texture = _get_floor_texture()
		_floor_mat.uv1_triplanar = true
		_floor_mat.uv1_world_triplanar = true
		_floor_mat.uv1_scale = Vector3(0.55, 0.55, 0.55)
	else:
		_floor_mat.albedo_color = Color(0.86, 0.878, 0.90)
	_floor_mat.roughness = 0.28
	_floor_mat.metallic = 0.02
	_floor_mat.metallic_specular = 0.42

	# Модульные стеновые панели чистой лаборатории — матово-сатиновые, чуть светлее пола.
	_wall_mat = StandardMaterial3D.new()
	if not headless:
		_wall_mat.albedo_color = Color.WHITE
		_wall_mat.albedo_texture = _get_wall_texture()
		_wall_mat.uv1_triplanar = true
		_wall_mat.uv1_world_triplanar = true
		_wall_mat.uv1_scale = Vector3(0.55, 0.55, 0.55)
	else:
		_wall_mat.albedo_color = Color(0.925, 0.938, 0.952)
	_wall_mat.roughness = 0.58
	_wall_mat.metallic_specular = 0.25

	# Белый потолок с мягким собственным свечением (имитирует рассеянный свет чистой комнаты).
	_ceiling_mat = StandardMaterial3D.new()
	_ceiling_mat.albedo_color = Color(0.94, 0.95, 0.97)
	_ceiling_mat.roughness = 0.72
	_ceiling_mat.emission_enabled = true
	_ceiling_mat.emission = Color(0.72, 0.745, 0.785)
	_ceiling_mat.emission_energy_multiplier = 1.0

	# Анодированный серебристо-стальной профиль (плинтус, фриз, рамки, кромки ступеней, кольца колб).
	_trim_mat = StandardMaterial3D.new()
	_trim_mat.albedo_color = Color(0.56, 0.60, 0.65)
	_trim_mat.roughness = 0.38
	_trim_mat.metallic = 0.14
	_trim_mat.metallic_specular = 0.48

	# Тёмный технический шов гермодвери.
	_dark_detail_mat = StandardMaterial3D.new()
	_dark_detail_mat.albedo_color = Color(0.28, 0.31, 0.36)
	_dark_detail_mat.roughness = 0.48

	# Белый медицинский композит корпусов криокапсул, пилястр и створок двери (без пересвета в 255).
	_housing_mat = StandardMaterial3D.new()
	_housing_mat.albedo_color = Color(0.83, 0.85, 0.88)
	_housing_mat.roughness = 0.36
	_housing_mat.metallic_specular = 0.42

	# Потолочные световые диффузоры — чистый ровный белый свет, ясно выделяющийся на потолке.
	_panel_mat = StandardMaterial3D.new()
	_panel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_panel_mat.albedo_color = Color(0.985, 0.992, 1.0)

	# Прозрачное медицинское стекло капсул и осколков (без сплошной тени).
	_glass_mat = StandardMaterial3D.new()
	_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glass_mat.albedo_color = Color(0.68, 0.84, 0.90, 0.30)
	_glass_mat.roughness = 0.08
	_glass_mat.metallic = 0.05
	_glass_mat.metallic_specular = 0.75
	_glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Холодная био-дымка внутри целых капсул.
	_pod_core_mat = StandardMaterial3D.new()
	_pod_core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pod_core_mat.albedo_color = Color(0.78, 0.92, 0.96, 0.14)
	_pod_core_mat.roughness = 0.35
	_pod_core_mat.emission_enabled = true
	_pod_core_mat.emission = Color(0.60, 0.82, 0.90)
	_pod_core_mat.emission_energy_multiplier = 0.35

	# Компактные индикаторы статуса (без дополнительных источников света — 0 нагрузки на GPU).
	_status_cyan_mat = StandardMaterial3D.new()
	_status_cyan_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_status_cyan_mat.albedo_color = Color(0.42, 0.86, 0.95)

	_status_lock_mat = StandardMaterial3D.new()
	_status_lock_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_status_lock_mat.albedo_color = Color(0.86, 0.22, 0.20)

	# Небольшой засохший тёмно-алый след у разбитой капсулы (акцент контраста на белом полу).
	_blood_mat = StandardMaterial3D.new()
	_blood_mat.albedo_color = Color(0.32, 0.028, 0.032)
	_blood_mat.roughness = 0.30
	_blood_mat.metallic_specular = 0.45


static func _get_floor_texture() -> ImageTexture:
	if _cached_floor_tex != null:
		return _cached_floor_tex
	const S := 256
	var data := PackedByteArray()
	data.resize(S * S * 3)
	for y in range(S):
		var dy := mini(y, S - 1 - y)
		var dmid_y := absi(y - S / 2)
		for x in range(S):
			var dx := mini(x, S - 1 - x)
			var dmid_x := absi(x - S / 2)
			var edge := mini(dx, dy)
			var sub := mini(dmid_x, dmid_y)
			var r := 220
			var g := 224
			var b := 230
			if edge <= 1:
				r = 172
				g = 180
				b = 191
			elif edge == 2:
				r = 198
				g = 204
				b = 213
			elif edge == 3:
				r = 227
				g = 231
				b = 236
			elif sub == 0:
				r = 203
				g = 209
				b = 217
			var idx := (y * S + x) * 3
			data[idx] = r
			data[idx + 1] = g
			data[idx + 2] = b
	var img := Image.create_from_data(S, S, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	_cached_floor_tex = ImageTexture.create_from_image(img)
	return _cached_floor_tex


static func _get_wall_texture() -> ImageTexture:
	if _cached_wall_tex != null:
		return _cached_wall_tex
	const S := 256
	var data := PackedByteArray()
	data.resize(S * S * 3)
	for y in range(S):
		var dy := mini(y, S - 1 - y)
		for x in range(S):
			var dx := mini(x, S - 1 - x)
			var edge := mini(dx, dy)
			var r := 236
			var g := 239
			var b := 243
			if edge <= 1:
				r = 204
				g = 210
				b = 219
			elif edge == 2:
				r = 223
				g = 227
				b = 233
			var idx := (y * S + x) * 3
			data[idx] = r
			data[idx + 1] = g
			data[idx + 2] = b
	var img := Image.create_from_data(S, S, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	_cached_wall_tex = ImageTexture.create_from_image(img)
	return _cached_wall_tex


func _make_light() -> void:
	_env = ToonLight.make_environment(T.BRIGHTNESS, T.QUALITY, _is_showcase)
	_world_env = WorldEnvironment.new()
	_world_env.name = "WorldEnvironment"
	_world_env.environment = _env
	add_child(_world_env)

	_sun = DirectionalLight3D.new()
	_sun.name = "KeyLight"
	ToonLight.configure_sun(_sun, T.BRIGHTNESS, _is_showcase)
	add_child(_sun)

	_fill_a = OmniLight3D.new()
	_fill_a.name = "CeilingFillA"
	_fill_a.position = Vector3(-3.8, T.ROOM_HEIGHT - 0.55, -2.6)
	ToonLight.configure_fill(_fill_a, T.BRIGHTNESS, false, T.QUALITY, _is_showcase)
	add_child(_fill_a)

	_fill_b = OmniLight3D.new()
	_fill_b.name = "CeilingFillB"
	_fill_b.position = Vector3(3.8, T.ROOM_HEIGHT - 0.55, 2.6)
	ToonLight.configure_fill(_fill_b, T.BRIGHTNESS, true, T.QUALITY, _is_showcase)
	add_child(_fill_b)

	_probe = ReflectionProbe.new()
	_probe.name = "LabReflectionProbe"
	_probe.position = Vector3(0.0, T.ROOM_HEIGHT * 0.5, 0.0)
	ToonLight.configure_probe(
		_probe,
		Vector3(T.ROOM_WIDTH, T.ROOM_HEIGHT, T.ROOM_DEPTH),
		T.QUALITY,
		_is_showcase
	)
	add_child(_probe)


## Обновляет свет на месте без пересоздания узлов и мерцания кадра.
func rebuild_lighting(_toon: bool = false) -> void:
	if _env == null:
		return
	ToonLight.apply_environment(_env, T.BRIGHTNESS, T.QUALITY, _is_showcase)
	ToonLight.configure_sun(_sun, T.BRIGHTNESS, _is_showcase)
	if _is_showcase:
		_fill_a.position = Vector3(2.8, 2.6, 2.8)
		_fill_b.position = Vector3(-2.6, 2.8, -2.6)
	else:
		_fill_a.position = Vector3(-3.8, T.ROOM_HEIGHT - 0.55, -2.6)
		_fill_b.position = Vector3(3.8, T.ROOM_HEIGHT - 0.55, 2.6)
	ToonLight.configure_fill(_fill_a, T.BRIGHTNESS, false, T.QUALITY, _is_showcase)
	ToonLight.configure_fill(_fill_b, T.BRIGHTNESS, true, T.QUALITY, _is_showcase)
	ToonLight.configure_probe(
		_probe,
		Vector3(T.ROOM_WIDTH, T.ROOM_HEIGHT, T.ROOM_DEPTH),
		T.QUALITY,
		_is_showcase
	)
	_apply_surface_mood()


## Применяет пресет качества графики (F4 или меню паузы) к вьюпорту и освещению.
func apply_quality() -> void:
	ToonLight.apply_viewport_quality(get_viewport(), T.QUALITY)
	rebuild_lighting(T.TOON_ENABLED)


## Студийный свет для витрины анимаций (H): сохраняется при переключении B, G и F4.
func showcase_lighting() -> void:
	_is_showcase = true
	apply_quality()


func _apply_surface_mood() -> void:
	if _floor_mat == null or _wall_mat == null or _ceiling_mat == null:
		return
	var headless := DisplayServer.get_name() == "headless"
	if _is_showcase:
		# В витрине фон чуть спокойнее, чтобы белый халат, руки и подошвы читались идеально.
		_floor_mat.albedo_color = Color(0.76, 0.785, 0.825)
		_wall_mat.albedo_color = Color(0.78, 0.805, 0.845)
		_ceiling_mat.emission_energy_multiplier = 0.34
	else:
		# Реалистичный коэффициент отражения белого эпоксидного пола и панелей (как в Mirror's Edge):
		# зал остаётся стерильно-белым, но швы плитки, ступени, тени и лицо не выбиваются в 255.
		_floor_mat.albedo_color = Color(0.80, 0.82, 0.85) if not headless else Color(0.82, 0.84, 0.87)
		_wall_mat.albedo_color = Color(0.82, 0.84, 0.87) if not headless else Color(0.85, 0.87, 0.90)
		_ceiling_mat.emission_energy_multiplier = 0.42


func _make_room() -> void:
	var w := T.ROOM_WIDTH
	var d := T.ROOM_DEPTH
	var h := T.ROOM_HEIGHT
	var t := 0.35

	# Внешняя оболочка не отбрасывает тени — ключевой свет сверху свободно освещает весь зал.
	_static_box(Vector3(w, t, d), Vector3(0.0, -t * 0.5, 0.0), _floor_mat, false)
	_decor_box(Vector3(w + t * 2.0, t, d + t * 2.0), Vector3(0.0, h + t * 0.5, 0.0), _ceiling_mat, false)

	_static_box(Vector3(t, h, d), Vector3(-w * 0.5 - t * 0.5, h * 0.5, 0.0), _wall_mat, false)
	_static_box(Vector3(t, h, d), Vector3(w * 0.5 + t * 0.5, h * 0.5, 0.0), _wall_mat, false)
	_static_box(Vector3(w + t * 2.0, h, t), Vector3(0.0, h * 0.5, -d * 0.5 - t * 0.5), _wall_mat, false)
	_static_box(Vector3(w + t * 2.0, h, t), Vector3(0.0, h * 0.5, d * 0.5 + t * 0.5), _wall_mat, false)

	# 9 потолочных световых секций в металлических рамках (отражаются на белом полу и в колбах).
	for x in [-5.2, 0.0, 5.2]:
		for z in [-5.2, 0.0, 5.2]:
			_decor_box(Vector3(2.58, 0.05, 1.48), Vector3(x, h - 0.025, z), _trim_mat, false)
			_decor_box(Vector3(2.36, 0.04, 1.26), Vector3(x, h - 0.055, z), _panel_mat, false)


func _make_trim_and_door() -> void:
	var hx := T.ROOM_WIDTH * 0.5
	var hz := T.ROOM_DEPTH * 0.5
	var h := T.ROOM_HEIGHT

	# Серебристый плинтус по всему периметру — чёткая линия стыка пола и стен.
	var ph := 0.16
	var pd := 0.04
	_decor_box(Vector3(T.ROOM_WIDTH, ph, pd), Vector3(0.0, ph * 0.5, -hz + pd * 0.5), _trim_mat, false)
	_decor_box(Vector3(T.ROOM_WIDTH, ph, pd), Vector3(0.0, ph * 0.5, hz - pd * 0.5), _trim_mat, false)
	_decor_box(Vector3(pd, ph, T.ROOM_DEPTH), Vector3(-hx + pd * 0.5, ph * 0.5, 0.0), _trim_mat, false)
	_decor_box(Vector3(pd, ph, T.ROOM_DEPTH), Vector3(hx - pd * 0.5, ph * 0.5, 0.0), _trim_mat, false)

	# Верхний технический фриз — чёткая граница между стенами и потолком.
	var fh := 0.18
	var fd := 0.05
	var fy := h - fh * 0.5
	_decor_box(Vector3(T.ROOM_WIDTH, fh, fd), Vector3(0.0, fy, -hz + fd * 0.5), _trim_mat, false)
	_decor_box(Vector3(T.ROOM_WIDTH, fh, fd), Vector3(0.0, fy, hz - fd * 0.5), _trim_mat, false)
	_decor_box(Vector3(fd, fh, T.ROOM_DEPTH), Vector3(-hx + fd * 0.5, fy, 0.0), _trim_mat, false)
	_decor_box(Vector3(fd, fh, T.ROOM_DEPTH), Vector3(hx - fd * 0.5, fy, 0.0), _trim_mat, false)

	# Рельефные пилястры с вертикальными стальными вставками (отбрасывают лёгкую архитектурную тень).
	for z in [-5.4, 0.0, 5.4]:
		for side in [-1.0, 1.0]:
			_static_box(Vector3(0.28, h, 0.46), Vector3(side * (hx - 0.14), h * 0.5, z), _housing_mat, true)
			_decor_box(Vector3(0.03, h - 0.5, 0.08), Vector3(side * (hx - 0.295), h * 0.5, z), _trim_mat, false)

	for sx in [-4.2, 4.2]:
		_static_box(Vector3(0.46, h, 0.28), Vector3(sx, h * 0.5, -hz + 0.14), _housing_mat, true)
		_decor_box(Vector3(0.08, h - 0.5, 0.03), Vector3(sx, h * 0.5, -hz + 0.295), _trim_mat, false)

	# Заблокированная гермодверь Сектора 01 позади точки появления героини.
	_decor_box(Vector3(2.76, 0.22, 0.16), Vector3(0.0, 3.05, hz - 0.08), _trim_mat, false)
	_decor_box(Vector3(0.22, 3.16, 0.16), Vector3(-1.27, 1.58, hz - 0.08), _trim_mat, false)
	_decor_box(Vector3(0.22, 3.16, 0.16), Vector3(1.27, 1.58, hz - 0.08), _trim_mat, false)
	_decor_box(Vector3(1.12, 2.92, 0.09), Vector3(-0.58, 1.46, hz - 0.045), _housing_mat, false)
	_decor_box(Vector3(1.12, 2.92, 0.09), Vector3(0.58, 1.46, hz - 0.045), _housing_mat, false)
	_decor_box(Vector3(0.04, 2.92, 0.10), Vector3(0.0, 1.46, hz - 0.05), _dark_detail_mat, false)
	_decor_box(Vector3(2.28, 0.08, 0.11), Vector3(0.0, 1.38, hz - 0.055), _trim_mat, false)
	_decor_box(Vector3(0.56, 0.045, 0.03), Vector3(0.0, 3.28, hz - 0.02), _status_lock_mat, false)


func _make_props() -> void:
	# Две целые криокапсулы слева, две вскрытые справа; весь центр зала свободен для боя и витрины.
	_make_pod(Vector3(-5.8, 0.0, -2.2), false, 0.38)
	_make_pod(Vector3(-5.2, 0.0, -5.8), false, 0.55)
	_make_pod(Vector3(5.8, 0.0, -2.2), true, -0.38)
	_make_pod(Vector3(5.2, 0.0, -5.8), true, -0.55)

	# Тёмно-алый биослед у вскрытой капсулы (отсылка к концепт-арту 02-white-pod-chamber).
	_floor_disc(0.36, Vector3(4.58, 0.004, -2.55), _blood_mat)
	_floor_disc(0.27, Vector3(4.32, 0.004, -2.78), _blood_mat)
	_floor_disc(0.18, Vector3(4.12, 0.004, -2.52), _blood_mat)
	_floor_disc(0.09, Vector3(3.86, 0.004, -2.34), _blood_mat)


func _make_pod(origin: Vector3, broken: bool, yaw_rad: float) -> void:
	var pod := StaticBody3D.new()
	pod.name = "PodBroken" if broken else "PodIntact"
	pod.position = origin
	pod.rotation.y = yaw_rad
	pod.collision_layer = WORLD_LAYER
	pod.collision_mask = 0

	if not broken:
		# Целая колба: сплошная цилиндрическая коллизия во всю высоту стекла.
		var col := CollisionShape3D.new()
		var cshape := CylinderShape3D.new()
		cshape.radius = 0.86
		cshape.height = 2.80
		col.shape = cshape
		col.position = Vector3(0.0, 1.40, 0.0)
		pod.add_child(col)
	else:
		# Разбитая колба: коллизия строго по нижнему цоколю и заднему каркасу — без «невидимой
		# стены» в пустом воздухе на высоте камеры (не вдавливает SpringArm3D в голову героини).
		var base_col := CollisionShape3D.new()
		var base_shape := CylinderShape3D.new()
		base_shape.radius = 0.88
		base_shape.height = 0.62
		base_col.shape = base_shape
		base_col.position = Vector3(0.0, 0.31, 0.0)
		pod.add_child(base_col)

		var spine_col := CollisionShape3D.new()
		var spine_shape := BoxShape3D.new()
		spine_shape.size = Vector3(0.54, 2.56, 0.34)
		spine_col.shape = spine_shape
		spine_col.position = Vector3(0.0, 1.38, -0.66)
		pod.add_child(spine_col)

	# Цоколь, металлические обручи, три несущие стойки каркаса и верхний купол.
	_pod_cyl(pod, 0.88, 0.94, 0.22, Vector3(0.0, 0.11, 0.0), _housing_mat, true)
	_pod_cyl(pod, 0.77, 0.80, 0.08, Vector3(0.0, 0.26, 0.0), _trim_mat, true)
	_pod_cyl(pod, 0.86, 0.82, 0.24, Vector3(0.0, 2.66, 0.0), _housing_mat, true)
	_pod_cyl(pod, 0.77, 0.77, 0.06, Vector3(0.0, 2.51, 0.0), _trim_mat, true)
	# Задняя силовая колонна и две боковые дуги каркаса (капсула читается объёмной, не «столиком»).
	_decor_box(Vector3(0.24, 2.34, 0.16), Vector3(0.0, 1.40, -0.73), _trim_mat, true, pod)
	var side_l := _decor_box(Vector3(0.075, 2.30, 0.095), Vector3(-0.62, 1.40, -0.44), _trim_mat, false, pod)
	side_l.rotation.y = 0.62
	var side_r := _decor_box(Vector3(0.075, 2.30, 0.095), Vector3(0.62, 1.40, -0.44), _trim_mat, false, pod)
	side_r.rotation.y = -0.62
	# Индикатор состояния утоплен заподлицо в переднюю грань цоколя (не висит в воздухе).
	_decor_box(
		Vector3(0.30, 0.04, 0.06),
		Vector3(0.0, 0.11, 0.875),
		_status_lock_mat if broken else _status_cyan_mat,
		false,
		pod
	)

	if not broken:
		_pod_cyl(pod, 0.44, 0.44, 2.18, Vector3(0.0, 1.39, 0.0), _pod_core_mat, false)
		_pod_cyl(pod, 0.72, 0.72, 2.22, Vector3(0.0, 1.39, 0.0), _glass_mat, false)
	else:
		# Остатки разбитой стеклянной колбы снизу и под куполом + неровные зубцы и осколки на полу.
		_pod_cyl(pod, 0.72, 0.72, 0.34, Vector3(0.0, 0.47, 0.0), _glass_mat, false)
		_pod_cyl(pod, 0.72, 0.72, 0.22, Vector3(0.0, 2.37, 0.0), _glass_mat, false)
		var rim_angles: Array[float] = [-2.2, -1.15, -0.35, 0.55, 1.45, 2.35]
		for j in range(rim_angles.size()):
			var ang: float = rim_angles[j]
			var jh := 0.24 + float(j % 3) * 0.14
			var tooth := _decor_box(
				Vector3(0.18, jh, 0.025),
				Vector3(sin(ang) * 0.71, 0.62 + jh * 0.45, cos(ang) * 0.71),
				_glass_mat,
				false,
				pod
			)
			tooth.rotation.y = ang
		var offsets := [
			Vector3(0.95, 0.014, 0.72),
			Vector3(-0.82, 0.014, 0.96),
			Vector3(0.32, 0.014, 1.24),
			Vector3(1.22, 0.014, 0.18),
			Vector3(-0.35, 0.014, 1.42),
		]
		for i in range(offsets.size()):
			var shard := _decor_box(
				Vector3(0.24 - i * 0.02, 0.022, 0.15 + (i % 2) * 0.05),
				offsets[i],
				_glass_mat,
				false,
				pod
			)
			shard.rotation.y = float(i) * 1.15 + 0.3

	add_child(pod)


func _make_stairs_and_deck() -> void:
	# Наблюдательный подиум (0.72 м) у дальней стены и 3 ступени по 0.18 м с металлической кромкой.
	# По ступеням героиня и клон поднимаются плавно без прыжка; с боков подиума проверяется прыжок [F].
	var deck_h := 0.72
	var deck_w := 6.4
	var deck_d := 1.8
	var deck_z := -T.ROOM_DEPTH * 0.5 + deck_d * 0.5 + 0.04
	var deck_front_z := deck_z + deck_d * 0.5

	_static_box(Vector3(deck_w, deck_h, deck_d), Vector3(0.0, deck_h * 0.5, deck_z), _floor_mat, true)
	_decor_box(Vector3(deck_w + 0.02, 0.045, 0.05), Vector3(0.0, deck_h - 0.02, deck_front_z + 0.01), _trim_mat, false)

	var step_w := 3.2
	var step_d := 0.44
	var step_rise := 0.18
	for i in range(3):
		var sh := step_rise * float(i + 1)
		var sz := deck_front_z + step_d * (2.5 - float(i))
		_static_box(Vector3(step_w, sh, step_d), Vector3(0.0, sh * 0.5, sz), _floor_mat, true)
		_decor_box(
			Vector3(step_w + 0.02, 0.035, 0.04),
			Vector3(0.0, sh - 0.016, sz + step_d * 0.5 + 0.008),
			_trim_mat,
			false
		)


func _decor_box(
	size: Vector3,
	pos: Vector3,
	mat: Material,
	casts_shadow: bool,
	parent: Node = self
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if casts_shadow
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	parent.add_child(mi)
	return mi


func _static_box(
	size: Vector3,
	pos: Vector3,
	mat: Material,
	casts_shadow: bool,
	parent: Node = self
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	_decor_box(size, Vector3.ZERO, mat, casts_shadow, body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)
	return body


func _pod_cyl(
	parent: Node3D,
	r_top: float,
	r_bot: float,
	height: float,
	pos: Vector3,
	mat: Material,
	casts_shadow: bool
) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = height
	cm.radial_segments = 24
	cm.rings = 1
	mi.mesh = cm
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if casts_shadow
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	parent.add_child(mi)


func _floor_disc(radius: float, pos: Vector3, mat: Material) -> void:
	_pod_cyl(self, radius, radius, 0.006, pos, mat, false)


## Настраивает материалы и оптимизацию персонажа под текущий стиль (полуреализм либо Toon по G).
## Одежду (textile), линию верхних век (upper_lid_deep_brown) и блеск глаз НЕ трогает.
func style_character(root: Node, use_toon: bool = false) -> void:
	if root == null or DisplayServer.get_name() == "headless":
		return
	for mesh in _find_meshes(root):
		var mi := mesh as MeshInstance3D
		var nm := mi.name.to_lower()

		# Скрытая резервная капсула Fallback не участвует в отрисовке.
		if nm == "fallback":
			mi.visible = false
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			continue

		# Динамический слой 2: персонаж виден камере и отбрасывает тени, но не запекается в отражение пола.
		mi.layers = CHARACTER_VISUAL_LAYER

		# Халат и живой подол (зона второго агента) — не меняем материал, оставляем мягкую тень.
		if mi.has_meta("textile"):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			continue

		# Глаза и тёмная линия верхних век: оставляем родные материалы и не тратим теневой проход.
		if nm.contains("eye") or nm.contains("lid"):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			continue

		if mi.mesh == null:
			continue
		# face_blink содержит 774 треугольника верхних век (обязательно видим и окрашен той же кожей!),
		# но тень от головы уже отбрасывает основной меш тела — экономим лишний теневой проход.
		mi.visible = true
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if nm == "face_blink"
			else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		)
		for i in range(mi.mesh.get_surface_count()):
			var base := _original_surface_material(mi, i)
			if base == null:
				continue
			var rname := base.resource_name.to_lower()
			if rname.contains("eye") or rname.contains("lid"):
				continue
			if use_toon:
				mi.set_surface_override_material(i, _make_toon_material(base))
			else:
				mi.set_surface_override_material(i, _make_skin_pbr(base))


func apply_toon(root: Node) -> void:
	style_character(root, true)


func clear_toon(root: Node) -> void:
	style_character(root, false)


func _original_surface_material(mi: MeshInstance3D, surface: int) -> BaseMaterial3D:
	var key := "_orig_mat_%d" % surface
	if mi.has_meta(key):
		return mi.get_meta(key) as BaseMaterial3D
	var cur := mi.get_active_material(surface)
	if cur is BaseMaterial3D:
		mi.set_meta(key, cur)
		return cur as BaseMaterial3D
	var base := mi.mesh.surface_get_material(surface)
	if base is BaseMaterial3D:
		mi.set_meta(key, base)
		return base as BaseMaterial3D
	return null


func _make_skin_pbr(base: BaseMaterial3D) -> StandardMaterial3D:
	if _cached_skin_materials.has(base):
		return _cached_skin_materials[base]
	var mat := StandardMaterial3D.new()
	mat.resource_name = "heroine_skin_pbr"
	# Сохраняем полную текстуру лица (брови, губы, румянец), защищаем красный канал от пересвета
	# и даём мягкую полуреалистичную светотень по скулам, носу и подбородку.
	mat.albedo_color = Color(0.95, 0.935, 0.925)
	mat.albedo_texture = base.albedo_texture
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	mat.roughness = 0.58
	mat.metallic = 0.0
	mat.metallic_specular = 0.24
	mat.backlight_enabled = true
	mat.backlight = Color(0.032, 0.013, 0.010)
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_cached_skin_materials[base] = mat
	return mat


func _make_toon_material(base: BaseMaterial3D) -> ShaderMaterial:
	if _cached_toon_materials.has(base):
		return _cached_toon_materials[base]
	if _cached_toon_shader == null:
		_cached_toon_shader = Shader.new()
		_cached_toon_shader.code = TOON_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _cached_toon_shader
	if base.albedo_texture != null:
		mat.set_shader_parameter("albedo_tex", base.albedo_texture)
		mat.set_shader_parameter("use_texture", true)
		mat.set_shader_parameter("base_color", Color.WHITE)
	else:
		mat.set_shader_parameter("use_texture", false)
		mat.set_shader_parameter("base_color", base.albedo_color)
	_cached_toon_materials[base] = mat
	return mat


func _find_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_meshes(c))
	return out


## Точка появления героини (смотрит в -Z — на центр зала, клона, капсулы и лестницу).
func spawn_point() -> Vector3:
	return Vector3(0.0, 0.08, 5.4)


## Точка появления клона — свободный центр зала вдали от капсул и стен.
func clone_spawn_point() -> Vector3:
	return Vector3(0.0, 0.08, -2.2)
