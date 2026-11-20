## ISOLATED review driver: unchanged project scenes/controllers, actual physics ticks.
## No full-skin or review hooks are added to the game sources.
extends Node3D

var scene: Node3D
var mode := "game"
var observer: Camera3D
var view := "game"
var old_id := 0
var remaining := 0
var pending_id := 0
var pending_snapshot := false
var elapsed_ticks := 0
var physics_states: Array = []
var stamps: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 1000
	for item in [["model_sha256","res://assets/heroine/female_A_rigged_safe.glb"],
			["appearance_sha256","res://assets/heroine/appearance/lab_uniform.json"],
			["motion_set_sha256","res://assets/heroine/animations/motion_set.json"],
			["runtime_sha256","res://scripts/character_appearance.gd"],
			["controller_sha256","res://scripts/character_anim.gd"],
			["player_sha256","res://scripts/player.gd"],["clone_sha256","res://scripts/clone_enemy.gd"],
			["hit_check_sha256","res://scripts/hit_check.gd"],["lock_on_sha256","res://scripts/lock_on.gd"],
			["hud_sha256","res://scripts/hud.gd"],["world_sha256","res://scripts/build_scene.gd"],
			["lighting_sha256","res://shaders/toon_light.gd"],["showcase_sha256","res://scripts/showcase.gd"]]:
		stamps[item[0]] = FileAccess.get_sha256(item[1])
	observer = Camera3D.new()
	observer.fov = 36
	observer.near = .08
	add_child(observer)
	await load_scene("game")
	get_tree().paused = true
	print("REPLAY_READY ", Engine.get_version_info()["string"], " / ", FileAccess.get_sha256("res://scripts/character_appearance.gd"))

func load_scene(which: String) -> void:
	get_tree().paused = true
	for action in ["move_forward","move_back","move_left","move_right","run","walk_slow"]: Input.action_release(action)
	if is_instance_valid(scene):
		observer.make_current()
		scene.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	mode = which
	view = "game"
	elapsed_ticks = 0
	physics_states.clear()
	scene = load("res://scenes/main.tscn" if which == "game" else "res://scenes/showcase.tscn").instantiate()
	# The driver is ALWAYS so it can receive commands while paused. The
	# actual scene must explicitly be PAUSABLE, not inherit that ALWAYS.
	scene.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(scene)
	if which == "game": scene.player.rig.reparent(scene)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if which == "showcase":
		scene._playing = false
		scene.cam.make_current()
		scene._process(0)

func disable_review_shadows(node: Node) -> void:
	if node is Light3D: node.shadow_enabled = false
	if node is WorldEnvironment and node.environment != null: node.environment.glow_enabled = false
	for child in node.get_children(): disable_review_shadows(child)

func set_ui_visibility(node: Node, value: bool) -> void:
	for child in node.get_children():
		if child is CanvasLayer or child is Label3D: child.visible = value
		else: set_ui_visibility(child,value)

func update_camera() -> void:
	if mode != "game" or view == "game": return
	var player: Node3D = scene.player
	var focus := player.global_position+Vector3(0,.86,0)
	var direction: Vector3 = {"front":Vector3(0,.12,1),"side":Vector3(1,.12,0),"back":Vector3(0,.12,-1),"three":Vector3(.7,.12,1)}.get(view,Vector3(.8,.16,1))
	var distance := 3.8
	if view == "pair":
		focus = (player.global_position+scene.clone.global_position)*.5+Vector3(0,.84,0)
		direction = Vector3(0,.16,1)
		distance = 4.5
	elif view == "route":
		# Side tracking along the clean FRONT corridor, away from pods/stairs.
		# A world-fixed camera keeps the wall out of the sightline at both ends.
		direction = Vector3(0,.12,1)
	else:
		direction = player.character.global_basis*direction
	observer.global_position = focus+direction.normalized()*distance
	observer.look_at(focus)
	observer.make_current()

func actor_state(character: Node3D, snapshot: bool) -> Dictionary:
	var rig: Skeleton3D = character.skeleton
	var p := character.global_position
	var result := {"state":character._state,"phase":character._phase,"position":[p.x,p.y,p.z],
		"gait":character._gait_blend,"sprint":character._sprint_blend,"combat_blend":character._combat_blend,
		"hit_time":character._hit_time,"hit_active":character._hit_time < character.clip_duration("hit")}
	if snapshot:
		var q: Array = []
		for i in rig.get_bone_count():
			var rotation := rig.get_bone_pose_rotation(i)
			q.append([rotation.x,rotation.y,rotation.z,rotation.w])
		var h := rig.get_bone_pose_position(rig.find_bone("hips"))
		var cloth: Array = []
		for point in character.appearance.cloth_vertices(): cloth.append([point.x,point.y,point.z])
		result.merge({"rotations":q,"hips":[h.x,h.y,h.z],"cloth":cloth,
			"hand_open":character.appearance.hand_open,"cloth_gap":character.appearance.collision_gap()})
	return result

