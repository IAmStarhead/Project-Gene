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
	_test_grounded_attack_pose(character)
	_test_distance_and_air(character)
	_test_locomotion_posture(character)
	_test_air_progress(character)
	_test_stance_blending(character)
	_test_three_tiers(character)
	_test_ordinary_arm_carriage(character)
	_test_native_blended_soles(character)
	_test_relaxed_jump(character)
	_test_directional_dodge(character)
	_test_appearance(character)
	_test_rounded_material_hem(character)
	_test_garment_surface(character)
	_test_player_modes()
	_test_combat()
	await _test_showcase()
	character.free()
	await _test_actual_physics()
	await _test_modifier_and_dodge_physics()
	world.free()
	print("GEN native animation suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _test_native_tracks(character: Node3D) -> void:
	var mirror: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/heroine/animations/motion_set.json"))
	check(Character.MOTIONS.get_animation_list().size() == 39, "all 18 legacy + 12 directional + Q hook + 8 reaction native clips loaded")
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
				var target := Vector3(.045, 1.305, .67039497) if side == "L" else Vector3(-.035, 1.305, .70535173)
				check(joint(character, "hand." + side).distance_to(target) < .0001,
					"no low-pass delay at impact, %d FPS, %s" % [fps, side])


func _test_grounded_attack_pose(character: Node3D) -> void:
	# Once transition blending is finished, grounded attacks must be exactly
	# the authored clip, for player and clone timings and both hands.
	for timing in [Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY),
			Vector3(T.CLONE_WINDUP, T.CLONE_ACTIVE, T.CLONE_RECOVER)]:
		for side in ["L", "R"]:
			character.reset_motion()
			var action_time: float = timing.x + timing.y * .5
			character.update_motion(.1, Vector3(0, 0, 1.65), "attack", action_time, side,
				{"grounded": true, "combat": true, "distance": .1, "attack_timing": timing})
			var clip := "attack_left" if side == "L" else "attack_right"
			var expected: Dictionary = character.sample_clip(clip, character.attack_clip_time(action_time, timing, side))
			var difference := 0.0
			for i in character.skeleton.get_bone_count():
				var actual: Quaternion = character.skeleton.get_bone_pose_rotation(i)
				var wanted: Quaternion = expected.rotations[i]
				difference = maxf(difference, 1.0 - absf(actual.dot(wanted)))
			var hip: Vector3 = character.skeleton.get_bone_pose_position(character.skeleton.find_bone("hips"))
			check(difference < .000002 and hip.distance_to(expected.hips) < .000002,
				"grounded attack clip preserved for %s" % side)


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
	# A guard-relative arm delta is not valid on fully lowered relaxed arms.
	# Retain an immediate torso/head response while the stance raises the arms.
	character.reset_motion(false)
	character._hit_time = .055
	var relaxed: Dictionary = character.sample_clip("idle_relaxed", 0.0)
	var relaxed_hit: Dictionary = character._add_hit(relaxed, 1.0)
	var protected_arms := true
	for name in ["shoulder.L", "upper_arm.L", "forearm.L", "hand.L", "shoulder.R", "upper_arm.R", "forearm.R", "hand.R"]:
		var bone: int = character.skeleton.find_bone(name)
		protected_arms = protected_arms and absf(relaxed["rotations"][bone].dot(relaxed_hit["rotations"][bone])) > .999999
	check(protected_arms, "guard-relative hit arms fade with combat entry rather than folding through the waist")
	var chest: int = character.skeleton.find_bone("chest")
	check(absf(relaxed["rotations"][chest].dot(relaxed_hit["rotations"][chest])) < .9999,
		"relaxed hit still reacts immediately in the torso")
	character._combat_blend = .5
	var half_hit: Dictionary = character._add_hit(relaxed, 1.0)
	character._combat_blend = 1.0
	var full_hit: Dictionary = character._add_hit(relaxed, 1.0)
	var upper_arm: int = character.skeleton.find_bone("upper_arm.L")
	var expected: Quaternion = relaxed["rotations"][upper_arm].slerp(full_hit["rotations"][upper_arm], .5)
	check(absf(expected.dot(half_hit["rotations"][upper_arm])) > .999999,
		"combat-entry hit arms interpolate the authored guard-relative delta")


func _test_locomotion_posture(character: Node3D) -> void:
	# Exercise the actual sampler/blender too, including the clone's 3.4 m/s
	# walk/run mix. Raising the Character node cannot satisfy these bone checks.
	for speed in [T.COMBAT_WALK_SPEED, T.CLONE_RUN, T.COMBAT_RUN_SPEED]:
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


