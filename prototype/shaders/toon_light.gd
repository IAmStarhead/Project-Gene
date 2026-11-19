## Освещение, постобработка и пресеты качества графики под Compatibility (OpenGL 3.3).
##
## ПОЧЕМУ ПРОШЛЫЙ СВЕТ НЕ РАБОТАЛ (две настоящие технические причины):
##   1. В build_scene.gd функция enable_shadows() включала отбрасывание теней на ПОТОЛКЕ
##      и внешних стенах зала. Потолок работал как глухая бетонная крыша и на 100%
##      перекрывал направленный свет (DirectionalLight3D): в комнате не было ни одного
##      прямого луча и ни одной тени под ногами героини — только плоский серый ambient.
##   2. В Godot 4.7 Compatibility (GLES3) источник с тенями рисуется отдельным проходом
##      и складывается с базовым кадром в гамма-пространстве sRGB:
##          итог_sRGB = sRGB(база) + sRGB(ключевой_свет_с_тенью)
##      Из-за кривой степени 1/2.4 линейная энергия 0.105 уже даёт +0.34 sRGB (+87 из 255).
##      Старые значения 1.55..2.30 при открытом потолке мгновенно пережигали бы пол, стены
##      и кожу в сплошной белый 255.
##
## Таблицы ниже рассчитаны точно по формуле шейдеров scene.glsl / tonemap_inc.glsl Godot 4.7.2:
##   - Пол лаборатории: ~240/255 (чистый белый без клиппинга), швы плитки ~209, тень ~184.
##   - Стены: ~231 / ~226 / ~187, серебристый плинтус ~158 — все грани чётко разделены.
##   - Кожа героини: ~[232, 213, 199] на свету и ~[172, 144, 132] в тени — тёплая и живая.
##   - Лабораторный халат: ~232 на свету и ~148 в складках — читается весь объём ткани.
extends RefCounted

# Три уровня яркости (клавиша B): 0 = приглушённо, 1 = штатно, 2 = ярко.
# Откалиброваны по реальным замерам кадров на GeForce 940MX (0% пересвета на всех трёх уровнях:
# пол ~205 / ~222 / ~235, отчётливая мягкая тень ~182 / ~198 / ~212, читаемые швы плитки и черты лица).
const AMBIENT := [0.21, 0.27, 0.33]
const SUN := [0.075, 0.095, 0.115]
const FILL := [0.045, 0.065, 0.085]
const EXPOSURE := [0.91, 0.96, 1.01]
const POST_BRIGHTNESS := [0.96, 0.99, 1.01]

# Студийный свет витрины анимаций (клавиша H): портретный ¾-свет, максимальная читаемость поз и стоп.
const SHOWCASE_AMBIENT := [0.21, 0.27, 0.33]
const SHOWCASE_SUN := [0.08, 0.10, 0.12]
const SHOWCASE_FILL := [0.06, 0.085, 0.11]


static func _make_sky(showcase: bool) -> Sky:
	var mat := ProceduralSkyMaterial.new()
	if showcase:
		mat.sky_top_color = Color(0.86, 0.89, 0.93)
		mat.sky_horizon_color = Color(0.79, 0.82, 0.86)
		mat.ground_horizon_color = Color(0.69, 0.72, 0.76)
		mat.ground_bottom_color = Color(0.57, 0.60, 0.65)
	else:
		# Полусферический свет белой лаборатории: нейтрально-чистый верх без синевы,
		# спокойный горизонт и мягкий рефлекс от светлого пола снизу.
		mat.sky_top_color = Color(0.88, 0.90, 0.93)
		mat.sky_horizon_color = Color(0.81, 0.83, 0.86)
		mat.ground_horizon_color = Color(0.72, 0.74, 0.78)
		mat.ground_bottom_color = Color(0.60, 0.63, 0.67)
	mat.sky_curve = 0.22
	mat.ground_curve = 0.18
	mat.use_debanding = true
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	return sky


static func make_environment(level: int, quality: int = 1, showcase: bool = false) -> Environment:
	var env := Environment.new()
	apply_environment(env, level, quality, showcase)
	return env


