## Захват цели (lock-on) для боя.
##
## Зачем отдельным файлом: логику захвата не надо размазывать по player.gd,
## который ведёт другой агент. Здесь только выбор цели, поворот к ней и стрейф;
## игрок лишь спрашивает «куда мне смотреть» и «есть ли цель».
##
## Как ведёт себя (по мотивам Dark Souls 3 / Elden Ring):
##   • Tab или средняя кнопка мыши — взять ближайшего врага в поле зрения;
##   • повторное нажатие — снять захват;
##   • колесо мыши — переключить цель (следующая по часовой стрелке);
##   • цель умерла или ушла дальше RADIUS — захват снимается сам, но если
##     рядом есть другая цель, переключается на неё;
##   • пока захват активен, камера смотрит на цель, а персонаж стоит к ней
##     лицом. A/D — стрейф вокруг цели, W/S — сближение и отход;
##   • поворот тела плавный (lerp по углу), а не мгновенный: иначе персонаж
##     дёргается и «прилипает» к врагу.
##
## Почему не через Area3D: целей в тестовой комнате одна-две, а список уже
## есть в группе "damageable". Сортировка по углу дешевле, чем настройка слоёв.
extends RefCounted

const T := preload("res://scripts/tuning.gd")

## Радиус захвата. 12 м — чуть больше диагонали комнаты 18×18, но цель должна
## быть в поле зрения, поэтому одного радиуса мало.
const RADIUS := 12.0
## Полуугол конуса захвата от направления взгляда, градусы. 60 — это широко,
## но не «захват за спиной», как в некоторых играх.
const HALF_ANGLE := 60.0
## Скорость доворота тела к цели (коэффициент lerp за кадр при 60 FPS).
const TURN_RATE := 10.0
## Скорость доворота КАМЕРЫ к цели. Медленнее тела: если камера дёргается
## вместе с телом при переключении цели, игрока укачивает. Так делают все
## соулсы: тело поворачивается быстро, камера догоняет за ~0.3 с.
const CAMERA_TURN_RATE := 4.5

var target: Node3D = null
var _player: Node3D
var _last_target_pos := Vector3.ZERO


func setup(player: Node3D) -> void:
	_player = player


func active() -> bool:
	return is_instance_valid(target) and not _target_dead()


## Вызывать каждый кадр: сама снимает захват, если цель умерла или убежала.
## Аргумента delta нет намеренно: вся плавность живёт в поворотах, а не здесь.
func update() -> void:
	if target == null:
		return
	if _target_dead():
		target = null
		return
	var dist: float = _flat_distance()
	if dist > RADIUS:
		# Цель ушла далеко — пробуем взять любую другую В КОНУСЕ ВЗГЛЯДА.
		# Если другой нет, захват снимается: возвращать ту же самую цель,
		# которая уже вне радиуса, бессмысленно.
		var previous := target
		target = null
		_try_acquire(false)
		if target == previous:
			target = null
	if is_instance_valid(target):
		_last_target_pos = target.global_position


## Обработка ввода. Возвращает true, если событие поглощено.
func handle_input(event: InputEvent) -> bool:
	if event.is_action_pressed("lock_on"):
		if active():
			target = null
		else:
			_try_acquire(false)
		return true
	if not active():
		return false
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle(-1)
			return true
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle(1)
			return true
	return false


## Направление от игрока к цели в горизонтали. Нужно и камере, и телу.
func direction_to_target() -> Vector3:
	if not active():
		return Vector3.ZERO
	return _flat_direction()


## Куда персонажу смотреть: на цель или по направлению движения.
## Возвращает true, если направление задаёт захват (тогда вызывающий код
## не должен поворачивать тело по вводу).
func facing(out: Array) -> bool:
	if not active():
		return false
	var to_target: Vector3 = target.global_position - _player.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return false
	out.clear()
	out.append(to_target.normalized())
	return true


## Направление движения в режиме захвата: A/D — стрейф вокруг цели.
## Возвращает Vector3 или null-эквивалент (пустой массив), если свободный режим.
func movement(flat_input: Vector2, out: Array) -> bool:
	if not active():
		return false
	var to_target: Vector3 = target.global_position - _player.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return false
	var forward := to_target.normalized()
	var right := forward.cross(Vector3.UP).normalized()
	# flat_input.y = +1 означает «назад» (так работает Input.get_vector и
	# текущий код игрока), поэтому вперёд берём минус.
	var dir := right * flat_input.x - forward * flat_input.y
	if dir.length_squared() < 0.0001:
		out.clear()
		out.append(Vector3.ZERO)
		return true
	out.clear()
	out.append(dir.normalized())
	return true