func _test_three_tiers(character: Node3D) -> void:
	for fps in [30, 60, 120]:
		var dt: float = 1.0/fps
		for entry in [[T.WALK_SPEED, "walk_relaxed", 0.0, 0.0],
				[T.JOG_SPEED, "run_relaxed", 1.0, 0.0], [T.RUN_SPEED, "sprint_relaxed", 1.0, 1.0]]:
			character.reset_motion(false)
			var speed: float = entry[0]
			var context := {"combat": false, "grounded": true, "distance": speed*dt,
				"walk_speed": T.WALK_SPEED, "jog_speed": T.JOG_SPEED, "sprint_speed": T.RUN_SPEED}
			for i in fps:
				character.update_motion(dt, Vector3(0, 0, speed), "", 0, "R", context)
			check(is_equal_approx(character._gait_blend, entry[2]) and is_equal_approx(character._sprint_blend, entry[3]),
				"player tier settles to its own clip at %d FPS: %s" % [fps, entry[1]])
			var expected: Dictionary = character.sample_clip(entry[1], character._phase*character.clip_duration(entry[1]))
			var difference: Vector3 = joint(character, "hips")-(expected["hips"] as Vector3)
			check(Vector2(difference.x, difference.z).length() < .000001 and difference.y >= -.000001 and difference.y < .003,
				"actual runtime samples its own tier with only a sub-3mm sole lift: "+entry[1])
			var phase: float = character._phase
			context["distance"] = float(Character.MOTIONS.get_animation(entry[1]).get_meta("stride"))/fps
			for i in fps:
				character.update_motion(dt, Vector3(0, 0, speed), "", 0, "R", context)
			check(absf(wrapf(character._phase-phase+.5, 0, 1)-.5) < .00001,
				"walk/jog/sprint each make one cycle per real authored stride at %d FPS" % fps)
		# Going down the speed tiers must not leave a stale sprint blend or
		# reset phase on a modifier / stance change.
		var previous := joint(character, "hand.L")
		var max_hand_step := 0.0
		for speed in [T.JOG_SPEED, T.WALK_SPEED]:
			for i in fps:
				character.update_motion(dt, Vector3(0, 0, speed), "", 0, "R",
					{"combat": false, "grounded": true, "distance": speed*dt,
					"walk_speed": T.WALK_SPEED, "jog_speed": T.JOG_SPEED, "sprint_speed": T.RUN_SPEED})
				max_hand_step = maxf(max_hand_step, joint(character, "hand.L").distance_to(previous))
				previous = joint(character, "hand.L")
		check(character._gait_blend == 0.0 and character._sprint_blend == 0.0,
			"releasing Shift and holding Alt really restores walking at %d FPS" % fps)
		check(max_hand_step < .16, "no wrist teleport across sprint/jog/walk transitions at %d FPS" % fps)
		character._sprint_blend = 1.0
		character.reset_motion(false)
		check(character._sprint_blend == 0.0, "respawn/reset clears sprint history")
	# The clone supplies no player speed context. Retain its existing
	# combat calibration instead of interpreting 3.4 m/s as a full sprint.
	character.reset_motion(true)
	for i in 60:
		character.update_motion(1.0/60, Vector3(0, 0, T.CLONE_RUN), "", 0, "R",
			{"combat": true, "grounded": true, "distance": T.CLONE_RUN/60})
	check(character._gait_blend > .5 and character._gait_blend < .9 and character._sprint_blend == 0.0,
		"clone 3.4 m/s still uses the previous combat walk/run mix, not player sprint")


func _test_ordinary_arm_carriage(character: Node3D) -> void:
	# Sample the real distance-phase runtime, not a second Euler animation.
	# Python protects accepted lower-body keys and dense skin clearance;
	# these checks catch a different pose / wrist frame reaching Godot.
	var skeleton: Skeleton3D = character.skeleton
	for speed in [T.WALK_SPEED, T.JOG_SPEED, T.RUN_SPEED]:
		character.reset_motion(false)
		var context := {"combat": false, "grounded": true, "distance": speed/60.0,
			"walk_speed": T.WALK_SPEED, "jog_speed": T.JOG_SPEED, "sprint_speed": T.RUN_SPEED}
		for i in 60:
			character.update_motion(1.0/60, Vector3(0, 0, speed), "", 0, "R", context)
		var upper_angles: Array[float] = []
		var elbow_bends: Array[float] = []
		var nearest_back := INF
		var farthest_front := -INF
		var min_palm_inward := 1.0
		var max_wrist_angle := 0.0
		var head_min := Vector3(INF, INF, INF)
		var head_max := -head_min
		for i in 144:
			character.update_motion(1.0/60, Vector3(0, 0, speed), "", 0, "R", context)
			var chest: Basis = skeleton.get_bone_global_pose(skeleton.find_bone("chest")).basis.orthonormalized()
			var head: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("head")).basis.get_euler()
			head_min = head_min.min(head)
			head_max = head_max.max(head)
			for side in ["L", "R"]:
				var sign_side := 1.0 if side == "L" else -1.0
				var shoulder := joint(character, "upper_arm."+side)
				var elbow := joint(character, "forearm."+side)
				var wrist := joint(character, "hand."+side)
				var upper := elbow-shoulder
				upper_angles.append(atan2(upper.z, -upper.y))
				elbow_bends.append(upper.angle_to(wrist-elbow))
				nearest_back = minf(nearest_back, (wrist-shoulder).z)
				farthest_front = maxf(farthest_front, (wrist-shoulder).z)
				var hand: Basis = skeleton.get_bone_global_pose(skeleton.find_bone("hand."+side)).basis.orthonormalized()
				var fore: Basis = skeleton.get_bone_global_pose(skeleton.find_bone("forearm."+side)).basis.orthonormalized()
				min_palm_inward = minf(min_palm_inward, (sign_side*hand.x).dot(-sign_side*chest.x))
				max_wrist_angle = maxf(max_wrist_angle, fore.get_rotation_quaternion().angle_to(hand.get_rotation_quaternion()))
		var mean_upper := 0.0
		var mean_bend := 0.0
		for i in upper_angles.size():
			mean_upper += upper_angles[i]/upper_angles.size()
			mean_bend += elbow_bends[i]/elbow_bends.size()
		var covariance := 0.0
		var upper_variance := 0.0
		var bend_variance := 0.0
		for i in upper_angles.size():
			var u := upper_angles[i]-mean_upper
			var b := elbow_bends[i]-mean_bend
			covariance += u*b
			upper_variance += u*u
			bend_variance += b*b
		var correlation := covariance/sqrt(maxf(upper_variance*bend_variance, .000000001))
		check(correlation > .8, "native elbows flex with the front swing at %.2f m/s" % speed)
		check(min_palm_inward > .92, "actual GLB palm +/-X stays neutral, not a 90-degree axis mixup")
		check(rad_to_deg(max_wrist_angle) < 2, "forearm carries twist without a wrist-only kink")
		check(farthest_front < .32, "native wrist does not stay stretched far in front of the body")
		check(nearest_back < (.025 if speed == T.JOG_SPEED else -.045),
			"native hand returns towards/past its shoulder rather than sawing in front")
		check(head_max.y-head_min.y > deg_to_rad(1.8) and maxf(absf(head_max.y), absf(head_min.y)) < deg_to_rad(2.2),
			"head has a quiet response, not a world-space lock or a large look-away")
		check(head_max.x-head_min.x > deg_to_rad(1.8) and head_max.x < deg_to_rad(6),
			"native head nod remains small but alive")


