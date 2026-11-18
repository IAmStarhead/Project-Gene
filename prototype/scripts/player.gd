## Прототип героини: движение от третьего лица, отзывчивое управление.
##
## Проверяет три вещи без анимаций:
##   1) ощущение движения и камеры;
##   2) отзывчивость ввода (буфер, отмена атаки уворотом);
##   3) стамину, уворот с неуязвимостью и попадание по цели.
##
## ── Как устроено управление и почему именно так ───────────────────────────
## Камера — ОТДЕЛЬНЫЙ узел (CameraRig), он не ребёнок героини. Раньше камера
## была вложена в тело, а тело поворачивается к направлению движения. Из-за
## этого получался порочный круг, который пользователь описал как «управление
## из 90-х»:
##
##   нажали W   -> героиня повернулась -> повернулась камера
##   -> направление «вперёд» изменилось -> героиня снова повернулась
##
## Отсюда и «чтобы идти, надо сначала туда посмотреть», и «А/D как стрейф»,
## и «иногда идёт куда хочет». Теперь:
##
##   камера смотрит туда, куда её повернул игрок (мышью),
##   WASD задаёт направление В ОСЯХ КАМЕРЫ, это стандарт всех экшенов,
##   героиня ТОЛЬКО поворачивается к направлению движения,
##   камера за героиней не поворачивается вообще.
##
## Клавиатура и мышь, геймпад не поддерживается.
extends CharacterBody3D

const T := preload("res://scripts/tuning.gd")
const CameraRigScene := preload("res://scenes/camera_rig.tscn")
const LockOn := preload("res://scripts/lock_on.gd")
const HitCheck := preload("res://scripts/hit_check.gd")

@onready var character: Node3D = $Character
@onready var label: Label = $UI/DebugLabel
@onready var hud: CanvasLayer = get_node_or_null("HUD")

## Камера живёт в корне сцены и следует за героиней, но не наследует её поворот.
var rig: Node3D
var yaw: float = 0.0                       ## рыскание камеры, радианы
var pitch: float = -14.0                   ## наклон камеры, градусы

var health: float = T.MAX_HEALTH
var stamina: float = T.MAX_STAMINA

## Стойка игрока, НЕ переключатель тренировочного клона (он по T).
## Начинаем с обычного передвижения; удар или полученный урон включают бой.
var combat_mode := false

var _stamina_cooldown: float = 0.0

# Состояние действия: "" | "attack" | "dodge"
var _action: String = ""
var _action_time: float = 0.0

# Буфер ввода: сколько секунд назад нажата кнопка.
# ВАЖНО: значение «не нажимали» должно быть БОЛЬШИМ, а не отрицательным —
# буфер сравнивается по «<= INPUT_BUFFER», и −99 проходил эту проверку,
# из-за чего удар запускался сам, без нажатия кнопки.
const BUF_NEVER := 999.0
var _buf_dodge: float = BUF_NEVER
var _buf_attack: float = BUF_NEVER
var _buf_secondary: float = BUF_NEVER   ## ПКМ: удар правой рукой
## Какой рукой идёт текущий удар: "L" (ЛКМ) или "R" (ПКМ).
var _attack_side: String = "L"
var _buf_dir: Vector3 = Vector3.ZERO

var _dodge_local_dir := Vector3(0, 0, 1)
var _dodge_dir: Vector3 = Vector3.ZERO
var _invulnerable: bool = false
var _coyote: float = 0.0          ## сколько ещё можно прыгнуть после схода с края
var _jump_buffer: float = BUF_NEVER
var _jump_started := false       ## одно физическое обновление: отличаем прыжок от падения

var _targets: Array = []
## Захват цели. Отдельный класс, чтобы модель движения и бой не разрастались.
var lock := LockOn.new()
var _fps_accum: float = 0.0
var _fps_frames: int = 0
var _fps: float = 0.0
var _last_hit: String = ""
var show_details := false   ## F3: подробная отладка


func _ready() -> void:
	add_to_group("player")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	rig = CameraRigScene.instantiate()
	rig.setup(self, yaw, pitch)
	get_tree().current_scene.add_child(rig)

	_refresh_targets()
	lock.setup(self)
	# HUD получает ссылки на игрока и на захват: полосы здоровья рисует он,
	# а не отладочный текст. Подробности остаются на F3.
	if hud != null and hud.has_method("setup"):
		hud.setup(self, lock)
	# Отладочный текст виден только по F3: пользователь дважды жаловался,
	# что надписей слишком много. Цифры здоровья теперь в полосах HUD.
	if label != null:
		label.visible = false
	if character != null and character.has_method("reset_motion"):
		character.reset_motion(combat_mode)


