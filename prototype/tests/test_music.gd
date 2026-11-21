## Game scene music, independent menu setting, pause, looping and cleanup.
extends SceneTree
const Main := preload("res://scenes/main.tscn")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var previous_level: int = T.MUSIC_LEVEL
	var previous_foley: bool = T.FOLEY_ENABLED
	T.MUSIC_LEVEL = 1
	T.FOLEY_ENABLED = true
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 3.0
	AudioServer.add_bus_effect(0, capture)
	var main := Main.instantiate()
	root.add_child(main)
	var music = main.music
	# The headless game intentionally suppresses autoplay; test the real player.
	music.set_level(T.MUSIC_LEVEL)
	# Dummy audio mixes on a real-time thread even under --fixed-fps.
	OS.delay_msec(1500)
	var frames := capture.get_buffer(capture.get_frames_available())
	var peak := 0.0
	for frame in frames:
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	check(frames.size() > 0 and peak > .00001, "actual mixer produces nonzero signal")
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0)-1)
	check(music.track is AudioStreamOggVorbis and music.track.get_length() > 30.0, "imported playable full music track")
	print("Music length: %.2f s" % music.track.get_length())
	check(music.players.size() == 2 and music.players[0].playing and not music.players[1].playing, "one player starts on entry")
	check(is_equal_approx(music.players[0].volume_db, -24.0), "quiet initial level")
	check(main.menu._items.has("music") and main.menu._items.has("sound"), "independent menu rows")
	check("тихо" in main.menu._items["music"]["button"].text, "menu displays the actual initial level")
	main.menu.open()
	check(paused and music.can_process() and music.players[0].can_process(), "music continues while pause menu is open")
	main.menu._activate("music")
	check(T.MUSIC_LEVEL == 2 and T.FOLEY_ENABLED and is_equal_approx(music.players[0].volume_db, -16.0), "menu selects normal without affecting effects")
	main.menu._activate("music")
	check(T.MUSIC_LEVEL == 0 and not music.players[0].playing and not music.players[1].playing and T.FOLEY_ENABLED, "menu stops music without muting effects")
	main.menu._activate("music")
	check(T.MUSIC_LEVEL == 1 and music.players[0].playing, "music can be restarted quietly")
	main.menu.close()
	# Test the overlap deterministically with the real imported stream.
	music.players[music.current].seek(music.track.get_length() - 3.5)
	music._process(.1)
	check(music.fading and music.players[1-music.current].playing, "second player starts before end")
	var old: int = music.current
	music._process(1.0)
	check(music.players[old].volume_db < -24.0 and music.players[1-old].volume_db < -24.0, "both tracks are attenuated during overlap")
	music._process(10.0)
	check(not music.fading and music.current != old and not music.players[old].playing and music.players[music.current].playing, "overlap ends with just new player")
	music.players[music.current].seek(music.track.get_length() - 3.5)
	music._process(.1)
	music.set_level(0)
	check(not music.fading and not music.players[0].playing and not music.players[1].playing, "off stops both during crossfade")
	main.free()
	var again := Main.instantiate()
	root.add_child(again)
	check(T.MUSIC_LEVEL == 0 and not again.music.players[0].playing and not again.music.players[1].playing, "setting retained across scene recreation")
	again.free()
	T.MUSIC_LEVEL = previous_level
	T.FOLEY_ENABLED = previous_foley
	await process_frame
	print("Ambient music suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
