## Точка входа прототипа: собирает белую лабораторию, спавнит героиню, клона и чистый интерфейс.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const ROOM_SCENE := preload("res://scenes/room.tscn")
const PRELOAD_MENU := preload("res://scenes/pause_menu.tscn")

var room: Node3D
var player: CharacterBody3D
var clone: CharacterBody3D
var _hint_panel: PanelContainer
var _hint: Label
var _hint_age := 0.0
var menu: Control


func _ready() -> void:
	room = ROOM_SCENE.instantiate()
	add_child(room)

	player = PlayerScene.instantiate()
	player.position = room.spawn_point()
	add_child(player)

	# Клон появляется в свободном центре зала лицом к героине (не внутри криокапсулы).
	clone = CloneScene.instantiate()
	clone.position = (
		room.clone_spawn_point()
		if room.has_method("clone_spawn_point")
		else Vector3(0.0, 0.08, -2.2)
	)
	clone.rotation.y = PI
	add_child(clone)

	_apply_style_to_characters()
	_build_overlay()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# Краткая памятка управления слева сверху — плавно гаснет целиком вместе с рамкой через 18 с.
	_hint_panel = PanelContainer.new()
	_hint_panel.position = Vector2(14.0, 12.0)
	_hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.add_theme_stylebox_override("panel", _make_card_style())
	root.add_child(_hint_panel)

	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.90, 0.94, 0.99))
	_hint.add_theme_constant_override("line_spacing", 3)
	_hint.text = (
		"WASD — бег · Shift — спринт · Left Alt — шаг\n"
		+ "ЛКМ / ПКМ — прямые · Q — хук в корпус · Пробел — уворот · F — прыжок\n"
		+ "Tab или СКМ — захват цели · колесо — смена цели"
	)
	_hint_panel.add_child(_hint)

	# Компактная тёмная плашка горячих клавиш справа сверху: GROW_DIRECTION_BEGIN не даёт ей
	# уходить за правый край окна, а тёмная подложка читается на фоне светлого потолка.
	var bar_panel := PanelContainer.new()
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_theme_stylebox_override("panel", _make_card_style())
	bar_panel.anchor_left = 1.0
	bar_panel.anchor_right = 1.0
	bar_panel.anchor_top = 0.0
	bar_panel.anchor_bottom = 0.0
	bar_panel.offset_left = -14.0
	bar_panel.offset_right = -14.0
	bar_panel.offset_top = 12.0
	bar_panel.offset_bottom = 12.0
	bar_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	bar_panel.grow_vertical = Control.GROW_DIRECTION_END
	root.add_child(bar_panel)

	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override("separation", 9)
	bar_panel.add_child(bar)

	for pair in [
		["R", "стойка"],
		["T", "клон"],
		["O", "костюм"],
		["H", "витрина"],
		["B", "свет"],
		["F4", "графика"],
		["F3", "FPS"],
		["Esc", "меню"],
	]:
		bar.add_child(_key_badge(pair[0], pair[1]))

	menu = PRELOAD_MENU.instantiate()
	menu.action.connect(_on_menu_action)
	layer.add_child(menu)


func _make_card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.11, 0.76)
	style.border_color = Color(0.55, 0.64, 0.76, 0.48)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style


func _process(delta: float) -> void:
	if _hint_panel == null or not _hint_panel.visible:
		return
	_hint_age += delta
	if _hint_age >= 18.0:
		_hint_panel.visible = false
	elif _hint_age > 16.0:
		_hint_panel.modulate.a = clampf((18.0 - _hint_age) / 2.0, 0.0, 1.0)


func _key_badge(key: String, caption: String) -> Control:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)

	var k := Label.new()
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	k.text = key
	k.add_theme_font_size_override("font_size", 11)
	k.add_theme_color_override("font_color", Color(0.08, 0.10, 0.15))
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color(0.88, 0.92, 0.98)
	ks.set_corner_radius_all(3)
	ks.content_margin_left = 5.0
	ks.content_margin_right = 5.0
	ks.content_margin_top = 1.0
	ks.content_margin_bottom = 1.0
	k.add_theme_stylebox_override("normal", ks)
	box.add_child(k)

	var c := Label.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.text = caption
	c.add_theme_font_size_override("font_size", 12)
	c.add_theme_color_override("font_color", Color(0.86, 0.91, 0.97))
	box.add_child(c)
	return box


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("cycle_quality"):
		T.QUALITY = (T.QUALITY + 1) % T.QUALITY_NAMES.size()
		_apply_quality()
		_refresh_debug_if_open()
	elif event.is_action_pressed("cycle_brightness"):
		T.BRIGHTNESS = (T.BRIGHTNESS + 1) % T.BRIGHTNESS_NAMES.size()
		_apply_lighting()
		_refresh_debug_if_open()
	elif event.is_action_pressed("toggle_render_style"):
		T.TOON_ENABLED = not T.TOON_ENABLED
		_apply_lighting()
		_apply_style_to_characters()
		_refresh_debug_if_open()
	elif event.is_action_pressed("toggle_outfit"):
		T.OUTFIT = "suit" if T.OUTFIT == "dress" else "dress"
		for ch in [player.character, clone.character]:
			if ch.appearance != null:
				ch.appearance.set_outfit(T.OUTFIT)
		_refresh_debug_if_open()
	elif event.is_action_pressed("open_showcase"):
		get_tree().change_scene_to_file("res://scenes/showcase.tscn")
	elif event.is_action_pressed("toggle_clone"):
		if is_instance_valid(clone) and clone.has_method("cycle_mode"):
			clone.cycle_mode()


func _on_menu_action(id: String) -> void:
	match id:
		"stance":
			if is_instance_valid(player):
				player.toggle_combat_mode()
		"showcase":
			get_tree().change_scene_to_file("res://scenes/showcase.tscn")
		"quality":
			T.QUALITY = (T.QUALITY + 1) % T.QUALITY_NAMES.size()
			_apply_quality()
			_refresh_debug_if_open()
		"brightness":
			T.BRIGHTNESS = (T.BRIGHTNESS + 1) % T.BRIGHTNESS_NAMES.size()
			_apply_lighting()
			_refresh_debug_if_open()
		"toon":
			T.TOON_ENABLED = not T.TOON_ENABLED
			_apply_lighting()
			_apply_style_to_characters()
			_refresh_debug_if_open()
		"clone":
			if is_instance_valid(clone) and clone.has_method("cycle_mode"):
				clone.cycle_mode()


func _apply_quality() -> void:
	if is_instance_valid(room) and room.has_method("apply_quality"):
		room.apply_quality()


func _apply_lighting() -> void:
	if is_instance_valid(room) and room.has_method("rebuild_lighting"):
		room.rebuild_lighting(T.TOON_ENABLED)


func _apply_style_to_characters() -> void:
	_style_actor(player)
	_style_actor(clone)


func _style_actor(who: Node3D) -> void:
	if not is_instance_valid(room) or not is_instance_valid(who):
		return
	var ch: Node = who.get_node_or_null("Character")
	if ch == null:
		return
	if room.has_method("style_character"):
		room.style_character(ch, T.TOON_ENABLED)
	elif T.TOON_ENABLED and room.has_method("apply_toon"):
		room.apply_toon(ch)
	elif room.has_method("clear_toon"):
		room.clear_toon(ch)


func _refresh_debug_if_open() -> void:
	if is_instance_valid(player) and bool(player.get("show_details")):
		if player.has_method("_write_debug_label"):
			player.call("_write_debug_label")
