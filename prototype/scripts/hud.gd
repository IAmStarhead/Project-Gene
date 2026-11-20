## Игровой HUD: здоровье (с «догоняющей» полосой урона из Souls), стамина, индикатор стойки
## и экранная метка захваченной цели на уровне груди противника.
extends CanvasLayer

const T := preload("res://scripts/tuning.gd")
const Reticle := preload("res://scripts/target_reticle.gd")

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
var _values_label: Label
var _training_label: Label
var _training_panel: PanelContainer
var _quick_access: Control
var _target_mark: Control
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

	# Статус вверху слева, быстрые ячейки внизу: ничего не изображает несуществующие предметы.
	var panel := PanelContainer.new()
	panel.name = "StatusPanel"
	panel.position = Vector2(MARGIN, 14)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _card_style())
	root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	var header := HBoxContainer.new()
	column.add_child(header)
	var brand := _text("GEN  /  СОСТОЯНИЕ", 12, Color(.98, .65, .36))
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(brand)
	header.visible = false
	_stance_label = _text("СТОЙКА: ОБЫЧНАЯ  [R]", 11, Color(.75, .82, .83))
	header.add_child(_stance_label)

	_values_label = _text("ЗДОРОВЬЕ  100   /   ВЫНОСЛИВОСТЬ  100", 11, Color(.87, .92, .92))
	column.add_child(_values_label)
	_values_label.visible = false

	var health_row := _bar_row(HP_HEIGHT, true)
	column.add_child(_named_bar("HP", health_row["root"]))
	_health_lag = health_row["lag"]
	_health_fill = health_row["fill"]
	_health_lag.color = Color(1.0, .76, .51, .8)
	_health_fill.color = Color(.96, .38, .12, 1.0)

	var stamina_row := _bar_row(ST_HEIGHT, false)
	column.add_child(_named_bar("ST", stamina_row["root"]))
	_stamina_fill = stamina_row["fill"]
	_stamina_fill.color = Color(.70, .87, .88, 1.0)

	var quick := Control.new()
	quick.name = "QuickAccess"
	_quick_access = quick
	quick.anchor_top = 1.0
	quick.anchor_bottom = 1.0
	quick.position = Vector2(MARGIN, -186)
	quick.size = Vector2(166, 187)
	quick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(quick)
	var quick_title := _text("БЫСТРЫЙ ДОСТУП  /  ПУСТО", 10, Color(.88, .93, .93))
	var caption_style := StyleBoxFlat.new()
	caption_style.bg_color = Color(.035, .055, .065, .86)
	caption_style.content_margin_left = 4
	caption_style.content_margin_right = 4
	caption_style.content_margin_top = 1
	caption_style.content_margin_bottom = 1
	quick_title.add_theme_stylebox_override("normal", caption_style)
	quick_title.position = Vector2(0, 0)
	quick_title.visible = false
	quick.add_child(quick_title)
	var slots := preload("res://scripts/quick_slots.gd").new()
	slots.name = "EmptySlots"
	slots.position = Vector2.ZERO
	quick.add_child(slots)

	var training_panel := PanelContainer.new()
	training_panel.name = "TrainingPanel"
	_training_panel = training_panel
	training_panel.anchor_top = 1.0
	training_panel.anchor_bottom = 1.0
	training_panel.position = Vector2(205, -20)
	training_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	training_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_panel.add_theme_stylebox_override("panel", _card_style())
	root.add_child(training_panel)
	_training_label = _text("", 12, Color(1.0, .76, .53))
	training_panel.add_child(_training_label)
	_training_label.visible = false
	training_panel.visible = false


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(.035, .055, .065, .90)
	style.border_color = Color(.55, .67, .68, .72)
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	return style


func _text(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _named_bar(name_text: String, bar: Control) -> HBoxContainer:
	var container := HBoxContainer.new()
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_theme_constant_override("separation", 8)
	var name_label := _text(name_text, 11, Color(.79, .87, .88))
	name_label.custom_minimum_size.x = 22
	container.add_child(name_label)
	name_label.visible = false
	container.add_child(bar)
	return container


func _bar_row(bar_h: float, with_ticks: bool) -> Dictionary:
	var row := Control.new()
	row.custom_minimum_size = Vector2(BAR_WIDTH, bar_h)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := ColorRect.new()
	back.color = Color(.12, .17, .18, .98)
	back.size = Vector2(BAR_WIDTH, bar_h)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(back)
	var lag := ColorRect.new()
	lag.color = Color(0, 0, 0, 0)
	lag.size = Vector2(BAR_WIDTH, bar_h)
	lag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lag)
	var fill := ColorRect.new()
	fill.size = Vector2(BAR_WIDTH, bar_h)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(fill)
	if with_ticks:
		for step in [.25, .5, .75]:
			var tick := ColorRect.new()
			tick.color = Color(.04, .07, .08, .48)
			tick.position = Vector2(BAR_WIDTH * step, 0)
			tick.size = Vector2(1, bar_h)
			tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(tick)
	return {"root": row, "lag": lag, "fill": fill}


func _build_target_mark() -> void:
	# Контрастная метка захвата с тёмным контуром: не теряется на фоне белого халата и стен.
	_target_mark = Reticle.new()
	_target_mark.size = Vector2(28.0, 28.0)
	_target_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_values_label.text = "ЗДОРОВЬЕ  %d   /   ВЫНОСЛИВОСТЬ  %d" % [roundi(hp), roundi(st)]
	var s_ratio := clampf(st / maxf(T.MAX_STAMINA, 1.0), 0.0, 1.0)
	_stamina_fill.size.x = BAR_WIDTH * s_ratio
	_stamina_fill.color = (
		Color(.70, .87, .88, 1.0)
		if st >= T.ATTACK_STAMINA
		else Color(.94, .62, .31, 1.0)
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

	_training_label.visible = bool(player.get("training_blade"))
	# В маленьком окне диагностика F3 занимает нижнюю часть экрана.
	var compact_debug := bool(player.get("show_details")) and get_viewport().get_visible_rect().size.y < 560.0
	_quick_access.visible = not compact_debug
	_training_panel.visible = false # Управление и состояние клинка — только в паузе / F3.
	if _training_label.visible:
		var chosen: int = int(player.get("training_limb"))
		var names := ["левая рука", "правая рука", "левая нога", "правая нога"]
		var material := "особый · рост заблокирован" if bool(player.get("training_special")) else "обычный · рост включён"
		_training_label.text = "КЛИНОК [V] · %s [1–4]\n%s [N] · сброс манекена [K]" % [names[chosen], material]

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
