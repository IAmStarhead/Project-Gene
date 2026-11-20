## Training sword is a visual prop: original hit and inventory rules stay intact.
extends SceneTree
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func press_v(player: Node) -> void:
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_V
	player._unhandled_input(event)

func meshes(node: Node) -> Array:
	var result := []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(meshes(child))
	return result

func _run() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame
	var p = scene.player
	var sword = p.training_sword
	check(sword != null and is_instance_valid(sword.visual), "actual imported sword scene is attached")
	check(not sword.visual.visible and not p.training_blade, "sword starts hidden")
	check(sword.sockets["R"].bone_idx == p.character.skeleton.find_bone("hand.R")
		and sword.sockets["L"].bone_idx == p.character.skeleton.find_bone("hand.L"), "both sockets bind actual hand bones")
	var models := meshes(sword.visual)
	check(models.size() > 0 and models[0].has_meta("weapon_visual"), "sword has a tagged visible mesh")
	if not models.is_empty():
		var mi: MeshInstance3D = models[0]
		var material: Material = mi.mesh.surface_get_material(0)
		check(material is BaseMaterial3D and (material as BaseMaterial3D).albedo_color.a > .99,
			"imported sword material is opaque and remains visible")
	press_v(p)
	check(p.training_blade and sword.visual.visible and sword.side == "R", "V shows sword in right hand")
	var mi: MeshInstance3D = models[0]
	var original_material: Material = mi.mesh.surface_get_material(0)
	scene._apply_style_to_characters()
	check(mi.mesh.surface_get_material(0) == original_material and mi.material_override == null,
		"room style does not replace sword materials")
	check(not scene.clone.has_node("Character/TrainingSwordVisual"), "clone is not given the player's sword")
	scene._toggle_outfit()
	check(sword.visual.visible and is_instance_valid(sword.visual.get_parent()), "sword survives outfit switch")
	scene._toggle_outfit()
	p.rig._set_hero_visible(false)
	check(not sword.visual.is_visible_in_tree(), "near-wall hero hiding also hides sword")
	p.rig._set_hero_visible(true)
	check(sword.visual.is_visible_in_tree(), "sword reappears with hero")
	p._attack_side = "L"
	p._start_attack()
	check(p._attack_blade and sword.visual.visible and sword.side == "L"
		and sword.visual.get_parent() == sword.sockets["L"], "left cut attaches sword to striking hand")
	press_v(p)
	check(not p.training_blade and sword.visual.visible, "V off mid-cut keeps prop until captured cut ends")
	p._action = ""
	p._sync_training_sword()
	check(not sword.visual.visible, "prop hides after cut ends")
	p._attack_side = "R"
	p._start_attack()
	press_v(p)
	check(p.training_blade and not p._attack_blade and not sword.visual.visible,
		"V on mid-punch does not imply that ordinary punch can cut")
	p._action = ""
	p._sync_training_sword()
	check(sword.visual.visible, "prop appears when ordinary punch has ended")
	p._attack_side = "R"
	p._start_attack()
	check(p._attack_blade and sword.side == "R" and sword.visual.get_parent() == sword.sockets["R"],
		"right cut attaches sword to right hand")
	# The grip is close to the hand in all approved punch poses; no new
	# animation or game hit test was authored by the visual attachment.
	p.character.seek_clip("attack_right", .18)
	await process_frame
	var sk: Skeleton3D = p.character.skeleton
	var hand_world := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hand.R"))
	check(sword.sockets["R"].global_position.distance_to(hand_world.origin) < .001,
		"socket follows posed hand")
	check(sword.visual.global_position.distance_to(hand_world.origin) < .09,
		"handle remains near wrist in attack")
	p._action = ""
	p.training_blade = true
	p._update_character_anim(1.0 / 60.0, Vector3.ZERO)
	check(p.character.appearance.hand_open < 1.0, "weapon mode closes the relaxed hands for a grip")
	scene.queue_free()
	await process_frame
	print("Training sword suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
