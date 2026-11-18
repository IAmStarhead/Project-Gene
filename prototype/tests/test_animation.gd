## Run from repository root:
## godot --headless --path prototype --fixed-fps 60 --script res://tests/test_animation.gd
## First import once: godot --headless --path prototype --editor --import
extends SceneTree

const Character := preload("res://scripts/character_anim.gd")
const T := preload("res://scripts/tuning.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const ShowcaseScene := preload("res://scenes/showcase.tscn")
const Probe := preload("res://tests/damage_probe.gd")

var failures := 0
var checks := 0
var world: Node3D


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func make_character() -> Node3D:
	var character := Node3D.new()
	character.set_script(Character)
	world.add_child(character)
	return character


func joint(character: Node3D, bone: String) -> Vector3:
	var skeleton: Skeleton3D = character.skeleton
	return skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin


func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var character := make_character()
	check(character.skeleton != null, "actual GLB imported with Skeleton3D")
	if character.skeleton == null:
		quit(1)
		return
	_test_native_tracks(character)
	_test_attack_clock(character)
	_test_distance_and_air(character)
	_test_locomotion_posture(character)
	_test_air_progress(character)
	_test_stance_blending(character)
	_test_relaxed_jump(character)
	_test_player_modes()
	_test_combat()
	_test_showcase()
	character.free()
	await _test_actual_physics()
	world.free()
	print("GEN native animation suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _test_native_tracks(character: Node3D) -> void:
	var mirror: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/heroine/animations/motion_set.json"))
	check(Character.MOTIONS.get_animation_list().size() == 14, "all 14 native clips loaded")
	check(character.skeleton.get_bone_count() == 21, "the original 21-bone rig is retained")
	var max_rotation_error := 0.0
	var max_position_error := 0.0
	for clip_name in mirror["clips"]:
		var data: Dictionary = mirror["clips"][clip_name]
		var clip: Animation = Character.MOTIONS.get_animation(clip_name)
		check(clip.get_track_count() == 22, "%s has all bones and hips" % clip_name)
		check(absf(clip.length - float(data["duration"])) < .000001, "%s duration" % clip_name)
		var count: int = data["times"].size()
		for frame in [0, count / 3, count / 2, count - 1]:
			var k := int(frame)
			character.seek_clip(clip_name, data["times"][k])
			for b in mirror["bones"].size():
				var values: Array = data["rotations"][k][b]
				var expected := Quaternion(values[0], values[1], values[2], values[3]).normalized()
				var actual: Quaternion = character.skeleton.get_bone_pose_rotation(
					character.skeleton.find_bone(mirror["bones"][b]))
				max_rotation_error = maxf(max_rotation_error, 1.0 - absf(actual.dot(expected)))
			var p: Array = data["hips"][k]
			var expected_position := Vector3(p[0], p[1], p[2])
			var actual_position: Vector3 = character.skeleton.get_bone_pose_position(
				character.skeleton.find_bone("hips"))
			max_position_error = maxf(max_position_error, expected_position.distance_to(actual_position))
	check(max_rotation_error < .000002, "native quaternion tracks match browser/source keys")
	check(max_position_error < .000002, "native hips track matches source")
	print("Native/source error: quaternion 1-|dot|=%.9f; hips=%.9f m" % [max_rotation_error, max_position_error])


func _test_attack_clock(character: Node3D) -> void:
	for timing in [Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY),
			Vector3(T.CLONE_WINDUP, T.CLONE_ACTIVE, T.CLONE_RECOVER)]:
		for side in ["L", "R"]:
			check(absf(character.attack_clip_time(timing.x, timing, side) - .18) < .000001,
				"gameplay active boundary equals visual contact: " + side)
			check(absf(character.attack_clip_time(timing.x + timing.y, timing, side) - .30) < .000001,
				"active end remaps for player and clone")
			for fps in [30, 60, 120]:
				character.reset_motion()
				var context := {"grounded": true, "distance": 0.0, "attack_timing": timing}
				character.update_motion(0, Vector3.ZERO, "attack", 0, side, context)
				var time := 0.0
				while time < timing.x - .00001:
					var delta := minf(1.0 / fps, timing.x - time)
					time += delta
					character.update_motion(delta, Vector3.ZERO, "attack", time, side, context)
				var target := Vector3(.045, 1.305, .638) if side == "L" else Vector3(-.035, 1.305, .677)
				check(joint(character, "hand." + side).distance_to(target) < .0001,
					"no low-pass delay at impact, %d FPS, %s" % [fps, side])


func _test_distance_and_air(character: Node3D) -> void:
	character.reset_motion()
	var walk_stride := float(Character.MOTIONS.get_animation("walk").get_meta("stride"))
	for i in 100:
		character.update_motion(.01, Vector3(0, 0, T.WALK_SPEED), "", 0, "R",
			{"grounded": true, "distance": walk_stride / 100})
	check(absf(wrapf(character._phase + .5, 0, 1) - .5) < .00001, "one cycle per authored walking stride")
	var before: float = character._phase
	for i in 40:
		character.update_motion(1.0 / 60, Vector3(0, 0, 4.6), "", 0, "R",
			{"grounded": true, "distance": 0.0})
	check(absf(character._phase - before) < .000001, "blocked displacement does not advance gait")
	character.reset_motion()
	character.update_motion(.016, Vector3.ZERO, "", 0, "R", {"grounded": false, "vertical_speed": 7.0})
	check(character._state == "air", "take-off is detected from post-physics floor state")
	for i in 15:
		character.update_motion(.016, Vector3.ZERO, "", 0, "R", {"grounded": false, "vertical_speed": 2.0})
	check(joint(character, "hand.R").z > .15, "jump arms remain in front")
	character.update_motion(.05, Vector3.ZERO, "", 0, "R", {"grounded": false, "vertical_speed": -5.0})
	character.update_motion(.016, Vector3.ZERO, "", 0, "R", {"grounded": true})
	character.update_motion(.08, Vector3.ZERO, "", 0, "R", {"grounded": true})
	check(character._state == "land", "landing state occurs once after flight")
	check(character.skeleton.get_bone_pose_position(character.skeleton.find_bone("hips")).y < .80,
		"landing absorbs impact through the hips/knees")
	var leg_before: Quaternion = character.skeleton.get_bone_pose_rotation(character.skeleton.find_bone("thigh.L"))
	character.play_hit()
	character._hit_time = .055
	var hit_pose: Dictionary = character._add_hit(character._last_pose, 1.0)
	var leg_after: Quaternion = hit_pose["rotations"][character.skeleton.find_bone("thigh.L")]
	check(absf(leg_before.dot(leg_after)) > .999999, "additive hit reaction does not replace the legs")


func _test_locomotion_posture(character: Node3D) -> void:
	# Exercise the actual sampler/blender too, including the clone's 3.4 m/s
	# walk/run mix. Raising the Character node cannot satisfy these bone checks.
	for speed in [T.WALK_SPEED, T.CLONE_RUN, T.RUN_SPEED]:
		character.reset_motion()
		var context := {"grounded": true, "distance": speed / 60.0}
		for i in 60:
			character.update_motion(1.0 / 60, Vector3(0, 0, speed), "", 0, "R", context)
		var min_hip := INF
		var hip_sum := 0.0
		for i in 180:
			character.update_motion(1.0 / 60, Vector3(0, 0, speed), "", 0, "R", context)
			var height := joint(character, "hips").y
			min_hip = minf(min_hip, height)
			hip_sum += height
		check(min_hip > .80, "no crouched locomotion floor at %.2f m/s" % speed)
		check(hip_sum / 180 > .845, "upright average pelvis in runtime blend at %.2f m/s" % speed)


func knee_bend(character: Node3D, side: String) -> float:
	var thigh := joint(character, "thigh." + side)
	var shin := joint(character, "shin." + side)
	var foot := joint(character, "foot." + side)
	return rad_to_deg((shin - thigh).angle_to(foot - shin))


func _test_air_progress(character: Node3D) -> void:
	var launch := sqrt(2.0 * T.GRAVITY * T.JUMP_HEIGHT)
	for fps in [30, 60, 120]:
		character.reset_motion()
		character.update_motion(0, Vector3.ZERO, "", 0, "R",
			{"grounded": false, "vertical_speed": launch, "jump_started": true})
		var previous := joint(character, "foot.L")
		var max_step := 0.0
		var time := 0.0
		while time < launch / T.GRAVITY:
			var dt := minf(1.0 / fps, launch / T.GRAVITY - time)
			time += dt
			character.update_motion(dt, Vector3.ZERO, "", 0, "R",
				{"grounded": false, "vertical_speed": maxf(0, launch - T.GRAVITY*time)})
			var foot := joint(character, "foot.L")
			max_step = maxf(max_step, foot.distance_to(previous))
			previous = foot
		check(max_step < .075, "no frozen-pose switch during ascent at %d FPS" % fps)
		check(joint(character, "foot.L").y > .30, "legs fold by the apex at %d FPS" % fps)
		for i in fps / 3:
			var vertical: float = -T.GRAVITY_FALL * (i + 1.0) / fps
			character.update_motion(1.0 / fps, Vector3.ZERO, "", 0, "R",
				{"grounded": false, "vertical_speed": vertical})
		check(joint(character, "foot.L").y < .09 and knee_bend(character, "L") < 25,
			"legs extend before impact at %d FPS" % fps)

	character.reset_motion()
	character.update_motion(.016, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "vertical_speed": -.3})
	check(not character._air_launched, "stepping off a ledge does not play take-off")
	character.update_motion(.10, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "vertical_speed": -1.0})
	check(joint(character, "foot.L").y < .15, "ledge fall starts in a braced pose, not an apex tuck")
	character.update_motion(.016, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "vertical_speed": launch, "jump_started": true})
	check(character._air_launched and character._air_time == 0.0,
		"coyote jump restarts take-off even when already airborne")
	character._air_time = 1.0
	character._apply_pose(character._air_pose({"vertical_speed": -1.0, "floor_distance": .01}))
	check(joint(character, "foot.L").y < .10, "nearby raised floor prepares feet before early contact")
	character.reset_motion()
	check(not character._air_launched, "reset clears jump flight history")