func _test_native_blended_soles(character: Node3D) -> void:
	# Use ALL low-foot vertices and weights in the ACTUAL post-import body,
	# not merely the reduced runtime probes or the authoring ankle targets.
	var body: MeshInstance3D = character.appearance.body
	var arrays: Array = body.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var feet: Array[int] = []
	for i in points.size():
		if points[i].y < .09:
			feet.append(i)
	var minimum := INF
	var overestimate := 0.0
	character.reset_motion(false)
	for speed in [T.WALK_SPEED, T.JOG_SPEED, T.RUN_SPEED, T.WALK_SPEED]:
		for step in 36:
			character.update_motion(1.0/60, Vector3(0, 0, speed), "", 0, "R",
				{"combat": false, "grounded": true, "distance": speed/60,
				"walk_speed": T.WALK_SPEED, "jog_speed": T.JOG_SPEED, "sprint_speed": T.RUN_SPEED})
			if step % 3 != 0:
				continue
			var transforms: Array[Transform3D] = []
			var to_character: Transform3D = character.global_transform.affine_inverse()*character.skeleton.global_transform
			for i in body.skin.get_bind_count():
				var bone: int = character.skeleton.find_bone(body.skin.get_bind_name(i))
				transforms.append(to_character*character.skeleton.get_bone_global_pose(bone)*body.skin.get_bind_pose(i))
			var floor_y := INF
			for i in feet:
				var y := 0.0
				for k in 4:
					y += weights[i*4+k]*(transforms[bones[i*4+k]]*points[i]).y
				floor_y = minf(floor_y, y)
			minimum = minf(minimum, floor_y)
			overestimate = maxf(overestimate, character.appearance.sole_height()-floor_y)
	check(feet.size() > 2000, "native sole test uses the real dense soft-skinned feet")
	check(minimum > -.001, "walk/jog/sprint and their transitions keep the imported skin above the floor")
	check(overestimate < .001, "small runtime support set agrees with the full native sole")
	print("Native soft soles: %d vertices, 48 blended poses; minimum %.3f mm; support-set error %.3f mm" % [
		feet.size(), minimum*1000, overestimate*1000])


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


func _test_directional_dodge(character: Node3D) -> void:
	for entry in [[Vector3(0, 0, 1), "dodge"], [Vector3(0, 0, -1), "dodge_back"],
			[Vector3(1, 0, 0), "dodge_left"], [Vector3(-1, 0, 0), "dodge_right"]]:
		var pose: Dictionary = character.sample_dodge(.18, entry[0])
		var expected: Dictionary = character.sample_clip(entry[1], .18)
		var identical := true
		for b in pose["rotations"].size():
			identical = identical and absf((pose["rotations"][b] as Quaternion).dot(expected["rotations"][b])) > .999999
		check(identical, "direction chooses its own native dodge: "+entry[1])
	for name in ["dodge", "dodge_back", "dodge_left", "dodge_right"]:
		var minimum_distance := INF
		var minimum_front := INF
		var maximum_fold := 0.0
		for i in 61:
			character.seek_clip(name, .48*i/60)
			var chest: Transform3D = character.skeleton.get_bone_global_pose(character.skeleton.find_bone("chest"))
			for side in ["L", "R"]:
				var shoulder := joint(character, "upper_arm."+side)
				var elbow := joint(character, "forearm."+side)
				var wrist := joint(character, "hand."+side)
				var hand: Transform3D = character.skeleton.get_bone_global_pose(character.skeleton.find_bone("hand."+side))
				minimum_distance = minf(minimum_distance, shoulder.distance_to(wrist))
				maximum_fold = maxf(maximum_fold, rad_to_deg((elbow-shoulder).angle_to(wrist-elbow)))
				minimum_front = minf(minimum_front, (chest.affine_inverse()*(hand*Vector3(0, .075, 0))).z)
		check(minimum_distance > .185 and maximum_fold < 140, "native dodge elbow no longer folds its fist into its shoulder: "+name)
		check(minimum_front > .18, "native dodge fists stay in front of the moving chest: "+name)
	var diagonal: Dictionary = character.sample_dodge(.18, Vector3(1, 0, -1).normalized())
	var expected_diagonal: Dictionary = character._blend_pose(character.sample_clip("dodge_back", .18),
		character.sample_clip("dodge_left", .18), .5)
	check((diagonal["hips"] as Vector3).distance_to(expected_diagonal["hips"]) < .000001,
		"diagonals blend the adjacent directional clips, not facing rotation")
	var player := PlayerScene.instantiate()
	player.set_physics_process(false)
	world.add_child(player)
	for direction in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1),
			Vector3(0, 0, -1), Vector3(1, 0, -1).normalized()]:
		player.rotation.y = .71
		player._buf_dir = player.character.global_basis*direction
		var facing: Basis = player.global_basis
		player._start_dodge()
		check(player.global_basis.is_equal_approx(facing), "starting a dodge preserves body facing")
		check(player._dodge_local_dir.distance_to(direction) < .00001, "world input becomes correct model-local dodge")
		player._process_dodge(.10)
		var travel := Vector3(player.velocity.x, 0, player.velocity.z).normalized()
		check(travel.distance_to((player.character.global_basis*direction).normalized()) < .00001,
			"actual dodge velocity follows requested travel independently of facing")
	player._buf_dir = Vector3.ZERO
	player._start_dodge()
	check(player._dodge_local_dir.z < -.999, "no-input dodge moves back relative to the body, not the camera")
	player.rotation = Vector3.ZERO
	player._buf_dodge = 0.0
	Input.action_press("move_left")
	player._process_move(1.0/60)
	Input.action_release("move_left")
	check(absf(player.rotation.y) < .00001, "ordinary move cannot turn the body on the buffered dodge's first frame")
	player.free()


