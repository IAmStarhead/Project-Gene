## Учебный экран снаряжения: данные не подменяют будущую систему предметов.
extends Control

signal closed(return_to_pause: bool)

const T := preload("res://scripts/tuning.gd")
const DISPLAY_FONT := preload("res://assets/fonts/CormorantGaramond.ttf")
const GOLD := Color(.76, .68, .47)
const TEXT := Color(.90, .88, .81)
const MUTED := Color(.62, .62, .57)
const CATEGORIES := ["ОРУЖИЕ", "ОДЕЖДА", "ПРЕДМЕТЫ"]

var player: Node3D
var return_to_pause := false
var category := 1
var tabs: Array[Button] = []
var grid: GridContainer
var heading: Label
var description: Label
var icon: Control
var hp: Label
var stamina: Label
var entry: Button
var layout: MarginContainer


func setup(who: Node3D) -> void:
	player = who


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var shade := ColorRect.new()
	shade.color = Color(.035, .035, .038, .96)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var margin := MarginContainer.new()
	layout = margin
	margin.size = Vector2(1280, 720)
	for key in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(key, 38)
	for key in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(key, 25)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	var top := HBoxContainer.new()
	page.add_child(top)
	var title := _label("Снаряжение", 38, TEXT, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var tag := _label("GEN    /    ЛАБОРАТОРИЯ", 13, GOLD)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(tag)
	page.add_child(_line())
	var sub := _label("ОБЗОР СНАРЯЖЕНИЯ   /   ПРОТОТИП", 12, MUTED)
	page.add_child(sub)
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	page.add_child(content)
	var left := _column(content, 1.05)
	var mid := _column(content, 1.1)
	var right := _column(content, .78)
	left.add_child(_section("КАТЕГОРИИ"))
	for i in CATEGORIES.size():
		var tab := _button(CATEGORIES[i], 15)
		tab.custom_minimum_size.y = 39
		tab.pressed.connect(select_category.bind(i))
		left.add_child(tab)
		tabs.append(tab)
	left.add_child(_spacer(8))
	left.add_child(_section("СОДЕРЖИМОЕ"))
	grid = GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	left.add_child(grid)
	mid.add_child(_section("ОПИСАНИЕ"))
	var icon_area := PanelContainer.new()
	icon_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon_area.add_theme_stylebox_override("panel", _panel(Color(.085, .083, .078), Color(.28, .27, .22)))
	mid.add_child(icon_area)
	icon = Control.new()
	icon.custom_minimum_size = Vector2(100, 105)
	icon.draw.connect(_draw_icon)
	icon_area.add_child(icon)
	heading = _label("", 25, TEXT, true)
	mid.add_child(heading)
	description = _label("", 14, MUTED)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size.y = 48
	mid.add_child(description)
	right.add_child(_section("СОСТОЯНИЕ"))
	right.add_child(_label("Героиня", 25, TEXT, true))
	right.add_child(_line())
	hp = _label("", 15, TEXT)
	stamina = _label("", 15, TEXT)
	right.add_child(hp)
	right.add_child(stamina)
	right.add_child(_spacer(16))
	right.add_child(_section("НА ГЕРОИНЕ"))
	right.add_child(_label("Лабораторное платье", 16, TEXT))
	var note := _label("Смена и характеристики одежды пока не реализованы.", 13, MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(note)
	page.add_child(_line())
	var footer := HBoxContainer.new()
	page.add_child(footer)
	var hint := _label("МЫШЬ  выбор    ·    СТРЕЛКИ ВЛЕВО / ВПРАВО  разделы    ·    ESC  назад", 13, MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(hint)
	var close_button := _button("ЗАКРЫТЬ   ×", 13)
	close_button.pressed.connect(close)
	footer.add_child(close_button)
	select_category(1)
	resized.connect(_fit_layout)
	_fit_layout()


func _fit_layout() -> void:
	var factor := minf(size.x / 1280.0, size.y / 720.0)
	layout.scale = Vector2.ONE * factor
	layout.position = (size - Vector2(1280, 720) * factor) * .5


func _column(parent: Control, ratio: float) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = ratio
	col.add_theme_constant_override("separation", 7)
	parent.add_child(col)
	return col


func _panel(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _panel(Color(.08, .079, .075), Color(.22, .21, .18)))
	b.add_theme_stylebox_override("hover", _panel(Color(.16, .145, .11), GOLD))
	b.add_theme_stylebox_override("pressed", _panel(Color(.22, .19, .13), GOLD))
	b.add_theme_stylebox_override("focus", _panel(Color(0, 0, 0, 0), GOLD))
	return b


func _label(text: String, font_size: int, color: Color, serif: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if serif:
		label.add_theme_font_override("font", DISPLAY_FONT)
	return label


func _section(text: String) -> Label:
	return _label(text, 12, GOLD)


func _line() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(.45, .39, .28, .8)
	line.custom_minimum_size.y = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _spacer(height: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	return spacer


func open(from_pause: bool = false) -> void:
	return_to_pause = from_pause
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true
	select_category(1)
	_update_values()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit(return_to_pause)


func select_category(index: int) -> void:
	category = posmod(index, CATEGORIES.size())
	for i in tabs.size():
		tabs[i].add_theme_stylebox_override("normal", _panel(
			Color(.20, .17, .12) if i == category else Color(.08, .079, .075),
			GOLD if i == category else Color(.22, .21, .18)))
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	entry = null
	for i in 12:
		if category == 1 and i == 0:
			entry = _button("ОДЕЖДА", 11)
			entry.tooltip_text = "Текущее лабораторное платье"
			entry.custom_minimum_size = Vector2(70, 50)
			entry.pressed.connect(_select_clothing)
			grid.add_child(entry)
		else:
			var empty := PanelContainer.new()
			empty.custom_minimum_size = Vector2(70, 50)
			empty.add_theme_stylebox_override("panel", _panel(Color(.075, .073, .069), Color(.19, .18, .16)))
			grid.add_child(empty)
	if category == 1:
		_select_clothing()
	elif category == 0:
		heading.text = "Оружие отсутствует"
		description.text = "В прототипе пока нет оружия. Тестовый невидимый клинок — инструмент для манекена, не предмет инвентаря."
	else:
		heading.text = "Предметов пока нет"
		description.text = "Здесь появятся найденные предметы, когда они будут добавлены в игру."
	icon.queue_redraw()


func _select_clothing() -> void:
	heading.text = "Лабораторное платье"
	description.text = "Текущая одежда героини. Другая экипировка и смена одежды пока не добавлены."
	icon.queue_redraw()


func _draw_icon() -> void:
	var center := icon.size * .5
	var pale := Color(.78, .78, .71, .9)
	var faint := Color(.53, .47, .34, .55)
	icon.draw_arc(center, minf(icon.size.x, icon.size.y) * .38, 0, TAU, 64, faint, 1.0, true)
	if category == 1:
		# Оригинальная пиктограмма платья, не игровой арт FromSoftware.
		var p := PackedVector2Array([Vector2(-20,-50),Vector2(-42,-36),Vector2(-49,-15),Vector2(-29,-8),Vector2(-24,-20),Vector2(-23,2),Vector2(-48,47),Vector2(48,47),Vector2(23,2),Vector2(24,-20),Vector2(29,-8),Vector2(49,-15),Vector2(42,-36),Vector2(20,-50),Vector2(10,-40),Vector2(-10,-40)])
		for i in p.size(): p[i] += center
		icon.draw_colored_polygon(p, Color(.55,.55,.51,.25))
		icon.draw_polyline(p + PackedVector2Array([p[0]]), pale, 2.0, true)
		icon.draw_line(center + Vector2(-23, 2), center + Vector2(23, 2), pale, 1.0)
	else:
		icon.draw_line(center + Vector2(-14, 0), center + Vector2(14, 0), faint, 1.5, true)
		icon.draw_line(center + Vector2(0, -14), center + Vector2(0, 14), faint, 1.5, true)


func _update_values() -> void:
	if is_instance_valid(player):
		hp.text = "Здоровье    %.0f / %.0f" % [player.health, T.MAX_HEALTH]
		stamina.text = "Выносливость    %.0f / %.0f" % [player.stamina, T.MAX_STAMINA]


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		select_category(category - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		select_category(category + 1)
		get_viewport().set_input_as_handled()