func _test_stance_blending(character: Node3D) -> void:
	character.reset_motion(false)
	check(joint(character, "hand.L").y < .95 and joint(character, "hips").y > .89,
		"ordinary idle starts upright with lowered arms")
	var stride := float(Character.MOTIONS.get_animation("walk_relaxed").get_meta("stride"))
	for i in 100:
		character.update_motion(.01, Vector3(0, 0, T.WALK_SPEED), "", 0, "R",
			{"grounded": true, "combat": false, "distance": stride/100})
	check(absf(wrapf(character._phase + .5, 0, 1) - .5) < .00001,
		"ordinary walking also advances one cycle per real stride")
	for fps in [30, 60, 120]:
		character.reset_motion(false)
		var dt: float = 1.0/fps
		for i in fps:
			character.update_motion(dt, Vector3(0, 0, T.WALK_SPEED), "", 0, "R",
				{"grounded": true, "combat": false, "distance": T.WALK_SPEED*dt})
		var phase: float = character._phase
		character.update_motion(0, Vector3.ZERO, "", 0, "R",
			{"grounded": true, "combat": true, "distance": 0.0})
		check(character._phase == phase, "switching stance does not reset foot phase at %d FPS" % fps)
		var previous := joint(character, "hand.L")
		var max_step := 0.0
		for i in fps/2:
			character.update_motion(dt, Vector3(0, 0, T.WALK_SPEED), "", 0, "R",
				{"grounded": true, "combat": true, "distance": T.WALK_SPEED*dt})
			max_step = maxf(max_step, previous.distance_to(joint(character, "hand.L")))
			previous = joint(character, "hand.L")
		check(max_step < .15, "no arm teleport while entering guard at %d FPS" % fps)
		check(character._combat_blend == 1.0 and joint(character, "hand.L").y > 1.1,
			"combat walking retains its guard at %d FPS" % fps)
		for i in fps/2:
			character.update_motion(dt, Vector3(0, 0, T.WALK_SPEED), "", 0, "R",
				{"grounded": true, "combat": false, "distance": T.WALK_SPEED*dt})
		check(character._combat_blend == 0.0 and joint(character, "hand.L").y < .95,
			"leaving combat restores a real ordinary walk at %d FPS" % fps)
		check(joint(character, "hips").y > .85, "ordinary runtime walking is upright")
		phase = character._phase
		for i in 20:
			character.update_motion(dt, Vector3.ZERO, "", 0, "R",
				{"grounded": true, "combat": false, "distance": 0.0})
		check(character._phase == phase, "ordinary gait also stops at a wall")