func cloth_rings_ordered(appearance: Node3D) -> bool:
	# Report 40: fixed Y was the cause of the boxy knee. Test real material
	# order and winding instead: lifted rows must still descend, never wrap.
	for row in appearance._rings:
		for k in appearance._segments:
			var i: int = row*appearance._segments+k
			var point: Vector3 = appearance._hips_inverse*appearance._points[i]
			var next: Vector3 = appearance._hips_inverse*appearance._points[row*appearance._segments+(k+1)%appearance._segments]
			var angle:=fposmod(atan2(next.x,next.z-.02)-atan2(point.x,point.z-.02),TAU)
			if angle <= 0.0 or angle > PI*.25: return false
			if row > 0:
				var above: Vector3 = appearance._hips_inverse*appearance._points[i-appearance._segments]
				if point.y >= above.y-.000001: return false
	return true


func cloth_strain(appearance: Node3D) -> Vector2:
	var result := Vector2.ZERO  # complete meridian, ring circumference
	for k in appearance._segments:
		var length := 0.0
		for row in range(1, appearance._rings):
			var i: int = row*appearance._segments+k
			length += (appearance._points[i] as Vector3).distance_to(appearance._points[i-appearance._segments])
		result.x = maxf(result.x, length/appearance._meridian_lengths[(appearance._rings-1)*appearance._segments+k])
	for row in appearance._rings:
		var perimeter := 0.0
		for k in appearance._segments:
			perimeter += (appearance._points[row*appearance._segments+k] as Vector3).distance_to(appearance._points[row*appearance._segments+(k+1)%appearance._segments])
		result.y = maxf(result.y, perimeter/appearance._circumferences[row])
	return result


func cloth_local_strain(appearance: Node3D) -> Vector2:
	var result := Vector2.ZERO  # individual meridian / circumferential edges
	for row in appearance._rings:
		for k in appearance._segments:
			var i: int = row*appearance._segments+k
			var next: int = row*appearance._segments+(k+1)%appearance._segments
			result.y = maxf(result.y, (appearance._points[i] as Vector3).distance_to(appearance._points[next])/
				(appearance._rest[i] as Vector3).distance_to(appearance._rest[next]))
			if row > 0:
				var above: int = i-appearance._segments
				result.x = maxf(result.x, (appearance._points[i] as Vector3).distance_to(appearance._points[above])/
					(appearance._rest[i] as Vector3).distance_to(appearance._rest[above]))
	return result


