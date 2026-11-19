## Diagnostic CPU microbenchmark, not a whole-game or GPU/FPS benchmark.
## godot --headless --path prototype --script res://tests/benchmark_animation.gd
extends SceneTree

const Character := preload("res://scripts/character_anim.gd")


func _initialize() -> void:
	call_deferred("_run")


func _bench(characters: Array, label: String, action: String, with_appearance: bool, hit: bool) -> void:
	var appearances: Array = []
	for c in characters:
		appearances.append(c.appearance)
		if not with_appearance:
			c.appearance = null
		c.reset_motion(true)
	var timings: Array[int] = []
	for i in 240:
		var start := Time.get_ticks_usec()
		for c in characters:
			if hit and i % 12 == 0:
				c.play_hit()
			c.update_motion(1.0 / 60.0, Vector3(0, 0, 1.65), action,
				fposmod(float(i) / 60.0, 0.56), "R",
				{"distance": 1.65 / 60.0, "grounded": true, "combat": true})
		if i >= 40:
			timings.append(Time.get_ticks_usec() - start)
	for i in characters.size():
		characters[i].appearance = appearances[i]
	timings.sort()
	print("BENCH %s: median=%d us, p95=%d us (%d samples)" % [label,
		timings[timings.size() / 2], timings[int(timings.size() * .95)], timings.size()])


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var characters: Array = []
	for i in 2:
		var character := Node3D.new()
		character.set_script(Character)
		world.add_child(character)
		characters.append(character)
	_bench([characters[0]], "one walk, pose only", "", false, false)
	_bench([characters[0]], "one attack, pose only", "attack", false, false)
	_bench([characters[0]], "one walk, with appearance", "", true, false)
	_bench(characters, "two walk, with appearance", "", true, false)
	_bench(characters, "two attack and hit reactions, with appearance", "attack", true, true)
	world.free()
	quit()
