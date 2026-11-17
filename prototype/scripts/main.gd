## Точка входа прототипа: строит комнату, спавнит героиню и заглушку цели.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const DummyScene := preload("res://scenes/dummy_target.tscn")
const ROOM_SCENE := preload("res://scenes/room.tscn")

var room: Node3D
var player: CharacterBody3D


func _ready() -> void:
	room = ROOM_SCENE.instantiate()
	add_child(room)

	player = PlayerScene.instantiate()
	player.position = room.spawn_point()
	add_child(player)

	var dummy := DummyScene.instantiate()
	dummy.position = Vector3(3.5, 1.0, -2.0)
	add_child(dummy)

	var hint := Label.new()
	hint.text = "WASD — идти · Shift — бег · ЛКМ — удар · Пробел — уворот · Esc — курсор"
	hint.position = Vector2(16, 12)
	hint.add_theme_color_override("font_color", Color(0.1, 0.12, 0.16))
	add_child(hint)
