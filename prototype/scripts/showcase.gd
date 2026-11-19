## Витрина ВСЕХ настоящих клипов, а не отдельный список похожих поз.
## Игра, клон и эта сцена читают одну AnimationLibrary.
## Пробел — пауза, ←/→ — кадр, ↑/↓ — клип, L — скорость, Esc/H — игра.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const CharacterScript := preload("res://scripts/character_anim.gd")
const BuildScene := preload("res://scripts/build_scene.gd")
const Controls := preload("res://scripts/showcase_controls.gd")
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
var _controls: RefCounted


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
	cam.current = true
	add_child(cam)
	_make_ui()
	if T.TOON_ENABLED:
		_world.apply_toon(character)
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
	_controls = Controls.new(self)
	_controls.build()


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
	_controls.fit_full_body = true


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
	var frame: Dictionary = _controls.camera_frame(orbit, _distance)
	var focus: Vector3 = frame["focus"]
	cam.global_position = frame["position"]
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
		_phase.text = "Подготовка / разгон" if _time < windup else "КОНТАКТ / активная фаза" if _time <= active_end else "Возврат в защиту"
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
			_controls.fit_full_body = false
			_distance = maxf(1.8, _distance - .2)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_controls.fit_full_body = false
			_distance = minf(6.0, _distance + .2)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		match key:
			KEY_SPACE: _toggle_play()
			KEY_LEFT: _step_frame(-1)
			KEY_RIGHT: _step_frame(1)
			KEY_UP: _select_clip(_selected - 1)
			KEY_DOWN: _select_clip(_selected + 1)
			KEY_ESCAPE, KEY_H: _exit_showcase()
			KEY_R: _set_camera(0)
			KEY_V: _controls.toggle_visible()
			KEY_L:
				_speed_index = (_speed_index + 1) % SPEEDS.size()
				_speed_picker.select(_speed_index)
			KEY_B:
				T.BRIGHTNESS = (T.BRIGHTNESS + 1) % 3
				_world.rebuild_lighting(T.TOON_ENABLED)
			KEY_G:
				T.TOON_ENABLED = not T.TOON_ENABLED
				_world.rebuild_lighting(T.TOON_ENABLED)
				if T.TOON_ENABLED:
					_world.apply_toon(character)
				else:
					_world.clear_toon(character)
			_:
				if key >= KEY_1 and key <= KEY_9:
					_select_clip(key - KEY_1)
				elif key == KEY_0:
					_select_clip(9)
