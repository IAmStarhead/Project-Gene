## Separate deterministic smoke/regression checks for presentation systems.
extends SceneTree

const T := preload("res://scripts/tuning.gd")
const Foley := preload("res://scripts/actor_foley.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)


func _run() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	var player: CharacterBody3D = scene.player
	var clone: CharacterBody3D = scene.clone
	var rig = player.rig
	check(is_instance_valid(rig) and is_instance_valid(rig.spring), "camera exists")
	check(absf(rig.spring.spring_length - T.CAMERA_DISTANCE) < 0.2, "camera initial distance")
	check(rig.spring.collision_mask == 1 and rig.spring.shape is SphereShape3D, "sphere collides with world only")
	var wall := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 2.0, 0.3)
	collider.shape = box
	wall.add_child(collider)
	root.add_child(wall)
	wall.global_transform = rig.spring.global_transform.translated_local(Vector3(0.0, 0.0, 1.0))
	for i in 4:
		await physics_frame
	check(rig.spring.get_hit_length() < 1.3, "camera spring retracts at a wall")
	wall.queue_free()
	for i in 4:
		await physics_frame
	check(is_instance_valid(player.foley) and is_instance_valid(clone.foley), "foley attached to both actors")
	check(Foley.STEPS.size() == 8 and Foley.STEPS[0] is AudioStreamWAV, "barefoot assets imported")
	check(player.hud.get("_values_label") != null, "HUD numeric labels")
	check(scene.menu.get("_items").has("camera") and scene.menu.get("_items").has("sound"), "pause controls")
	var initial_energy: float = scene.room.get("_sun").light_energy
	scene._on_menu_action("brightness")
	check(scene.room.get("_sun").light_energy > initial_energy, "brightness preset changes light")
	T.BRIGHTNESS = 1
	scene.room.rebuild_lighting(T.TOON_ENABLED)
	scene.menu.open()
	check(paused and scene.menu.visible, "menu pauses")
	scene._on_menu_action("sound")
	check(not T.FOLEY_ENABLED, "menu toggles sound")
	scene._on_menu_action("sound")
	scene._on_menu_action("camera")
	check(not T.CAMERA_DYNAMIC, "menu toggles camera dynamics")
	scene._on_menu_action("camera")
	scene.menu.close()
	check(not paused and not scene.menu.visible, "menu resumes")

	player.velocity = Vector3(T.RUN_SPEED, 0, 0)
	rig._process(1.0)
	check(rig.spring.spring_length > T.CAMERA_DISTANCE + 0.2, "speed pulls camera back")
	check(rig.camera.fov > 71.0, "speed increases FOV")
	T.CAMERA_DYNAMIC = false
	rig.add_kick(1.0)
	rig._process(1.0)
	check(absf(rig.camera.fov - 68.0) < 0.3, "reduced motion resets FOV")
	check(absf(float(rig.get("_kick_deg"))) < 0.001, "reduced motion disables kick")
	T.CAMERA_DYNAMIC = true

	var player_slot: int = player.foley.get("_slot")
	var start_position: Vector3 = player.global_position
	Input.action_press("move_forward")
	for i in 75:
		await physics_frame
	Input.action_release("move_forward")
	check(player.global_position.distance_to(start_position) > 0.5, "actual controller moved")
	check(int(player.foley.get("_slot")) > player_slot, "actual controller triggered steps")
	player_slot = player.foley.get("_slot")
	player._start_attack()
	for i in 20:
		await physics_frame
	check(int(player.foley.get("_slot")) > player_slot, "actual attack triggered swing")

	var f = Foley.new()
	root.add_child(f)
	await process_frame
	f.update_motion(1.0 / 60.0, 0.49, true, 0.02, "")
	var n: int = f.get("_slot")
	f.update_motion(1.0 / 60.0, 0.51, true, 0.02, "")
	check(int(f.get("_slot")) == n + 1, "step at contact phase crossing")
	n = f.get("_slot")
	f.update_motion(1.0 / 60.0, 0.99, true, 0.0, "")
	f.update_motion(1.0 / 60.0, 0.01, true, 0.0, "")
	check(int(f.get("_slot")) == n, "no steps against wall")
	f.update_motion(1.0 / 60.0, 0.49, false, 0.02, "")
	f.update_motion(1.0 / 60.0, 0.51, false, 0.02, "")
	check(int(f.get("_slot")) == n, "no steps in air")
	f.update_motion(1.0 / 60.0, 0.51, true, 0.0, "")
	check(int(f.get("_slot")) == n + 1, "one landing")
	n = f.get("_slot")
	f.update_motion(1.0 / 60.0, 0.99, true, 0.02, "attack")
	f.update_motion(1.0 / 60.0, 0.01, true, 0.02, "attack")
	check(int(f.get("_slot")) == n, "no gait step during attack")
	T.FOLEY_ENABLED = false
	f.swing()
	f.impact()
	f.hurt()
	check(int(f.get("_slot")) == n, "muted foley does not start voices")
	T.FOLEY_ENABLED = true
	f.impact()
	check(int(f.get("_slot")) == n + 1, "impact starts a voice")
	f.queue_free()
	scene.queue_free()
	await process_frame
	# Allow the dummy audio mixer to retire stopped playbacks before shutdown.
	OS.delay_msec(100)
	await process_frame
	print("Presentation suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
