## Прототип героини: движение от третьего лица, отзывчивое управление.
##
## Проверяет три вещи без модели и без анимаций:
##   1) ощущение движения и камеры;
##   2) отзывчивость ввода (буфер, отмена атаки уворотом);
##   3) стамину, уворот с неуязвимостью и попадание по цели.
##
## Все числа — в scripts/tuning.gd. Здесь только логика.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")

@onready var pivot: Node3D = $CameraPivot
@onready var spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var character: Node3D = $Character
@onready var label: Label = $UI/DebugLabel

var health: float = T.MAX_HEALTH
var stamina: float = T.MAX_STAMINA

var _yaw: float = 0.0
var _pitch: float = -12.0
var _stamina_cooldown: float = 0.0

# Состояние действия: "" | "attack" | "dodge"
var _action: String = ""
var _action_time: float = 0.0
var _stamina_locked: bool = false

# Буфер ввода: сколько секунд назад нажата кнопка.
# ВАЖНО: значение «не нажимали» должно быть БОЛЬШИМ, а не отрицательным —
# буфер сравнивается по «<= INPUT_BUFFER», и −99 проходил эту проверку,
# из-за чего удар запускался сам, без нажатия кнопки.
const BUF_NEVER := 999.0
var _buf_dodge: float = BUF_NEVER
var _buf_attack: float = BUF_NEVER
var _buf_dir: Vector3 = Vector3.ZERO

var _dodge_dir: Vector3 = Vector3.ZERO
var _invulnerable: bool = false

var _targets: Array = []
var _fps_accum: float = 0.0
var _fps_frames: int = 0
var _fps: float = 0.0
var _last_hit: String = ""


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spring.spring_length = T.CAMERA_DISTANCE
	pivot.position.y = T.CAMERA_HEIGHT
	spring.add_excluded_object(get_rid())
	for n in get_tree().get_nodes_in_group("damageable"):
		_targets.append(n)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * T.MOUSE_SENSITIVITY
		_pitch = clamp(_pitch - event.relative.y * T.MOUSE_SENSITIVITY * 60.0,
			T.CAMERA_PITCH_MIN, T.CAMERA_PITCH_MAX)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("attack"):
		_buf_attack = 0.0
	elif event.is_action_pressed("dodge"):
		_buf_dodge = 0.0
		_buf_dir = _input_direction()


func _input_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input.length() < 0.1:
		return Vector3.ZERO
	var basis_yaw := Basis(Vector3.UP, _yaw)
	return (basis_yaw * Vector3(input.x, 0.0, input.y)).normalized()


func _physics_process(delta: float) -> void:
	_update_buffers(delta)
	_update_camera(delta)
	_update_stamina(delta)

	if _action == "dodge":
		_process_dodge(delta)
	elif _action == "attack":
		_process_attack(delta)
	else:
		_process_move(delta)
		_try_start_actions()

	_update_character_anim(delta)

	# гравитация и движение
	if not is_on_floor():
		velocity.y -= T.GRAVITY * delta
	elif _action != "dodge":
		velocity.y = 0.0
	move_and_slide()
	_update_debug(delta)


## Передаёт модели скорость и текущее действие: она считает позу кодом.
func _update_character_anim(delta: float) -> void:
	if character != null and character.has_method("update_anim"):
		var planar := Vector2(velocity.x, velocity.z).length()
		var ratio := planar / T.RUN_SPEED
		character.update_anim(delta, ratio, _action, _action_time)


func _update_buffers(delta: float) -> void:
	_buf_dodge += delta
	_buf_attack += delta


func _update_camera(delta: float) -> void:
	pivot.rotation.y = lerp_angle(pivot.rotation.y, _yaw, min(1.0, delta * T.CAMERA_FOLLOW_SPEED))
	pivot.rotation.x = deg_to_rad(_pitch)


func _update_stamina(delta: float) -> void:
	if _stamina_cooldown > 0.0:
		_stamina_cooldown -= delta
	elif stamina < T.MAX_STAMINA:
		stamina = min(T.MAX_STAMINA, stamina + T.STAMINA_REGEN * delta)


func _spend_stamina(amount: float) -> bool:
	if stamina < amount:
		return false
	stamina -= amount
	_stamina_cooldown = T.STAMINA_REGEN_DELAY
	return true


func _process_move(delta: float) -> void:
	var dir := _input_direction()
	var speed := T.RUN_SPEED if Input.is_action_pressed("run") else T.WALK_SPEED
	var target := dir * speed
	var rate := T.ACCELERATION if dir.length() > 0.0 else T.DECELERATION
	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)

	if dir.length() > 0.0:
		# модель смотрит в +Z, поэтому поворот считается от -Z
		var want := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, want, min(1.0, delta * T.TURN_SPEED))