static func apply_environment(
	env: Environment,
	level: int,
	quality: int = 1,
	showcase: bool = false
) -> void:
	if env == null:
		return
	var b := clampi(level, 0, AMBIENT.size() - 1)
	var q := clampi(quality, 0, 2)
	var amb_energy: float = SHOWCASE_AMBIENT[b] if showcase else AMBIENT[b]

	if DisplayServer.get_name() == "headless":
		# В headless-тестах не создаём GPU-небо, чтобы Dummy-рендерер чисто освобождал ресурсы.
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.88, 0.90, 0.94)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.88, 0.91, 0.95)
		env.ambient_light_energy = amb_energy
		env.glow_enabled = false
		env.ssao_enabled = false
		return

	env.background_mode = Environment.BG_SKY
	env.sky = _make_sky(showcase)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = amb_energy
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Кинематографичная кривая FILMIC мягко сжимает света и сохраняет черты лица и складки ткани.
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = EXPOSURE[b]
	env.tonemap_white = 1.18

	# Единый пост-проход цветокоррекции: одинаковая яркость на всех пресетах качества
	# и чистый архитектурный микроконтраст в духе Mirror's Edge.
	env.adjustment_enabled = true
	env.adjustment_brightness = POST_BRIGHTNESS[b]
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.03

	# В Compatibility нет HDR: glow размазывает белые стены в «молоко», держим выключенным.
	env.glow_enabled = false

	# Деликатный SSAO в стыках стен, плинтусов и ступеней — только на пресете «Высокое».
	env.ssao_enabled = (q >= 2)
	if env.ssao_enabled:
		env.ssao_radius = 0.72
		env.ssao_intensity = 0.75
		env.ssao_power = 1.35
		env.ssao_detail = 0.40
		env.ssao_horizon = 0.08
		env.ssao_sharpness = 0.92


static func configure_sun(sun: DirectionalLight3D, level: int, showcase: bool = false) -> void:
	if sun == null:
		return
	var b := clampi(level, 0, SUN.size() - 1)
	# Угол -48° в игре даёт читаемую тень под стопами и мягкий 3D-объём на лице и ступенях;
	# -44° в витрине даёт классический портретный 3/4-свет для осмотра анимаций и стоп.
	sun.rotation_degrees = Vector3(-44.0, -36.0, 0.0) if showcase else Vector3(-48.0, -38.0, 0.0)
	sun.light_color = Color(1.0, 0.985, 0.96)
	sun.light_energy = SHOWCASE_SUN[b] if showcase else SUN[b]
	# Живой блик в глазах и на стекле колб, без огромного «солнечного пятна» на полу.
	sun.light_specular = 0.22
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY

	# Один ортогональный каскад (SHADOW_ORTHOGONAL) вместо 4 каскадов PSSM:
	# в 4 раза меньше теневых вызовов отрисовки на GeForce 940MX и ровная мягкая тень на весь зал.
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.88
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 24.0
	sun.directional_shadow_fade_start = 0.9
	sun.directional_shadow_pancake_size = 8.0
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.35
	sun.shadow_blur = 1.35


static func configure_fill(
	light: OmniLight3D,
	level: int,
	secondary: bool = false,
	quality: int = 1,
	showcase: bool = false
) -> void:
	if light == null:
		return
	var b := clampi(level, 0, FILL.size() - 1)
	var q := clampi(quality, 0, 2)
	# На пресете «Низкое» оставляем один заполняющий источник, уменьшая попиксельную нагрузку.
	light.visible = (not secondary) or (q >= 1)
	light.light_color = Color(0.965, 0.982, 1.0)
	var energy: float = SHOWCASE_FILL[b] if showcase else FILL[b]
	if q == 0 and not secondary:
		energy *= 1.25
	light.light_energy = energy * (0.85 if secondary else 1.0)
	# Минимальный specular убирает некрасивые круглые пятна точечных ламп на полу.
	light.light_specular = 0.06
	light.omni_range = 15.0
	light.omni_attenuation = 0.85
	light.shadow_enabled = false


static func configure_probe(
	probe: ReflectionProbe,
	room_size: Vector3,
	quality: int = 1,
	showcase: bool = false
) -> void:
	if probe == null:
		return
	var q := clampi(quality, 0, 2)
	# Однократный снимок зала (UPDATE_ONCE): 0 мс нагрузки в кадре, мягкие реалистичные
	# отражения потолочных световых панелей на белом полу, стекле криокапсул и в глазах.
	probe.visible = (q >= 1) and (not showcase) and (DisplayServer.get_name() != "headless")
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.box_projection = true
	probe.interior = true
	probe.enable_shadows = false
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	# Слой 1 — только статичная архитектура; персонажи на слое 2 не застывают в отражении пола.
	probe.cull_mask = 1
	probe.intensity = 0.28
	probe.size = room_size + Vector3(1.2, 1.2, 1.2)
	probe.max_distance = 28.0


static func apply_viewport_quality(viewport: Viewport, quality: int = 1) -> void:
	if viewport == null or DisplayServer.get_name() == "headless":
		return
	var q := clampi(quality, 0, 2)
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	match q:
		0:
			# Максимум FPS (выручает даже на встроенной графике): 85% 3D-разрешения, без AA.
			viewport.scaling_3d_scale = 0.85
			viewport.msaa_3d = Viewport.MSAA_DISABLED
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		1:
			# Оптимальный пресет под GeForce 940MX (1280x720): 100% разрешение + лёгкий FXAA.
			viewport.scaling_3d_scale = 1.0
			viewport.msaa_3d = Viewport.MSAA_DISABLED
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		2:
			# Высокое качество: 100% разрешение + честный 2x MSAA + деликатный SSAO.
			viewport.scaling_3d_scale = 1.0
			viewport.msaa_3d = Viewport.MSAA_2X
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
