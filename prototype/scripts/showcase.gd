## Витрина ВСЕХ настоящих клипов, а не отдельный список похожих поз.
## Игра, клон и эта сцена читают одну AnimationLibrary.
## Пробел — пауза, ←/→ — кадр, ↑/↓ — клип, L — скорость, Esc/H — игра.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const CharacterScript := preload("res://scripts/character_anim.gd")
const BuildScene := preload("res://scripts/build_scene.gd")
const CLIPS := [
	["idle_relaxed", "Спокойная стойка"], ["walk_relaxed", "Обычная ходьба"],
	["run_relaxed", "Лёгкий бег"], ["sprint_relaxed", "Быстрый бег — Shift"],
	["guard", "Боевая стойка"], ["walk", "Ходьба — бой"], ["run", "Бег — бой"],
	["attack_left", "Джеб — левая"], ["attack_right", "Кросс — правая"],
	["dodge", "Уворот вперёд"], ["dodge_back", "Уворот назад"],
	["dodge_left", "Уворот влево"], ["dodge_right", "Уворот вправо"], ["jump_start", "Отрыв от земли"],
	["jump_up", "Подъём в прыжке"], ["jump_down", "Падение"],
	["land", "Приземление"], ["hit", "Реакция на удар"],
]
const SPEEDS := [0.25, 0.5, 1.0]

var character: Node3D
var cam: Camera3D
var _world: Node3D
var _yaw := 0.0
var _pitch := -8.0
var _distance := 3.8
var _selected := 0
var _playing := true
var _time := 0.0
var _speed_index := 2
var _repeat := true
var _title: Label
var _phase: Label
var _time_label: Label
var _timeline: HSlider
var _play_button: Button
var _speed_picker: OptionButton
var _clip_buttons: Array[Button] = []
var _clip_scroll: ScrollContainer


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_world = Node3D.new()
	_world.set_script(BuildScene)
	add_child(_world)
	_world.showcase_lighting()
	character = Node3D.new()
	character.set_script(CharacterScript)
	add_child(character)
	cam = Camera3D.new()
	cam.fov = 36.0
	cam.near = 0.08
	cam.far = 64.0
	cam.current = true
	add_child(cam)
	_make_ui()
	if _world.has_method("style_character"):
		_world.style_character(character, T.TOON_ENABLED)
	_select_clip(0)


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(.065, .09, .12, .94)
	style.border_color = Color(.25, .34, .39)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 13
	style.content_margin_bottom = 13
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _button(caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	return button


func _make_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_color_override("font_color", Color(.86, .92, .95))
	root.add_theme_font_size_override("font_size", 15)
	layer.add_child(root)

	var library := _panel()
	root.add_child(library)
	library.anchor_bottom = 1.0
	library.offset_left = 16
	library.offset_right = 244
	library.offset_top = 16
	library.offset_bottom = -142
	_clip_scroll = ScrollContainer.new()
	_clip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	library.add_child(_clip_scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	_clip_scroll.add_child(list)
	var heading := Label.new()
	heading.text = "GEN / АНИМАЦИИ"
	heading.add_theme_font_size_override("font_size", 19)
	list.add_child(heading)
	var note := Label.new()
	note.text = "21 кость · единая библиотека"
	note.add_theme_font_size_override("font_size", 12)
	list.add_child(note)
	list.add_child(HSeparator.new())
	for i in CLIPS.size():
		var button := _button("%02d  %s" % [i + 1, CLIPS[i][1]], _select_clip.bind(i))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.toggle_mode = true
		list.add_child(button)
		_clip_buttons.append(button)
	list.add_child(HSeparator.new())
	list.add_child(_button("← Вернуться в игру  [Esc]", _exit_showcase))

	var camera_bar := HBoxContainer.new()
	camera_bar.position = Vector2(264, 16)
	camera_bar.add_theme_constant_override("separation", 6)
	root.add_child(camera_bar)
	for pair in [["Спереди", 0.0], ["Сбоку", 90.0], ["Сзади", 180.0], ["¾", 35.0]]:
		camera_bar.add_child(_button(pair[0], _set_camera.bind(pair[1])))

	_title = Label.new()
	_title.position = Vector2(266, 64)
	_title.add_theme_font_size_override("font_size", 21)
	_title.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	_title.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.12, 0.92))
	_title.add_theme_constant_override("outline_size", 5)
	root.add_child(_title)
	_phase = Label.new()
	_phase.position = Vector2(266, 96)
	_phase.add_theme_font_size_override("font_size", 14)
	_phase.add_theme_color_override("font_color", Color(0.90, 0.94, 0.99))
	_phase.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.12, 0.90))
	_phase.add_theme_constant_override("outline_size", 4)
	root.add_child(_phase)

	var transport := _panel()
	root.add_child(transport)
	transport.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	transport.offset_left = 16
	transport.offset_right = -16
	transport.offset_top = -126
	transport.offset_bottom = -16
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	transport.add_child(stack)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	stack.add_child(row)
	row.add_child(_button("|< Кадр", _step_frame.bind(-1)))
	_play_button = _button("Пауза", _toggle_play)
	_play_button.custom_minimum_size.x = 118
	row.add_child(_play_button)
	row.add_child(_button("Кадр >|", _step_frame.bind(1)))
	_speed_picker = OptionButton.new()
	for speed in SPEEDS:
		_speed_picker.add_item("%.2f×" % speed)
	_speed_picker.select(_speed_index)
	_speed_picker.item_selected.connect(func(index: int) -> void: _speed_index = index)
	row.add_child(_speed_picker)
	var repeat_button := CheckButton.new()
	repeat_button.text = "Повторять"
	repeat_button.button_pressed = true
	repeat_button.focus_mode = Control.FOCUS_NONE
	repeat_button.toggled.connect(func(value: bool) -> void: _repeat = value)
	row.add_child(repeat_button)
	_time_label = Label.new()
	row.add_child(_time_label)
	_timeline = HSlider.new()
	_timeline.step = .001
	_timeline.custom_minimum_size.y = 18
	_timeline.value_changed.connect(_seek)
	stack.add_child(_timeline)
	var help := Label.new()
	help.text = "Пробел — пауза · ← → кадр · ↑ ↓ клип · L скорость · B свет · F4 графика · G стиль · ЛКМ — орбита · колесо — зум"
	help.add_theme_font_size_override("font_size", 12)
	stack.add_child(help)


