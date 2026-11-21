## Меню паузы на Esc: переход в витрину, качество графики, яркость, стиль, стойка и бой клона.
extends Control

signal action(action_id: String)

const T := preload("res://scripts/tuning.gd")

var _panel: PanelContainer
var _controls_panel: PanelContainer
var _controls_back: Button
var _items := {}
var _selected := 0
var _buttons: Array[Button] = []
var enabled := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	theme = _make_theme()

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.07, 0.58)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.034, 0.032, 0.98)
	style.border_color = Color(0.67, 0.59, 0.40, 0.70)
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	style.shadow_size = 8
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	_panel.add_child(col)

	var title := Label.new()
	title.text = "ПАУЗА"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	col.add_child(title)

	var sub := Label.new()
	sub.text = "Мышь или стрелки — выбор · Enter — применить · Esc — вернуться"
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.64, 0.70, 0.80))
	col.add_child(sub)

	col.add_child(HSeparator.new())

	_add_item(col, "resume", "Продолжить игру", "")
	_add_item(col, "equipment", "Снаряжение", "I")
	_add_item(col, "controls", "Управление", "")
	_add_item(col, "showcase", "Витрина анимаций", "H")
	_add_item(col, "quality", "Качество графики", "F4")
	_add_item(col, "brightness", "Освещение зала", "B")
	_add_item(col, "toon", "Стиль персонажей", "G")
	_add_item(col, "stance", "Режим игрока", "R")
	_add_item(col, "clone", "Бой клона", "T")
	_add_item(col, "camera", "Динамика камеры", "")
	_add_item(col, "sound", "Звуки", "")
	_add_item(col, "quit", "Выйти из игры", "")

	refresh()
	_build_controls(center, style)

	var hint := Label.new()
	hint.text = "Совет: нажмите F3 в игре, чтобы увидеть точный FPS, время кадра и активную видеокарту."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(460.0, 0.0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.58, 0.64, 0.74))
	col.add_child(hint)
	resized.connect(_fit_panel)
	call_deferred("_fit_panel")


