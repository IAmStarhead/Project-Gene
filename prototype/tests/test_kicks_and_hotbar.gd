## Real input / automatic physics plus read-only native-track kick sweeps.
## No renderer/FPS or artistic-acceptance claim is made by this suite.
extends SceneTree
const Moves := preload("res://scripts/move_catalog.gd")
const HitCheck := preload("res://scripts/hit_check.gd")
const T := preload("res://scripts/tuning.gd")
var checks := 0
var failures := 0
var frames := 0
var world: Node3D
var player
var receiver

class Receiver extends Node3D:
	var hits := 0
	var damage := 0.0
	var accepted := true
	var alive := true
	var last: Dictionary = {}
	func is_alive() -> bool: return alive
	func receive_hit(amount: float, hit: Dictionary) -> bool:
		hits += 1
		last = hit.duplicate()
		if accepted: damage += amount
		return accepted

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
		frames += 1
func key(code: int, walk_modifier: bool = false) -> void:
	var e := InputEventKey.new()
	e.pressed = true
	e.physical_keycode = code
	e.alt_pressed = walk_modifier
	root.push_input(e)
	var up := InputEventKey.new()
	up.physical_keycode = code
	root.push_input(up)
func attack_event() -> void:
	var e := InputEventAction.new()
	e.action = "attack"
	e.pressed = true
	player._unhandled_input(e)
func floor_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	body.position = pos
	world.add_child(body)
	return body
func fixture() -> void:
	player.set_physics_process(true)
	player.position = Vector3(0,.05,0)
	player.rotation = Vector3.ZERO
	player.velocity = Vector3.ZERO
	player.lock.clear()
	player._action = ""
	player._attack_kind = "straight"
	player._kick_planting = false
	player._action_time = 0
	player.training_blade = false
	player.stamina = 100
	player._buf_attack = player.BUF_NEVER
	player._buf_primary_slot = -1
	player._buf_secondary = player.BUF_NEVER
	player._buf_hook = player.BUF_NEVER
	player._buf_dodge = player.BUF_NEVER
	player._jump_buffer = player.BUF_NEVER
	player.character.reset_motion(true)
	receiver.position = Vector3(0,0,-.90)
	receiver.hits = 0
	receiver.damage = 0
	receiver.accepted = true
	receiver.alive = true
	receiver.last = {}
	await tick(12)

