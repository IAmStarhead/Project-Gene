## Combined-game regressions for report 42: both sides of the integration.
## Logic/scene tests, NOT a rendered/GPU or anatomical-hitbox acceptance test.
extends SceneTree

const T := preload("res://scripts/tuning.gd")
const BuildScene := preload("res://scripts/build_scene.gd")
const HitCheck := preload("res://scripts/hit_check.gd")
const MainScene := preload("res://scenes/main.tscn")
const ShowcaseScene := preload("res://scenes/showcase.tscn")

class Target:
	extends Node3D
	var health := 60.0
	var hits := 0
	func is_alive() -> bool:
		return health > 0
	func take_damage(amount: float, _direction: Vector3) -> void:
		health -= amount
		hits += 1

var checks := 0
var failures := 0
var world: Node3D

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func event(action: String) -> InputEventAction:
	var result := InputEventAction.new()
	result.action = action
	result.pressed = true
	return result

func key(code: Key) -> InputEventKey:
	var result := InputEventKey.new()
	result.physical_keycode = code
	result.pressed = true
	return result

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	_test_material_lifetime()
	_test_hit_geometry()
	await _test_combined_game()
	await _test_showcase_composition()
	world.free()
	print("GEN combined integration suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_material_lifetime() -> void:
	var room_a := Node3D.new()
	room_a.set_script(BuildScene)
	var room_b := Node3D.new()
	room_b.set_script(BuildScene)
	var base := StandardMaterial3D.new()
	base.albedo_color = Color(.7, .6, .5)
	var skin: Material = room_a._make_skin_pbr(base)
	var toon: Material = room_a._make_toon_material(base)
	check(skin == room_a._make_skin_pbr(base), "PBR is cached, not allocated on every style sweep")
	check(toon == room_a._make_toon_material(base), "toon lifetime repair survives upstream lighting rewrite")
	room_a.free()
	check(skin == room_b._make_skin_pbr(base) and toon == room_b._make_toon_material(base),
		"both immutable overrides outlive the room during main/showcase handoff")
	check(base.albedo_color == Color(.7, .6, .5), "style overrides do not mutate the source material")
	var other := StandardMaterial3D.new()
	check(skin != room_b._make_skin_pbr(other) and toon != room_b._make_toon_material(other),
		"distinct source materials do not alias the same cached override")
	room_b.free()

func _test_hit_geometry() -> void:
	var attacker := Node3D.new()
	world.add_child(attacker)
	var target := Target.new()
	world.add_child(target)
	target.position = Vector3(0, 0, -.9)
	var hit := HitCheck.find_hit(attacker, [target], Vector3.FORWARD, .72, 52)
	check(hit.get("target") == target and hit.get("zone") == "torso", "incoming segment hit + approximate torso zone are retained")
	check(HitCheck.nearest_hit(attacker, [target], Vector3.FORWARD, .72, 52) == target,
		"legacy nearest-hit adapter still resolves the same target")
	target.position.z = -.25
	check(HitCheck.overlaps(attacker, target, Vector3.FORWARD, .72), "whole arm segment hits at very close range")
	target.position.z = -1.10
	check(not HitCheck.overlaps(attacker, target, Vector3.FORWARD, .72), "anatomical radius does not restore the old overlong hit range")
	target.position = Vector3(.6, 0, -.8)
	check(HitCheck.find_hit(attacker, [target], Vector3.FORWARD, .72, 52).is_empty(), "inside cone is insufficient without geometric contact")
	target.position = Vector3(0, 0, -.9)
	check(HitCheck.find_hit(attacker, [target], Vector3.BACK, .72, 52).is_empty(), "no damage behind the attack facing")
	for item in [[-.22, "head"], [0.0, "torso"], [.60, "legs"]]:
		target.position.y = item[0]
		hit = HitCheck.find_hit(attacker, [target], Vector3.FORWARD, .72, 52)
		check(hit.get("zone") == item[1], "existing height-based approximation, not new anatomy: " + item[1])
	target.position.y = 2.0
	check(not HitCheck.overlaps(attacker, target, Vector3.FORWARD, .72), "vertical separation can miss")
	target.position.y = 0
	target.health = 0
	check(HitCheck.find_hit(attacker, [target], Vector3.FORWARD, .72, 52).is_empty(), "dead targets cannot be damaged again")
	target.free()
	attacker.free()

func _test_combined_game() -> void:
	var main := MainScene.instantiate()
	world.add_child(main)
	var player: CharacterBody3D = main.player
	var clone: CharacterBody3D = main.clone
	player.set_physics_process(false)
	clone.set_physics_process(false)
	player.rig.set_process(false)
	check(player.global_position == main.room.spawn_point() and clone.global_position == main.room.clone_spawn_point(),
		"new laboratory spawn points, not old overlapping clone fixture")
	check(player.hud != null and player.hud.player == player and player.hud.lock == player.lock,
		"new live HUD is wired to the real player + lock")
	check(player.rig.get_parent() != player and player.rig.target == player,
		"separate camera root cannot inherit character turn")
	check(player.character.appearance.gown != null and clone.character.appearance.clone_variant,
		"repair-41 garment and independent clone fabric survive the new main scene")
	check(not T.TOON_ENABLED, "upstream default PBR is not replaced with old default toon")

	var sun: DirectionalLight3D = main.room._sun
	var environment: Environment = main.room._env
	var saved_quality: int = T.QUALITY
	var saved_brightness: int = T.BRIGHTNESS
	for preset in [0, 1, 2]:
		T.QUALITY = preset
		main._apply_quality()
		check(main.room._sun == sun and main.room._env == environment,
			"quality changes existing light/environment nodes in place: %d" % preset)
	T.BRIGHTNESS = 2
	main._apply_lighting()
	check(main.room._sun.light_energy > 0 and main.room._sun == sun, "upstream brightness path remains active")
	T.QUALITY = saved_quality
	T.BRIGHTNESS = saved_brightness
	main._apply_quality()

	# The incoming passive-clone optimisation may freeze cloth/pose, but the
	# parent still turns toward a walking player. Read the UPLOADED mesh, not
	# old world solver points transformed by a new parent basis (false FCL hit).
	var appearance: Node3D = clone.character.appearance
	var displayed_before: PackedVector3Array = appearance.cloth_vertices()
	var uploaded: PackedByteArray = appearance._vertex_bytes.duplicate()
	var rotation_before := clone.rotation.y
	clone.rotation.y += .75
	var displayed_after: PackedVector3Array = appearance.cloth_vertices()
	var largest := 0.0
	for i in displayed_before.size():
		largest = maxf(largest, displayed_before[i].distance_to(displayed_after[i]))
	check(displayed_before.size() == 320 and largest < .000001,
		"sleeping/turning clone readback remains the same ACTUALLY DISPLAYED local skirt")
	check(uploaded == appearance._vertex_bytes, "diagnostic readback cannot wake or re-upload the sleeping clone")
	clone.rotation.y = rotation_before

	# Tab must acquire a passive clone too, without silently choosing a stance.
	player._unhandled_input(event("lock_on"))
	check(player.lock.target == clone and not player.combat_mode, "Tab acquires the visible passive clone independently of R/T")
	var result: Array = []
	check(player.lock.movement(Vector2(1, -1).normalized(), result) and absf((result[0] as Vector3).length()-1) < .00001,
		"lock-on diagonal is normalized")
	result.clear()
	check(player.lock.facing(result) and (result[0] as Vector3).dot(Vector3.FORWARD) > .99,
		"lock-on faces the actual target, not the camera's visual child")
	check(not is_nan(player.lock.camera_yaw(.1, player.yaw)) and not is_nan(player.lock.camera_pitch(.1, player.pitch)),
		"both lock camera axes remain connected")

	var second := Target.new()
	second.name = "SecondTarget"
	second.position = Vector3(1.2, 0, 1.8)
	world.add_child(second)
	second.add_to_group("damageable")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	check(player.lock.handle_input(wheel) and player.lock.target == second, "wheel changes target using the incoming lock controller")
	second.health = 0
	player.lock.update(.1)
	check(not player.lock.active() and player.lock.target == null, "dead target is released safely")
	second.health = 60
	player.lock.target = second
	second.visible = false
	player.lock.update(.1)
	check(player.lock.target == null, "hidden target is released safely")
	second.visible = true
	player.lock.target = second
	second.position = player.position+Vector3(0, 0, -30)
	player.lock.update(.1)
	check(player.lock.target != second, "out-of-range target cannot be retained")
	player.lock.clear()
	second.free()

	# Occlusion grace uses the actual physics world, rather than a fake bool.
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	wall.position = Vector3(0, 1.3, 2.0)
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3, 3, .2)
	shape_node.shape = shape
	wall.add_child(shape_node)
	world.add_child(wall)
	await physics_frame
	player.lock.target = clone
	player.lock.update(.40)
	check(player.lock.active(), "brief occlusion retains lock during the grace interval")
	player.lock.update(.50)
	check(not player.lock.active(), "sustained wall occlusion breaks lock")
	player.lock.handle_input(event("lock_on"))
	check(not player.lock.active(), "cannot acquire a target through a static wall")
	wall.free()
	await physics_frame

	player.health = T.MAX_HEALTH-14
	player.stamina = 40
	player.combat_mode = true
	player.hud._process(.05)
	check(absf(player.hud._health_fill.size.x/player.hud.BAR_WIDTH-.86) < .00001,
		"HUD reads actual HP after integration")
	check(player.hud._health_lag.size.x > player.hud._health_fill.size.x,
		"incoming lagging damage bar is preserved")
	check(absf(player.hud._stamina_fill.size.x/player.hud.BAR_WIDTH-.40) < .00001
		and player.hud._stance_label.text.contains("БОЕВАЯ"), "HUD reads stamina and stance")
	player.show_details = true
	player._write_debug_label()
	check(player.label.text.contains("Последний контакт") and player.label.text.contains("захват"),
		"F3 retains incoming hit/lock diagnostics")

	# Two-argument passive/active clone damage contract is NOT a new zone API.
	var old_hp: float = clone.health
	clone.take_damage(24, Vector3.FORWARD)
	check(clone.health == old_hp and clone.is_passive(), "passive clone still confirms contact without losing HP")
	clone.cycle_mode()
	clone.take_damage(24, Vector3.FORWARD)
	check(clone.health == old_hp-24 and clone.character._hit_time == 0,
		"active clone loses existing damage and plays repaired additive hit")
	player._action = "attack"
	player._action_time = .13
	player._invulnerable = true
	var hp: float = player.health
	player.take_damage(14, Vector3.FORWARD)
	check(player.health == hp, "dodge i-frames still reject received damage")
	player._invulnerable = false
	player.take_damage(1, Vector3.FORWARD)
	check(player._action == "attack" and player._action_time == .13,
		"decorative hit cannot add an unannounced stun or reset an ongoing attack clock")
	player.lock.target = clone
	player.take_damage(T.MAX_HEALTH+1, Vector3.FORWARD)
	check(player.health == T.MAX_HEALTH and player.stamina == T.MAX_STAMINA and not player.lock.active()
		and not player.combat_mode and player.character._combat_blend == 0,
		"death clears lock, action and repair-41 stance/hit state")
	clone.take_damage(T.CLONE_HEALTH+1, Vector3.FORWARD)
	check(clone.is_passive() and clone.health == T.CLONE_HEALTH and clone._attack_time < 0,
		"clone respawn returns to the upstream passive mode")
	main.free()
	await process_frame