func _try_start_actions() -> void:
	# Уворот в приоритете: он отменяет всё и не должен «проглатываться»
	if _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return
	if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_start_attack()
		_buf_attack = BUF_NEVER


func _start_dodge() -> void:
	_action = "dodge"
	_action_time = 0.0
	# направление: ввод, иначе назад от взгляда
	_dodge_dir = _buf_dir if _buf_dir.length() > 0.0 else -global_transform.basis.z
	if _dodge_dir.length() < 0.1:
		_dodge_dir = -global_transform.basis.z
	_dodge_dir.y = 0.0
	_dodge_dir = _dodge_dir.normalized()
	rotation.y = atan2(-_dodge_dir.x, -_dodge_dir.z)
	_invulnerable = false


func _process_dodge(delta: float) -> void:
	_action_time += delta
	_invulnerable = _action_time >= T.DODGE_IFRAMES_START and _action_time <= T.DODGE_IFRAMES_END
	var t := _action_time / T.DODGE_DURATION
	var speed_curve := 1.0 - pow(clamp(t, 0.0, 1.0), 1.6)  # быстро в начале, гаснет
	velocity.x = _dodge_dir.x * T.DODGE_SPEED * speed_curve
	velocity.z = _dodge_dir.z * T.DODGE_SPEED * speed_curve

	if _action_time >= T.DODGE_DURATION:
		_action = ""
		_invulnerable = false
		# если игрок жал атаку во время уворота — не теряем нажатие
		if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
			_start_attack()
			_buf_attack = BUF_NEVER


func _start_attack() -> void:
	_action = "attack"
	_action_time = 0.0
	_last_hit = ""


func _attack_phase() -> String:
	if _action_time < T.ATTACK_WINDUP:
		return "замах"
	elif _action_time < T.ATTACK_WINDUP + T.ATTACK_ACTIVE:
		return "удар"
	return "восстановление"


func _process_attack(delta: float) -> void:
	var prev := _action_time
	_action_time += delta
	# тормозим на месте во время удара, чтобы удар «весил»
	velocity.x = move_toward(velocity.x, 0.0, T.DECELERATION * delta)
	velocity.z = move_toward(velocity.z, 0.0, T.DECELERATION * delta)

	var phase := _attack_phase()
	if phase == "удар" and _last_hit.is_empty():
		_do_hit()

	# отмена уворотом — только в восстановлении и только если хватает стамины
	var recovery_time := _action_time - (T.ATTACK_WINDUP + T.ATTACK_ACTIVE)
	if recovery_time > 0.0 and _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return

	var total := T.ATTACK_WINDUP + T.ATTACK_ACTIVE + T.ATTACK_RECOVERY
	if _action_time >= total:
		_action = ""


func _do_hit() -> void:
	var origin := global_position + Vector3.UP * 1.0
	var forward := -global_transform.basis.z
	for target in _targets:
		if not is_instance_valid(target):
			continue
		var to_target: Vector3 = target.global_position - origin
		to_target.y = 0.0
		if to_target.length() > T.ATTACK_RANGE:
			continue
		var angle := rad_to_deg(forward.angle_to(to_target.normalized()))
		if angle > T.ATTACK_ANGLE:
			continue
		# попадание
		_last_hit = target.name
		if target.has_method("take_damage"):
			target.take_damage(T.ATTACK_DAMAGE, forward)
		break


## Вызывается целью при её ударе по игроку.
func take_damage(amount: float, from_dir: Vector3) -> void:
	if _invulnerable:
		_last_hit = "увернулся"
		return
	health = max(0.0, health - amount)
	if health <= 0.0:
		health = T.MAX_HEALTH
		stamina = T.MAX_STAMINA
		global_position = Vector3(0.0, 1.0, 6.0)
		_last_hit = "смерть → респавн"


func _update_debug(delta: float) -> void:
	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 0.25:
		_fps = _fps_frames / _fps_accum
		_fps_accum = 0.0
		_fps_frames = 0
	if label == null:
		return
	var state := "покой"
	if _action == "attack":
		state = "атака: " + _attack_phase()
	elif _action == "dodge":
		state = "уворот" + ("  [неуязвим]" if _invulnerable else "")
	var dbg_action := "—"
	if _action != "":
		dbg_action = "%.2f" % _action_time
	label.text = "\n".join([
		"FPS: %.0f" % _fps,
		"состояние: %s" % state,
		"здоровье: %.0f" % health,
		"стамина: %.0f" % stamina,
		"цель: %s" % (_last_hit if not _last_hit.is_empty() else "—"),
		"действие: %s  буфер: удар %s / уворот %s" % [
			dbg_action,
			"нет" if _buf_attack > T.INPUT_BUFFER else "%.2f" % _buf_attack,
			"нет" if _buf_dodge > T.INPUT_BUFFER else "%.2f" % _buf_dodge,
		],
	])
