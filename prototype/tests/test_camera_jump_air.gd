## Actual physics frames: shoulder collision, real jump, and visual-only trail.
extends SceneTree
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", description)

func tick(count: int) -> void:
	for i in count:
		await physics_frame
		await process_frame

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor_body := StaticBody3D.new()
	var floor_collider := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, .2, 30)
	floor_collider.shape = floor_box
	floor_collider.position.y = -.1
	floor_body.add_child(floor_collider)
	world.add_child(floor_body)
	var player = load("res://scenes/player.tscn").instantiate()
	world.add_child(player)
	await tick(12)
	var rig = player.rig
	check(player.is_on_floor(), "player starts grounded on real collision floor")
	check(T.CAMERA_SHOULDER < 0.0 and absf(rig.spring.position.x - T.CAMERA_SHOULDER) < .02,
		"camera is left of the heroine on open ground")
	check(rig.shoulder_probe.collision_mask == 1 and rig.spring.collision_mask == 1,
		"both camera segments collide with world, not actors")

	# Place a thin wall between pivot and desired shoulder, not behind camera.
	var wall := StaticBody3D.new()
	var wall_collider := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(.08, 2.0, 4.0)
	wall_collider.shape = wall_box
	wall.add_child(wall_collider)
	world.add_child(wall)
	wall.global_position = rig.to_global(Vector3(-.43, 0, 0))
	await tick(5)
	check(rig.shoulder_probe.is_colliding(), "side probe detects shoulder wall")
	check(absf(rig.spring.position.x) < absf(T.CAMERA_SHOULDER) * .65,
		"shoulder retracts immediately before wall")
	wall.queue_free()
	await tick(35)
	check(absf(rig.spring.position.x - T.CAMERA_SHOULDER) < .02, "shoulder returns smoothly after wall")
	check(player.strike_air.points.is_empty() and not player.strike_air.visible, "no air effect at rest")

	# Jump input starts on the next physics step: do not add anticipation lag.
	var base_y: float = player.position.y
	player._jump_buffer = 0.0
	var max_height := 0.0
	var airborne_frames := 0
	var seen_air := false
	var seen_land := false
	for i in 90:
		await tick(1)
		var height: float = player.position.y - base_y
		max_height = maxf(max_height, height)
		if i == 0:
			check(height > .02 and player.velocity.y > 0.0, "jump impulse is immediate")
		if not player.is_on_floor():
			seen_air = true
			airborne_frames += 1
		if seen_air and player.character._state == "land":
			seen_land = true
	check(seen_air and seen_land and player.is_on_floor(), "jump lands and plays landing transition")
	check(max_height > 1.00 and max_height < 1.25, "jump keeps approximately the previous measured height")
	check(airborne_frames >= 36 and airborne_frames <= 45, "jump flight has a measured, bounded duration")
	print("Jump 60 Hz measured: height %.3f m, airborne %d frames (%.3f s)" % [max_height, airborne_frames, airborne_frames / 60.0])

	player._attack_side = "L"
	player._start_attack()
	check(not player.strike_air.visible, "attack windup has no premature trail")
	var saw_trail := false
	var max_points := 0
	for i in 45:
		await tick(1)
		max_points = maxi(max_points, player.strike_air.points.size())
		saw_trail = saw_trail or player.strike_air.visible
	check(saw_trail and max_points >= 2 and max_points <= player.strike_air.MAX_POINTS,
		"actual missed attack creates bounded hand trail")
	check(player.strike_air.points.is_empty() and not player.strike_air.visible,
		"trail expires completely after the attack")
	check(player.strike_air.has_meta("air_effect") and player.strike_air.layers == 2
		and player.strike_air.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"trail is excluded from skin styling and does not cast shadows")
	player.training_blade = true
	player._attack_side = "R"
	player._start_attack()
	var saw_sword_trail := false
	for i in 24:
		await tick(1)
		saw_sword_trail = saw_sword_trail or player.strike_air.visible
	check(player._attack_blade and saw_sword_trail, "training sword uses the same visual hand trail")
	player.training_blade = false
	player._start_attack("hook")
	for i in 15: await tick(1)
	player.rig._set_hero_visible(false)
	check(not player.strike_air.is_visible_in_tree(), "near-wall hide also hides hand trail")
	player.rig._set_hero_visible(true)
	player.strike_air.clear_trail()
	player.strike_air.advance(.016, Vector3.ZERO, true, Vector3(0, 1, 3))
	player.strike_air.advance(.016, Vector3(4, 0, 0), true, Vector3(0, 1, 3))
	check(player.strike_air.points.size() == 1 and not player.strike_air.visible,
		"teleport cannot leave a ribbon across the room")
	world.queue_free()
	await process_frame
	OS.delay_msec(100) # Allow the dummy audio mixer to release playing streams.
	print("Camera jump air suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