func _test_appearance(character: Node3D) -> void:
	var appearance: Node3D = character.appearance
	check(appearance != null and appearance.gown != null and appearance.skirt != null,
		"heroine has a real bodice and simulated skirt")
	check(appearance.gown.get_node(appearance.gown.skeleton) == character.skeleton,
		"native gown is bound to the actual imported skeleton")
	var bind_order := true
	for i in character.skeleton.get_bone_count():
		bind_order = bind_order and appearance.gown.skin.get_bind_name(i) == character.skeleton.get_bone_name(i)
	check(bind_order, "garment joint indices use the original named Skin binds")
	check(appearance._data["gown"]["cuff_edges"].size() > 60
		and appearance._data["gown"]["positions"].size() > 3000,
		"native tailored shoulders/axilla and cuffs use continuous body-derived topology")
	for side in ["L", "R"]:
		var sleeve: Dictionary = appearance._data["coverage"]["underarm_cores"][0 if side == "L" else 1]
		var origin: Vector3 = appearance._vector(sleeve["origin"])
		var axis: Vector3 = appearance._vector(sleeve["axis"])
		var bones := PackedInt32Array([character.skeleton.find_bone("upper_arm."+side), 0, 0, 0])
		var weights := PackedFloat32Array([1, 0, 0, 0])
		check(appearance.covered(origin+axis*.04, bones, weights, 0, Array(character._bone_names)),
			"only the closed proximal axillary core is occluded: "+side)
		check(not appearance.covered(origin+axis*.13, bones, weights, 0, Array(character._bone_names)),
			"real skin continues well INSIDE the cuff, not an amputated edge: "+side)
	var gown_arrays: Array = appearance.gown.mesh.surface_get_arrays(0)
	check((gown_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 5000
		and (gown_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array)[3] != 0,
		"native bodice has real indexed triangles after JSON conversion")
	var seam_gap := 0.0
	var gown_points: PackedVector3Array = gown_arrays[Mesh.ARRAY_VERTEX]
	var gown_bones: PackedInt32Array = gown_arrays[Mesh.ARRAY_BONES]
	for pose_name in ["idle_relaxed", "walk_relaxed", "run_relaxed", "sprint_relaxed", "dodge_left", "guard"]:
		character.seek_clip(pose_name, character.clip_duration(pose_name)*.43)
		var cloth: PackedVector3Array = appearance.cloth_vertices()
		for i in int(appearance._data["gown"]["waist_vertices"]):
			var at: float = appearance._data["gown"]["waist_cloth_samples"][i]
			var lo := floori(at)
			var pinned := cloth[lo].lerp(cloth[(lo+1)%appearance._segments], at-lo)
			var bind := gown_bones[i*4]
			var bone: int = character.skeleton.find_bone(appearance.gown.skin.get_bind_name(bind))
			var skin_pose: Transform3D = character.skeleton.get_bone_global_pose(bone)*appearance.gown.skin.get_bind_pose(bind)
			var native: Vector3 = character.global_transform.affine_inverse()*character.skeleton.global_transform*(skin_pose*gown_points[i])
			seam_gap = maxf(seam_gap, native.distance_to(pinned))
	check(seam_gap < .00001, "native Skin and pinned cloth have a shared waist seam without overlapping surfaces")
	check(appearance.body.mesh.get_blend_shape_count() == 1
		and appearance.body.mesh.get_meta("hand_vertices") >= 3400,
		"post-import mesh contains the existing fingers' real relaxed shape")
	character.reset_motion(false)
	check(appearance.hand_open == 1.0 and appearance.body.get_blend_shape_value(0) == 1.0,
		"ordinary idle actually opens the mesh, not just the wrist bones")
	character.reset_motion(true)
	check(appearance.hand_open == 0.0 and appearance.body.get_blend_shape_value(0) == 0.0,
		"combat keeps the exact original baked fists")
	check(appearance.gown.has_meta("textile") and appearance.skirt.has_meta("textile"),
		"toon sweep identifies clothing as textile, not untextured skin")
	var clone := CloneScene.instantiate()
	clone.set_physics_process(false)
	clone.position.x = 3.0
	world.add_child(clone)
	var clone_appearance: Node3D = clone.character.appearance
	check(clone_appearance.gown.mesh == appearance.gown.mesh,
		"clone uses the same generated garment mesh")
	check(clone_appearance.clone_variant and clone_appearance.gown.material_override != appearance.gown.material_override,
		"clone has its own cool-tinted fabric material")
	check(clone_appearance._points != appearance._points, "actors do not share cloth particle state")
	var worst_gap := INF
	var finite := true
	var worst_secondary := 0.0
	var worst_strain := Vector2.ZERO
	var worst_local_strain := Vector2.ZERO
	var ordered := true
	for fps in [30, 60, 120]:
		character.reset_motion(false)
		var dt: float = 1.0/fps
		for i in fps*2:
			character.position.z += T.RUN_SPEED*dt
			character.update_motion(dt, Vector3(0, 0, T.RUN_SPEED), "", 0, "L",
				{"combat": false, "grounded": true, "distance": T.RUN_SPEED*dt})
			worst_gap = minf(worst_gap, appearance.collision_gap())
			ordered = ordered and cloth_rings_ordered(appearance)
			worst_strain = worst_strain.max(cloth_strain(appearance))
			worst_local_strain = worst_local_strain.max(cloth_local_strain(appearance))
			for k in appearance._points.size():
				finite = finite and (appearance._points[k] as Vector3).is_finite()
				worst_secondary = maxf(worst_secondary, (appearance._points[k] as Vector3).distance_to(appearance._goals[k]))
		check(appearance.hand_open == 1.0, "running hands remain relaxed at %d FPS" % fps)
		character.update_motion(.10, Vector3.ZERO, "attack", .10, "L", {"combat": false})
		check(appearance.body.get_blend_shape_value(0) == 0.0,
			"even an ordinary-mode punch closes the actual fingers before contact")
	for fps in [30, 60, 120]:
		for direction in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0)]:
			character.reset_motion(true)
			for i in ceili(T.DODGE_DURATION*fps):
				character.update_motion(1.0/fps, Vector3.ZERO, "dodge", minf(T.DODGE_DURATION, (i+1.0)/fps), "R",
					{"combat": true, "grounded": true, "dodge_direction": direction, "distance": 0.0})
				worst_gap = minf(worst_gap, appearance.collision_gap())
				ordered = ordered and cloth_rings_ordered(appearance)
				worst_strain = worst_strain.max(cloth_strain(appearance))
				worst_local_strain = worst_local_strain.max(cloth_local_strain(appearance))
	check(ordered, "sprint and all four dodges cannot invert or twist the skirt rings at 30/60/120 FPS")
	check(finite and appearance.cloth_vertices().size() == 320, "cloth remains finite at 30/60/120 FPS")
	check(worst_gap > -.00001, "free cloth points stay outside the analytic leg collision envelopes")
	check(worst_secondary < .01201, "coherent secondary motion stays within 1.2 cm AFTER collision, including sprint knees")
	check(worst_strain.x < 1.04, "material-length drape cannot double the meridians over a knee (4% maximum)")
	check(worst_strain.y < 1.90, "soft perimeter control reduces the former 2.49x lateral skirt stretch below 1.90x")
	check(worst_local_strain.x < 1.25, "individual meridian edges cannot hide stretching in a safe total length")
	check(worst_local_strain.y < 2.50, "material redistribution removes the former 5.88x local lateral triangle stretch")
	print("Cloth LOCAL meridian/circumferential edge max ratio: %.4f / %.4f" % [worst_local_strain.x, worst_local_strain.y])
	print("Cloth material length/perimeter max ratio: %.4f / %.4f (not inextensible woven cloth)" % [worst_strain.x,worst_strain.y])
	for clip_name in ["dodge_back", "dodge_left", "dodge_right"]:
		character.seek_clip(clip_name,.24)
		var lift := 0.0
		for k in appearance._segments:
			var i: int = (appearance._rings-1)*appearance._segments+k
			lift = maxf(lift,(appearance._goal_local[i] as Vector3).y-(appearance._rest[i] as Vector3).y)
		check(lift > .08,"report 40: knee support raises the material hem instead of inflating fixed Y rows: "+clip_name)
	check(appearance.collision_count > 0, "body collision is actually exercised, not just declared")
	character.position = Vector3(10, 0, -10)
	character.update_motion(.016, Vector3.ZERO, "", 0, "R", {"combat": false})
	var after_teleport := 0.0
	for i in appearance._points.size():
		after_teleport = maxf(after_teleport, (appearance._points[i] as Vector3).distance_to(appearance._goals[i]))
	check(after_teleport < .10, "teleport resets cloth instead of dragging it across the room")
	print("Clothing: 320 surface nodes; actual imported hand matches %d; sampled capsule gap %.6f m; secondary max %.3f m" % [
		appearance.body.mesh.get_meta("hand_vertices"), worst_gap, worst_secondary])
	clone.free()
	character.position = Vector3.ZERO
	character.reset_motion(false)