func _exit_tree() -> void:
	if is_instance_valid(rig):
		rig.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	# Захват цели обрабатывается первым: если он поглотил событие, дальше
	# мышь не должна крутить камеру, иначе цель «уезжает» из кадра.
	if lock != null and lock.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		yaw -= event.relative.x * T.MOUSE_SENSITIVITY
		pitch = clampf(pitch - event.relative.y * T.MOUSE_SENSITIVITY * 60.0,
			T.CAMERA_PITCH_MIN, T.CAMERA_PITCH_MAX)
	elif event.is_action_pressed("toggle_debug_details"):
		show_details = not show_details
		if label != null:
			label.visible = show_details
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if event.button_index == MOUSE_BUTTON_LEFT:
			_buf_attack = 0.0
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_buf_secondary = 0.0
	elif event.is_action_pressed("attack"):
		_buf_attack = 0.0
	elif event.is_action_pressed("attack_secondary"):
		_buf_secondary = 0.0
	# Сторону фиксируем ТОЛЬКО при старте атаки. Нажатие другой кнопки
	# в буфер не должно менять уже летящий кулак посреди удара.
	elif event.is_action_pressed("dodge"):
		_buf_dodge = 0.0
		_buf_dir = _input_direction()
	elif event.is_action_pressed("jump"):
		_jump_buffer = 0.0
	elif event.is_action_pressed("toggle_stance"):
		toggle_combat_mode()


func toggle_combat_mode() -> void:
	# Меняем локомоцию и целевую скорость, но не отменяем действие,
	# не сбрасываем фазу шага, стамину или вертикальную траекторию.
	combat_mode = not combat_mode


func stance_name() -> String:
	return "боевой" if combat_mode else "обычный"


## Направление движения в осях КАМЕРЫ. Это и есть стандарт экшенов:
## W — от камеры, A — влево на экране, и так далее.
## Направление взгляда камеры по горизонтали. Нужно захвату цели: конус
## поиска должен считаться от того, куда игрок реально смотрит, а не от
## ориентации тела (тело может быть повёрнуто вбок при движении).
func aim_forward() -> Vector3:
	var f := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return f.normalized()


func _input_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input.length() < 0.1:
		return Vector3.ZERO
	var basis_yaw := Basis(Vector3.UP, yaw)
	return (basis_yaw * Vector3(input.x, 0.0, input.y)).normalized()


func _physics_process(delta: float) -> void:
	var previous_position := global_position
	_jump_started = false
	if lock != null:
		lock.update()
	_update_buffers(delta)
	_update_stamina(delta)

	if _action == "dodge":
		_process_dodge(delta)
	elif _action == "attack":
		_process_attack(delta)
	else:
		_process_move(delta)
		_try_start_actions()

	# Гравитация разная для подъёма и падения: падать быстрее, чем взлетать, —
	# так прыжок читается собранным, а не «на луне».
	if is_on_floor():
		# держим на полу только если мы не в прыжке и не в увороте
		if _action != "dodge" and velocity.y <= 0.0:
			velocity.y = 0.0
	else:
		var g := T.GRAVITY if velocity.y > 0.0 else T.GRAVITY_FALL
		velocity.y -= g * delta

	# Прыжок. Как в Elden Ring: F — прыжок, Space — уворот.
	# Буфер позволяет нажать чуть раньше приземления, coyote — чуть позже
	# схода с края. Без этих двух мелочей прыжок ощущается «глухим».
	# Ставится ПОСЛЕ гашения вертикальной скорости — иначе его же и обнулит.
	if _jump_buffer <= T.INPUT_BUFFER and _action != "dodge" and _coyote > 0.0:
		_try_jump()

	move_and_slide()
	# Анимация получает фактическое перемещение и УЖЕ обновлённый пол.
	# У стены ноги не бегут на месте, взлёт/посадка не запаздывают на кадр.
	_update_character_anim(delta, global_position - previous_position)
	_update_camera(delta)
	_update_debug(delta)


