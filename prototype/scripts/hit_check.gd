## Попадание по цели: пересечение реальной геометрии, а не «расстояние по центрам».
##
## ЗАЧЕМ. Раньше удар считался так:
##
##     dist = |цель.центр − игрок.центр|
##     if dist > ATTACK_RANGE: мимо
##
## Радиус корпуса каждого был 0.34, поэтому при ATTACK_RANGE 1.9 удар проходил
## при зазоре между телами 1.22 м — кулак бил воздух на расстоянии больше метра.
## Отсюда жалоба «хитбокс больше, чем должен».
##
## ТЕПЕРЬ. Попадание — это сфера кулака, которая пересекает цилиндр цели.
## Цилиндр, а не капсула: у капсулы скруглённые концы, и рост менял бы радиус
## попадания у головы и ног. Высота цилиндра измеряется по самой цели: если у
## неё есть поле health/named узлы — берём высоту персонажа из CollisionShape3D,
## иначе падаем на константы.
##
## Дополнительно проверяется высота кулака: удар на уровне груди не должен
## попадать по голове и наоборот. Это важно, когда появится расчленение.
##
## Почему не Area3D. Для точного совета из практики Godot: у Area3D-хитбоксов
## две проблемы — двойные попадания за один взмах и необходимость включать и
## выключать формы по кадрам анимации. Обе решаются учётом флага «уже попал»,
## но проще и честнее считать пересечение в момент активной фазы. Один удар —
## одна проверка, двойных попаданий не бывает по построению.
extends RefCounted

## Радиус кулака. Кисть в кулаке — примерно 0.05 м; 0.075 даёт небольшой
## запас, чтобы удар не «проскакивал» на границе. Больше делать нельзя:
## именно этот радиус и создавал ощущение раздутого хитбокса.
const FIST_RADIUS := 0.075
## Радиус корпуса цели, если его не удалось измерить по сцене.
const DEFAULT_BODY_RADIUS := 0.30
## Высота цилиндра цели по умолчанию (рост модели 1.675).
const DEFAULT_BODY_HEIGHT := 1.68
## Предел отклонения по высоте: кулак должен идти в корпус, а не в пустоту
## над головой или под коленом.
const VERTICAL_SLACK := 0.55


## Измерить габариты цели по её CollisionShape3D. Возвращает [radius, height].
static func body_size(node: Node3D) -> Array:
	for child in node.get_children():
		var shape_node: CollisionShape3D = null
		if child is CollisionShape3D:
			shape_node = child
		elif child.get_child_count() > 0:
			for grand in child.get_children():
				if grand is CollisionShape3D:
					shape_node = grand
					break
		if shape_node == null:
			continue
		var shape: Shape3D = shape_node.shape
		if shape == null:
			continue
		if shape is CapsuleShape3D:
			var cap := shape as CapsuleShape3D
			return [cap.radius, cap.height]
		if shape is CylinderShape3D:
			var cyl := shape as CylinderShape3D
			return [cyl.radius, cyl.height]
		if shape is SphereShape3D:
			var sph := shape as SphereShape3D
			return [sph.radius, sph.radius * 2.0]
	return [DEFAULT_BODY_RADIUS, DEFAULT_BODY_HEIGHT]


## Куда бьёт кулак. Берём точку на линии удара на высоте груди:
##   origin  — центр корпуса атакующего (+1.2 м),
##   forward — направление удара,
##   reach   — насколько далеко вынесен кулак от корпуса.
## Возвращает точку в мире.
static func fist_point(origin: Vector3, forward: Vector3, reach: float) -> Vector3:
	var f := Vector3(forward.x, 0.0, forward.z)
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	f = f.normalized()
	return Vector3(origin.x, origin.y + 1.20, origin.z) + f * reach


## Пересекает ли кулак цилиндр цели. Возвращает true, если да.
##
## reach — расстояние от центра атакующего до кулака в момент активной фазы.
## Считается вызывающим кодом: у героини и клона руки разной длины.
static func overlaps(attacker: Node3D, victim: Node3D, forward: Vector3,
		reach: float) -> bool:
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return false
	var fist := fist_point(attacker.global_position, forward, reach)
	var target_center := victim.global_position
	var size := body_size(victim)
	var radius: float = size[0]
	var height: float = size[1]

	# Горизонталь: расстояние от оси цели до кулака.
	var dx := fist.x - target_center.x
	var dz := fist.z - target_center.z
	var horizontal := sqrt(dx * dx + dz * dz)
	if horizontal > radius + FIST_RADIUS:
		return false

	# Вертикаль: кулак должен попасть в тело, а не над головой.
	# Центр цели — на полу; тело занимает от 0 до height.
	var local_y := fist.y - target_center.y
	if local_y < -VERTICAL_SLACK * 0.2 or local_y > height + VERTICAL_SLACK:
		return false
	return true


## Ближайшая цель, которую кулак реально задевает. Возвращает узел или null.
##
## Перебираем именно кандидатов в конусе, а не всех сразу: конус отсекает
## «попадание за спину», которое игрок не ожидает и считает багом.
static func nearest_hit(attacker: Node3D, candidates: Array, forward: Vector3,
		reach: float, half_angle_deg: float) -> Node3D:
	var f := Vector3(forward.x, 0.0, forward.z)
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	f = f.normalized()
	var best: Node3D = null
	var best_dist := INF
	for node in candidates:
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		var victim := node as Node3D
		var to := victim.global_position - attacker.global_position
		to.y = 0.0
		var dist := to.length()
		if dist < 0.001:
			continue
		var angle := rad_to_deg(f.angle_to(to.normalized()))
		if angle > half_angle_deg:
			continue
		if not overlaps(attacker, victim, f, reach):
			continue
		if dist < best_dist:
			best_dist = dist
			best = victim
	return best


## Для отладки: расстояние между поверхностями тел (0 — касаются).
static func surface_gap(attacker: Node3D, victim: Node3D, own_radius: float) -> float:
	var d := victim.global_position - attacker.global_position
	d.y = 0.0
	var size := body_size(victim)
	return maxf(0.0, d.length() - own_radius - float(size[0]))