func _test_rounded_material_hem(character: Node3D) -> void:
	var app: Node3D = character.appearance
	# Same 32-point material boundary, exact seeks and local coordinates as
	# 9fecef0, NOT subdivided render vertices or a different metric. These
	# are geometric second differences in metres, not physical cloth stress.
	for item in [["dodge_back", .24, .04859], ["dodge_left", .24, .03818],
			["dodge_right", .24, .05541], ["sprint_relaxed", .31, .03439]]:
		character.seek_clip(item[0], item[1])
		var maximum := 0.0
		var base: int = (app._rings-1)*app._segments
		for k in app._segments:
			var p: Vector3 = app._goal_local[base+k]
			var before: Vector3 = app._goal_local[base+(k+app._segments-1)%app._segments]
			var after: Vector3 = app._goal_local[base+(k+1)%app._segments]
			maximum = maxf(maximum, (before+after-p*2).length())
		check(maximum < float(item[2])*.95,
			"same-grid hem fillet improves the frozen pre-fillet curvature, not just tessellation: "+item[0])
		print("Hem second difference %s @ %.3f: %.3f mm" % [item[0], item[1], maximum*1000])
	# Regression found during development: after a normal fillet a positive
	# radial drift can RE-ENTER a bent calf. Keep one bounded amplitude for
	# the entire material meridian; do not fix independent points afterwards.
	character.position = Vector3.ZERO
	character.reset_motion(false)
	for i in 12:
		character.position.z += T.RUN_SPEED/60.0
		character.update_motion(1.0/60.0, Vector3(0,0,T.RUN_SPEED), "", 0, "L",
			{"combat":false, "grounded":true, "distance":T.RUN_SPEED/60.0})
	var limited := false
	var clear := true
	for k in app._segments:
		var amount: float = app._safe_secondary(k, .012)
		limited = limited or amount < .0119
		clear = clear and amount >= 0 and amount <= .012 and app._secondary_clear(k, amount)
	check(limited and clear, "bent-calf regression exercises the coherent collision-limited secondary amplitude")
	check(app.collision_gap() > -.00001, "limited secondary drift cannot re-enter the current calf envelope")
	character.position = Vector3.ZERO
	character.reset_motion(false)


