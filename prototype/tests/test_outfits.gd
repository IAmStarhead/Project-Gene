## Both native wardrobe meshes, controls, morph and comparable CPU cost.
## No rendered FPS / target GPU claim; actual framebuffer review is separate.
extends SceneTree
const MainScene := preload("res://scenes/main.tscn")
const ShowcaseScene := preload("res://scenes/showcase.tscn")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
var world: Node3D

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: "+message)

func action(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	T.OUTFIT = "dress"
	var main := MainScene.instantiate()
	world.add_child(main)
	main.player.set_physics_process(false)
	main.clone.set_physics_process(false)
	main.player.rig.set_process(false)
	check(main.player.character.appearance.outfit == "dress" and main.clone.character.appearance.outfit == "dress",
		"a new session starts in the retained dress")
	var original: Mesh = main.player.character.appearance.body.mesh
	main._unhandled_input(action("toggle_outfit"))
	check(T.OUTFIT == "suit", "O selects fitted subject jumpsuit")
	for character in [main.player.character, main.clone.character]:
		var a: Node3D = character.appearance
		check(a.suit.visible and not a.gown.visible and not a.skirt.visible and a.outfit == "suit",
			"both actual actors switch geometry, not just a wardrobe label")
		check(a.suit.skin == a.body.skin and a.suit.skeleton == a.body.skeleton,
			"outfit binds the original imported skeleton")
		check(a.suit.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() > 5000,
			"real continuous fitted shell geometry installed")
		a.set_hands(.75)
		check(absf(a.body.get_blend_shape_value(0)-.75) < .000001,
			"switching body coverage preserves the manual RelaxedHands morph")
		var previous_upload: PackedByteArray = a._vertex_bytes.duplicate()
		for clip in character.MOTIONS.get_animation_list():
			character.seek_clip(clip, character.clip_duration(clip)*.43)
			check(a.suit.visible and a.body.mesh.get_blend_shape_count() == 1, "suit + hand morph during "+clip)
		check(a._vertex_bytes == previous_upload, "hidden skirt does not simulate/upload under trousers")
	# Persist selection through the actual H -> showcase and Esc -> game
	# resources, without losing scene-lighting or clone tint composition.
	var showcase := ShowcaseScene.instantiate()
	world.add_child(showcase)
	showcase.set_process(false)
	check(showcase.character.appearance.outfit == "suit", "showcase inherits session wardrobe")
	showcase._toggle_outfit()
	check(T.OUTFIT == "dress" and showcase.character.appearance.gown.visible,
		"showcase wardrobe control returns to retained dress")
	showcase.free()
	for ch in [main.player.character, main.clone.character]:
		ch.appearance.set_outfit("dress")
	check(main.player.character.appearance.body.mesh == original,
		"round trip restores EXACT cached dress body index buffer (no mask growth)")
	check(main.clone.character.appearance.clone_variant, "wardrobe does not remove clone fabric tint")
	# Identical two-actor pose/control workload; only wardrobe differs.
	for outfit in ["dress", "suit"]:
		var timings: Array[int] = []
		for ch in [main.player.character, main.clone.character]:
			ch.appearance.set_outfit(outfit)
			ch.reset_motion(true)
		for i in 150:
			var started := Time.get_ticks_usec()
			for ch in [main.player.character, main.clone.character]:
				ch.update_motion(1.0/60, Vector3(2, 0, -2), "", 0, "R",
					{"grounded": true, "combat": true, "directional": true, "distance": 2.9/60})
			if i >= 30:
				timings.append(Time.get_ticks_usec()-started)
		timings.sort()
		var a: Node3D = main.player.character.appearance
		var triangles: int = a.body.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size()/3
		triangles += a.suit.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size()/3 if outfit == "suit" else a.gown.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size()/3+576
		print("Wardrobe %s: two-actor CPU median %d us p95 %d us max %d us; per-actor visible mesh triangles %d. Headless sandbox, NOT GPU FPS." % [outfit, timings[timings.size()/2], timings[int(timings.size()*.95)], timings[-1], triangles])
	main.free()
	T.OUTFIT = "dress"
	world.free()
	await process_frame
	print("GEN wardrobe suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