## Прыжок с заданной высоты: скорость = sqrt(2 * g * h).
func _try_jump() -> void:
	velocity.y = sqrt(2.0 * T.GRAVITY * T.JUMP_HEIGHT)
	_jump_started = true
	_jump_buffer = BUF_NEVER
	_coyote = 0.0


## Доля управления в воздухе: на земле 1.0, в прыжке ниже.
func _air_control() -> float:
	return 1.0 if is_on_floor() else T.AIR_CONTROL


## Библиотека общая с витриной и клоном, физика остаётся авторитетной.
func _update_character_anim(delta: float, displacement: Vector3) -> void:
	if character != null and character.has_method("update_motion"):
		var planar := Vector3(displacement.x, 0.0, displacement.z)
		var local_velocity := character.global_basis.inverse() * (planar / maxf(delta, .001))
		var floor_distance := -1.0
		if not is_on_floor() and velocity.y <= 0.0:
			var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP*.06,
				global_position + Vector3.DOWN*3.0, collision_mask, [get_rid()])
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				floor_distance = maxf(0.0, global_position.y - (hit["position"] as Vector3).y)
		character.update_motion(delta, local_velocity, _action, _action_time, _attack_side, {
			"distance": planar.length(), "grounded": is_on_floor(),
			"vertical_speed": velocity.y, "jump_started": _jump_started,
			"floor_distance": floor_distance, "combat": combat_mode,
			"dodge_direction": _dodge_local_dir,
			"walk_speed": T.WALK_SPEED, "jog_speed": T.JOG_SPEED, "sprint_speed": T.RUN_SPEED,
			"attack_timing": Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY),
		})


func _update_buffers(delta: float) -> void:
	_buf_dodge += delta
	_buf_attack += delta
	_buf_secondary += delta
	_jump_buffer += delta
	if is_on_floor():
		_coyote = T.COYOTE_TIME
	else:
		_coyote = maxf(0.0, _coyote - delta)


## Камера следует за героиней по позиции, но НЕ по повороту.
func _update_camera(delta: float) -> void:
	# В режиме захвата камеру ведёт цель: yaw плавно доворачивается к ней.
	# Иначе игрок смотрит в одну сторону, а героиня колотит в другую.
	if lock != null and lock.active():
		var wanted: float = lock.camera_yaw(delta, yaw)
		if not is_nan(wanted):
			yaw = wanted
	if is_instance_valid(rig):
		rig.rotation.y = yaw
		rig.rotation.x = deg_to_rad(pitch)
		rig.global_position = global_position + Vector3(0.0, T.CAMERA_HEIGHT, 0.0)


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
	# В режиме захвата направление задаёт цель, а не камера: A/D — стрейф
	# вокруг неё. Без этого лок-он бесполезен — тело поворачивалось бы на ввод.
	if lock != null and lock.active():
		var flat := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var out: Array = []
		if lock.movement(flat, out):
			dir = out[0]
	# Одна переменная на три скорости. Раньше это была тройная вложенная
	# тернарная запись в 130 символов — её невозможно было прочитать.
	var speed := T.JOG_SPEED
	if Input.is_action_pressed("walk_slow"):
		speed = T.WALK_SPEED
	elif Input.is_action_pressed("run"):
		# Shift важнее шага: если зажаты оба, игрок ожидает бег.
		speed = T.RUN_SPEED
	var target := dir * speed
	var ac := _air_control()
	var rate := (T.ACCELERATION if dir.length() > 0.0 else T.DECELERATION) * ac
	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)

	if dir.length() > 0.0 and _buf_dodge > T.INPUT_BUFFER and not (lock != null and lock.active()):
		# Уворот фиксирует взгляд ДО обычного поворота на ввод.
		# модель смотрит в +Z, поэтому поворот считается от -Z
		var want := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, want, min(1.0, delta * T.TURN_SPEED))

	# При захвате тело смотрит на цель даже когда стоим на месте.
	# Поворот плавный: мгновенный выглядит как «приклеивание» к врагу.
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			var fwd: Vector3 = face[0]
			rotation.y = lerp_angle(rotation.y, atan2(-fwd.x, -fwd.z),
				min(1.0, delta * LockOn.TURN_RATE))