func _test_garment_surface(character: Node3D) -> void:
	var app: Node3D = character.appearance
	var body: MeshInstance3D = app.body
	var arrays: Array = body.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var body_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var visible: Dictionary = {}
	for i in body_indices:
		visible[i] = true
	var probes: Array[int] = []
	for i in points.size():
		if points[i].y > .77 or not visible.has(i):
			continue
		var largest := 0.0
		var name := ""
		for k in 4:
			if weights[i*4+k] > largest:
				largest = weights[i*4+k]
				name = str(body.skin.get_bind_name(bones[i*4+k]))
		if name.begins_with("thigh.") or name.begins_with("shin."):
			probes.append(i)
	var worst := INF
	var sampled := 0
	for entry in [["sprint_relaxed", .136], ["sprint_relaxed", .44], ["dodge", .166],
			["dodge_left", .166], ["dodge_back", .232]]:
		character.seek_clip(entry[0], entry[1])
		var transforms: Array[Transform3D] = []
		for i in body.skin.get_bind_count():
			var bone: int = character.skeleton.find_bone(body.skin.get_bind_name(i))
			transforms.append(app._hips_inverse*character.skeleton.global_transform*character.skeleton.get_bone_global_pose(bone)*body.skin.get_bind_pose(i))
		var cloth := PackedVector3Array()
		for point in app._points:
			cloth.append(app._hips_inverse*point)
		for i in probes:
			var point := Vector3.ZERO
			for k in 4:
				point += weights[i*4+k]*(transforms[bones[i*4+k]]*points[i])
			if point.y <= .545 or point.y >= 1.018:
				continue
			var origin := Vector3(0, point.y, .02)
			var radial := point-origin
			var radius := radial.length()
			var hit_distance := INF
			for row in app._rings-1:
				for k in app._segments:
					var a: int = row*app._segments+k
					var b: int = row*app._segments+(k+1)%app._segments
					for face in [[a, b, a+app._segments], [b, b+app._segments, a+app._segments]]:
						var minimum:=minf(cloth[face[0]].y,minf(cloth[face[1]].y,cloth[face[2]].y))
						var maximum:=maxf(cloth[face[0]].y,maxf(cloth[face[1]].y,cloth[face[2]].y))
						if point.y < minimum-.00001 or point.y > maximum+.00001: continue
						var hit = Geometry3D.ray_intersects_triangle(origin, radial/radius, cloth[face[0]], cloth[face[1]], cloth[face[2]])
						if hit != null:
							hit_distance = minf(hit_distance, origin.distance_to(hit))
			if hit_distance < INF:
				sampled += 1
				worst = minf(worst, hit_distance-radius)
	check(probes.size() > 1000 and sampled > 1000, "native textile test skins the real dense visible thigh/knee mesh")
	check(worst > .003, "displayed TRIANGLES, not just cloth particles, cover the sprint/dodge knee")
	print("Native displayed-skirt/soft-skin radial gap: %.3f mm, %d eligible vertex/pose samples" % [worst*1000, sampled])

	# Validate the actual native upload layout, including Godot's implicit
	# tangents. The dummy renderer doesn't implement buffer readback/update;
	# inspect the exact bytes sent to the real GLES/Vulkan upload instead.
	var format: int = app.skirt.mesh.surface_get_format(0)
	check(RenderingServer.mesh_surface_get_format_vertex_stride(format, app._points.size()) == 12
		and app._normal_stride == 8, "dynamic mesh layout includes Godot's implicit tangent, not a 4-byte-only normal stream")
	check(app._vertex_bytes.size() == app._normal_offset+app._normal_stride*app._points.size()
		and (format & Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE) != 0, "one reusable dynamic surface receives a complete position/normal/tangent buffer")
	var byte_error := 0.0
	var normal_length_error := 0.0
	var normal_alignment := 1.0
	var tangent_error := 0.0
	var inverse: Transform3D = app.global_transform.affine_inverse()
	for i in app._points.size():
		var p := Vector3(app._vertex_bytes.decode_float(i*12), app._vertex_bytes.decode_float(i*12+4), app._vertex_bytes.decode_float(i*12+8))
		byte_error = maxf(byte_error, p.distance_to(app.global_transform.affine_inverse()*app._points[i]))
		var oct := Vector2(app._vertex_bytes.decode_u16(app._normal_offset+i*app._normal_stride), app._vertex_bytes.decode_u16(app._normal_offset+i*app._normal_stride+2))/65535.0
		var n := Vector3.octahedron_decode(oct)
		normal_length_error = maxf(normal_length_error, absf(n.length()-1.0))
		var row: int = i/app._segments
		var k: int = i%app._segments
		var expected: Vector3
		if row == 0:
			expected = (inverse.basis*app._hips_transform.basis*app._waist_normals[k]).normalized()
		else:
			var around: Vector3 = app._points[row*app._segments+(k+1)%app._segments]-app._points[row*app._segments+(k+app._segments-1)%app._segments]
			var vertical: Vector3 = app._points[mini(row+1, app._rings-1)*app._segments+k]-app._points[(row-1)*app._segments+k]
			expected = (inverse.basis*vertical.cross(around)).normalized()
		normal_alignment = minf(normal_alignment, n.dot(expected))
		var tangent_oct := Vector2(app._vertex_bytes.decode_u16(app._tangent_offset+i*app._normal_stride), app._vertex_bytes.decode_u16(app._tangent_offset+i*app._normal_stride+2))/65535.0
		tangent_oct.y = absf(tangent_oct.y*2.0-1.0)
		tangent_error = maxf(tangent_error, absf(n.dot(Vector3.octahedron_decode(tangent_oct))))
	check(byte_error < .000001 and normal_length_error < .00001, "native upload bytes match current cloth points and unit decoded normals")
	check(normal_alignment > .99999 and tangent_error < .0003,
		"every packed normal points outwards, the pinned seam lighting agrees, and tangents are orthogonal")
	var data_indices: Array = app._data["gown"]["indices"]
	var native_indices: PackedInt32Array = app.gown.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var winding := true
	for i in range(0, native_indices.size(), 3):
		winding = winding and native_indices[i] == int(data_indices[i]) and native_indices[i+1] == int(data_indices[i+2]) and native_indices[i+2] == int(data_indices[i+1])
	check(winding, "GLTF/Three CCW converts to Godot CW without inverting outward textile normals")
	character.reset_motion(false)


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
	var alt := InputEventKey.new()
	alt.physical_keycode = KEY_ALT
	alt.location = KEY_LOCATION_LEFT
	check(InputMap.event_is_action(alt, "walk_slow"), "Left Alt is the walking modifier")
	alt.location = KEY_LOCATION_RIGHT
	check(not InputMap.event_is_action(alt, "walk_slow"), "Right Alt / AltGr is not the Left Alt control")
	Input.action_press("move_forward")
	for combat in [false, true]:
		for entry in [[false, false, T.JOG_SPEED], [true, false, T.WALK_SPEED],
				[false, true, T.RUN_SPEED], [true, true, T.RUN_SPEED]]:
			player.combat_mode = combat
			player.velocity = Vector3.ZERO
			Input.action_release("run")
			Input.action_release("walk_slow")
			if entry[0]:
				Input.action_press("walk_slow")
			if entry[1]:
				Input.action_press("run")
			player._process_move(1.0)
			check(absf(Vector2(player.velocity.x, player.velocity.z).length()-float(entry[2])) < .00001,
				"Alt/default/Shift speeds and Shift priority are identical in either player stance")
	Input.action_release("run")
	Input.action_release("walk_slow")
	Input.action_release("move_forward")
	player.combat_mode = false
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
	showcase._select_clip(2)  # Ordinary run, with real secondary motion.
	for i in 30:
		showcase._process(1.0/60)
	showcase._toggle_play()
	var paused: PackedVector3Array = showcase.character.appearance.cloth_vertices().duplicate()
	for i in 12:
		showcase._process(1.0/60)
	check(showcase.character.appearance.cloth_vertices() == paused,
		"showcase pause freezes simulated cloth without resetting its history")
	showcase._seek(.2)
	var sought: PackedVector3Array = showcase.character.appearance.cloth_vertices().duplicate()
	showcase._seek(.5)
	showcase._seek(.2)
	check(showcase.character.appearance.cloth_vertices() == sought,
		"showcase seek resets cloth deterministically at the selected pose")
	showcase._toggle_play()
	for i in 6:
		showcase._process(1.0/60)
	check(showcase.character.appearance.cloth_vertices() != sought,
		"showcase resumes real cloth simulation after a paused seek")
	await _test_showcase_layout(showcase)
	showcase.free()


