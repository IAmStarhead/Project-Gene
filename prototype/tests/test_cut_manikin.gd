## Integration test for the training blade in the actual main scene.
extends SceneTree

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)

func key(code: Key) -> void:
	var e := InputEventKey.new()
	e.pressed = true
	e.physical_keycode = code
	Input.parse_input_event(e)
	var release := InputEventKey.new()
	release.physical_keycode = code
	Input.parse_input_event(release)

func click() -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	Input.parse_input_event(e)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	Input.parse_input_event(release)

func _run() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame
	var player = scene.player
	var dummy = scene.cut_manikin
	var clone = scene.clone
	check(is_instance_valid(dummy) and dummy.is_in_group("damageable"), "manikin in game and lock target")
	check(dummy.parts.size() == 4, "four prepared parts")
	for part in dummy.parts:
		check(part.whole.visible and not part.stump.visible, "prepared stump hidden while intact")
	player.global_position = dummy.global_position + Vector3(0, .08, 1.0)
	player.rotation.y = 0.0
	player.yaw = 0.0
	player.rig.snap_now()
	player.lock.target = dummy
	key(KEY_V)
	await physics_frame
	check(player.training_blade, "V enables test blade")
	key(KEY_2)
	key(KEY_N)
	await physics_frame
	check(player.training_limb == 1 and player.training_special, "2 selects arm and N selects special")
	check(dummy.parts[1].whole.get_child(0).material_override == dummy._selected_material, "selected limb highlighted")
	await process_frame
	check(player.hud.get("_training_label").visible, "blade controls visible on HUD")
	var clone_health: float = clone.health
	click()
	for i in 45:
		await physics_frame
	check(dummy.parts[1].state == dummy.LimbState.BLOCKED, "real mouse attack cuts selected limb")
	check(not dummy.parts[1].whole.visible and dummy.parts[1].stump.visible, "prepared stump shown")
	check(is_instance_valid(dummy.parts[1].debris), "physical piece spawned")
	check(is_equal_approx(clone.health, clone_health), "blade does not damage clone")
	key(KEY_3)
	key(KEY_N)
	for i in 12:
		await physics_frame
	click()
	for i in 45:
		await physics_frame
	check(dummy.parts[2].state == dummy.LimbState.GROWING, "ordinary blade cuts leg")
	check(dummy.parts[1].state == dummy.LimbState.BLOCKED, "ordinary cut does not unblock prior injury")
	# Pause freezes regrowth and physics.
	var before_pause: float = dummy.parts[2].time
	paused = true
	await create_timer(.2, true).timeout
	check(is_equal_approx(dummy.parts[2].time, before_pause), "regrowth pauses")
	paused = false
	dummy._physics_process(dummy.GROW_TIME * .4)
	check(dummy.parts[2].stages[0].visible and not dummy.parts[2].stump.visible, "prepared growth stage displayed")
	dummy._physics_process(dummy.GROW_TIME)
	check(dummy.parts[2].state == dummy.LimbState.INTACT, "ordinary injury regrows")
	check(dummy.parts[1].state == dummy.LimbState.BLOCKED, "special injury remains blocked")
	key(KEY_K)
	await physics_frame
	check(dummy.parts[1].state == dummy.LimbState.INTACT, "K restores blocked limb")
	# Check range, facing and line of sight against a real physics wall.
	player.set_physics_process(false)
	player.training_blade = true
	player.training_limb = 0
	player.training_special = false
	player.global_position = dummy.global_position + Vector3(0, .08, 4.0)
	player.lock.clear()
	player.rotation.y = 0.0
	player._start_attack()
	check(not player._do_hit(true), "cannot cut from far away")
	player.global_position = dummy.global_position + Vector3(0, .08, 1.0)
	player.rotation.y = PI
	player._start_attack()
	check(not player._do_hit(true), "cannot cut behind player")
	player.rotation.y = 0.0
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 2, .1)
	coll.shape = shape
	wall.add_child(coll)
	root.add_child(wall)
	wall.global_position = dummy.global_position + Vector3(0, 1, .5)
	await physics_frame
	player._start_attack()
	check(not player._do_hit(true), "cannot cut through wall")
	wall.queue_free()
	await physics_frame
	player._start_attack()
	check(player._do_hit(true), "reachable unblocked limb can be cut")
	check(not player._do_hit(true), "same limb cannot be cut twice")
	key(KEY_K)
	await physics_frame
	player.training_limb = 3
	player._start_attack()
	check(player._do_hit(true) and dummy.parts[3].state == dummy.LimbState.GROWING, "fourth limb can be cut")
	# Clone is directly in range while the mannequin is out of range.
	dummy.global_position = Vector3(6, 0, 5)
	clone.global_position = player.global_position + Vector3(0, 0, -1.0)
	clone.mode = clone.Mode.ON
	clone.health = 100.0
	player._start_attack()
	check(not player._do_hit(true) and is_equal_approx(clone.health, 100.0), "test blade cannot damage nearby active clone")
	player.training_blade = false
	player._start_attack()
	check(not player._attack_blade, "V-off attack uses normal combat")
	scene.queue_free()
	await process_frame
	OS.delay_msec(100)
	await process_frame
	print("Cut manikin suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