func _select_clip(index: int) -> void:
	_selected = posmod(index, CLIPS.size())
	_time = 0.0
	_playing = true
	_timeline.max_value = character.clip_duration(CLIPS[_selected][0])
	for i in _clip_buttons.size():
		_clip_buttons[i].set_pressed_no_signal(i == _selected)
	_clip_scroll.ensure_control_visible(_clip_buttons[_selected])
	character.seek_clip(CLIPS[_selected][0], _time)
	_update_ui()


func _seek(value: float) -> void:
	_time = value
	_playing = false
	character.seek_clip(CLIPS[_selected][0], _time)
	_update_ui()


func _step_frame(direction: int) -> void:
	_seek(clampf(_time + float(direction) / 60.0, 0.0, _timeline.max_value))


func _toggle_play() -> void:
	if _time >= _timeline.max_value:
		_time = 0.0
	_playing = not _playing
	_update_ui()


func _set_camera(yaw: float) -> void:
	_yaw = yaw
	_pitch = -8.0
	_distance = 3.8


func _process(delta: float) -> void:
	var duration: float = character.clip_duration(CLIPS[_selected][0])
	if _playing and duration > 0:
		_time += delta * SPEEDS[_speed_index]
		if _time > duration:
			if _repeat:
				_time = fposmod(_time, duration)
			else:
				_time = duration
				_playing = false
	character.seek_clip(CLIPS[_selected][0], _time, delta*SPEEDS[_speed_index] if _playing else -1.0)
	var orbit := Basis(Vector3.UP, deg_to_rad(_yaw)) * Basis(Vector3.RIGHT, deg_to_rad(_pitch))
	var focus := Vector3(0, .85, 0)
	cam.global_position = focus + orbit * Vector3(0, 0, _distance)
	cam.look_at(focus, Vector3.UP)
	_update_ui()


func _update_ui() -> void:
	_title.text = "%02d / %02d   %s" % [_selected + 1, CLIPS.size(), CLIPS[_selected][1]]
	_play_button.text = "Пауза  [Space]" if _playing else "Играть  [Space]"
	_time_label.text = "   %.3f / %.2f с   ·   кадр %d" % [_time, _timeline.max_value, roundi(_time * 60)]
	_timeline.set_value_no_signal(_time)
	var clip: Animation = CharacterScript.MOTIONS.get_animation(CLIPS[_selected][0])
	if clip.has_meta("impact"):
		var windup: float = clip.get_meta("windup")
		var active_end: float = clip.get_meta("active_end")
		_phase.text = "Подготовка → разгон" if _time < windup else "КОНТАКТ / активная фаза" if _time <= active_end else "Возврат в защиту"
		_phase.modulate = Color(.55, 1, .77) if _time >= windup and _time <= active_end else Color.WHITE
	else:
		_phase.text = "Та же AnimationLibrary, что в игре. Пауза и ползунок показывают точный кадр."
		_phase.modulate = Color.WHITE


func _exit_showcase() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_yaw -= event.relative.x * .35
		_pitch = clampf(_pitch - event.relative.y * .25, -65, 35)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(1.8, _distance - .2)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(6.0, _distance + .2)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		match key:
			KEY_SPACE: _toggle_play()
			KEY_LEFT: _step_frame(-1)
			KEY_RIGHT: _step_frame(1)
			KEY_UP: _select_clip(_selected - 1)
			KEY_DOWN: _select_clip(_selected + 1)
			KEY_ESCAPE, KEY_H: _exit_showcase()
			KEY_R: _set_camera(0)
			KEY_L:
				_speed_index = (_speed_index + 1) % SPEEDS.size()
				_speed_picker.select(_speed_index)
			KEY_F4:
				T.QUALITY = (T.QUALITY + 1) % T.QUALITY_NAMES.size()
				_world.showcase_lighting()
			KEY_B:
				T.BRIGHTNESS = (T.BRIGHTNESS + 1) % T.BRIGHTNESS_NAMES.size()
				_world.showcase_lighting()
			KEY_G:
				T.TOON_ENABLED = not T.TOON_ENABLED
				_world.showcase_lighting()
				if _world.has_method("style_character"):
					_world.style_character(character, T.TOON_ENABLED)
			_:
				if key >= KEY_1 and key <= KEY_9:
					_select_clip(key - KEY_1)
				elif key == KEY_0:
					_select_clip(9)