## Ближайшая живая цель в конусе перед игроком.
## `skip_nearest` — взять следующую по удалённости (для переключения).
func _try_acquire(skip_nearest: bool) -> void:
	var camera_forward: Vector3 = -_player.global_transform.basis.z
	if _player.has_method("aim_forward"):
		camera_forward = _player.aim_forward()
	camera_forward.y = 0.0
	if camera_forward.length_squared() < 0.001:
		camera_forward = Vector3.FORWARD
	camera_forward = camera_forward.normalized()

	var candidates: Array = []
	for node in _player.get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		if _is_dead(node):
			continue
		var to: Vector3 = (node as Node3D).global_position - _player.global_position
		to.y = 0.0
		var dist := to.length()
		if dist > RADIUS or dist < 0.01:
			continue
		var angle := rad_to_deg(camera_forward.angle_to(to.normalized()))
		if angle > HALF_ANGLE:
			continue
		candidates.append({"node": node, "dist": dist, "angle": angle})

	if candidates.is_empty():
		return
	# Сортируем сначала по углу (ближе к центру экрана — важнее), потом по
	# дистанции: игрок ждёт захвата того, на кого смотрит, а не того, кто ближе.
	candidates.sort_custom(func(a, b):
		if absf(a["angle"] - b["angle"]) > 12.0:
			return a["angle"] < b["angle"]
		return a["dist"] < b["dist"])
	var pick: int = 1 if skip_nearest and candidates.size() > 1 else 0
	target = candidates[pick]["node"]


## Переключение колесом: следующая цель по часовой стрелке вокруг игрока.
func _cycle(direction: int) -> void:
	var list: Array = []
	for node in _player.get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(node) or not (node is Node3D) or _is_dead(node):
			continue
		var to: Vector3 = (node as Node3D).global_position - _player.global_position
		if Vector2(to.x, to.z).length() > RADIUS:
			continue
		list.append({"node": node, "a": atan2(to.x, to.z)})
	if list.size() < 2:
		return
	# Отсчёт от направления камеры: при захвате корпус уже смотрит на цель,
	# и перебор по нему вернул бы ту же цель.
	var aim: Vector3 = _player.aim_forward() if _player.has_method("aim_forward") \
		else -_player.global_transform.basis.z
	var here := atan2(aim.x, aim.z)
	list.sort_custom(func(a, b): return a["a"] < b["a"])
	var best: int = -1
	var best_delta := 999.0
	for i in list.size():
		var d: float = wrapf(list[i]["a"] - here, -PI, PI)
		if direction > 0 and d > 0.001 and d < best_delta:
			best_delta = d
			best = i
		elif direction < 0 and d < -0.001 and absf(d) < absf(best_delta):
			best_delta = d
			best = i
	if best >= 0:
		target = list[best]["node"]


## Записать поворот камеры обратно в угол игрока. Камера в режиме захвата
## ведётся кодом, но yaw в player.gd остаётся источником правды для ввода:
## если его не обновлять, после снятия захвата камера прыгнет обратно.
## Возвращает новый yaw или NAN, если захвата нет.
func camera_yaw(delta: float, current_yaw: float) -> float:
	if not active():
		return NAN
	var want := _flat_direction()
	if want.length_squared() < 0.0001:
		return NAN
	var desired := atan2(-want.x, -want.z)
	return lerp_angle(current_yaw, desired, minf(1.0, delta * CAMERA_TURN_RATE))


func _flat_direction() -> Vector3:
	if not is_instance_valid(target) or not is_instance_valid(_player):
		return Vector3.ZERO
	var d: Vector3 = target.global_position - _player.global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return Vector3.ZERO
	return d.normalized()


func _flat_distance() -> float:
	var d: Vector3 = target.global_position - _player.global_position
	d.y = 0.0
	return d.length()


func _is_dead(node: Node) -> bool:
	if node.has_method("is_alive"):
		return not node.is_alive()
	# У клона здоровье лежит в поле health.
	var v: Variant = node.get("health")
	if v != null and float(v) <= 0.0:
		return true
	return false


func _target_dead() -> bool:
	if not is_instance_valid(target):
		return true
	return _is_dead(target)
