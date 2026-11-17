## Освещение, исправленное под Compatibility-рендерер.
##
## ЗАЧЕМ ЭТОТ ФАЙЛ. Пользователь три раза подряд сказал «темновато», а я три
## раза подряд не попадал, потому что лечил не причину.
##
## Причина в документации Godot (Internal rendering architecture, раздел
## Compatibility): этот рендерер рисует источники БЕЗ теней одним проходом, а
## источники С тенями — отдельным многопроходным путём, и «свет с тенями
## смешивается в пространстве sRGB, а не в линейном». То есть в одной сцене
## одновременно работают два разных пространства освещения. Плюс ambient,
## судя по поведению, применяется заново на каждом таком проходе.
##
## Симптом ровно наш: сколько ни добавляй света, картинка либо тусклая, либо
## засвеченная, а ступени селлшейдинга пропадают — их съедает пересвет.
##
## ЧТО СДЕЛАНО:
##   1. Яркость набирается заполняющим светом БЕЗ теней и ambient-ом, а не
##      солнцем. Солнце же с тенями намеренно слабое: в Compatibility его
##      энергия и должна быть в разы меньше единицы, а не 1.35–2.10, как было.
##   2. Glow почти выключен. В Compatibility нет HDR: цвет тонамапится и
##      хранится в sRGB, поэтому glow работает по уже сжатым значениям и
##      размазывает светлое в белое. 0.35 — это много.
##   3. Тональная компрессия вместо линейной: при LINEAR всё, что выше 1.0,
##      просто обрезается в белый. FILMIC мягче держит светлую кожу.
##
## Все числа — в таблицах, по уровню яркости (T.BRIGHTNESS 0/1/2), чтобы
## пользователь мог переключать и сравнивать.
extends RefCounted


## Три уровня. Главный принцип: основной источник и заполняющий различаются
## не в разы по абсолютной величине, а по НАПРАВЛЕНИЮ и по тому, есть ли у
## них тени. Тени остаются только у солнца — это единственный проход sRGB.
const AMBIENT := [0.95, 1.25, 1.55]
const SUN := [0.32, 0.42, 0.52]          ## с тенями, поэтому маленькое
const FILL := [0.55, 0.80, 1.05]         ## без теней, тянет тени из черноты
const BOUNCE := [0.18, 0.24, 0.30]       ## от белого пола снизу
const GLOW := [0.10, 0.12, 0.14]
const EXPOSURE := [1.0, 1.05, 1.10]

const BACKGROUND := [
	Color(0.80, 0.85, 0.91),
	Color(0.88, 0.91, 0.95),
	Color(0.94, 0.96, 0.99),
]
const AMBIENT_COLOR := [
	Color(0.74, 0.79, 0.88),
	Color(0.84, 0.88, 0.94),
	Color(0.91, 0.94, 0.98),
]


## Собрать окружение по уровню яркости.
static func make_environment(level: int) -> Environment:
	var b: int = clampi(level, 0, 2)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = BACKGROUND[b]
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = AMBIENT_COLOR[b]
	e.ambient_light_energy = AMBIENT[b]
	# FILMIC, а не LINEAR: линейный режим обрезает всё выше 1.0 в белый, и
	# именно поэтому светлая кожа теряла и форму, и черты лица.
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = EXPOSURE[b]
	e.glow_enabled = true
	e.glow_intensity = GLOW[b]
	e.glow_bloom = 0.02
	e.glow_hdr_threshold = 1.4
	# SSAO есть и в Compatibility (в отличие от SSIL и SSR). Он даёт контакт
	# персонажа с полом — без него фигура «висит в воздухе».
	e.ssao_enabled = true
	e.ssao_radius = 1.2
	e.ssao_intensity = 1.6

	if b > 0:
		# Чуть тёплый оттенок в середине: чисто белый свет на белой комнате
		# читается как больничный, а стерильность нужна «дорогая».
		e.background_color = e.background_color.lerp(Color(0.95, 0.96, 0.98), 0.15 * b)
	return e


## Настройки солнца. Тени ВКЛ — это единственный источник с тенями в сцене:
## каждый лишний источник с тенями добавляет ещё один проход sRGB и снова
## сдвигает цвет всей сцены.
static func configure_sun(sun: DirectionalLight3D, level: int) -> void:
	var b: int = clampi(level, 0, 2)
	sun.light_color = Color(1.0, 0.99, 0.96)
	sun.light_energy = SUN[b]
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 28.0
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.5
	sun.rotation_degrees = Vector3(-48.0, -38.0, 0.0)


## Заполняющий свет. Без теней — значит рисуется в обычном проходе и не
## добавляет ещё один sRGB-проход.
static func configure_fill(light: OmniLight3D, level: int) -> void:
	var b: int = clampi(level, 0, 2)
	light.light_color = Color(0.94, 0.97, 1.0)
	light.light_energy = FILL[b]
	light.omni_range = 20.0
	light.shadow_enabled = false


static func configure_bounce(light: OmniLight3D, level: int) -> void:
	var b: int = clampi(level, 0, 2)
	light.light_color = Color(0.97, 0.98, 1.0)
	light.light_energy = BOUNCE[b]
	light.omni_range = 9.0
	light.shadow_enabled = false
