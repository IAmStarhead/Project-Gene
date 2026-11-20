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
	var hud_root: Control = player.hud.get_child(0)
	var status_panel: Control = hud_root.get_node("StatusPanel")
	var quick: Control = hud_root.get_node("QuickAccess")
	var slots: Control = quick.get_node("EmptySlots")
	check(status_panel.position.y == 14.0 and quick.anchor_top == 1.0, "status at top, slots anchored at bottom")
	check(slots.get("POSITIONS").size() == 4 and slots.get_child_count() == 0, "four empty quick slots without invented items")
	check(not scene._hint_panel.visible and not scene._bar_panel.visible and not player.hud._values_label.visible, "gameplay has no text hints")
	var old_hp: float = player.health
	var old_stamina: float = player.stamina
	player.health = T.MAX_HEALTH * .5
	player.stamina = T.MAX_STAMINA * .25
	player.hud._process(0.0)
	check(absf(player.hud._health_fill.size.x - player.hud.BAR_WIDTH * .5) < .01, "health bar reflects real health")
	check(absf(player.hud._stamina_fill.size.x - player.hud.BAR_WIDTH * .25) < .01, "stamina bar reflects real stamina")
	check(player.hud._values_label.text.contains("50") and player.hud._values_label.text.contains("25"), "HUD text matches values")
	player.training_blade = true
	player.hud._process(0.0)
	check(not player.hud._training_panel.visible and player.hud._training_label.visible, "blade guidance stays off gameplay screen")
	player.training_blade = false
	player.hud._process(0.0)
	check(not player.hud._training_panel.visible, "blade guidance hides when disabled")
	player.health = old_hp
	player.stamina = old_stamina
	player.hud._process(0.0)
	check(scene.menu.get("_items").has("camera") and scene.menu.get("_items").has("sound"), "pause controls")
	var initial_energy: float = scene.room.get("_sun").light_energy
	scene._on_menu_action("brightness")
	check(scene.room.get("_sun").light_energy > initial_energy, "brightness preset changes light")
	T.BRIGHTNESS = 1
	scene.room.rebuild_lighting(T.TOON_ENABLED)
	scene.menu.open()
	check(paused and scene.menu.visible, "menu pauses")
	check(scene.menu._items.has("controls"), "pause offers controls")
	scene.menu._activate("controls")
	check(scene.menu._controls_panel.visible and not scene.menu._panel.visible and paused, "controls open within pause")
	var back_key := InputEventKey.new()
	back_key.pressed = true
	back_key.keycode = KEY_ESCAPE
	root.push_input(back_key)
	check(not scene.menu._controls_panel.visible and scene.menu._panel.visible and paused, "escape returns from controls to pause")
	scene._on_menu_action("sound")
	check(not T.FOLEY_ENABLED, "menu toggles sound")
	scene._on_menu_action("sound")
	scene._on_menu_action("camera")
	check(not T.CAMERA_DYNAMIC, "menu toggles camera dynamics")
	scene._on_menu_action("camera")
	scene.menu.close()
	check(not paused and not scene.menu.visible, "menu resumes")

	check(scene.menu._items.has("equipment"), "equipment accessible from pause")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_I
	key.physical_keycode = KEY_I
	root.push_input(key)
	check(paused and scene.equipment.visible and not scene.menu.enabled, "I opens equipment and pauses")
	check(scene.equipment.category == 1 and scene.equipment.entry != null, "real clothing shown by default")
	scene.equipment.tabs[0].pressed.emit()
	check(scene.equipment.category == 0 and scene.equipment.entry == null and scene.equipment.grid.get_child_count() == 12, "weapon grid is empty")
	scene.equipment.tabs[2].pressed.emit()
	check(scene.equipment.category == 2 and scene.equipment.entry == null, "item grid is empty")
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	root.push_input(escape)
	check(not paused and not scene.equipment.visible and scene.menu.enabled, "escape from direct equipment resumes")
	scene.menu.open()
	scene.menu._activate("equipment")
	check(paused and scene.equipment.visible and not scene.menu.visible, "pause opens equipment")
	root.push_input(escape)
	check(paused and scene.menu.visible and not scene.equipment.visible, "escape returns to pause without resuming")
	scene.menu.close()

	player.show_details = true
	player._set_clone_profiling(true)
	for i in 70:
		await physics_frame
	check(clone.profile_enabled and str(clone.profile_text).contains("Клон CPU/тик:"), "F3 collects clone timing window")
	player.show_details = false
	player._set_clone_profiling(false)
	await process_frame
	await physics_frame
	check(not clone.profile_enabled, "clone profiling stops with F3")

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
	f.swing()
	check(int(f.get("_slot")) == n + 1, "swing plays only one non-vocal sound")
	check(f.get("_voices")[(n % 4)].stream == Foley.SWISH, "swing uses swish")
	n = f.get("_slot")
	f.hurt()
	check(int(f.get("_slot")) == n, "hurt does not play a vocal")
	T.FOLEY_ENABLED = false
	f.swing()
	f.impact()
	f.hurt()
	check(int(f.get("_slot")) == n, "muted foley does not start voices")
	T.FOLEY_ENABLED = true
	f.impact()
	check(int(f.get("_slot")) == n + 1, "impact starts a voice")
	# Use deterministic ticks to verify regeneration and hit gating.
	player.set_physics_process(false)
	player.health = 70.0
	player.take_damage(10.0, Vector3.ZERO)
	check(is_equal_approx(player.health, 60.0), "damage applied")
	player._update_health_regen(T.HEALTH_REGEN_DELAY - 0.5)
	check(is_equal_approx(player.health, 60.0), "no regeneration during delay")
	player._invulnerable = true
	player.take_damage(10.0, Vector3.ZERO)
	player._invulnerable = false
	player._update_health_regen(1.5)
	check(is_equal_approx(player.health, 60.0 + T.HEALTH_REGEN), "invulnerable hit does not reset delay; remainder heals")
	player.take_damage(1.0, Vector3.ZERO)
	var after_hit: float = player.health
	player._update_health_regen(T.HEALTH_REGEN_DELAY)
	check(is_equal_approx(player.health, after_hit), "new hit restarts delay")
	player._update_health_regen(100.0)
	check(is_equal_approx(player.health, T.MAX_HEALTH), "regeneration clamps to max")
	player.take_damage(999.0, Vector3.ZERO)
	check(is_equal_approx(player.health, T.MAX_HEALTH) and is_equal_approx(float(player.get("_health_cooldown")), 0.0), "prototype respawn resets health and delay")
	player.health = 50.0
	player.set_physics_process(true)
	scene.menu.open()
	await create_timer(0.15, true).timeout
	check(is_equal_approx(player.health, 50.0), "regeneration pauses with game")
	scene.menu.close()
	f.queue_free()
	scene.queue_free()
	await process_frame
	# Allow the dummy audio mixer to retire stopped playbacks before shutdown.
	OS.delay_msec(100)
	await process_frame
	print("Presentation suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