func _test_relaxed_jump(character: Node3D) -> void:
	character.reset_motion(false)
	var wrist := joint(character, "hand.L")
	var launch := sqrt(2.0*T.GRAVITY*T.JUMP_HEIGHT)
	character.update_motion(0, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "combat": false, "vertical_speed": launch, "jump_started": true})
	check(joint(character, "hand.L").distance_to(wrist) < .00001,
		"ordinary take-off does not insert a combat-guard frame")
	character.update_motion(.10, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "combat": false, "vertical_speed": launch - T.GRAVITY*.10})
	check(knee_bend(character, "L") < 30, "ordinary jump joins the accepted extension phase")
	character.update_motion(.25, Vector3.ZERO, "", 0, "R",
		{"grounded": false, "combat": false, "vertical_speed": -5.0})
	character.update_motion(.016, Vector3.ZERO, "", 0, "R", {"grounded": true, "combat": false})
	character.update_motion(.075, Vector3.ZERO, "", 0, "R", {"grounded": true, "combat": false})
	check(joint(character, "hips").y < .80, "ordinary landing still absorbs the impact")
	for i in 24:
		character.update_motion(1.0/60, Vector3.ZERO, "", 0, "R", {"grounded": true, "combat": false})
	check(character._state == "ground" and joint(character, "hand.L").y < .95,
		"ordinary landing recovers to relaxed idle, not guard")
	character.reset_motion(false)
	check(character._takeoff_pose.is_empty() and not character._air_from_relaxed,
		"reset clears the captured launch pose too")


