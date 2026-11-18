## Игровой HUD: здоровье, стамина, захваченная цель и короткие подсказки.
##
## ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. До этого всё состояние рисовалось отладочными
## строками в player.gd и ещё одной панелью в main.gd, и пользователь дважды
## жаловался: «на экране слишком много надписей», «H ВИТРИНА тонет в тексте».
## Здесь один источник правды: полосы вместо цифр, подсказка — только по делу,
## и никакого пересечения с панелью анимаций.
##
## Что на экране (и ничего больше):
##   • слева снизу — полоса здоровья и полоса стамины, с разделителями;
##   • по центру — метка захваченной цели (точка), над целью в мире — рамка;
##   • подсказку по управлению HUD НЕ рисует: она живёт в main.gd.
##   • F3 — включает подробную отладку (её рисует player.gd, как раньше).
##
## Почему не готовый .tscn: HUD целиком собирается кодом, как и комната.
## Опечатка в тексте скрипта видна сразу, а в .tscn ломает файл целиком.
extends CanvasLayer

const T := preload("res://scripts/tuning.gd")

const BAR_WIDTH := 260.0
const BAR_HEIGHT := 12.0
const MARGIN := 22.0

var player: Node3D
var lock: RefCounted

var _health_fill: ColorRect
var _health_lag: ColorRect
var _stamina_fill: ColorRect
var _health_back: ColorRect
var _stamina_back: ColorRect
var _target_mark: Label

## «Догоняющая» полоса здоровья: пока она отстаёт, видно, сколько урона
## только что прилетело. Это дешёвый и очень читаемый приём из соулсов.
var _health_lag_value := 1.0


func setup(who: Node3D, lock_on: RefCounted) -> void:
	player = who
	lock = lock_on


func _ready() -> void:
	layer = 15                      # ниже панели подсказок в main.gd (20)
	_build_bars()
	_build_target_mark()


func _build_bars() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.45)
	style.set_corner_radius_all(5)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	# Прижимаем к левому нижнему углу ЯКОРЯМИ, а не координатой: разрешение у
	# пользователя может быть 1280x720 или 1600x900, и на втором координатный
	# угол уехал бы. PRESET_MODE_MINSIZE берёт высоту из содержимого, поэтому
	# панель не надо пересчитывать при смене шрифта.
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT,
		Control.PRESET_MODE_MINSIZE, 0)
	panel.position += Vector2(MARGIN, -MARGIN)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	# Здоровье: тёмная подложка, красная заливка, светлая «догоняющая».
	var health_row := _bar_row()
	column.add_child(health_row["root"])
	_health_back = health_row["back"]
	_health_lag = health_row["lag"]
	_health_fill = health_row["fill"]
	_health_lag.color = Color(0.98, 0.62, 0.55, 0.75)
	_health_fill.color = Color(0.72, 0.16, 0.20, 1.0)

	var stamina_row := _bar_row()
	column.add_child(stamina_row["root"])
	_stamina_back = stamina_row["back"]
	_stamina_fill = stamina_row["fill"]
	_stamina_fill.color = Color(0.55, 0.80, 0.42, 1.0)


## Одна полоса: подложка + (необязательная) догоняющая заливка + заливка.
func _bar_row() -> Dictionary:
	var row := Control.new()
	row.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := ColorRect.new()
	back.color = Color(0.10, 0.11, 0.14, 0.85)
	back.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(back)
	var lag := ColorRect.new()
	lag.color = Color(0.0, 0.0, 0.0, 0.0)
	lag.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	lag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lag)
	var fill := ColorRect.new()
	fill.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(fill)
	return {"root": row, "back": back, "lag": lag, "fill": fill}


func _build_target_mark() -> void:
	# Метка цели: не рамка в 3D (дорого и лезет в геометрию), а точка на
	# экране, спроецированная из мира. Если цели нет — скрыта.
	_target_mark = Label.new()
	_target_mark.text = "◇"
	_target_mark.add_theme_font_size_override("font_size", 22)
	_target_mark.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	_target_mark.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_target_mark.add_theme_constant_override("shadow_offset_x", 1)
	_target_mark.add_theme_constant_override("shadow_offset_y", 1)
	_target_mark.visible = false
	add_child(_target_mark)


func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return

	# ── здоровье. Берём из игрока, но не падаем, если поле переименуют.
	var hp: float = float(player.get("health")) if player.get("health") != null else T.MAX_HEALTH
	var max_hp: float = T.MAX_HEALTH
	var ratio: float = clampf(hp / max(max_hp, 1.0), 0.0, 1.0)
	_health_fill.size.x = BAR_WIDTH * ratio
	# Догоняющая полоса: отстаёт с задержкой и подтягивается вверх.
	if _health_lag_value > ratio:
		_health_lag_value = maxf(ratio, _health_lag_value - delta * 0.55)
	else:
		_health_lag_value = ratio
	_health_lag.size.x = BAR_WIDTH * _health_lag_value
	_health_lag.size.y = BAR_HEIGHT

	var st: float = float(player.get("stamina")) if player.get("stamina") != null else T.MAX_STAMINA
	var s_ratio: float = clampf(st / max(T.MAX_STAMINA, 1.0), 0.0, 1.0)
	_stamina_fill.size.x = BAR_WIDTH * s_ratio
	_stamina_fill.size.y = BAR_HEIGHT
	# Стамина кончилась — цвет в тёмный, чтобы это читалось без цифр.
	_stamina_fill.color = Color(0.55, 0.80, 0.42) if s_ratio > 0.05 else Color(0.45, 0.30, 0.28)

	_update_target_mark()


func _update_target_mark() -> void:
	if lock == null or not lock.has_method("active") or not lock.active():
		_target_mark.visible = false
		return
	var target: Node3D = lock.target
	if not is_instance_valid(target):
		_target_mark.visible = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_target_mark.visible = false
		return
	var world_point := target.global_position + Vector3(0, 1.95, 0)
	if camera.is_position_behind(world_point):
		_target_mark.visible = false
		return
	var screen := camera.unproject_position(world_point)
	_target_mark.visible = true
	_target_mark.position = screen - Vector2(11, 14)
