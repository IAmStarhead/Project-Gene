## Controller + real physics; no mocked ledge or hand-written displacement.
extends SceneTree
const Player := preload("res://scenes/player.tscn")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
var world: Node3D
var actor: CharacterBody3D
var platform: StaticBody3D

func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
func box(size: Vector3, pos: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	b.add_child(col)
	world.add_child(b)
	b.position = pos
	return b
func tick(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame
func action(name: String) -> void:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	actor._unhandled_input(e)
func key(code: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	actor._unhandled_input(e)
func reset(pos: Vector3) -> void:
	for name in ["move_forward", "move_back", "move_left", "move_right", "run"]:
		Input.action_release(name)
	actor._action = ""
	actor._ledge.clear()
	actor._ledge_jump = false
	actor._ledge_cooldown = 0
	actor._buf_dodge = actor.BUF_NEVER
	actor._buf_roll = false
	actor._jump_buffer = actor.BUF_NEVER
	actor._coyote = 0
	actor.velocity = Vector3.ZERO
	actor.position = pos
	actor.rotation = Vector3.ZERO
	actor.yaw = 0
	actor.stamina = T.MAX_STAMINA
	actor.character.reset_motion(false)
	await tick(6)
func wait_state(state: String, n: int) -> bool:
	for i in n:
		if actor._action == state:
			return true
		await tick(1)
	return actor._action == state
func start_grab() -> bool:
	await reset(Vector3(0,.05,2.0))
	Input.action_press("move_forward")
	action("jump")
	return await wait_state("ledge_hang", 110)
func run() -> void:
	T.FOLEY_ENABLED = false
	world = Node3D.new()
	root.add_child(world)
	box(Vector3(30,.2,30), Vector3(0,-.1,0))
	platform = box(Vector3(2.2,2,2.2), Vector3(0,1,0))
	platform.add_to_group("climbable_ledge")
	actor = Player.instantiate()
	world.add_child(actor)
	await reset(Vector3(5,.05,5))
	Input.action_press("move_forward")
	action("dodge")
	await tick(2)
	check(actor._action == "dodge", "plain space remains dodge")
	await reset(Vector3(5,.05,5))
	Input.action_press("run")
	Input.action_press("move_forward")
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	space.shift_pressed = true
	actor._unhandled_input(space)
	await tick(2)
	check(actor._action == "roll", "physical shift + direction + space starts roll")
	check(absf(actor.stamina-(T.MAX_STAMINA-T.ROLL_STAMINA)) < .1, "roll spends stamina once")
	check(actor.character._state == "roll", "roll uses a separate animation")
	await tick(14)
	check(actor._invulnerable, "roll i-frame window")
	await tick(50)
	check(actor._action != "roll" and not actor._invulnerable, "roll ends and i-frames end")
	for dir in ["move_forward", "move_back", "move_left", "move_right"]:
		await reset(Vector3(5,.05,5))
		Input.action_press("run")
		Input.action_press(dir)
		action("dodge")
		await tick(2)
		check(actor._action == "roll", "roll starts for " + dir)
		var from: Vector3 = actor.position
		await tick(46)
		check(Vector2(actor.position.x-from.x, actor.position.z-from.z).length() > 1.3, "roll travels for " + dir)
	await reset(Vector3(5,.05,5))
	var wall := box(Vector3(3,2,.2), Vector3(5,1,4.2))
	Input.action_press("run")
	Input.action_press("move_forward")
	action("dodge")
	await tick(50)
	check(actor.position.z > 4.63, "roll cannot pass through wall")
	wall.free()
	await reset(Vector3(5,.05,5))
	Input.action_press("run")
	action("dodge")
	await tick(2)
	check(actor._action == "dodge", "shift without direction retains dodge")
	var grabbed := await start_grab()
	check(grabbed, "jumping towards marked platform reaches hanging state, state=" + actor._action + " pos=" + str(actor.position))
	if grabbed:
		var hanging: Vector3 = actor.position
		await tick(12)
		check(actor.position.distance_to(hanging) < .005, "hanging body stays at edge")
		for side in ["L", "R"]:
			var skeleton: Skeleton3D = actor.character.skeleton
			var hand := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("hand." + side)).origin
			check(absf(hand.y - 2.0) < .16 and absf(hand.z - 1.1) < .16, "hanging wrist near edge " + side + ": " + str(hand))
		key(KEY_C)
		check(actor._action == "" and actor._buf_dodge > T.INPUT_BUFFER, "C releases without triggering dodge")
		Input.action_release("move_forward")
		await tick(65)
		check(actor.is_on_floor() and actor.character._state in ["ground", "land"], "release transitions through fall to floor")
	grabbed = await start_grab()
	check(grabbed, "can grab again")
	if grabbed:
		key(KEY_CTRL)
		check(actor._action == "", "Ctrl releases ledge")
	grabbed = await start_grab()
	check(grabbed, "can grab for climb")
	if grabbed:
		Input.action_release("move_forward")
		key(KEY_SPACE)
		check(actor._action == "ledge_climb", "space starts climb, not dodge")
		await tick(90)
		check(actor._action == "" and actor.position.y > 1.99 and actor.position.z < 1.0, "climb ends on top: " + str(actor.position))
		await tick(10)
		check(actor.is_on_floor(), "capsule stands on platform")
	grabbed = await start_grab()
	check(grabbed, "can grab for obstruction test")
	if grabbed:
		var roof := box(Vector3(2.2,.2,2.2), Vector3(0,3.0,0))
		await tick(3)
		key(KEY_SPACE)
		check(actor._action == "ledge_hang", "blocked destination prevents climb")
		roof.free()
		await tick(2)
		key(KEY_SPACE)
		check(actor._action == "ledge_climb", "climb starts after roof removed")
		var moving_obstacle := box(Vector3(1,.2,1), actor.position + Vector3(0,2.05,0))
		await tick(30)
		check(actor._action != "ledge_climb", "new obstacle interrupts movement safely")
		moving_obstacle.free()
	grabbed = await start_grab()
	check(grabbed, "can grab before platform removal")
	if grabbed:
		platform.queue_free()
		await tick(3)
		check(actor._action == "", "removed platform releases player")
	actor.free()
	world.queue_free()
	await process_frame
	print("Traversal suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
