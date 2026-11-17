## Export actual player physics + native sampled bones, without a GPU renderer.
## godot --headless --path prototype --fixed-fps 60 --script res://tests/record_motion.gd
## Optional GEN_TRACE_OUTPUT=/absolute/path.json; default user://motion-trace.json.
## Reference/review tool, NOT a replacement for playing the game on the target GPU.
extends SceneTree

const PlayerScene := preload("res://scenes/player.tscn")
const FPS := 60
var world: Node3D


func _initialize() -> void:
	call_deferred("_record")


func vector(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func frame(player: CharacterBody3D) -> Dictionary:
	var character: Node3D = player.get_node("Character")
	var skeleton: Skeleton3D = character.skeleton
	var rotations: Array = []
	for i in skeleton.get_bone_count():
		var q := skeleton.get_bone_pose_rotation(i)
		rotations.append([q.x, q.y, q.z, q.w])
	var q := character.global_basis.get_rotation_quaternion()
	return {"rotations": rotations,
		"hips": vector(skeleton.get_bone_pose_position(skeleton.find_bone("hips"))),
		"position": vector(character.global_position), "orientation": [q.x, q.y, q.z, q.w],
		"vertical_speed": player.velocity.y, "grounded": player.is_on_floor(), "state": character._state}


func take(moving: bool, jump_at: int, count: int) -> Array:
	var player := PlayerScene.instantiate() as CharacterBody3D
	player.position = Vector3(0, .1, 0)
	world.add_child(player)
	for i in 25:
		await physics_frame
	if moving:
		Input.action_press("move_forward")
		Input.action_press("run")
		for i in 45:
			await physics_frame
	var result: Array = []
	for i in count:
		if i == jump_at:
			player._jump_buffer = 0.0
		await physics_frame
		result.append(frame(player))
	Input.action_release("move_forward")
	Input.action_release("run")
	player.free()
	return result


func _record() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(80, .2, 80)
	collision.shape = shape
	floor_body.position.y = -.1
	floor_body.add_child(collision)
	world.add_child(floor_body)
	var result := {"fps": FPS, "source": "Godot CharacterBody3D + character_anim.gd, actual physics frames",
		"takes": {"run": await take(true, -1, 120),
			"jump": await take(false, 18, 108), "run_jump": await take(true, 18, 108)}}
	var path := OS.get_environment("GEN_TRACE_OUTPUT")
	if path.is_empty():
		path = "user://motion-trace.json"
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write motion trace: " + path)
		quit(1)
		return
	output.store_string(JSON.stringify(result))
	output.close()
	world.free()
	print("GEN recorded 336 actual physics poses: " + ProjectSettings.globalize_path(path))
	quit()
