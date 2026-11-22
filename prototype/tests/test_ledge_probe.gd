## Real physics rays and capsule-overlap checks for a future climbing prototype.
extends SceneTree
const Probe := preload("res://scripts/ledge_probe.gd")
var checks := 0
var failures := 0
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)
func _initialize() -> void:
	call_deferred("run")
func box(size: Vector3, pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	root.add_child(body)
	body.position = pos
	return body
func run() -> void:
	var floor := box(Vector3(20,.2,20), Vector3(0,-.1,0))
	var ledge := box(Vector3(2,2,1), Vector3(0,1,0))
	ledge.add_to_group("climbable_ledge")
	var actor := CharacterBody3D.new()
	actor.collision_layer = 2
	actor.collision_mask = 5
	var col := CollisionShape3D.new()
	col.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = .34
	capsule.height = 1.70
	col.shape = capsule
	col.position.y = .85
	actor.add_child(col)
	root.add_child(actor)
	actor.global_position = Vector3(0,.2,1.15)
	await physics_frame
	var result := Probe.find_candidate(actor, Vector3.FORWARD)
	check(not result.is_empty(), "marked ledge found from front")
	if not result.is_empty():
		check(result.surface == ledge and result.normal.z > .99, "actual front surface and normal")
		check(absf(result.edge.y-2.0) < .01 and absf(result.edge.z-.5) < .01, "edge matches real geometry")
		check(absf(result.landing.y-2.04) < .01 and result.landing.z < .1, "landing is above and safely inside platform")
	check(Probe.find_candidate(actor, Vector3.BACK).is_empty(), "facing away does not grab")
	check(Probe.find_candidate(actor, Vector3.ZERO).is_empty(), "zero direction rejected")
	check(Probe.find_candidate(actor, Vector3(INF, 0, 0)).is_empty(), "non-finite direction rejected")
	actor.global_position.y = 1.0
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "ledge below reach rejected")
	actor.global_position.y = -.5
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "ledge above reach rejected")
	actor.global_position.y = .2
	actor.global_position.x = .85
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "unsupported corner landing rejected")
	actor.global_position.x = 0
	actor.global_position.z = 1.5
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "out-of-range ledge rejected")
	actor.global_position.z = 1.15
	ledge.remove_from_group("climbable_ledge")
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "ordinary walls cannot be grabbed")
	ledge.add_to_group("climbable_ledge")
	var roof := box(Vector3(2,.2,2), Vector3(0,3.0,0))
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "overhead obstruction prevents standing on platform")
	roof.free()
	var blocker := box(Vector3(1,1,.15), Vector3(0,1.4,.8))
	await physics_frame
	check(Probe.find_candidate(actor, Vector3.FORWARD).is_empty(), "wall or obstacle in front blocks ledge")
	blocker.free()
	ledge.free()
	actor.free()
	floor.free()
	await process_frame
	print("Ledge probe suite: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