func _test_player_modes() -> void:
	var player := PlayerScene.instantiate()
	player.set_physics_process(false)
	world.add_child(player)
	var clone := CloneScene.instantiate()
	clone.set_physics_process(false)
	world.add_child(clone)
	check(not player.combat_mode and joint(player.character, "hand.L").y < .95,
		"a fresh player actually starts in ordinary mode")
	check(InputMap.action_get_events("toggle_stance")[0].physical_keycode == KEY_R,
		"R is a physical-key binding for player stance")
	check(InputMap.action_get_events("toggle_clone")[0].physical_keycode == KEY_T,
		"T remains the separate clone-combat binding")
	var toggle := InputEventAction.new()
	toggle.action = "toggle_stance"
	toggle.pressed = true
	player.velocity = Vector3(1.0, 2.0, 3.0)
	player.character._phase = .37
	var stamina: float = player.stamina
	player._unhandled_input(toggle)
	check(player.combat_mode and clone.mode == clone.Mode.OFF, "R changes the player, not the clone")
	check(player.velocity == Vector3(1.0, 2.0, 3.0) and player.stamina == stamina
		and player.character._phase == .37, "stance changes do not alter physics/stamina/foot phase")
	player._unhandled_input(toggle)
	check(not player.combat_mode, "R can also leave combat")
	player._start_attack()
	check(player.combat_mode and player._action == "attack" and player._action_time == 0.0,
		"a punch enters combat immediately, without a new input delay")
	player._action_time = .13
	player._unhandled_input(toggle)
	check(not player.combat_mode and player._action == "attack" and player._action_time == .13,
		"R cannot cancel an ongoing punch or change its clock")
	player._action = ""
	player.take_damage(1, Vector3.FORWARD)
	check(player.combat_mode, "a received hit enters combat")
	player.combat_mode = false
	player._invulnerable = true
	player.take_damage(1, Vector3.FORWARD)
	check(not player.combat_mode, "an evaded hit does not force a stance change")
	player._invulnerable = false
	player.take_damage(T.MAX_HEALTH + 1, Vector3.FORWARD)
	check(not player.combat_mode and player.character._combat_blend == 0.0,
		"respawn clears combat stance and its visual blend")

	# Exercise the real pause-menu -> main handler -> player/clone wiring.
	var main := Node3D.new()
	main.set_script(load("res://scripts/main.gd"))
	main.player = player
	main.clone = clone
	var menu := (load("res://scenes/pause_menu.tscn") as PackedScene).instantiate()
	world.add_child(menu)
	menu.action.connect(main._on_menu_action)
	check(menu._items["stance"]["button"].text.contains("обычный"), "menu reads the current player stance")
	menu._activate("stance")
	check(player.combat_mode and menu._items["stance"]["button"].text.contains("боевой"),
		"pause menu changes stance and refreshes its live label")
	menu._activate("clone")
	check(clone.mode == clone.Mode.ON and player.combat_mode,
		"clone toggle does not overwrite the player's chosen stance")
	menu._activate("stance")
	check(not player.combat_mode and clone.mode == clone.Mode.ON, "player can relax independently of clone mode")
	menu.free()
	main.free()
	clone.free()
	player.free()


func _test_combat() -> void:
	var player := PlayerScene.instantiate()
	player.set_physics_process(false)
	world.add_child(player)
	var probe := Node3D.new()
	probe.set_script(Probe)
	probe.position = Vector3(0, 0, -.9)
	world.add_child(probe)
	probe.add_to_group("damageable")
	player._attack_side = "L"
	player._start_attack()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	player._unhandled_input(press)
	check(player._attack_side == "L", "buffering right does not swap an ongoing left punch")
	check(player._buf_secondary == 0.0, "right punch was buffered, not dropped")
	player._process_attack(.40)  # Skip over the WHOLE active window on purpose.
	player._process_attack(.05)
	check(probe.hits == 1, "crossing/skipping active window deals exactly one hit")
	check(probe.total_damage == T.ATTACK_DAMAGE, "damage matches the gameplay tuning")
	var clone := CloneScene.instantiate()
	clone.set_physics_process(false)
	clone.position = Vector3(0, 0, -.95)
	world.add_child(clone)
	clone.mode = clone.Mode.ON
	clone._attack_time = 0.0
	var health_before: float = player.health
	clone._deal_damage(.95)
	check(player.health == health_before, "a forward clone punch cannot hit behind its locked facing")
	clone.rotation.y = PI  # Player is at +Z relative to the clone.
	clone._fight(T.CLONE_WINDUP)
	check(player.health == health_before - T.CLONE_DAMAGE, "clone hit occurs at its own windup boundary")
	clone.take_damage(T.CLONE_HEALTH + 1, Vector3.FORWARD)
	check(clone._attack_time < 0 and clone.mode == clone.Mode.OFF, "respawn cannot leave clone frozen in an attack")
	clone.free()
	probe.free()
	player.free()


