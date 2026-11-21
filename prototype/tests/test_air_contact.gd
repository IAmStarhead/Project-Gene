## Settled real gameplay and automatic jump / ledge physics, BOTH costumes
## and stances. Dense soles are measured independently from runtime probes.
extends SceneTree
const DenseSoles := preload("res://tests/native_soles.gd")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
var physics_frames := 0
var world: Node3D
var player
var samples: Array = []
var platform: StaticBody3D

func _initialize() -> void: call_deferred("run")
func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ",description)
func tick(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame
		physics_frames += 1
func record(label: String, stationary: bool) -> void:
	var soles := DenseSoles.measure(player.character)
	var start: Vector3 = player.global_position+Vector3.UP*.05
	var query := PhysicsRayQueryParameters3D.create(start,start+Vector3.DOWN*2,1)
	var hit: Dictionary = world.get_world_3d().direct_space_state.intersect_ray(query)
	check(not hit.is_empty(),"diagnostic ray finds real floor under "+label)
	if hit.is_empty(): return
	var floor_y: float = hit.position.y
	var left := float(soles.left_world_y)-floor_y
	var right := float(soles.right_world_y)-floor_y
	var collision: CollisionShape3D = player.get_node("Collision")
	var collider_bottom: float = collision.global_position.y-(collision.shape as CapsuleShape3D).height*.5
	check(soles.vertices > 2000,"measurement uses complete dense imported skin, not ankles or reduced probes")
	check(minf(left,right) > -.001,"no visible-sole penetration in "+label)
	if stationary:
		check(maxf(left,right) < .007,"both actual soles settle within 7 mm of floor: "+label)
		check(absf(collider_bottom-floor_y) < .005,"collider bottom agrees with real support plane: "+label)
	samples.append(soles.merged({"stage":label,"outfit":player.character.appearance.outfit,
		"combat":player.combat_mode,"body_y":player.global_position.y,"floor_y":floor_y,
		"left_gap":left,"right_gap":right,"collider_bottom":collider_bottom,
		"grounded":player.is_on_floor(),"state":player.character._state}))
func fixture(combat: bool) -> void:
	for action in ["move_left","move_right","move_forward","move_back","walk_slow","run"]:
		Input.action_release(action)
	platform.position.x = 30
	player.position = Vector3(0,.08,2.5)
	player.velocity = Vector3.ZERO
	player.rotation = Vector3.ZERO
	player.yaw = 0
	player._action = ""
	player.combat_mode = combat
	player._jump_buffer = player.BUF_NEVER
	player.character.reset_motion(combat)
	await tick(30)

func run() -> void:
	world = load("res://scenes/main.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	player = world.player
	player.rig.set_process(false)
	world.clone.set_physics_process(false)
	platform = StaticBody3D.new()
	platform.position = Vector3(30,.5,2.5)
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4,1.0,2.0)
	collider.shape = box
	platform.add_child(collider)
	world.add_child(platform)
	for outfit in ["dress","suit"]:
		player.character.appearance.set_outfit(outfit)
		# Controlled reproduction of the diagnostic mistake, NOT gameplay:
		# freezing the real starting root 8 cm over the collision plane.
		# The old screenshot's original driver is not available, so this
		# demonstrates the mechanism without claiming its exact provenance.
		player.set_physics_process(false)
		player.position = Vector3(0,.08,2.5)
		player.character.reset_motion(false)
		await tick(1)
		record("DIAGNOSTIC-frozen-spawn-not-gameplay",false)
		var frozen := DenseSoles.measure(player.character)
		check(minf(frozen.left_world_y,frozen.right_world_y) > .070,"freezing at spawn reproduces an apparent centimetre-scale gap")
		player.set_physics_process(true)
		for combat in [false,true]:
			await fixture(combat)
			record("settled-idle",true)
			for moving in [false,true]:
				await fixture(combat)
				if moving:
					Input.action_press("move_left")
					await tick(14)
				var base_y: float = player.position.y
				player._jump_buffer = 0
				var max_height := 0.0
				var seen_air := false
				var landed := false
				var air_frames := 0
				var previous_foot: Vector3 = player.character.skeleton.get_bone_global_pose(player.character.skeleton.find_bone("foot.L")).origin
				var max_local_foot_step := 0.0
				for i in 76:
					await tick(1)
					max_height = maxf(max_height,player.position.y-base_y)
					var foot: Vector3 = player.character.skeleton.get_bone_global_pose(player.character.skeleton.find_bone("foot.L")).origin
					max_local_foot_step = maxf(max_local_foot_step,foot.distance_to(previous_foot))
					previous_foot = foot
					if not player.is_on_floor():
						seen_air = true
						air_frames += 1
					if i == 0:
						check(player.velocity.y > 0 and player.position.y-base_y > .02,"launch remains immediate, no anticipation delay")
					if not player.is_on_floor() and absf(player.velocity.y) < .8:
						var sk: Skeleton3D = player.character.skeleton
						var left := sk.get_bone_global_pose(sk.find_bone("hand.L")).origin
						var right := sk.get_bone_global_pose(sk.find_bone("hand.R")).origin
						check(left.x > .255 and right.x < -.255,
							"apex forearms carry outside the raised retained hem, not back through the skirt; full skin/FCL remains separate")
					if seen_air and player.is_on_floor() and not landed:
						landed = true
						record("moving-touchdown" if moving else "stationary-touchdown",not moving)
					if not combat and player.character._state == "land":
						var hand: Vector3 = player.character.skeleton.get_bone_global_pose(player.character.skeleton.find_bone("hand.L")).origin
						check(hand.y < 1.15,"ordinary landing does not route through a face-level guard")
				check(seen_air and landed and player.is_on_floor(),"full jump returns through real collision contact")
				check(max_height > 1.0 and max_height < 1.25 and air_frames >= 36 and air_frames <= 45,
					"existing physical trajectory / airtime retained for both stances and outfits")
				check(max_local_foot_step < (.18 if moving else .10),"bounded continuous local foot motion, including apex/contact")
				Input.action_release("move_left")
				await tick(36)
				record("moving-stop-settled" if moving else "jump-settled",true)
			# Walk off a REAL one-metre fixture. No jump input, pose injection,
			# root animation or fake vertical velocity inside this take.
			await fixture(combat)
			platform.position.x = 0
			player.position = Vector3(0,1.05,2.5)
			player.velocity = Vector3.ZERO
			player.character.reset_motion(combat)
			await tick(15)
			check(player.is_on_floor() and player.position.y > .99,"ledge fixture is physical, not a floating frozen rig")
			Input.action_press("move_right")
			Input.action_press("walk_slow")
			var left_edge := false
			var found_contact := false
			for i in 145:
				await tick(1)
				if not player.is_on_floor():
					left_edge = true
					check(not player.character._air_launched,"step-off has no takeoff impulse / apex tuck")
				if left_edge and player.is_on_floor():
					found_contact = true
					break
			check(left_edge and found_contact,"ledge descent reaches real lower floor")
			Input.action_release("move_right"); Input.action_release("walk_slow")
			await tick(40)
			record("ledge-settled",true)
	for action in ["move_left","move_right","walk_slow"]: Input.action_release(action)
	var output_path := OS.get_environment("GEN_AIR_CONTACT")
	if not output_path.is_empty():
		var output := FileAccess.open(output_path,FileAccess.WRITE)
		output.store_string(JSON.stringify({"physics_hz":60,"physics_frames":physics_frames,
			"source":"actual main.tscn / automatic player controller; physical ledge fixture only; complete native foot skin",
			"samples":samples},"  "))
	world.free()
	await process_frame
	OS.delay_msec(100)
	print("GEN air-contact suite: %d checks, %d failures; %d actual physics frames" % [checks,failures,physics_frames])
	quit(1 if failures else 0)