func _try_start_actions() -> void:
	# Уворот в приоритете: он отменяет всё и не должен «проглатываться»
	if _buf_dodge <= T.INPUT_BUFFER and _spend_stamina(T.DODGE_STAMINA):
		_start_dodge()
		_buf_dodge = BUF_NEVER
		return
	# ЛКМ — левая рука, ПКМ — правая. Если нажали ту, на которую не хватило
	# стамины, второе нажатие не тратится зря: сначала левая, потом правая.
	if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_attack_side = "L"
		_start_attack()
		_buf_attack = BUF_NEVER
	elif _buf_secondary <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
		_attack_side = "R"
		_start_attack()
		_buf_secondary = BUF_NEVER


func _start_dodge() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_action = "dodge"
	_action_time = 0.0
	# Ввод задаёт перемещение, но НЕ разворачивает модель. Без ввода —
	# шаг назад относительно тела, даже если камера смотрит с другой стороны.
	_dodge_dir = _buf_dir if _buf_dir.length() > 0.0 else global_basis.z
	_dodge_dir.y = 0.0
	if _dodge_dir.length() < 0.1:
		_dodge_dir = _camera_forward()
	_dodge_dir = _dodge_dir.normalized()
	_dodge_local_dir = character.global_basis.inverse() * _dodge_dir
	_dodge_local_dir.y = 0.0
	_dodge_local_dir = _dodge_local_dir.normalized()
	_invulnerable = false


## Куда смотрит камера на плоскости.
func _camera_forward() -> Vector3:
	var f := -Basis(Vector3.UP, yaw).z
	f.y = 0.0
	return f.normalized()


func _process_dodge(delta: float) -> void:
	var before := T.dodge_progress(_action_time/T.DODGE_DURATION)
	_action_time += delta
	_invulnerable = _action_time >= T.DODGE_IFRAMES_START and _action_time <= T.DODGE_IFRAMES_END
	var after := T.dodge_progress(_action_time/T.DODGE_DURATION)
	# Integrating the displacement curve exactly avoids FPS-dependent travel
	# and gives the animator the same root path as its foot contact anchors.
	var speed := T.DODGE_DISTANCE*(after-before)/maxf(delta, .000001)
	velocity.x = _dodge_dir.x * speed
	velocity.z = _dodge_dir.z * speed

	if _action_time >= T.DODGE_DURATION:
		_action = ""
		_invulnerable = false
		# если игрок жал атаку во время уворота — не теряем нажатие
		if _buf_attack <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
			_attack_side = "L"
			_start_attack()
			_buf_attack = BUF_NEVER
		elif _buf_secondary <= T.INPUT_BUFFER and _spend_stamina(T.ATTACK_STAMINA):
			_attack_side = "R"
			_start_attack()
			_buf_secondary = BUF_NEVER


func _start_attack() -> void:
	combat_mode = true
	_action = "attack"
	_action_time = 0.0
	_last_hit = ""


func _attack_phase() -> String:
	if _action_time < T.ATTACK_WINDUP:
		return "замах"
	if _action_time < T.ATTACK_WINDUP + T.ATTACK_ACTIVE:
		return "удар"
	return "восстановление"


func _process_attack(delta: float) -> void:
	var previous_time := _action_time
	_action_time += delta
	# тормозим на месте во время удара, чтобы удар «весил»
	velocity.x = move_toward(velocity.x, 0.0, T.DECELERATION * delta)
	velocity.z = move_toward(velocity.z, 0.0, T.DECELERATION * delta)

	# Пересечение окна, а не равенство кадру: при просадке FPS нельзя
	# перескочить активную фазу целиком и потерять удар.
	if previous_time < T.ATTACK_WINDUP + T.ATTACK_ACTIVE \
			and _action_time >= T.ATTACK_WINDUP and _last_hit.is_empty():
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
	_refresh_targets()
	var forward := -global_transform.basis.z
	# При захвате удар направлен на цель. Это и есть главная польза лок-она:
	# при угле конуса 45° промахнуться по стоящей цели становится невозможно.
	if lock != null and lock.active():
		var face: Array = []
		if lock.facing(face):
			forward = face[0]
	# Попадание считается пересечением кулака с цилиндром цели, а не
	# расстоянием между центрами. Подробности и обоснование — в hit_check.gd.
	# Коротко: раньше при ATTACK_RANGE 1.9 удар проходил при зазоре 1.22 м.
	var best := HitCheck.nearest_hit(self, _targets, forward, T.ATTACK_REACH,
		T.ATTACK_ANGLE) as Node
	if best == null:
		_last_hit = _miss_reason()
		return
	_last_hit = String(best.name)
	if best.has_method("take_damage"):
		best.take_damage(T.ATTACK_DAMAGE, forward)