func _test_showcase() -> void:
	var showcase := ShowcaseScene.instantiate()
	world.add_child(showcase)
	showcase.set_process(false)
	for i in showcase.CLIPS.size():
		showcase._select_clip(i)
		var clip_name: String = showcase.CLIPS[i][0]
		var time: float = showcase.character.clip_duration(clip_name) * .43
		showcase._seek(time)
		var source: Dictionary = showcase.character.sample_clip(clip_name, time)
		var actual: Dictionary = showcase.character._last_pose
		var same := true
		for b in source["rotations"].size():
			var a: Quaternion = actual["rotations"][b]
			var expected: Quaternion = source["rotations"][b]
			same = same and absf(a.dot(expected)) > .999999
		check(same, "showcase seeks actual library keys: " + clip_name)
	showcase._step_frame(1)
	check(not showcase._playing, "frame stepping pauses playback")
	showcase.free()


func box(size: Vector3, position: Vector3) -> void:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.position = position
	body.add_child(collision)
	world.add_child(body)


func _test_actual_physics() -> void:
	box(Vector3(14, .2, 14), Vector3(0, -.1, 0))
	box(Vector3(3, 2, .2), Vector3(0, 1, -2))
	var player := PlayerScene.instantiate()
	player.position = Vector3(0, .1, 0)
	world.add_child(player)
	for i in 25:
		await physics_frame
	check(player.is_on_floor(), "real CharacterBody settles on the floor")
	Input.action_press("move_forward")
	Input.action_press("run")
	for i in 70:
		await physics_frame
	check(player.position.z < -1.4 and player.position.z > -1.7, "real movement is stopped by the test wall")
	var phase_before: float = player.character._phase
	for i in 12:
		await physics_frame
	check(absf(player.character._phase - phase_before) < .00001, "walking into a wall freezes distance phase")
	Input.action_release("move_forward")
	Input.action_release("run")
	player.position = Vector3(3, 0, 0)
	player.velocity = Vector3.ZERO
	for i in 3:
		await physics_frame
	player._jump_buffer = 0.0
	var highest := 0.0
	var saw_air := false
	var saw_land := false
	for i in 75:
		await physics_frame
		highest = maxf(highest, player.position.y)
		saw_air = saw_air or player.character._state == "air"
		saw_land = saw_land or player.character._state == "land"
	check(highest > 1.0, "jump physics still reaches its intended height")
	check(saw_air and saw_land and player.is_on_floor(), "real jump passes through air and landing states")
	player._buf_dodge = 0.0
	player._buf_dir = Vector3.RIGHT
	var invulnerable_seen := false
	for i in 40:
		await physics_frame
		invulnerable_seen = invulnerable_seen or player._invulnerable
	check(invulnerable_seen and player._action == "", "dodge iframes and recovery still work")

	# A raised landing must use the player's real downward ray, not just a
	# synthetic floor_distance passed directly to the sampler above.
	box(Vector3(3, .6, 3), Vector3(5, .3, 3))
	player.position = Vector3(2.8, 0, 3)
	player.velocity = Vector3.ZERO
	for i in 5:
		await physics_frame
	Input.action_press("move_right")
	Input.action_press("run")
	player._jump_buffer = 0.0
	var braced_early := false
	var landed_high := false
	for i in 65:
		await physics_frame
		if not player.is_on_floor() and player.velocity.y < -1.0 \
				and player.position.y < .83 and player.position.x > 3.6:
			braced_early = braced_early or knee_bend(player.character, "L") < 35
		landed_high = landed_high or (player.is_on_floor() and player.position.y > .55)
	Input.action_release("move_right")
	Input.action_release("run")
	check(braced_early, "real floor-distance ray unfolds legs for early platform contact")
	check(landed_high, "real running jump lands on a raised platform")
	player.free()