func _build_controls(center: Control, panel_style: StyleBoxFlat) -> void:
	_controls_panel = PanelContainer.new()
	_controls_panel.visible = false
	_controls_panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(_controls_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_controls_panel.add_child(col)
	var title := Label.new()
	title.text = "УПРАВЛЕНИЕ"
	title.add_theme_font_size_override("font_size", 24)
	col.add_child(title)
	var info := Label.new()
	info.custom_minimum_size = Vector2(500, 0)
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_constant_override("line_spacing", 6)
	info.text = "\n".join([
		"WASD  —  движение    ·    Shift  —  спринт    ·    Alt  —  шаг",
		"Мышь — камера · 1–9,0 — выбор приёма · ЛКМ — выполнить",
		"1 джеб · 2 кросс · 3 хук · 4 прямой ногой · 5 лоу · 6 сильный",
		"ПКМ — прежний правый прямой · Q — прежний левый хук",
		"Пробел  —  уворот    ·    F  —  прыжок",
		"Tab / СКМ  —  захват цели    ·    колесо  —  смена цели",
		"R  —  стойка    ·    T  —  бой клона",
		"V  —  тестовый клинок манекена",
		"С клинком: 1–4 — конечность · N — материал · K — сброс",
		"I  —  снаряжение    ·    H  —  витрина анимаций",
		"B  —  свет    ·    G  —  стиль    ·    F4  —  графика",
		"F3  —  диагностика    ·    Esc  —  пауза",
	])
	col.add_child(info)
	_controls_back = Button.new()
	_controls_back.text = "НАЗАД  /  ESC"
	_controls_back.pressed.connect(_close_controls)
	col.add_child(_controls_back)


func _close_controls() -> void:
	_controls_panel.visible = false
	_panel.visible = true
	if _items.has("controls"):
		_items["controls"]["button"].grab_focus()


func _fit_panel() -> void:
	var panel_size := _panel.get_combined_minimum_size()
	var factor := minf(1.0, minf((size.x - 20.0) / panel_size.x, (size.y - 20.0) / panel_size.y))
	_panel.pivot_offset = _panel.size * .5
	_panel.scale = Vector2.ONE * maxf(.1, factor)


func _add_item(parent: VBoxContainer, id: String, caption: String, key: String) -> void:
	var row := Button.new()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.custom_minimum_size = Vector2(460.0, 24.0)
	row.add_theme_font_size_override("font_size", 14)
	row.focus_mode = Control.FOCUS_ALL
	row.pressed.connect(_activate.bind(id))
	row.focus_entered.connect(_on_focus.bind(row))
	parent.add_child(row)
	_buttons.append(row)
	_items[id] = {"button": row, "caption": caption, "key": key}


func _on_focus(row: Button) -> void:
	_selected = _buttons.find(row)


func refresh() -> void:
	var q_idx := clampi(T.QUALITY, 0, T.QUALITY_NAMES.size() - 1)
	var b_idx := clampi(T.BRIGHTNESS, 0, T.BRIGHTNESS_NAMES.size() - 1)
	_items["quality"]["button"].text = _row_text("quality", T.QUALITY_NAMES[q_idx])
	_items["brightness"]["button"].text = _row_text("brightness", T.BRIGHTNESS_NAMES[b_idx])
	_items["toon"]["button"].text = _row_text("toon", "селлшейдинг" if T.TOON_ENABLED else "полуреализм")
	_items["clone"]["button"].text = _row_text("clone", _clone_label())
	_items["camera"]["button"].text = _row_text("camera", "вкл" if T.CAMERA_DYNAMIC else "выкл")
	_items["sound"]["button"].text = _row_text("sound", "вкл" if T.FOLEY_ENABLED else "выкл")
	var player := get_tree().get_first_node_in_group("player")
	_items["stance"]["button"].text = _row_text(
		"stance",
		String(player.call("stance_name")) if player != null and player.has_method("stance_name") else "—"
	)
	_items["resume"]["button"].text = _row_text("resume", "")
	_items["equipment"]["button"].text = _row_text("equipment", "")
	_items["controls"]["button"].text = _row_text("controls", "")
	_items["showcase"]["button"].text = _row_text("showcase", "")
	_items["quit"]["button"].text = _row_text("quit", "")


func _row_text(id: String, value: String) -> String:
	var it: Dictionary = _items[id]
	var text := "   " + String(it["caption"])
	if String(it["key"]) != "":
		text += "    [" + String(it["key"]) + "]"
	if value != "":
		text += "   —   " + value
	return text


func _clone_label() -> String:
	var nodes := get_tree().get_nodes_in_group("clone")
	if nodes.is_empty():
		return "—"
	var c: Node = nodes[0]
	return String(c.call("mode_name")) if c.has_method("mode_name") else "—"


func open() -> void:
	_controls_panel.visible = false
	_panel.visible = true
	visible = true
	refresh()
	_selected = 0
	if not _buttons.is_empty():
		_buttons[0].grab_focus()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	visible = false
	get_tree().paused = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	action.emit("resume")


func _activate(id: String) -> void:
	if id == "controls":
		_panel.visible = false
		_controls_panel.visible = true
		_controls_back.grab_focus()
		return
	if id == "resume":
		close()
		return
	if id == "quit":
		get_tree().quit()
		return
	if id == "showcase":
		visible = false
		get_tree().paused = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	action.emit(id)
	refresh()


func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if visible and _controls_panel.visible:
		if event.is_action_pressed("ui_cancel"):
			_close_controls()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		if visible:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	if event.is_action_pressed("ui_down"):
		_selected = (_selected + 1) % _buttons.size()
		_buttons[_selected].grab_focus()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up"):
		_selected = (_selected - 1 + _buttons.size()) % _buttons.size()
		_buttons[_selected].grab_focus()
		get_viewport().set_input_as_handled()


func _make_theme() -> Theme:
	var th := Theme.new()
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.085, 0.08, 0.07, 0.96)
	normal.set_corner_radius_all(1)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.22, 0.19, 0.13, 0.98)
	hover.set_corner_radius_all(1)
	hover.content_margin_left = 10.0
	hover.content_margin_right = 10.0
	var focus := hover.duplicate() as StyleBoxFlat
	focus.border_color = Color(0.77, 0.68, 0.48, 0.90)
	focus.set_border_width_all(2)
	th.set_stylebox("normal", "Button", normal)
	th.set_stylebox("hover", "Button", hover)
	th.set_stylebox("pressed", "Button", hover)
	th.set_stylebox("focus", "Button", focus)
	th.set_color("font_color", "Button", Color(0.89, 0.93, 0.99))
	th.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0))
	return th
