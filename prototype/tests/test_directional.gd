## Target-relative gait + actual player/clone controllers. No GPU/FPS claim.
extends SceneTree

const Character := preload("res://scripts/character_anim.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
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

func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var character := Node3D.new()
	character.set_script(Character)
	world.add_child(character)
	for combat in [false, true]:
		for direction in [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, -1),
				Vector3(1, 0, 1).normalized(), Vector3(-1, 0, -1).normalized()]:
			character.reset_motion(combat)
			for i in 90:
				character.update_motion(1.0/60, direction*2.9, "", 0, "R",
					{"grounded": true, "directional": true, "combat": combat, "distance": 2.9/60})
			var w: Vector4 = character._direction_weights
			check(absf(w.x+w.y+w.z+w.w-1) < .00001, "normalised direction blend, no diagonal boost")
			check(character._directional_blend == 1 and character._move_weight == 1,
				"both stances use new target-facing lower-body clips")
			check(character.appearance.sole_height() >= -.00005, "direction/stance blend keeps actual sole above floor")
			if direction.z < -.99:
				check(w.w > .999, "retreat is its own forward-time cycle")
			if absf(direction.x) > .99:
				check(w.y > .999 if direction.x > 0 else w.z > .999, "real displacement selects anatomical left/right")
			var phase: float = character._phase
			# A blocked actor must NOT pedal from desired velocity. Actual
			# displacement is zero, and transitions may not reset contact phase.
			for i in 50:
				character.update_motion(1.0/60, Vector3.ZERO, "", 0, "R",
					{"grounded": true, "distance": 0.0, "directional": i < 25, "combat": not combat})
			check(absf(character._phase-phase) < .00001 and character._move_weight == 0,
				"wall/lock/stance transition freezes phase at zero real speed")
	_relaxed_target_arm_scope(character)
	character.free()
	await _actual_controllers()
	world.free()
	print("GEN directional suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _relaxed_target_arm_scope(character: Node3D) -> void:
	# Regression for rendered-review frame dress-locked-walk/player:4:
	# a lower directional pelvis + copied ordinary upper body let the OPEN
	# left hand cut the skirt. The fix is local to relaxed target-facing arms,
	# not a re-authoring of the accepted ordinary gait or a garment mask.
	var base: Dictionary = character.sample_clip("combat_left_walk", .38)
	var ordinary: Dictionary = character.sample_clip("walk_relaxed", .38)
	var reference: Dictionary = character._replace_upper(base, ordinary)
	character._move_weight = 1
	var result: Dictionary = character._relaxed_target_upper(base, ordinary)
	var other_bones_same := true
	var input_unchanged := true
	for i in character.skeleton.get_bone_count():
		var name: String = character.skeleton.get_bone_name(i)
		var before: Quaternion = reference["rotations"][i]
		var after: Quaternion = result["rotations"][i]
		if name.begins_with("upper_arm."):
			check(absf(rad_to_deg(before.angle_to(after))-4) < .001,
				"target-relaxed arm clearance is a bounded four-degree abduction: "+name)
		else:
			other_bones_same = other_bones_same and before.is_equal_approx(after)
		var fresh: Dictionary = character.sample_clip("walk_relaxed", .38)
		input_unchanged = input_unchanged and ordinary["rotations"][i].is_equal_approx(fresh["rotations"][i])
	check(other_bones_same and result["hips"] == base["hips"],
		"clearance leaves pelvis, accepted lower body, torso, wrists and elbow LOCAL rotations intact")
	check(input_unchanged, "clearance does not mutate the sampled ordinary source pose")
	character._move_weight = 0
	var resting: Dictionary = character._relaxed_target_upper(base, ordinary)
	var same := true
	for i in character.skeleton.get_bone_count():
		same = same and reference["rotations"][i].is_equal_approx(resting["rotations"][i])
	check(same, "stationary target lock does not spread the relaxed arms")
	character.reset_motion(false)
	character._phase = .38
	character._move_weight = 1
	var free_pose: Dictionary = character._locomotion_pose()
	var old_free: Dictionary = character._locomotion_set(false)
	same = true
	for i in character.skeleton.get_bone_count():
		same = same and free_pose["rotations"][i].is_equal_approx(old_free["rotations"][i])
	check(same and free_pose["hips"] == old_free["hips"],
		"without lock the accepted ordinary gait remains exactly the legacy pose")


func release_input() -> void:
	for action in ["move_left", "move_right", "move_forward", "move_back", "run", "walk_slow"]:
		Input.action_release(action)

func _actual_controllers() -> void:
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, .2, 80)
	floor_shape.shape = box
	floor_body.position.y = -.1
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	var player: CharacterBody3D = PlayerScene.instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	player.rig.set_process(false)
	var target := Node3D.new()
	world.add_child(target)
	var clone: CharacterBody3D = CloneScene.instantiate()
	world.add_child(clone)
	clone.set_physics_process(false)
	clone.position = Vector3(5, 0, -4)
	await physics_frame
	for combat in [false, true]:
		for action in ["move_left", "move_right", "move_back", "move_forward"]:
			for tier in ["walk_slow", "", "run"]:
				release_input()
				player.position = Vector3.ZERO
				player.rotation = Vector3.ZERO
				player.velocity = Vector3.ZERO
				player.character.reset_motion(combat)
				player.combat_mode = combat
				player.lock.target = target
				Input.action_press(action)
				if tier != "":
					Input.action_press(tier)
				for i in 50:
					# Target stays exactly ahead: do not measure a curved
					# orbital path as a change to the control's speed limit.
					target.position = player.position+Vector3(0, 0, -5)
					player._physics_process(1.0/60)
				var planar := Vector2(player.velocity.x, player.velocity.z).length()
				var expected := 1.15 if tier == "walk_slow" else 2.9
				if tier == "run":
					expected = 5.6 if action == "move_forward" else 3.4
				check(absf(planar-expected) < .003, "locked %s %s speed %.2f (combat=%s)" % [action, tier, planar, combat])
				check(absf(player.rotation.y) < .0001, "side/back inputs do not turn the actor away from target")
				check(player.character._directional_blend == 1, "actual controller supplies directional context")
	# Releasing lock retains free camera-relative turn-to-travel in R mode.
	release_input()
	player.lock.clear()
	player.position = Vector3.ZERO
	player.rotation = Vector3.ZERO
	player.velocity = Vector3.ZERO
	Input.action_press("move_left")
	Input.action_press("run")
	for i in 60:
		player._physics_process(1.0/60)
	check(absf(player.velocity.length()-5.6) < .003 and absf(player.rotation.y) > 1.5,
		"combat without lock uses existing natural free turn and full 5.6 speed")
	check(player.character._directional_blend == 0, "lost/cleared lock fades back to free locomotion")
	release_input()
	# Clone's real retreat decision uses the same new backward tracks.
	clone.mode = clone.Mode.ON
	clone._player = player
	clone.position = Vector3(5, 0, 0)
	player.position = Vector3(5, 0, -1)
	clone._recover = 5
	for i in 40:
		clone._physics_process(1.0/60)
	check(clone.character._directional_blend == 1 and clone.character._direction_weights.w > .95,
		"actual clone retreat uses target-facing back cycle")
	check(absf(Vector2(clone.velocity.x, clone.velocity.z).length()-T.CLONE_WALK) < .003,
		"clone retreat physical speed is unchanged")
	clone.cycle_mode()
	for i in 40:
		clone._physics_process(1.0/60)
	check(clone.character._directional_blend < .001, "passive clone safely leaves directional movement")
	player.free()
	clone.free()
	target.free()
	floor_body.free()
	await process_frame