## Почему удар не попал — для строки F3. Без этого «мимо» ничего не говорит:
## непонятно, промах по углу, по дистанции или вообще цели нет.
func _miss_reason() -> String:
	var near := _nearest_target()
	if near == null:
		return "мимо (нет цели в группе damageable)"
	var gap: float = HitCheck.surface_gap(self, near, 0.30)
	return "мимо (зазор до тела %.2f м)" % gap


## Ближайшая живая цель — для отладочной строки и подсказок.
func _nearest_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for v in _targets:
		if not is_instance_valid(v):
			continue
		var d: Vector3 = v.global_position - global_position
		d.y = 0.0
		if d.length() < best_d:
			best_d = d.length()
			best = v
	return best


## Расстояние до ближайшей цели — только для отладочной строки.
func _nearest_distance() -> float:
	var best := INF
	for v in _targets:
		if is_instance_valid(v):
			var d: Vector3 = v.global_position - global_position
			d.y = 0.0
			best = minf(best, d.length())
	return best


## Обновляет список целей.
##
## ПОЧЕМУ ЭТО ОТДЕЛЬНАЯ ФУНКЦИЯ. Раньше список набирался ОДИН РАЗ в _ready().
## Но порядок добавления детей в сцене такой, что героиня оказывается в дереве
## раньше клона: на момент её _ready() в группе "damageable" ещё никого нет,
## список остаётся пустым на весь бой. Отсюда «хп у клона не отнимается».
## Теперь список пополняется перед каждым ударом — это три узла, дёшево.
func _refresh_targets() -> void:
	for n in get_tree().get_nodes_in_group("damageable"):
		if not _targets.has(n):
			_targets.append(n)


## Вызывается целью при её ударе по игроку.
func take_damage(amount: float, _from_dir: Vector3) -> void:
	if _invulnerable:
		_last_hit = "увернулся"
		return
	combat_mode = true
	health = max(0.0, health - amount)
	if character != null and character.has_method("play_hit"):
		character.play_hit()
	if health <= 0.0:
		health = T.MAX_HEALTH
		stamina = T.MAX_STAMINA
		global_position = Vector3(0.0, 1.0, 6.0)
		_action = ""
		_invulnerable = false
		velocity = Vector3.ZERO
		combat_mode = false
		if character != null and character.has_method("reset_motion"):
			character.reset_motion(combat_mode)
		_last_hit = "смерть → респавн"


func _update_debug(delta: float) -> void:
	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 0.25:
		_fps = float(_fps_frames) / _fps_accum
		_fps_accum = 0.0
		_fps_frames = 0
	if label == null:
		return
	var state := "покой"
	if _action == "attack":
		state = "атака (%s): " % ("правая" if _attack_side == "R" else "левая") + _attack_phase()
	elif _action == "dodge":
		state = "уворот" + ("  [неуязвим]" if _invulnerable else "")
	var buf_atk := "нет" if _buf_attack > T.INPUT_BUFFER else "%.2f" % _buf_attack
	var buf_dg := "нет" if _buf_dodge > T.INPUT_BUFFER else "%.2f" % _buf_dodge
	# Отладка сокращена до пяти строк. Раньше их было 13, и они закрывали
	# треть экрана, перекрывая подсказку по управлению и надпись над клоном.
	# Подробности (буферы, цель) включаются клавишей F3 — см. show_details.
	var lines := [
		"FPS: %.0f" % _fps,
		"режим: %s [R] · %s" % [stance_name(), state],
		# Здоровье и стамина теперь полосами в HUD (scripts/hud.gd).
		# Здесь оставляем цифры только в подробном режиме F3.
	]
	if show_details:
		lines.append("здоровье: %.0f   стамина: %.0f" % [health, stamina])
	if show_details:
		lines.append("буфер: удар %s / уворот %s" % [buf_atk, buf_dg])
		lines.append("цель: %s" % (_last_hit if not _last_hit.is_empty() else "—"))
	lines.append("яркость: %s" % T.BRIGHTNESS_NAMES[clampi(T.BRIGHTNESS, 0, 2)])
	label.text = "\n".join(lines)