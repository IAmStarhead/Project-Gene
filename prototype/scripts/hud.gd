## Игровой HUD: здоровье (с «догоняющей» полосой урона из Souls), стамина, индикатор стойки
## и экранная метка захваченной цели на уровне груди противника.
extends CanvasLayer

const T := preload("res://scripts/tuning.gd")

const BAR_WIDTH := 248.0
const HP_HEIGHT := 11.0
const ST_HEIGHT := 8.0
const MARGIN := 20.0

var player: Node3D
var lock: RefCounted

var _health_fill: ColorRect
var _health_lag: ColorRect
var _stamina_fill: ColorRect
var _stance_label: Label
var _target_mark: Label
var _health_lag_value := 1.0
var _last_combat_state := -1


func setup(who: Node3D, lock_on: RefCounted) -> void:
	player = who
	lock = lock_on


func _ready() -> void:
	layer = 15
	_build_bars()
	_build_target_mark()


func _build_bars() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.11, 0.76)
	style.border_color = Color(0.56, 0.65, 0.78, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)

	# GROW_DIRECTION_BEGIN держит нижнюю границу строго в 20 px от низа экрана при любом разрешении.
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = MARGIN
	panel.offset_right = MARGIN
	panel.offset_top = -MARGIN
	panel.offset_bottom = -MARGIN
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	_stance_label = Label.new()
	_stance_label.text = "СТОЙКА: ОБЫЧНАЯ  [R]"
	_stance_label.add_theme_font_size_override("font_size", 11)
	_stance_label.add_theme_color_override("font_color", Color(0.78, 0.84, 0.92, 0.92))
	_stance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_stance_label)

	var health_row := _bar_row(HP_HEIGHT, true)
	column.add_child(health_row["root"])
	_health_lag = health_row["lag"]
	_health_fill = health_row["fill"]
	_health_lag.color = Color(0.97, 0.62, 0.52, 0.82)
	_health_fill.color = Color(0.78, 0.18, 0.23, 1.0)

	var stamina_row := _bar_row(ST_HEIGHT, false)
	column.add_child(stamina_row["root"])
	_stamina_fill = stamina_row["fill"]
	_stamina_fill.color = Color(0.38, 0.78, 0.46, 1.0)


func _bar_row(bar_h: float, with_ticks: bool) -> Dictionary:
	var row := Control.new()
	row.custom_minimum_size = Vector2(BAR_WIDTH, bar_h)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var back := ColorRect.new()
	back.color = Color(0.12, 0.14, 0.19, 0.92)
	back.size = Vector2(BAR_WIDTH, bar_h)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(back)

	var lag := ColorRect.new()
	lag.color = Color(0.0, 0.0, 0.0, 0.0)
	lag.size = Vector2(BAR_WIDTH, bar_h)
	lag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lag)

	var fill := ColorRect.new()
	fill.size = Vector2(BAR_WIDTH, bar_h)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(fill)

	if with_ticks:
		# Тонкие четвертные засечки — считывать остаток ХП в бою проще, чем по голой полоске.
		for step in [0.25, 0.5, 0.75]:
			var tick := ColorRect.new()
			tick.color = Color(0.05, 0.07, 0.11, 0.45)
			tick.position = Vector2(BAR_WIDTH * step, 0.0)
			tick.size = Vector2(1.0, bar_h)
			tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(tick)

	return {"root": row, "lag": lag, "fill": fill}


func _build_target_mark() -> void:
	# Контрастная метка захвата с тёмным контуром: не теряется на фоне белого халата и стен.
	_target_mark = Label.new()
	_target_mark.text = "◈"
	_target_mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target_mark.size = Vector2(28.0, 28.0)
	_target_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_mark.add_theme_font_size_override("font_size", 20)
	_target_mark.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42, 0.96))
	_target_mark.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.12, 0.92))
	_target_mark.add_theme_constant_override("outline_size", 5)
	_target_mark.visible = false
	add_child(_target_mark)


func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return

	var hp_val: Variant = player.get("health")
	var hp := float(hp_val) if hp_val != null else T.MAX_HEALTH
	var ratio := clampf(hp / maxf(T.MAX_HEALTH, 1.0), 0.0, 1.0)
	_health_fill.size.x = BAR_WIDTH * ratio
	if _health_lag_value > ratio:
		_health_lag_value = maxf(ratio, _health_lag_value - delta * 0.50)
	else:
		_health_lag_value = ratio
	_health_lag.size.x = BAR_WIDTH * _health_lag_value

	var st_val: Variant = player.get("stamina")
	var st := float(st_val) if st_val != null else T.MAX_STAMINA
	var s_ratio := clampf(st / maxf(T.MAX_STAMINA, 1.0), 0.0, 1.0)
	_stamina_fill.size.x = BAR_WIDTH * s_ratio
	_stamina_fill.color = (
		Color(0.38, 0.78, 0.46, 1.0)
		if st >= T.ATTACK_STAMINA
		else Color(0.76, 0.54, 0.28, 1.0)
	)

	var in_combat := 1 if bool(player.get("combat_mode")) else 0
	if in_combat != _last_combat_state:
		_last_combat_state = in_combat
		if in_combat == 1:
			_stance_label.text = "СТОЙКА: БОЕВАЯ  [R]"
			_stance_label.add_theme_color_override("font_color", Color(0.98, 0.78, 0.52, 0.96))
		else:
			_stance_label.text = "СТОЙКА: ОБЫЧНАЯ  [R]"
			_stance_label.add_theme_color_override("font_color", Color(0.78, 0.84, 0.92, 0.90))

	_update_target_mark()


func _update_target_mark() -> void:
	if lock == null or not lock.has_method("active") or not bool(lock.call("active")):
		_target_mark.visible = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_target_mark.visible = false
		return
	var world_point: Vector3 = (
		lock.call("aim_point") as Vector3
		if lock.has_method("aim_point")
		else (lock.target as Node3D).global_position + Vector3(0.0, 1.25, 0.0)
	)
	if camera.is_position_behind(world_point):
		_target_mark.visible = false
		return
	var screen := camera.unproject_position(world_point)
	_target_mark.visible = true
	_target_mark.position = screen - _target_mark.size * 0.5
