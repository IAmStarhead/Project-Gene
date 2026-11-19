## UI-only layout/framing for the animation showcase, never the combat camera.
## Keep the model in the actual free rectangle; labels belong in the sidebar.
extends RefCounted

var owner_scene: Node3D
var root: Control
var transport: PanelContainer
var fit_full_body := true


func _init(scene: Node3D) -> void:
	owner_scene = scene


func button(text: String, callback: Callable) -> Button:
	return owner_scene._button(text, callback)


func build() -> void:
	var layer := CanvasLayer.new()
	owner_scene.add_child(layer)
	root = Control.new()
	root.name = "ShowcaseControls"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_color_override("font_color", Color(.86, .92, .95))
	root.add_theme_font_size_override("font_size", 15)
	layer.add_child(root)

	var library: PanelContainer = owner_scene._panel()
	root.add_child(library)
	library.anchor_bottom = 1.0
	library.offset_left = 16
	library.offset_right = 244
	library.offset_top = 16
	library.offset_bottom = -16
	var sidebar := VBoxContainer.new()
	sidebar.add_theme_constant_override("separation", 8)
	library.add_child(sidebar)
	var heading := Label.new()
	heading.text = "GEN / АНИМАЦИИ"
	heading.add_theme_font_size_override("font_size", 19)
	sidebar.add_child(heading)
	owner_scene._title = Label.new()
	owner_scene._title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	owner_scene._title.add_theme_font_size_override("font_size", 17)
	sidebar.add_child(owner_scene._title)
	owner_scene._phase = Label.new()
	owner_scene._phase.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	owner_scene._phase.add_theme_font_size_override("font_size", 12)
	sidebar.add_child(owner_scene._phase)
	sidebar.add_child(HSeparator.new())
	owner_scene._clip_scroll = ScrollContainer.new()
	owner_scene._clip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	owner_scene._clip_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	owner_scene._clip_scroll.custom_minimum_size.y = 60
	sidebar.add_child(owner_scene._clip_scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	owner_scene._clip_scroll.add_child(list)
	for i in owner_scene.CLIPS.size():
		var item := button("%02d  %s" % [i+1, owner_scene.CLIPS[i][1]], owner_scene._select_clip.bind(i))
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.toggle_mode = true
		list.add_child(item)
		owner_scene._clip_buttons.append(item)
	sidebar.add_child(button("В игру  [Esc]", owner_scene._exit_showcase))

	var cameras := HBoxContainer.new()
	cameras.position = Vector2(264, 16)
	cameras.add_theme_constant_override("separation", 6)
	root.add_child(cameras)
	for pair in [["Спереди", 0.0], ["Сбоку", 90.0], ["Сзади", 180.0], ["3/4", 35.0]]:
		cameras.add_child(button(pair[0], owner_scene._set_camera.bind(pair[1])))
	cameras.add_child(button("Весь рост", func() -> void: fit_full_body = true))
	cameras.add_child(button("UI [V]", toggle_visible))

	transport = owner_scene._panel()
	root.add_child(transport)
	transport.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	transport.offset_left = 264
	transport.offset_right = -16
	transport.offset_top = -126
	transport.offset_bottom = -16
	transport.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	transport.add_child(stack)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	stack.add_child(row)
	row.add_child(button("|< Кадр", owner_scene._step_frame.bind(-1)))
	owner_scene._play_button = button("Пауза", owner_scene._toggle_play)
	owner_scene._play_button.custom_minimum_size.x = 118
	row.add_child(owner_scene._play_button)
	row.add_child(button("Кадр >|", owner_scene._step_frame.bind(1)))
	owner_scene._speed_picker = OptionButton.new()
	for speed in owner_scene.SPEEDS:
		owner_scene._speed_picker.add_item("%.2fx" % speed)
	owner_scene._speed_picker.select(owner_scene._speed_index)
	owner_scene._speed_picker.item_selected.connect(func(index: int) -> void: owner_scene._speed_index = index)
	row.add_child(owner_scene._speed_picker)
	var repeat := CheckButton.new()
	repeat.text = "Повтор"
	repeat.button_pressed = true
	repeat.focus_mode = Control.FOCUS_NONE
	repeat.toggled.connect(func(value: bool) -> void: owner_scene._repeat = value)
	row.add_child(repeat)
	owner_scene._time_label = Label.new()
	row.add_child(owner_scene._time_label)
	owner_scene._timeline = HSlider.new()
	owner_scene._timeline.step = .001
	owner_scene._timeline.custom_minimum_size.y = 18
	owner_scene._timeline.value_changed.connect(owner_scene._seek)
	stack.add_child(owner_scene._timeline)
	var help := Label.new()
	# These ASCII key names do not depend on an OS fallback arrow font.
	help.text = "Space пауза · Left/Right кадр · Up/Down клип · L скорость · B свет · G стиль · V скрыть UI\nЛКМ + мышь — орбита · колесо — зум (кадрирование вручную)"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 12)
	stack.add_child(help)


func toggle_visible() -> void:
	root.visible = not root.visible


func safe_rect() -> Rect2:
	var size := owner_scene.get_viewport().get_visible_rect().size
	if not root.visible:
		return Rect2(Vector2(24, 24), size-Vector2(48, 48))
	var bottom := minf(transport.position.y-12, size.y-138)
	return Rect2(Vector2(264, 60), Vector2(maxf(size.x-280, 80), maxf(bottom-60, 80)))


func camera_frame(orbit: Basis, requested_distance: float) -> Dictionary:
	var size := owner_scene.get_viewport().get_visible_rect().size
	var rect := safe_rect()
	var tangent := tan(deg_to_rad(owner_scene.cam.fov)*.5)
	var distance := requested_distance
	if fit_full_body:
		# 1.88 m padded model bound, not a guessed ankle/head screenshot.
		distance = maxf(distance, 1.88*size.y/(2*tangent*rect.size.y))
	var half_height := tangent*distance
	var half_width := half_height*size.x/maxf(size.y, 1)
	var center := rect.get_center()
	var offset := Vector2((center.x-size.x*.5)/(size.x*.5)*half_width,
		(size.y*.5-center.y)/(size.y*.5)*half_height)
	var focus := Vector3(0, .86, 0)-orbit.x*offset.x-orbit.y*offset.y
	return {"focus": focus, "position": focus+orbit*Vector3(0, 0, distance)}