func run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	floor_box(Vector3(0,-.1,0),Vector3(20,.2,20))
	player = load("res://scenes/player.tscn").instantiate()
	world.add_child(player)
	player.rig.set_process(false)
	receiver = Receiver.new()
	receiver.add_to_group("damageable")
	world.add_child(receiver)
	await fixture()
	check(player.is_on_floor(),"fixture uses actual collision floor")
	check(player.selected_attack_slot == 0,"default LMB remains the old left jab")
	var digits := [KEY_1,KEY_2,KEY_3,KEY_4,KEY_5,KEY_6,KEY_7,KEY_8,KEY_9,KEY_0]
	for i in 10:
		key(digits[i])
		check(player.selected_attack_slot == i and player._action == "" and player.stamina == 100,
			"digit %d selects, does not attack/spend stamina" % ((i+1)%10))
		check(Moves.slot_profile(i).is_empty() == (i >= 6),"six real moves; 7/8/9/0 explicitly empty")
		if i >= 6:
			attack_event()
			await tick(1)
			check(player._action == "" and player.stamina == 100,"empty slot cannot silently fall back to a punch")
	key(KEY_5,true)
	check(player.selected_attack_slot == 4,"number selection still works with the original Left Alt WALK modifier held")
	key(KEY_KP_4)
	check(player.selected_attack_slot == 3,"numeric keypad supported, physical AZERTY row is independent of text")
	var selected: int = player.selected_attack_slot
	paused = true
	key(KEY_6)
	check(player.selected_attack_slot == selected,"paused player does not consume combat-selection input")
	paused = false
	var slots: Control = player.hud._move_slots
	check(slots.player == player and slots.SLOT_COUNT == 10 and slots._profiles.size() == 10,
		"actual HUD reads the same ten-slot catalog and player selection")
	# Selecting another number after a click changes the NEXT choice only.
	key(KEY_4); attack_event(); key(KEY_5)
	await tick(1)
	check(player._attack_kind == "front_kick" and player.selected_attack_slot == 4,
		"buffer captures the chosen move at click; no mid-windup replacement")
	await tick(70)
	for outfit in ["dress","suit"]:
		player.character.appearance.set_outfit(outfit)
		for slot in [3,4,5]:
			await fixture()
			var profile := Moves.slot_profile(slot)
			key(digits[slot]); attack_event()
			await tick(1)
			check(player._attack_kind == profile.kind and player._attack_side == profile.side and player._action == "attack",
				"actual selected kick starts in "+outfit)
			check(absf(player.stamina-(100-float(profile.stamina))) < .0001,"new move spends its authored cost once")
			var timing: Vector3 = profile.timing
			var saw_hand_trail := false
			var active_frames := 0
			var max_display_error := 0.0
			var support_points: Array[Vector3] = []
			var reacted := false
			for i in ceili((timing.x+timing.y+timing.z+.15)*60):
				await tick(1)
				saw_hand_trail = saw_hand_trail or player.strike_air.visible
				if player._action == "attack" and player._action_time < timing.x:
					check(receiver.hits == 0,"no kick damage before its own active window")
				if not reacted and player._action_time >= timing.x-.04:
					reacted = true
					player.receive_hit(1,{"zone":"torso","direction_world":Vector3.RIGHT})
				if player._action == "attack" and player._action_time >= timing.x and player._action_time <= timing.x+timing.y:
					active_frames += 1
					var pose: Array[Transform3D] = player.character.sample_joint_transforms(profile.clip,player._action_time)
					for bone_name in ["shin.","foot.","toe."]:
						var b: int = player.character.skeleton.find_bone(bone_name+profile.side)
						max_display_error = maxf(max_display_error,pose[b].origin.distance_to(player.character.skeleton.get_bone_global_pose(b).origin))
					var support: int = player.character.skeleton.find_bone("toe."+("R" if profile.side == "L" else "L"))
					support_points.append(player.character.skeleton.global_transform*player.character.skeleton.get_bone_global_pose(support).origin)
			check(active_frames >= 6 and max_display_error < .003,
				"authored leg sweep aligns with DISPLAYED blended/corrected native leg within 3 mm, even during concurrent hit")
			var support_drift := 0.0
			for point in support_points:
				var offset := point-support_points[0]
				support_drift = maxf(support_drift,Vector2(offset.x,offset.z).length())
			check(support_drift < .012,"actual planted forefoot pivots without a translating support slide in active kick")
			check(receiver.hits == 1 and absf(receiver.damage-float(profile.damage)) < .0001,
				"one confirmed leg contact / authored damage: "+String(profile.kind)+" / "+outfit)
			check(receiver.last.get("source","") == "authored_leg_sweep"
				and receiver.last.get("zone","") == ("legs" if slot == 4 else "torso"),
				"kick uses foot/shin approximate contact, never a fist fallback or selected zone")
			check(not saw_hand_trail,"new kicks do not draw the hand-only StrikeAir effect")
			check(player._action == "" and player.is_on_floor(),"new kick fully recovers on floor")
			# Read-only FK must agree with actual imported Godot bone globals.
			player.set_physics_process(false)
			for at in [0.0,timing.x,timing.x+timing.y*.5,timing.x+timing.y]:
				player.character.seek_clip(profile.clip,at)
				var poses: Array[Transform3D] = player.character.sample_joint_transforms(profile.clip,at)
				var error := 0.0
				for b in player.character.skeleton.get_bone_count():
					error = maxf(error,poses[b].origin.distance_to(player.character.skeleton.get_bone_global_pose(b).origin))
				check(error < .00001,"sampled sweep FK matches actual native rig without mutating it")
			# A single long tick skips the entire active interval, still once.
			receiver.hits = 0; receiver.damage = 0
			player._start_attack(profile.kind)
			player._process_attack(timing.x-.01)
			check(receiver.hits == 0,"skipped-window setup remains in preparation")
			player._process_attack(timing.y+.04)
			player._process_attack(.08)
			check(receiver.hits == 1,"long tick cannot miss or duplicate the bounded active sweep")
			# No invisible chest-height shortcut for a too-far / behind target.
			for target in [Vector3(0,0,-2),Vector3(0,0,.9)]:
				receiver.position = target
				check(HitCheck.find_kick_hit(player,[receiver],Vector3.FORWARD,profile.kind,timing.x,timing.x+timing.y).is_empty(),
					"kick range and facing really reject target")
			receiver.position = Vector3(0,0,-.90)
			receiver.alive = false
			check(HitCheck.find_kick_hit(player,[receiver],Vector3.FORWARD,profile.kind,timing.x,timing.x+timing.y).is_empty(),"dead target ignored")
			receiver.alive = true
			var wall := floor_box(Vector3(0,.9,-.45),Vector3(2,1.8,.08))
			await tick(1)
			check(HitCheck.find_kick_hit(player,[receiver],Vector3.FORWARD,profile.kind,timing.x,timing.x+timing.y).is_empty(),"world geometry blocks new kick contact")
			wall.free()
			await tick(1)
			# Accepted and rejected contacts are distinct; i-frames consume an
			# attempt, they do not allow a late second hit once protection ends.
			receiver.accepted = false; receiver.hits = 0; receiver.damage = 0
			player._start_attack(profile.kind)
			player._process_attack(timing.x+timing.y*.4)
			receiver.accepted = true
			player._process_attack(timing.y*.2)
			check(receiver.hits == 1 and receiver.damage == 0 and player._hit_done,"rejected/i-frame contact is consumed once")
			player._buf_dodge = 0
			player._process_attack(.01)
			check(player._action == "attack","cannot dodge-cancel a still-raised kicking leg")
			player._action_time = timing.x+timing.y+timing.z-.02
			player._buf_dodge = 0
			player._process_attack(.005)
			check(player._action == "dodge","authored late cancel works after replant")
			await fixture()
			player.stamina = float(profile.stamina)-1
			key(digits[slot]); attack_event()
			await tick(1)
			check(player._action == "" and receiver.hits == 0,"insufficient stamina cannot start new kick")
	# Moving kicks first brake with the SAME controller constant. They do
	# not slide a nominally planted kick under a still-sprinting capsule.
	for sprinting in [false,true]:
		await fixture()
		Input.action_press("move_right")
		if sprinting: Input.action_press("run")
		await tick(26)
		var before_speed: float = Vector2(player.velocity.x,player.velocity.z).length()
		key(KEY_4); attack_event(); await tick(1)
		check(player._kick_planting and player._action_time == 0,"moving kick responds by visibly preparing its support")
		Input.action_release("move_right"); Input.action_release("run")
		var braking_frames := 0
		while player._kick_planting and braking_frames < 30:
			var before: float = player.velocity.x
			await tick(1)
			braking_frames += 1
			check(absf(player.velocity.x-maxf(0,before-T.DECELERATION/60)) < .0001 and player._action_time == 0,
				"same deceleration / no authored leg lift or hidden damage before plant")
		check(braking_frames >= (16 if sprinting else 8) and braking_frames <= 18
			and absf(before_speed-(T.RUN_SPEED if sprinting else T.JOG_SPEED)) < .001,
			"real full-speed jog/sprint braking before the NEW kick, no old gait/physics retime")
		var planted: Vector3 = player.global_position
		var root_slide := 0.0
		var active := false
		for i in 65:
			await tick(1)
			if player._action == "attack":
				var offset: Vector3 = player.global_position-planted
				root_slide = maxf(root_slide,Vector2(offset.x,offset.z).length())
				active = active or player._action_time >= .30
		check(active and root_slide < .00001,"new kick's weight transfer/lift/contact/recovery start ONLY after the body has really stopped")
	await fixture()
	key(KEY_6); attack_event(); await tick(5)
	player._jump_buffer = 0
	await tick(5)
	check(player.is_on_floor() and player.velocity.y <= 0,"cannot add a jump impulse to a planted grounded kick")
	player.position.y = 1.0
	await tick(3)
	check(not player.is_on_floor() and player._action == "" and not player._kick_planting,
		"loss of real floor cancels new grounded kick; no invisible air-foot or punch fallback")
	# Existing direct inputs and the contextual training mode remain exact.
	await fixture()
	player.selected_attack_slot = 5
	player.training_blade = true
	key(KEY_2)
	check(player.training_limb == 1 and player.selected_attack_slot == 5,"V mode preserves legacy 1..4 limb meanings and saved unarmed choice")
	attack_event(); await tick(1)
	check(player._attack_kind == "straight" and player._attack_blade,"training LMB remains captured left cut, never a selected foot cut")
	await fixture()
	player.selected_attack_slot = 5
	var right := InputEventAction.new()
	right.action = "attack_secondary"; right.pressed = true
	player._unhandled_input(right); await tick(1)
	check(player._attack_kind == "straight" and player._attack_side == "R","RMB remains right punch regardless of hotbar")
	await fixture()
	var hook := InputEventAction.new()
	hook.action = "attack_hook"; hook.pressed = true
	player._unhandled_input(hook); await tick(1)
	check(player._attack_kind == "hook" and T.HOOK_DAMAGE == 30,"Q remains exact current 30-damage hook")
	await fixture()
	player._jump_buffer = 0
	await tick(8)
	key(KEY_4); attack_event()
	await tick(1)
	check(not player.is_on_floor() and player._action == "","ground-only kicks do not silently become upper-body air punches")
	await tick(65)
	check(player._action == "","expired aerial click does not attack after landing")
	player._buf_primary_slot = 5
	player.receive_hit(10000,{"zone":"torso","direction_world":Vector3.FORWARD})
	check(player._buf_primary_slot == -1 and player._action == "","respawn clears selected-move input buffer as well as old buffers")
	world.free()
	await process_frame
	OS.delay_msec(100)
	print("GEN kicks-hotbar suite: %d checks, %d failures; %d actual physics frames" % [checks,failures,frames])
	quit(1 if failures else 0)
