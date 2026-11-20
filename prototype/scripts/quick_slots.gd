## Декоративные пустые места быстрого доступа; предметов и привязок пока нет.
extends Control

const SLOT_SIZE := 50.0
const SLOT_STEP := 58.0
const POSITIONS := [Vector2(58, 0), Vector2(0, 58), Vector2(116, 58), Vector2(58, 116)]


func _ready() -> void:
	custom_minimum_size = Vector2(166, 166)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	for pos in POSITIONS:
		_draw_slot(pos)


func _draw_slot(pos: Vector2) -> void:
	# Собственная простая геометрия, без заимствованных текстур или пиктограмм.
	var points := PackedVector2Array([
		pos + Vector2(6, 0), pos + Vector2(SLOT_SIZE, 0),
		pos + Vector2(SLOT_SIZE, SLOT_SIZE - 6), pos + Vector2(SLOT_SIZE - 6, SLOT_SIZE),
		pos + Vector2(0, SLOT_SIZE), pos + Vector2(0, 6),
	])
	draw_colored_polygon(points, Color(.035, .055, .065, .82))
	draw_polyline(points + PackedVector2Array([points[0]]), Color(.73, .83, .84, .9), 1.5, true)
	draw_line(pos + Vector2(6, 6), pos + Vector2(SLOT_SIZE - 6, 6), Color(.72, .84, .84, .16), 1.0, true)
	draw_line(pos + Vector2(6, 6), pos + Vector2(6, SLOT_SIZE - 6), Color(.72, .84, .84, .16), 1.0, true)
	# Небольшие угловые метки — не обозначение выбранного предмета.
	draw_line(pos + Vector2(6, 2), pos + Vector2(17, 2), Color(1.0, .52, .20, .75), 1.5, true)
	draw_line(pos + Vector2(SLOT_SIZE - 12, SLOT_SIZE - 3), pos + Vector2(SLOT_SIZE - 6, SLOT_SIZE - 3), Color(.69, .78, .79, .6), 1.0, true)
