## Approved Q + confirmed-zone delivery through the EXISTING hit geometry.
## Logic/native-pose tests, not an anatomical hitbox or GPU acceptance test.
extends SceneTree
const T := preload("res://scripts/tuning.gd")
const HitCheck := preload("res://scripts/hit_check.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const CloneScene := preload("res://scenes/clone.tscn")
const Probe := preload("res://tests/damage_probe.gd")
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

func action(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func _run() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var player: CharacterBody3D = PlayerScene.instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	player.rig.set_process(false)
	check(InputMap.action_get_events("attack_hook")[0].physical_keycode == KEY_Q,
		"Q is a real separate physical binding, not a random LMB variant")
	check(T.ATTACK_REACH == .72 and T.ATTACK_DAMAGE == 24 and T.ATTACK_STAMINA == 18
		and Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY) == Vector3(.18, .12, .26),
		"old jab/cross parameters remain exact")
	var probe := Node3D.new()
	probe.set_script(Probe)
	world.add_child(probe)
	probe.add_to_group("damageable")
	for outfit in ["dress", "suit"]:
		player.character.appearance.set_outfit(outfit)
		for distance in [.25, .84, .90, 1.0]:
			probe.position = Vector3(0, 0, -distance)
			probe.hits = 0
			probe.total_damage = 0
			player._action = ""
			player.stamina = 100
			player._unhandled_input(action("attack_hook"))
			player._try_start_actions()
			check(player._attack_kind == "hook" and player._attack_side == "L"
				and player._action == "attack" and player.stamina == 82,
				"Q deterministically starts approved left hook, spending 18 once")
			check(player._attack_timing() == Vector3(.22, .10, .30), "Q exact .22/.10/.30 clock")
			player._process_attack(.21)
			check(probe.hits == 0, "no hook damage during preparation")
			# Intentionally skip the WHOLE active interval, not just a key.
			player._process_attack(.20)
			player._process_attack(.10)
			check(probe.hits == (1 if distance < .95 else 0), "short hook hit/close/miss after skipped active window")
			check(probe.total_damage == (18 if distance < .95 else 0), "one approved 18 damage, legacy target adapter")
			player._process_attack(.109)
			check(player._action == "attack", "hook recovery persists until .62")
			player._process_attack(.002)
			check(player._action == "", "hook ends at .62, without new stun")
			check(probe.hits <= 1, "never multiple damage for one hook")
		# Live low arc is used at the actual active pose, with short reach.
		probe.position = Vector3(0, 0, -.84)
		var ch: Node3D = player.character
		ch.seek_clip("attack_body_hook", .27)
		ch.skeleton.force_update_all_bone_transforms()
		var live := HitCheck.find_hit(player, [probe], Vector3.FORWARD, .60, T.ATTACK_ANGLE, "L", true, "hook")
		check(live.get("zone") == "torso" and live.get("source") == "live_hand",
			"live active hook confirms approximate torso, not fictitious head targeting")
		check(live.get("point_world", Vector3(INF, INF, INF)).is_finite()
			and (live.get("direction_world", Vector3.ZERO) as Vector3).dot(Vector3.FORWARD) > .999,
			"confirmed hit carries approximate point and explicit attacker->victim WORLD direction")
		player._action = ""
		player.stamina = 17
		player._unhandled_input(action("attack_hook"))
		player._try_start_actions()
		check(player._action == "" and player.stamina == 17, "insufficient stamina cannot start Q")
		player._buf_hook = player.BUF_NEVER
		player._attack_side = "R"
		player._start_attack()
		player._unhandled_input(action("attack_hook"))
		check(player._attack_kind == "straight" and player._attack_side == "R",
			"buffering Q cannot replace an ongoing cross")
		player._buf_hook = player.BUF_NEVER
	probe.free()
	var clone: CharacterBody3D = CloneScene.instantiate()
	world.add_child(clone)
	clone.set_physics_process(false)
	for outfit in ["dress", "suit"]:
		player.character.appearance.set_outfit(outfit)
		clone.character.appearance.set_outfit(outfit)
		await _received_contacts(player, clone)
		_reaction_overlay(player, clone)
	player.free()
	clone.free()
	world.free()
	await process_frame
	print("GEN combat-zone suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _received_contacts(player: CharacterBody3D, clone: CharacterBody3D) -> void:
	player.position = Vector3.ZERO
	player.rotation = Vector3.ZERO
	player.health = 100
	player._invulnerable = false
	player._action = "attack"
	player._action_time = .13
	clone.rotation.y = PI
	clone.mode = clone.Mode.ON
	clone.health = 120
	# Height differences make the existing approximate system actually
	# confirm head contact. Not fake aim-by-zone or new head damage scaling.
	clone.position = Vector3(0, .25, -.84)
	var hp: float = player.health
	check(clone._deal_damage(.84) and player.health == hp-T.CLONE_DAMAGE
		and player.character._hit_zone == "head", "clone -> player confirmed head zone through same geometry")
	check(player._action == "attack" and player._action_time == .13,
		"receiving head hit adds no action interruption/stun")
	clone.position.y = 0
	clone._deal_damage(.84)
	check(player.character._hit_zone == "torso", "level clone contact selects torso response")
	player._invulnerable = true
	hp = player.health
	player.character._hit_time = .17
	clone._deal_damage(.84)
	check(player.health == hp and player.character._hit_time == .17, "dodge i-frame rejects BOTH damage and reaction")
	player._invulnerable = false
	player.position.y = .25
	clone._attack_time = .14
	player._attack_side = "L"
	player._start_attack()
	check(player._do_hit(false) and clone.character._hit_zone == "head" and clone.health == 96,
		"player -> clone confirmed head zone, old 24 damage unchanged")
	check(clone._attack_time == .14, "clone's concurrent attack clock is not reset by flinch")
	player.position.y = 0
	player._do_hit(false)
	check(clone.character._hit_zone == "torso" and clone.health == 72, "level player contact selects torso")
	clone.mode = clone.Mode.OFF
	clone._idle_awake = 0
	var clone_hp: float = clone.health
	player._do_hit(false)
	check(clone.health == clone_hp and clone.character._hit_time == 0 and clone._idle_awake > .5,
		"passive clone still costs no HP but wakes for a visible zone response")
	clone.mode = clone.Mode.ON
	player.lock.target = clone
	clone.receive_hit(1000, {"zone": "head", "direction_world": Vector3.FORWARD})
	check(clone.mode == clone.Mode.OFF and clone.health == 120 and not player.lock.active()
		and clone._attack_time < 0 and clone.character._hit_time > 1,
		"clone death/respawn clears lock/attack/reaction, preserves wardrobe")
	player._buf_hook = 0
	player._attack_kind = "hook"
	player.receive_hit(1000, {"zone": "torso", "direction_world": Vector3.BACK})
	check(player.health == 100 and player.stamina == 100 and player._buf_hook > 1 and player._action == ""
		and player.character._hit_time > 1, "player respawn clears queued hook, action and reaction")
	player.show_details = true
	player._write_debug_label()
	check(player.label.text.contains("Реакция") and player.label.text.contains("Получено")
		and player.label.text.contains("Костюм"), "F3 exposes zone/direction/wardrobe, not only a flash")
	await process_frame

func _reaction_overlay(player: CharacterBody3D, clone: CharacterBody3D) -> void:
	for actor in [player, clone]:
		var ch: Node3D = actor.character
		for combat in [false, true]:
			ch.reset_motion(combat)
			var base: Dictionary = ch.sample_clip("guard" if combat else "idle_relaxed", 0)
			var reactions := {}
			for zone in ["head", "torso", "legs", "unknown"]:
				ch.play_hit(zone, ch.global_basis*Vector3(0, 0, -1))
				ch._hit_time = .055
				var p: Dictionary = ch._add_hit(base, 1.0)
				reactions[zone] = p
				var lower_ok: bool = p["hips"] == base["hips"]
				for i in ch._bone_names.size():
					if i not in ch._upper_body:
						lower_ok = lower_ok and absf(p["rotations"][i].dot(base["rotations"][i])) > .999999
				check(lower_ok, "decorative response does not replace hips/legs in either stance")
			var head: int = ch.skeleton.find_bone("head")
			var chest: int = ch.skeleton.find_bone("chest")
			check(absf(reactions["head"]["rotations"][head].dot(reactions["torso"]["rotations"][head])) < .995,
				"head and torso responses are visibly different, not renamed clips")
			check(absf(reactions["head"]["rotations"][chest].dot(reactions["torso"]["rotations"][chest])) < .995,
				"torso folding differs from head recoil")
			ch.play_hit("head", ch.global_basis*Vector3(-1, 0, 0))
			ch._hit_time = .055
			var left: Dictionary = ch._reaction_pose()
			var expected: Dictionary = ch.sample_clip("hit_head_left", .055)
			check(absf(left["rotations"][head].dot(expected["rotations"][head])) > .999999,
				"WORLD incoming direction converts to character-local anatomical left")
			ch.play_hit("bad zone", Vector3(INF, 0, 0))
			check(ch._hit_zone == "unknown" and ch._hit_direction == Vector3(0, 0, -1),
				"unknown zone/non-finite direction safely fall back to legacy response")
			for i in 3:
				ch.play_hit("torso", Vector3.ZERO)
				ch.update_motion(.055, Vector3(2, 0, 0), "", 0, "R",
					{"grounded": true, "combat": combat, "directional": true, "distance": .1})
			check(ch._state == "ground" and ch.appearance.sole_height() > -.00005,
				"quick repeat reactions during strafe preserve grounded state/floor")
			ch.update_motion(.016, Vector3.ZERO, "", 0, "R", {"grounded": false, "vertical_speed": 2.0, "combat": combat})
			ch.play_hit("head", Vector3.BACK)
			ch.update_motion(.055, Vector3.ZERO, "", 0, "R", {"grounded": false, "vertical_speed": 2.0, "combat": combat})
			check(ch._state == "air", "airborne hit cannot force land/ground or cancel flight")