func _test_showcase_layout(showcase: Node3D) -> void:
	var original_size := root.size
	for size in [Vector2i(800,450), Vector2i(1024,576), Vector2i(1280,720)]:
		root.size = size
		await process_frame
		await process_frame
		for index in showcase.CLIPS.size():
			showcase._select_clip(index)
			showcase._seek(.19 if index in [7,8] else showcase._timeline.max_value*.5)
			for yaw in [0.0,90.0,180.0,270.0]:
				showcase._set_camera(yaw)
				showcase._process(0)
				var safe: Rect2 = showcase._controls.safe_rect()
				var character: Node3D = showcase.character
				var head: Vector3 = character.skeleton.global_transform*(joint(character,"head")+Vector3(0,.12,0))
				var probes := [head, character.skeleton.global_transform*joint(character,"foot.L"), character.skeleton.global_transform*joint(character,"foot.R")]
				var framed := true
				for point in probes:
					framed = framed and safe.has_point(showcase.cam.unproject_position(point))
				check(framed,"showcase head/feet stay outside panels at %s / %s / %s" % [size,showcase.CLIPS[index][0],yaw])
	var event := InputEventKey.new()
	event.physical_keycode = KEY_V
	event.pressed = true
	showcase._unhandled_input(event)
	check(not showcase._controls.root.visible,"V hides the showcase overlay without changing combat")
	showcase._unhandled_input(event)
	check(showcase._controls.root.visible,"V restores showcase controls")
	var before: float = showcase._time
	event.physical_keycode = KEY_LEFT
	showcase._unhandled_input(event)
	check(showcase._time < before and not showcase._playing,"physical Left frame-steps and pauses independently of keyboard layout")
	root.size = original_size
	await process_frame


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


func _test_modifier_and_dodge_physics() -> void:
	var original_ticks := Engine.physics_ticks_per_second
	var directions := [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0),
		Vector3(-1, 0, 0), Vector3(1, 0, 1).normalized(), Vector3(-1, 0, -1).normalized()]
	var min_distance := INF
	var max_distance := 0.0
	for fps in [30, 60, 120]:
		Engine.physics_ticks_per_second = fps
		var player := PlayerScene.instantiate()
		player.position = Vector3(-4, .1, 3)
		world.add_child(player)
		for i in 10:
			await physics_frame
		# Actual modifier -> CharacterBody displacement -> animator, not a
		# direct call to _process_move or a synthetic speed fed to the blender.
		Input.action_press("move_forward")
		for entry in [[true, false, T.WALK_SPEED, 0.0, 0.0],
				[false, false, T.JOG_SPEED, 1.0, 0.0], [true, true, T.RUN_SPEED, 1.0, 1.0]]:
			player.position = Vector3(-4, .01, 3)
			player.velocity = Vector3.ZERO
			Input.action_release("run")
			Input.action_release("walk_slow")
			if entry[0]:
				Input.action_press("walk_slow")
			if entry[1]:
				Input.action_press("run")
			for i in fps:
				await physics_frame
			var character: Node3D = player.character
			check(absf(Vector2(player.velocity.x, player.velocity.z).length()-float(entry[2])) < .0001,
				"real modifier-controlled speed %.2f at %d physics FPS" % [entry[2], fps])
			check(is_equal_approx(character._gait_blend, entry[3]) and is_equal_approx(character._sprint_blend, entry[4]),
				"real player displacement selects correct gait at %d physics FPS" % fps)
		Input.action_release("run")
		Input.action_release("walk_slow")
		Input.action_release("move_forward")
		for direction in directions:
			player.position = Vector3(-4, .01, 3)
			player.velocity = Vector3.ZERO
			player.rotation.y = .71
			player.stamina = T.MAX_STAMINA
			for i in 3:
				await physics_frame
			var start: Vector3 = player.position
			var facing: Basis = player.global_basis
			var world_direction: Vector3 = player.character.global_basis*direction
			player._buf_dir = world_direction
			player._buf_dodge = 0.0
			var saw_iframes := false
			for i in ceili(T.DODGE_DURATION*fps)+4:
				await physics_frame
				saw_iframes = saw_iframes or player._invulnerable
			var displacement: Vector3 = player.position-start
			displacement.y = 0
			min_distance = minf(min_distance, displacement.length())
			max_distance = maxf(max_distance, displacement.length())
			check(displacement.distance_to(world_direction*T.DODGE_DISTANCE) < .001,
				"actual dodge travels authored 1.10 m in cardinal/diagonal directions at %d FPS" % fps)
			check(player.global_basis.is_equal_approx(facing), "actual physics dodge does not turn facing")
			check(saw_iframes and not player._invulnerable and player._action == "",
				"dodge iframes/recovery finish at %d FPS" % fps)
		player.position = Vector3(0, .01, -1.2)
		player.velocity = Vector3.ZERO
		player.stamina = T.MAX_STAMINA
		for i in 3:
			await physics_frame
		player._buf_dir = Vector3(0, 0, -1)
		player._buf_dodge = 0.0
		for i in ceili(T.DODGE_DURATION*fps)+4:
			await physics_frame
		check(player.position.z > -1.57 and player.position.z < -1.45,
			"real wall collision clips dodge travel without tunnelling at %d FPS" % fps)
		player.free()
	Engine.physics_ticks_per_second = original_ticks
	print("Dodge physics 30/60/120 Hz: %.6f–%.6f m; wall stops all three" % [min_distance, max_distance])
