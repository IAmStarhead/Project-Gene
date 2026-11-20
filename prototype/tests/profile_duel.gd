## Reproducible headless CPU-only scene test: real AI, player attacks and damage.
## Does not measure rendering/GPU or target hardware.
## godot --headless --fixed-fps 60 --path prototype --script res://tests/profile_duel.gd
extends SceneTree

const T := preload("res://scripts/tuning.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	T.FOLEY_ENABLED = OS.get_environment("DUEL_SOUND") != "0"
	var outfit := OS.get_environment("DUEL_OUTFIT")
	if outfit in ["dress", "suit"]:
		T.OUTFIT = outfit
	print("DUEL outfit: ", T.OUTFIT)
	print("DUEL sound enabled: ", T.FOLEY_ENABLED, " (headless dummy audio)")
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame
	var p = scene.player
	var c = scene.clone
	# Same near-camera positions in both scenarios, and no other target in the way.
	p.global_position = Vector3(0, .08, 0)
	c.global_position = Vector3(0, .08, -1.0)
	p.rotation.y = 0
	c.rotation.y = PI
	p.rig.snap_now()
	c.set_profiling(true)
	var passive_elapsed: Array[int] = []
	for i in 240:
		var begin := Time.get_ticks_usec()
		await physics_frame
		if i >= 60:
			passive_elapsed.append(Time.get_ticks_usec() - begin)
	print("DUEL passive: ", c.profile_text)
	_print_intervals("passive", passive_elapsed)
	c.cycle_mode()
	c.health = 1000.0 # Keep the clone alive through the controlled experiment.
	p.lock.target = c
	var clone_hits := 0
	var player_hits := 0
	var clone_attacking_ticks := 0
	var player_attacking_ticks := 0
	var previous_clone_health: float = c.health
	var previous_player_health: float = p.health
	var active_elapsed: Array[int] = []
	for i in 480:
		# Trigger the real attack state regularly; no manual damage or fake AI.
		if i % 50 == 0 and p._action == "":
			p._start_attack()
		var begin := Time.get_ticks_usec()
		await physics_frame
		if i >= 60:
			active_elapsed.append(Time.get_ticks_usec() - begin)
		if p.health < previous_player_health - .01:
			clone_hits += 1
		if c.health < previous_clone_health - .01:
			player_hits += 1
		previous_player_health = p.health
		previous_clone_health = c.health
		if c._attack_time >= 0.0:
			clone_attacking_ticks += 1
		if p._action == "attack":
			player_attacking_ticks += 1
	print("DUEL active: ", c.profile_text)
	_print_intervals("active", active_elapsed)
	print("DUEL hits clone=%d player=%d; attack_ticks clone=%d player=%d" % [
		clone_hits, player_hits, clone_attacking_ticks, player_attacking_ticks])
	if clone_hits < 1 or player_hits < 1:
		printerr("FAIL: duel did not include hits from both actors")
		quit(1)
		return
	scene.queue_free()
	await process_frame
	OS.delay_msec(100)
	await process_frame
	quit()


func _print_intervals(label: String, samples: Array[int]) -> void:
	samples.sort()
	print("DUEL %s elapsed between physics callbacks: median=%d us p95=%d us (%d samples)" % [label,
		samples[samples.size() / 2], samples[int(samples.size() * .95)], samples.size()])
