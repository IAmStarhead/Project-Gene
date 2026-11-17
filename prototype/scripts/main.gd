## Точка входа прототипа: строит комнату, спавнит героиню и клона.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const DummyScene := preload("res://scenes/dummy_target.tscn")
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

	# Столб оставлен рядом: на нём удобно проверять конус удара, не трогая клона.
	var dummy := DummyScene.instantiate()
	dummy.position = Vector3(5.0, 1.0, -2.0)
	add_child(dummy)

	_hint = Label.new()
	_hint.text = "WASD — идти · Shift — бег · F — прыжок · ЛКМ — удар · Пробел — уворот · T — режим клона · Esc — курсор"
	_hint.position = Vector2(16, 12)
	_hint.add_theme_color_override("font_color", Color(0.1, 0.12, 0.16))
	add_child(_hint)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_clone"):
		if is_instance_valid(clone) and clone.has_method("cycle_mode"):
			clone.cycle_mode()
