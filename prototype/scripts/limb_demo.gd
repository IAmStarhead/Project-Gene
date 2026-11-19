## Изолированный макет: заранее подготовленная культя и этапы отрастания.
## Только манекен; с реальной героиней и боевой системой пока не связан.
extends Node3D

enum State { INTACT, GROWING, BLOCKED }
const GROW_SECONDS := 8.0 # Ускорено для демонстрации, не игровой баланс.
const FULL_MAX_HEALTH := 100.0
const LOST_ARM_MAX_HEALTH := 85.0

var state := State.INTACT
var progress := 0.0
var max_health := FULL_MAX_HEALTH
var health := FULL_MAX_HEALTH
var intact_forearm: Node3D
var stump: Node3D
var growth_stages: Array[Node3D] = []
var debris: RigidBody3D
var status: Label
var skin_mat: StandardMaterial3D
var wound_mat: StandardMaterial3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	skin_mat = _material(Color(0.76, 0.58, 0.51))
	wound_mat = _material(Color(0.42, 0.12, 0.13))
	_build_world()
	_build_manikin()
	_build_ui()
	_update_visuals()


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = pos
	node.material_override = mat
	parent.add_child(node)
	return node


func _build_world() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(.12, .16, .20)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(.83, .88, .94)
	env.ambient_light_energy = 0.75
	environment.environment = env
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -25, 0)
	add_child(light)
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	_box(floor_body, Vector3(5, .08, 5), Vector3(0, -.06, 0), _material(Color(.28, .32, .35)))
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(5, .08, 5)
	floor_collision.shape = floor_shape
	floor_collision.position = Vector3(0, -.06, 0)
	floor_body.add_child(floor_collision)
	var camera := Camera3D.new()
	camera.position = Vector3(2.4, .85, 4.7)
	camera.current = true
	camera.fov = 32
	add_child(camera)
	camera.look_at(Vector3(0, 1.05, 0), Vector3.UP)


func _build_manikin() -> void:
	var shirt := _material(Color(.76, .82, .85))
	_box(self, Vector3(.55, .65, .26), Vector3(0, 1.22, 0), shirt)
	_box(self, Vector3(.27, .31, .24), Vector3(0, 1.72, 0), skin_mat)
	_box(self, Vector3(.20, .75, .21), Vector3(-.14, .43, 0), skin_mat)
	_box(self, Vector3(.20, .75, .21), Vector3(.14, .43, 0), skin_mat)
	_box(self, Vector3(.17, .54, .18), Vector3(-.38, 1.21, 0), skin_mat)
	_box(self, Vector3(.17, .54, .18), Vector3(.38, 1.21, 0), skin_mat)
	_box(self, Vector3(.15, .47, .16), Vector3(-.38, .71, 0), skin_mat)
	# Обычное предплечье и закрывающая срез культя существуют заранее.
	intact_forearm = Node3D.new()
	intact_forearm.name = "IntactForearm"
	add_child(intact_forearm)
	_box(intact_forearm, Vector3(.15, .47, .16), Vector3(.38, .71, 0), skin_mat)
	_box(intact_forearm, Vector3(.15, .16, .12), Vector3(.38, .42, 0), skin_mat)
	stump = Node3D.new()
	stump.name = "PreparedStumpHiddenInsideArm"
	add_child(stump)
	_box(stump, Vector3(.155, .022, .165), Vector3(.38, .935, 0), wound_mat)
	# Условные предварительно подготовленные стадии; не анатомическая модель.
	for height in [.12, .28]:
		var stage := Node3D.new()
		stage.name = "PreparedGrowthStage%d" % (growth_stages.size() + 1)
		add_child(stage)
		_box(stage, Vector3(.13, height, .14), Vector3(.38, .94 - height / 2, 0), skin_mat)
		_box(stage, Vector3(.135, .015, .145), Vector3(.38, .94 - height, 0), wound_mat)
		growth_stages.append(stage)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	layer.add_child(panel)
	var col := VBoxContainer.new()
	panel.add_child(col)
	var title := Label.new()
	title.text = "МАКЕТ / ПРЕДПЛЕЧЬЕ\nУсловная модель, не героиня"
	col.add_child(title)
	status = Label.new()
	col.add_child(status)
	_button(col, "Обычное лезвие — отсечь", _ordinary)
	_button(col, "Особый материал — отсечь", _special)
	_button(col, "Станция — восстановить", restore_at_station)
	_button(col, "Сбросить макет", reset_demo)


func _button(parent: Node, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)


func _ordinary() -> void:
	sever(false)


func _special() -> void:
	sever(true)


func sever(blocked: bool) -> void:
	if state != State.INTACT:
		return
	state = State.BLOCKED if blocked else State.GROWING
	progress = 0.0
	max_health = LOST_ARM_MAX_HEALTH
	health = minf(health, max_health)
	_spawn_detached()
	_update_visuals()


func _spawn_detached() -> void:
	_clear_debris()
	debris = RigidBody3D.new()
	debris.name = "DetachedForearm"
	debris.position = Vector3(.38, .71, 0)
	_box(debris, Vector3(.15, .47, .16), Vector3.ZERO, skin_mat)
	_box(debris, Vector3(.15, .16, .12), Vector3(0, -.29, 0), skin_mat)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(.15, .50, .16)
	collision.shape = shape
	debris.add_child(collision)
	add_child(debris)
	# Минимальная демонстрационная площадка столкновений.
	debris.linear_velocity = Vector3(.5, .2, 0)


func _clear_debris() -> void:
	if is_instance_valid(debris):
		debris.queue_free()
	debris = null


func _physics_process(delta: float) -> void:
	_advance_regrowth(delta)


func _advance_regrowth(delta: float) -> void:
	if state != State.GROWING:
		return
	progress = minf(GROW_SECONDS, progress + maxf(0.0, delta))
	if progress >= GROW_SECONDS:
		state = State.INTACT
		max_health = FULL_MAX_HEALTH
	_update_visuals()


func restore_at_station() -> void:
	state = State.INTACT
	progress = 0.0
	max_health = FULL_MAX_HEALTH
	health = FULL_MAX_HEALTH
	_clear_debris()
	_update_visuals()


func reset_demo() -> void:
	restore_at_station()


func _update_visuals() -> void:
	intact_forearm.visible = state == State.INTACT
	stump.visible = state != State.INTACT and (state != State.GROWING or progress < GROW_SECONDS / 3.0)
	for stage in growth_stages:
		stage.visible = false
	if state == State.GROWING:
		if progress >= GROW_SECONDS * 2.0 / 3.0:
			growth_stages[1].visible = true
		elif progress >= GROW_SECONDS / 3.0:
			growth_stages[0].visible = true
	var state_name := "цела" if state == State.INTACT else "заблокировано" if state == State.BLOCKED else "растёт: %.0f%%" % (progress / GROW_SECONDS * 100.0)
	status.text = "Рука: %s\nЗдоровье: %.0f / %.0f" % [state_name, health, max_health]
