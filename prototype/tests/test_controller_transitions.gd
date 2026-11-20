## Real PhysicsServer frames + actual controllers. Input is held, not a
## synthetic zero velocity passed to the animator. Fixtures reset BETWEEN
## takes only. These logic/pose checks are not rendered/GPU acceptance.
extends SceneTree
const Player := preload("res://scenes/player.tscn")
const Clone := preload("res://scenes/clone.tscn")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
var world: Node3D
var player: CharacterBody3D
var clone: CharacterBody3D
var wall: StaticBody3D
var frames: Array = []
var take := ""

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: "+message)

func vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func event(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func release() -> void:
	for name in ["move_left", "move_right", "move_forward", "move_back", "walk_slow", "run"]:
		Input.action_release(name)

func box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var solid := BoxShape3D.new()
	solid.size = size
	shape.shape = solid
	body.position = pos
	body.add_child(shape)
	world.add_child(body)
	return body

func tick(count: int) -> void:
	for i in count:
		var previous := player.position
		await physics_frame
		await process_frame
		var actual := player.position-previous
		var ch: Node3D = player.character
		frames.append({"take": take, "outfit": ch.appearance.outfit, "position": vec(player.position),
			"actual_delta": vec(actual), "velocity": vec(player.velocity), "phase": ch._phase,
			"move_weight": ch._move_weight, "directional": ch._directional_blend,
			"direction_weights": [ch._direction_weights.x, ch._direction_weights.y, ch._direction_weights.z, ch._direction_weights.w],
			"combat": player.combat_mode, "facing": vec(-player.global_basis.z),
			"lock": String(player.lock.target.name) if player.lock.active() else "",
			"state": ch._state, "grounded": player.is_on_floor(),
			"clone_position": vec(clone.position), "clone_phase": clone.character._phase,
			"clone_move_weight": clone.character._move_weight})

func fixture(pos: Vector3 = Vector3(0, .05, 4), target: Vector3 = Vector3(0, .05, -6)) -> void:
	release()
	player.lock.clear()
	clone.mode = clone.Mode.OFF
	clone._attack_time = -1
	clone.velocity = Vector3.ZERO
	clone.position = target
	clone.character.reset_motion(false)
	player.position = pos
	player.rotation = Vector3.ZERO
	player.yaw = 0
	player.velocity = Vector3.ZERO
	player._action = ""
	player.combat_mode = false
	player.character.reset_motion(false)
	wall.position.x = 30
	await tick(25)

func run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	box(Vector3(0, -.10, 0), Vector3(80, .2, 80))
	wall = box(Vector3(30, 1.5, 0), Vector3(.2, 3, 16))
	player = Player.instantiate()
	world.add_child(player)
	player.rig.set_process(false)
	clone = Clone.instantiate()
	world.add_child(clone)
	for outfit in ["dress", "suit"]:
		player.character.appearance.set_outfit(outfit)
		clone.character.appearance.set_outfit(outfit)
		await movement_and_transitions()
		await blocked_and_sliding()
		await clone_blocked()
		await target_lifecycle()
	release()
	var path := OS.get_environment("GEN_CONTROLLER_TRANSITIONS")
	if not path.is_empty():
		var output := FileAccess.open(path, FileAccess.WRITE)
		output.store_string(JSON.stringify({"fps": 60, "source": "ACTUAL automatic player/clone physics frames on floor/wall fixtures, input events/holds; not a GPU capture", "frames": frames}))
	world.free()
	await process_frame
	OS.delay_msec(100) # Give the dummy mixer time to release stopped foley streams.
	await process_frame
	print("GEN controller-transition suite: %d checks, %d failures; %d actual physics frames" % [checks, failures, frames.size()])
	quit(0 if failures == 0 else 1)

func movement_and_transitions() -> void:
	for row in [["move_left", "walk_slow", 1.15], ["move_right", "", 2.9], ["move_back", "run", 5.6],
			["move_forward", "run", 5.6]]:
		take = "locked-"+row[0]+"-"+row[1]
		await fixture()
		player._unhandled_input(event("lock_on"))
		check(player.lock.target == clone, "real Tab acquisition selects visible training clone")
		Input.action_press(row[0])
		if row[1] != "": Input.action_press(row[1])
		await tick(36)
		var speeds: Array[float] = []
		var facing_min := 1.0
		for f in frames.slice(-12):
			speeds.append(Vector2(f["actual_delta"][0], f["actual_delta"][2]).length()*60)
			var to := clone.position-Vector3(f["position"][0], 0, f["position"][2])
			to.y = 0
			facing_min = minf(facing_min, Vector3(f["facing"][0],0,f["facing"][2]).dot(to.normalized()))
		speeds.sort()
		check(absf(speeds[6]-row[2]) < .025, "%s actual settled speed %.3f, not requested velocity" % [take,speeds[6]])
		check(facing_min > .995, "%s stays facing target while physically moving" % take)
		check(player.character._directional_blend > .999, "controller supplies target-relative context in ordinary stance too")
		var phase: float = player.character._phase
		player._unhandled_input(event("toggle_stance"))
		await tick(1)
		check(absf(wrapf(player.character._phase-phase, -.5, .5)) < .15 and player.combat_mode,
			"R transition while moving retains common contact phase")
		await tick(22)
		check(player.character._combat_blend == 1 and player.character.appearance.sole_height() >= -.00005,
			"real stance entry completes without pushing soles through floor")
		player._unhandled_input(event("lock_on"))
		await tick(25)
		check(not player.lock.active() and player.character._directional_blend == 0,
			"unlock while moving fades to free turn-to-travel, no phase reset")
		var to_move := player.get_real_velocity()
		to_move.y = 0
		check((-player.global_basis.z).dot(to_move.normalized()) > .99,
			"combat-without-lock rule is natural free facing, not an invisible new strafe mode")
	# Both diagonal branches retain the original Shift speed without a diagonal boost.
	for pair in [["move_left", "move_forward", 5.6], ["move_right", "move_back", 5.6]]:
		take = "diagonal-"+pair[0]+"-"+pair[1]
		await fixture()
		player._unhandled_input(event("lock_on"))
		Input.action_press(pair[0]); Input.action_press(pair[1]); Input.action_press("run")
		await tick(40)
		var speed := Vector2(player.get_real_velocity().x,player.get_real_velocity().z).length()
		check(absf(speed-pair[2]) < .03, "real diagonal has documented speed, no diagonal boost")
		var weights: Vector4 = player.character._direction_weights
		var sorted: Array = [weights.x,weights.y,weights.z,weights.w]
		sorted.sort()
		check(sorted[2] > .46 and sorted[3] < .54, "diagonal actually blends two directional clips")

func blocked_and_sliding() -> void:
	take = "player-wall-stop"
	await fixture(Vector3(1.2,.05,3),Vector3(0,.05,-4))
	wall.position.x = 2.2
	Input.action_press("move_right"); Input.action_press("run")
	await tick(65)
	var pos := player.position
	var phase: float = player.character._phase
	await tick(20)
	# Measure the horizontal channel which drives the gait. The native
	# floor/wall corner may depenetrate vertically by ~1 mm; trace keeps Y.
	check(Vector2(player.position.x-pos.x,player.position.z-pos.z).length() < .0001 and player.position.x < 1.77, "real wall collision blocks player, no teleport fixture during take")
	check(absf(player.character._phase-phase) < .00001 and player.character._move_weight == 0,
		"still-held WASD/Shift cannot drive gait against wall")
	player._unhandled_input(event("lock_on"))
	Input.action_press("move_forward")
	take = "player-wall-slide"
	await tick(40)
	var real := player.get_real_velocity()
	var local: Vector3 = player.character.global_basis.inverse()*Vector3(real.x,0,real.z)
	var expected := Vector4(maxf(local.z,0),maxf(local.x,0),maxf(-local.x,0),maxf(-local.z,0))
	expected /= maxf(absf(local.x)+absf(local.z),.000001)
	check(absf(real.x) < .005 and absf(real.z) > .6, "diagonal input slides physically along wall tangent")
	check(player.character._direction_weights.distance_to(expected) < .045,
		"wall-slide blend follows ACTUAL displacement relative to facing, not WASD diagonal")
	release()
	# 5.6 m/s needs 17 ticks to decelerate, then the visual blend fades.
	await tick(30)
	check(player.character._move_weight == 0, "zero-speed release has no lingering pedalling")

func clone_blocked() -> void:
	take = "clone-wall-approach"
	await fixture(Vector3(4,.05,0),Vector3(1.2,.05,0))
	wall.position.x = 2.2
	clone.cycle_mode()
	await tick(65)
	var pos := clone.position
	var phase: float = clone.character._phase
	await tick(20)
	check(Vector2(clone.position.x-pos.x,clone.position.z-pos.z).length() < .0001 and clone.position.x < 1.77,
		"clone actual approach obeys same wall physics")
	check(absf(clone.character._phase-phase) < .00001 and clone.character._move_weight == 0,
		"blocked clone uses actual speed too, no marching against wall")
	# A separate retreat fixture; no scripted root motion inside the take.
	take = "clone-wall-retreat"
	await fixture(Vector3(.2,.05,0),Vector3(1.75,.05,0))
	wall.position.x = 2.2
	clone.cycle_mode()
	clone._recover = 3.0
	await tick(55)
	pos = clone.position
	phase = clone.character._phase
	await tick(20)
	check(Vector2(clone.position.x-pos.x,clone.position.z-pos.z).length() < .0001 and absf(clone.character._phase-phase) < .00001,
		"AI retreat cannot advance animation phase when blocked")

func target_lifecycle() -> void:
	take = "target-change-loss-death"
	await fixture()
	var other := Node3D.new()
	other.name = "OtherTarget"
	other.position = Vector3(3,0,-2)
	world.add_child(other)
	other.add_to_group("damageable")
	player._unhandled_input(event("lock_on"))
	Input.action_press("move_left")
	await tick(20)
	var phase: float = player.character._phase
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	player._unhandled_input(wheel)
	await tick(1)
	check(player.lock.target == other and absf(wrapf(player.character._phase-phase,-.5,.5)) < .15,
		"real wheel target change keeps common phase instead of restarting footfall")
	other.visible = false
	await tick(18)
	check(not player.lock.active() and player.character._directional_blend == 0,
		"hidden/lost target safely releases lock and directional blend")
	other.free()
	release()
	player.yaw = 0
	player._unhandled_input(event("lock_on"))
	check(player.lock.target == clone, "clone can be reacquired after target loss")
	clone.mode = clone.Mode.ON
	clone.receive_hit(1000,{"zone":"torso","direction_world":Vector3.FORWARD})
	await tick(15)
	check(not player.lock.active() and clone.mode == clone.Mode.OFF,
		"clone death/respawn clears live lock without retaining old facing")
