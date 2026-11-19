extends SceneTree

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func _run() -> void:
	var demo = load("res://scenes/limb_demo.tscn").instantiate()
	root.add_child(demo)
	current_scene = demo
	demo.set_physics_process(false)
	check(demo.intact_forearm.visible and not demo.stump.visible, "intact arm hides prepared stump")
	check(not demo.growth_stages[0].visible and not demo.growth_stages[1].visible, "growth pieces hidden while intact")
	demo.sever(false)
	check(not demo.intact_forearm.visible and demo.stump.visible and is_instance_valid(demo.debris), "sever reveals stump and spawns detached piece")
	check(is_equal_approx(demo.max_health, 85.0) and is_equal_approx(demo.health, 85.0), "max health falls")
	for i in 120:
		await physics_frame
	check(is_instance_valid(demo.debris) and demo.debris.global_position.y > 0.0, "detached piece lands on floor")
	demo._advance_regrowth(demo.GROW_SECONDS / 2.0)
	check(demo.growth_stages[0].visible and not demo.growth_stages[1].visible and not demo.stump.visible, "first growth stage replaces stump cap with its prepared tip")
	demo._advance_regrowth(demo.GROW_SECONDS / 4.0)
	check(not demo.growth_stages[0].visible and demo.growth_stages[1].visible, "second growth stage")
	demo._advance_regrowth(demo.GROW_SECONDS)
	check(demo.state == demo.State.INTACT and demo.intact_forearm.visible and not demo.stump.visible, "normal wound regrows")
	check(is_equal_approx(demo.max_health, 100.0), "regrowth restores max")
	demo.sever(true)
	check(demo.state == demo.State.BLOCKED and demo.stump.visible, "special blade blocks regrowth")
	demo._advance_regrowth(100.0)
	demo.sever(false)
	check(demo.state == demo.State.BLOCKED and demo.progress == 0.0, "ordinary cut cannot unblock old injury")
	demo.restore_at_station()
	check(demo.state == demo.State.INTACT and demo.intact_forearm.visible and not demo.stump.visible, "station restores blocked limb")
	check(is_equal_approx(demo.max_health, 100.0) and is_equal_approx(demo.health, 100.0) and demo.debris == null, "station restores health and removes debris")
	demo.queue_free()
	await process_frame
	print("Limb demo suite: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