func _test_showcase_composition() -> void:
	var showcase := ShowcaseScene.instantiate()
	world.add_child(showcase)
	showcase.set_process(false)
	check(showcase._controls != null and showcase._controls.safe_rect().size.y > 0,
		"responsive repair-41 showcase, not the old fixed-coordinate UI")
	check(showcase._world._is_showcase, "upstream studio lighting is used on entry")
	var saved_quality: int = T.QUALITY
	var saved_brightness: int = T.BRIGHTNESS
	showcase._unhandled_input(key(KEY_F4))
	check(T.QUALITY == (saved_quality+1)%T.QUALITY_NAMES.size() and showcase._world._is_showcase,
		"F4 retains studio lighting instead of reverting to the game's lighting")
	showcase._unhandled_input(key(KEY_B))
	check(T.BRIGHTNESS == (saved_brightness+1)%T.BRIGHTNESS_NAMES.size() and showcase._world._is_showcase,
		"B retains studio lighting too")
	showcase._unhandled_input(key(KEY_V))
	check(not showcase._controls.root.visible, "V still hides the responsive UI")
	await physics_frame
	showcase._distance = 20
	showcase._process(0)
	check(absf(showcase.cam.position.z) < 9 and showcase.cam.position.y >= .14,
		"upstream wall/floor guard composes with the actual off-centre framing")
	showcase._pitch = 12
	showcase._process(0)
	check(showcase.cam.position.y >= .14, "orbit cannot put the showcase camera below the floor")
	T.QUALITY = saved_quality
	T.BRIGHTNESS = saved_brightness
	showcase.free()
	await process_frame
