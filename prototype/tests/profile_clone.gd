## Actual scene/AI CPU diagnostic. Not a GPU, playtest, or target-hardware benchmark.
## godot --headless --fixed-fps 60 --path prototype --script res://tests/profile_clone.gd
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame
	var p = scene.player
	var c = scene.clone
	# Isolate clone costs but retain actual AI, physics and character updates.
	p.set_physics_process(false)
	p.set_process(false)
	p._invulnerable = true
	c.set_profiling(true)
	for i in 180:
		await physics_frame
	print("CLONE passive: ", c.profile_text)
	c.global_position = p.global_position + Vector3(0, 0, -1.0)
	c.cycle_mode()
	var attack_ticks := 0
	for i in 360:
		await physics_frame
		if c._attack_time >= 0.0:
			attack_ticks += 1
	print("CLONE active close: ", c.profile_text, " attack_ticks=", attack_ticks)
	if attack_ticks == 0:
		printerr("FAIL: clone never attacked")
		quit(1)
		return
	scene.queue_free()
	await process_frame
	OS.delay_msec(100)
	await process_frame
	quit()
