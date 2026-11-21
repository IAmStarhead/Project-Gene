## Background music for the laboratory. Non-spatial, independent of SFX.
## Two players overlap the end and beginning, so a non-looping track doesn't
## abruptly snap back to its start. The node lives only in the game scene.
extends Node

const T := preload("res://scripts/tuning.gd")
const TRACK_PATH := "res://assets/audio/music/calm_ambient_1.ogg"
const FADE_SECONDS := 4.0
const LEVEL_DB := [-80.0, -24.0, -16.0] # off, quiet (default), normal

var track: AudioStream
var available := false
var playback_requested := false
var players: Array[AudioStreamPlayer] = []
var current := 0
var fading := false
var fade_time := 0.0
var fade_length := FADE_SECONDS


func _ready() -> void:
	# Music and its menu controls remain active while the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Some stripped-down diagnostic builds omit Vorbis entirely. Do not let
	# missing optional audio prevent the game scene from loading.
	if not ClassDB.class_exists("AudioStreamOggVorbis"):
		return
	track = load(TRACK_PATH) as AudioStream
	if track == null:
		return
	available = true
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.stream = track
		player.volume_db = -80.0
		add_child(player)
		players.append(player)
	# Headless test runs have no speakers and may exit before the dummy audio
	# mixer has released its stream. Dedicated audio tests start it explicitly.
	if DisplayServer.get_name() != "headless":
		set_level(T.MUSIC_LEVEL)


func _exit_tree() -> void:
	for player in players:
		player.stop()
		player.stream = null
	track = null


func set_level(value: int) -> void:
	if not available:
		return
	T.MUSIC_LEVEL = clampi(value, 0, LEVEL_DB.size() - 1)
	playback_requested = T.MUSIC_LEVEL != 0
	if T.MUSIC_LEVEL == 0:
		for player in players:
			player.stop()
		fading = false
		fade_time = 0.0
		return
	if not players[current].playing:
		players[current].volume_db = LEVEL_DB[T.MUSIC_LEVEL]
		players[current].play()
	if fading:
		_set_fade_volumes()
	else:
		players[current].volume_db = LEVEL_DB[T.MUSIC_LEVEL]


func _set_fade_volumes() -> void:
	var t := clampf(fade_time / fade_length, 0.0, 1.0)
	var level := db_to_linear(LEVEL_DB[T.MUSIC_LEVEL])
	players[current].volume_db = linear_to_db(maxf(level * (1.0 - t), 0.0001))
	players[1-current].volume_db = linear_to_db(maxf(level * t, 0.0001))


func _process(delta: float) -> void:
	if not playback_requested or T.MUSIC_LEVEL == 0 or players.size() != 2:
		return
	var active := players[current]
	if not fading:
		if not active.playing:
			# Recover from a long frame or an audio device interruption.
			active.volume_db = LEVEL_DB[T.MUSIC_LEVEL]
			active.play()
			return
		var remaining := track.get_length() - active.get_playback_position()
		if remaining <= FADE_SECONDS:
			fade_length = maxf(remaining, .05)
			fade_time = 0.0
			fading = true
			players[1-current].volume_db = -80.0
			players[1-current].play()
	if fading:
		fade_time = minf(fade_time + delta, fade_length)
		_set_fade_volumes()
		if fade_time >= fade_length:
			players[current].stop()
			current = 1-current
			fading = false
