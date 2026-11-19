## Нарисованная метка, не зависящая от наличия символа в системном шрифте.
extends Control


func _draw() -> void:
	var center := size * 0.5
	var dark := Color(0.02, 0.06, 0.08, 0.95)
	var gold := Color(1.0, 0.82, 0.38, 1.0)
	draw_arc(center, 7.0, 0.0, TAU, 32, dark, 4.0, true)
	draw_arc(center, 7.0, 0.0, TAU, 32, gold, 1.7, true)
	for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_line(center + dir * 10.0, center + dir * 13.0, dark, 4.0, true)
		draw_line(center + dir * 10.0, center + dir * 13.0, gold, 1.7, true)
	draw_circle(center, 1.5, gold)
