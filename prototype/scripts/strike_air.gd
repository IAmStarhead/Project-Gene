## Small, short-lived camera-facing ribbon following the actual striking hand.
## Purely visual: does not take part in damage, hit tests, or audio.
extends MeshInstance3D

const LIFE := 0.13
const MAX_POINTS := 9
const HALF_WIDTH := 0.045
const OPACITY := 0.18
const VIEW_OFFSET := 0.055 # lifts the translucent air away from the hand surface

var points: Array[Dictionary] = []
var ribbon := ImmediateMesh.new()
var material := StandardMaterial3D.new()

func _ready() -> void:
	set_meta("air_effect", true)
	layers = 2 # Same character layer; exclude from floor reflections.
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = ribbon
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


func clear_trail() -> void:
	points.clear()
	ribbon.clear_surfaces()
	visible = false


func advance(delta: float, point: Vector3, sampling: bool, camera_position: Vector3) -> void:
	if not sampling and points.is_empty():
		return
	for p in points:
		p.age = float(p.age) + maxf(delta, 0.0)
	while not points.is_empty() and float(points[0].age) >= LIFE:
		points.pop_front()
	if sampling and point.is_finite():
		if not points.is_empty() and point.distance_to(points.back().position) > 0.8:
			clear_trail() # teleports must never draw across the room
		if points.is_empty() or point.distance_to(points.back().position) > .003:
			points.append({"position": point, "age": 0.0})
			if points.size() > MAX_POINTS:
				points.pop_front()
	_rebuild(camera_position)


func _rebuild(camera_position: Vector3) -> void:
	ribbon.clear_surfaces()
	visible = points.size() >= 2
	if not visible:
		return
	ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for i in range(points.size() - 1):
		var a: Vector3 = points[i].position
		var b: Vector3 = points[i + 1].position
		var along := b - a
		var to_camera := camera_position - (a + b) * .5
		var across := along.cross(to_camera).normalized()
		if across.length_squared() < .01:
			across = along.cross(Vector3.UP).normalized()
		if across.length_squared() < .01:
			across = Vector3.RIGHT
		var width := across * HALF_WIDTH
		# Separate the faint ribbon from the skin; depth testing still prevents
		# it from being drawn through walls or unrelated foreground objects.
		var lift := to_camera.normalized() * VIEW_OFFSET
		a += lift
		b += lift
		var ca := _color(float(points[i].age))
		var cb := _color(float(points[i + 1].age))
		_vertex(a - width, ca); _vertex(a + width, ca); _vertex(b + width, cb)
		_vertex(a - width, ca); _vertex(b + width, cb); _vertex(b - width, cb)
	ribbon.surface_end()


func _color(age: float) -> Color:
	return Color(.62, .65, .68, OPACITY * clampf(1.0 - age / LIFE, 0.0, 1.0))


func _vertex(pos: Vector3, color: Color) -> void:
	ribbon.surface_set_color(color)
	ribbon.surface_add_vertex(pos)
