## Небольшой пространственный набор звуков для игрока и клона.
## Фазы шагов соответствуют общей фазе анимации (0 и 0.5), а не таймеру ввода.
extends Node3D

const T := preload("res://scripts/tuning.gd")
const STEPS := [
	preload("res://assets/audio/barefoot_0.wav"), preload("res://assets/audio/barefoot_1.wav"),
	preload("res://assets/audio/barefoot_2.wav"), preload("res://assets/audio/barefoot_3.wav"),
	preload("res://assets/audio/barefoot_4.wav"), preload("res://assets/audio/barefoot_5.wav"),
	preload("res://assets/audio/barefoot_6.wav"), preload("res://assets/audio/barefoot_7.wav"),
]
const SWISH := preload("res://assets/audio/knife_swish.wav")
const IMPACT := preload("res://assets/audio/hit_body.wav")

var _voices: Array[AudioStreamPlayer3D] = []
var _slot := 0
var _step_index := 0
var _prev_phase := 0.0
var _phase_known := false
var _was_grounded := false
var _ground_known := false


func _ready() -> void:
	for i in 4:
		var voice := AudioStreamPlayer3D.new()
		voice.max_distance = 18.0
		voice.unit_size = 5.0
		voice.max_db = -3.0
		add_child(voice)
		_voices.append(voice)


func _exit_tree() -> void:
	silence()


func silence() -> void:
	for voice in _voices:
		voice.stop()


func update_motion(delta: float, phase: float, grounded: bool, distance: float, action: String) -> void:
	if _ground_known and grounded and not _was_grounded:
		_step(-9.0)
	_was_grounded = grounded
	_ground_known = true
	# Только фактически пройденное расстояние и только движение ног: в воздухе,
	# у стены, при увороте или атаке шаги не продолжаются по одному вводу.
	if _phase_known and grounded and action == "" and distance > 0.0005:
		var advance := fposmod(phase - _prev_phase + 0.5, 1.0) - 0.5
		if absf(advance) < 0.25:
			var before := int(floor(_prev_phase * 2.0))
			var after := int(floor((_prev_phase + advance) * 2.0))
			if before != after:
				_step(-15.0 if distance / maxf(delta, 0.001) < 1.6 else -11.5)
	_prev_phase = phase
	_phase_known = true


func _step(db: float) -> void:
	_play(STEPS[_step_index % STEPS.size()], db)
	_step_index += 3


func swing() -> void:
	_play(SWISH, -15.0)


func impact() -> void:
	_play(IMPACT, -10.0)


func hurt() -> void:
	# Вокал временно отключён: текущие записи не подходят персонажу.
	pass


func _play(stream: AudioStream, db: float) -> void:
	if not T.FOLEY_ENABLED or _voices.is_empty():
		return
	var voice := _voices[_slot % _voices.size()]
	_slot += 1
	voice.stream = stream
	voice.volume_db = db
	voice.pitch_scale = 1.0
	voice.play()
