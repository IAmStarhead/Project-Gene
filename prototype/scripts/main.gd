## Точка входа прототипа: строит комнату, спавнит героиню и клона.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const ROOM_SCENE := preload("res://scenes/room.tscn")

var room: Node3D
var player: CharacterBody3D
var clone: CharacterBody3D
var _hint: Label


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
		room.apply_toon(player.get_node("Character"))
		room.apply_toon(clone.get_node("Character"))

	_hint = Label.new()
	_hint.text = "WASD — идти · Shift — бег · F — прыжок · ЛКМ — удар левой · ПКМ — удар правой · Пробел — уворот · T — бой клона · H — витрина · G — селлшейдинг · Esc — курсор"
	_hint.position = Vector2(16, 12)
	_hint.add_theme_color_override("font_color", Color(0.1, 0.12, 0.16))
	add_child(_hint)


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
	if event.is_action_pressed("open_showcase"):
		get_tree().change_scene_to_file("res://scenes/showcase.tscn")
	elif event.is_action_pressed("toggle_clone"):
		if is_instance_valid(clone) and clone.has_method("cycle_mode"):
			clone.cycle_mode()
