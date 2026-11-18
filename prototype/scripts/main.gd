## Точка входа прототипа: строит комнату, спавнит героиню и клона.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const ROOM_SCENE := preload("res://scenes/room.tscn")
const PRELOAD_MENU := preload("res://scenes/pause_menu.tscn")

var room: Node3D
var player: CharacterBody3D
var clone: CharacterBody3D
var _hint: Label
var menu: Control


func _ready() -> void:
	room = ROOM_SCENE.instantiate()
	add_child(room)

	player = PlayerScene.instantiate()
	player.position = room.spawn_point()
	add_child(player)

	# Клон героини вместо столба. Начинает в режиме «спит», чтобы не мешать
	# смотреть на модель, свет и прыжок. Переключается клавишей T.
	clone = CloneScene.instantiate()
	clone.position = Vector3(-3.0, 1.0, -5.0)
	add_child(clone)

	# Селлшейдинг применяется ПОСЛЕ спавна: до этого у мешей ещё нет
	# материалов, и подменять нечего.
	if room != null and room.has_method("apply_toon"):
		var pc: Node = player.get_node_or_null("Character")
		var cc: Node = clone.get_node_or_null("Character")
		if pc != null:
			room.apply_toon(pc)
		if cc != null:
			room.apply_toon(cc)

	# ── Оверлей. Раньше это была одна длинная строка мелким текстом, и
	# пользователь её не увидел: она сливалась с отладочным текстом героини
	# в 13 полей. Информация о витрине тонула.
	# Теперь три блока: слева управление (крупно), справа — кнопки-подсказки
	# с рамкой, которые читаются как кнопки, а не как текст.
	# Слой ВЫШЕ отладочного текста героини: у неё Layer 10, значит этот
	# должен быть больше, иначе её 13 строк рисовались поверх подсказки.
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 10)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.12, 0.72)
	style.border_color = Color(0.55, 0.62, 0.72, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.86, 0.90, 0.96))
	_hint.text = "WASD — лёгкий бег · L Alt — шаг · Shift — быстрый бег\nF — прыжок\n" \
		+ "ЛКМ — удар левой · ПКМ — удар правой · Пробел — уворот"
	_hint.add_theme_constant_override("line_spacing", 3)
	panel.add_child(_hint)

	# Кнопки-подсказки: клавиша в рамке + что делает.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar.position = Vector2(12, 96)
	layer.add_child(bar)
	for pair in [["R", "стойка игрока"], ["H", "ВИТРИНА"], ["B", "яркость"], ["G", "селлшейдинг"], ["T", "бой клона"]]:
		bar.add_child(_key_badge(pair[0], pair[1]))

	# ── МЕНЮ ПАУЗЫ (Esc). Пользователь просил: из игры перейти в витрину,
	# поменять настройки и выйти из игры. Раньше Esc только освобождал
	# курсор, и меню не было.
	menu = PRELOAD_MENU.instantiate()
	menu.action.connect(_on_menu_action)
	layer.add_child(menu)


## Плашка «клавиша + подпись». Сделана как кнопка, а не как текст:
## пользователь искал витрину и не нашёл, потому что подсказка была
## строчкой в общем тексте.
func _key_badge(key: String, caption: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	var k := Label.new()
	k.text = " " + key + " "
	k.add_theme_font_size_override("font_size", 13)
	k.add_theme_color_override("font_color", Color(0.10, 0.12, 0.16))
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color(0.86, 0.90, 0.96)
	ks.set_corner_radius_all(4)
	ks.content_margin_left = 3
	ks.content_margin_right = 3
	k.add_theme_stylebox_override("normal", ks)
	box.add_child(k)
	var c := Label.new()
	c.text = caption
	c.add_theme_font_size_override("font_size", 13)
	c.add_theme_color_override("font_color", Color(0.80, 0.85, 0.92))
	box.add_child(c)
	return box


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_render_style"):
		# Пересобрать материал персонажей тоже надо: при выключении toon
		# возвращается родной материал модели с её текстурой.
		T.TOON_ENABLED = not T.TOON_ENABLED
		var toon: bool = T.TOON_ENABLED
		if room != null and room.has_method("rebuild_lighting"):
			room.rebuild_lighting(toon)
		for who in [player, clone]:
			if is_instance_valid(who):
				var ch: Node = who.get_node_or_null("Character")
				if ch != null:
					if toon and room.has_method("apply_toon"):
						room.apply_toon(ch)
					else:
						room.clear_toon(ch)
	if event.is_action_pressed("cycle_brightness"):
		T.BRIGHTNESS = (T.BRIGHTNESS + 1) % 3
		_apply_lighting()
	if event.is_action_pressed("open_showcase"):
		get_tree().change_scene_to_file("res://scenes/showcase.tscn")
	elif event.is_action_pressed("toggle_clone"):
		if is_instance_valid(clone) and clone.has_method("cycle_mode"):
			clone.cycle_mode()


## Что делает меню паузы. Действия повторяют «горячие» клавиши, но с
## понятными подписями и без необходимости помнить раскладку.
func _on_menu_action(id: String) -> void:
	match id:
		"stance":
			if is_instance_valid(player):
				player.toggle_combat_mode()
		"showcase":
			get_tree().change_scene_to_file("res://scenes/showcase.tscn")
		"brightness":
			T.BRIGHTNESS = (T.BRIGHTNESS + 1) % 3
			_apply_lighting()
		"toon":
			T.TOON_ENABLED = not T.TOON_ENABLED
			_apply_lighting()
			_apply_toon_to_characters()
		"clone":
			if is_instance_valid(clone) and clone.has_method("cycle_mode"):
				clone.cycle_mode()


## Пересобрать свет по текущей яркости.
func _apply_lighting() -> void:
	if room != null and room.has_method("rebuild_lighting"):
		room.rebuild_lighting(T.TOON_ENABLED)


## Переприменить/снять селлшейдинг на обоих персонажах.
func _apply_toon_to_characters() -> void:
	for who in [player, clone]:
		if not is_instance_valid(who):
			continue
		var ch: Node = who.get_node_or_null("Character")
		if ch == null:
			continue
		if T.TOON_ENABLED and room.has_method("apply_toon"):
			room.apply_toon(ch)
		elif room.has_method("clear_toon"):
			room.clear_toon(ch)