func reply() -> void:
	update_camera()
	var size := get_viewport().get_visible_rect().size
	var result := {"id":pending_id,"ticks":elapsed_ticks,"mode":mode,"view":view,
		"stamps":stamps,"viewport":[size.x,size.y],"window_pixels":[get_window().size.x,get_window().size.y]}
	if mode == "game":
		result["player"] = actor_state(scene.player.character,pending_snapshot)
		result["clone"] = actor_state(scene.clone.character,pending_snapshot)
		result["action"] = scene.player._action
		result["action_time"] = scene.player._action_time
		result["grounded"] = scene.player.is_on_floor()
		result["health"] = scene.player.health
		result["clone_health"] = scene.clone.health
		result["clone_action"] = scene.clone._attack_time
		result["clone_mode"] = scene.clone.mode
		result["stamina"] = scene.player.stamina
		result["lock_target"] = String(scene.player.lock.target.name) if scene.player.lock.active() else ""
		result["last_contact"] = scene.player._last_hit
		result["hud_visible"] = scene.player.hud.visible
		result["yaw"] = scene.player.rotation.y
		result["camera_yaw"] = scene.player.yaw
		result["velocity"] = [scene.player.velocity.x,scene.player.velocity.y,scene.player.velocity.z]
		result["capture_conditions"] = "isolated driver: PRODUCTION lighting, medium quality, PBR, shadows retained; actual main.tscn and controllers; only starting fixtures, sampled observer camera and UI visibility differ"
	else:
		result["safe_rect"] = str(scene._controls.safe_rect())
		result["viewport"] = str(get_viewport().get_visible_rect().size)
		result["head"] = str(scene.cam.unproject_position(Vector3(0,1.75,0)))
		result["feet"] = str(scene.cam.unproject_position(Vector3(0,0,0)))
	# Offline sampled capture: physics/cloth ran every tick, but avoid rasterising
	# discarded frames on SwiftShader. The screenshot sees a completed REAL
	# Godot framebuffer, held stable until the next command; no JS renderer.
	RenderingServer.render_loop_enabled = true
	await RenderingServer.frame_post_draw
	RenderingServer.render_loop_enabled = false
	print("REPLAY_DATA:",JSON.stringify(result))
	print("REPLAY_DONE:",pending_id)

func apply(command: Dictionary) -> void:
	pending_id = int(command["id"])
	pending_snapshot = command.get("snapshot",false)
	if command.has("scene"): await load_scene(command["scene"])
	if command.has("ui"):
		if mode == "game": set_ui_visibility(scene,command["ui"])
		else: scene._controls.root.visible = command["ui"]
	if mode == "game":
		for action in command.get("release",[]): Input.action_release(action)
		for action in command.get("press",[]): Input.action_press(action)
		if command.get("stance",false): scene.player.toggle_combat_mode()
		if command.get("jump",false): scene.player._jump_buffer = 0.0
		if command.has("attack"):
			if command["attack"] == "L": scene.player._buf_attack = 0.0
			else: scene.player._buf_secondary = 0.0
		if command.has("dodge"):
			var values: Array = command["dodge"]
			scene.player._buf_dodge = 0.0
			scene.player._buf_dir = scene.player.character.global_basis*Vector3(values[0],0,values[1]).normalized()
		if command.get("hit",false): scene.player.take_damage(5,Vector3.FORWARD)
		if command.get("clone",false): scene.clone.cycle_mode()
		if command.get("route",false):
			# Only the review starting location/input changes. No production
			# physics, speed, root path or laboratory geometry is modified.
			scene.player.global_position = Vector3(7.8,.03,4.0)
			scene.player.velocity = Vector3.ZERO
		if command.get("center",false):
			scene.player.global_position = Vector3(0,.03,2.5)
			scene.player.velocity = Vector3.ZERO
		if command.get("pair",false):
			scene.player.global_position = Vector3(-.45,.03,2.5)
			scene.clone.global_position = Vector3(.45,.03,2.5)
			scene.player.velocity = Vector3.ZERO
			scene.clone.velocity = Vector3.ZERO
			# Face the CONTROLLER toward the clone; do not turn only its
			# visual child (hit cones use the CharacterBody3D forward axis).
			scene.player.rotation.y = -PI*.5
			scene.player.character.rotation.y = PI
		if command.get("lock",false):
			var e := InputEventAction.new()
			e.action = "lock_on"
			e.pressed = true
			scene.player._unhandled_input(e)
		if command.has("view"): view=command["view"]
		if view == "game": scene.player.rig.spring.get_child(0).make_current()
	else:
		if command.has("clip"): scene._select_clip(command["clip"])
		if command.has("time"): scene._seek(command["time"])
		if command.has("yaw"): scene._yaw=command["yaw"]
		if command.has("playing"): scene._playing=command["playing"]
		scene._process(0)
	remaining = int(command.get("steps",0))
	if remaining > 0:
		RenderingServer.render_loop_enabled = false
		get_tree().paused = false
	else: reply()

func _physics_process(_delta: float) -> void:
	if remaining <= 0: return
	elapsed_ticks += 1
	if mode == "game":
		physics_states.append({"tick":elapsed_ticks,"player":actor_state(scene.player.character,false),"clone":actor_state(scene.clone.character,false)})
	remaining -= 1
	if remaining == 0:
		get_tree().paused = true
		call_deferred("reply")

func _process(_delta: float) -> void:
	if remaining > 0 or not OS.has_feature("web"): return
	var path := "/replay%d.json" % (old_id+1)
	if not FileAccess.file_exists(path): return
	var command = JSON.parse_string(FileAccess.get_file_as_string(path))
	if command is Dictionary:
		old_id = int(command["id"])
		apply(command)
