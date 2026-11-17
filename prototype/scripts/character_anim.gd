## Процедурная анимация героини.
##
## В файле female_A_rigged_safe.glb есть скелет из 21 кости, но НЕТ клипов
## ходьбы, бега, удара и уворота — их никто не делал, а взять негде. Поэтому
## поза считается кодом: углы задаются формулами от скорости, фазы шага и
## текущего действия.
##
## ── Главное правило, на котором всё держится ──────────────────────────────
## В Godot поза кости — это ПОЛНЫЙ поворот кости относительно родителя, а не
## добавка к позе покоя. Документация Skeleton3D: «Bone rest defines the
## initial transform of the bone pose».
##
## Поэтому «повернуть кость на 30° вокруг её оси X» в терминах Godot значит
## не «поставить поворот 30°», а «взять поворот покоя и домножить на 30°»:
##
##     pose = rest * bend          (bend — изгиб в осях покоя кости)
##     поставить(pose)
##
## Если поставить просто bend, кость потеряет наклон покоя и скелет
## складывается сам в себя. Именно это и произошло в первой версии.
##
## ── Оси и знаки ───────────────────────────────────────────────────────────
## Проверено расчётом по матрицам покоя модели:
##   бедро, голень, стопа, предплечье: поворот вокруг локальной X качает
##     конечность вперёд-назад. Для ГОЛЕНИ плюс — это переразгибание,
##     поэтому колено всегда сгибается отрицательным углом.
##   плечо: вокруг X — мах вперёд-назад, вокруг Z — отведение в сторону
##     (у правой руки знак Z противоположен левой).
##   предплечье: плюс вокруг X — локоть сгибается вперёд, кисть идёт вперёд.

extends Node3D

const T := preload("res://scripts/tuning.gd")

## Версия модели без blend shapes и без анимаций: на исходной редактор Godot
## падал при импорте. Геометрия, скелет и веса в ней те же.
const MODEL_PATH := "res://assets/heroine/female_A_rigged_safe.glb"

var skeleton: Skeleton3D

var _idx: Dictionary = {}       ## имя кости -> индекс в скелете
var _rest_rot: Dictionary = {}  ## имя кости -> поворот покоя
var _rest_pos: Dictionary = {}  ## имя кости -> положение покоя
var _bend: Dictionary = {}      ## имя кости -> сглаженный изгиб, градусы

var _fallback: Node3D
var _loaded := false
var _clock := 0.0
var _phase := 0.0


func _ready() -> void:
	_fallback = get_node_or_null("Fallback")
	if not load_character(MODEL_PATH):
		push_warning("Модель героини не загрузилась — остаётся заглушка-капсула")


## Загружает .glb и находит скелет. Возвращает false, если не вышло.
func load_character(path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var packed: Resource = load(path)
	if packed == null or not (packed is PackedScene):
		return false
	var inst: Node = (packed as PackedScene).instantiate()
	add_child(inst)

	skeleton = _find_skeleton(inst)
	if skeleton == null:
		inst.queue_free()
		return false

	for i in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(i)
		var rest: Transform3D = skeleton.get_bone_rest(i)
		_idx[name] = i
		_rest_rot[name] = rest.basis.get_rotation_quaternion()
		_rest_pos[name] = rest.origin
		_bend[name] = Vector3.ZERO

	if _fallback:
		_fallback.visible = false
	_loaded = true
	return true


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


## Вызывается каждый кадр из player.gd.
## speed_ratio — доля от скорости бега (0..1), action — "" | "attack" | "dodge".
## side — какой рукой бьёт: "R" (правая) или "L" (левая). Пустая строка для
## остальных действий. Сторона приходит из player.gd: ЛКМ — левая, ПКМ — правая.
func update_anim(delta: float, speed_ratio: float, action: String,
		action_time: float, side: String = "") -> void:
	_clock += delta
	if not _loaded:
		return

	var want: Dictionary = {}      # имя кости -> изгиб в градусах
	var hip_offset := Vector3.ZERO
	var w := clampf(speed_ratio, 0.0, 1.2)

	# ───────────────────────────────────────── боевая стойка
	_breathe(want, 1.0)
	# Боевая стойка. Ключ к ней — ЛОКТИ ВНИЗ, а не «руки подняты»:
	# если поднимать плечо, получаются вытянутые вперёд руки, будто персонаж
	# зомби. Здесь плечо почти в покое (6-8°), а предплечье согнуто на 125°,
	# поэтому локоть остаётся внизу у ребра (Y 1.08), а кулак поднимается
	# к лицу (Y 1.21). Проверено рендером с четырёх ракурсов.
	#
	# Ноги в стойке не вместе: левая чуть впереди, колени подогнуты, вес
	# пониже. Корпус вполоборота — правая рука (ударная) отведена назад,
	# левая прикрывает.
	# ВАЖНО про удары. Позы удара — АБСОЛЮТНЫЕ, а не добавка к стойке.
	# Это была ошибка, которая ломала анимацию: _mix() прибавляет углы к
	# тому, что уже лежит в want. Пока стойка была с локтем 55°, удар
	# (65°) давал 120° — терпимо. Но со стойкой в 125° тот же удар дал бы
	# 190°, то есть локоть складывался за спину. Поэтому при ударе стойка
	# рук вообще не выставляется: иначе боевая стойка и боевой удар
	# несовместимы по определению.
	var stance_arms := action != "attack"
	if stance_arms:
		var idle_sway := sin(_clock * 1.4) * 1.6
		# Плечо вперёд 30°, отведено НАЗАД по скрутке (-20 для правой), локоть
		# 130°. Кисть выходит на Y 1.29 (уровень подбородка), X -0.10 (ближе
		# к центру, не торчит в сторону), Z +0.27 (перед корпусом), локоть
		# опущен на Y 1.10 и держится ПЕРЕД корпусом, а не выставлен вбок.
		#
		# История: при локте 45° кулак висел на уровне пояса (Y 0.91); при
		# 140° локти разъезжались в стороны и в кадре из-за спины выглядели
		# как «руки подняты и расставлены». Проверено рендером с четырёх
		# ракурсов, включая вид из-за спины.
		# Скрутка (Y) разворачивает кулаки тыльной стороной наружу.
		want["upper_arm.L"] = Vector3(30.0 + idle_sway, 20.0, 5.0)
		want["upper_arm.R"] = Vector3(30.0 - idle_sway, -20.0, -5.0)
		want["forearm.L"] = Vector3(130.0, 0.0, 0.0)
		want["forearm.R"] = Vector3(130.0, 0.0, 0.0)
		want["hand.L"] = Vector3(0.0, 0.0, 8.0)
		want["hand.R"] = Vector3(0.0, 0.0, -8.0)
	# корпус вполоборота: правое плечо назад, левое вперёд
	want["spine"] = Vector3(8.0, 0.0, 0.0)
	want["chest"] = Vector3(2.0, 8.0, 0.0)
	want["head"] = Vector3(-4.0, -8.0, 0.0)
	# ноги: левая впереди, колени подогнуты, стойка пониже
	want["thigh.L"] = Vector3(16.0, 0.0, 3.0)
	want["thigh.R"] = Vector3(10.0, 0.0, -3.0)
	want["shin.L"] = Vector3(-28.0, 0.0, 0.0)
	want["shin.R"] = Vector3(-20.0, 0.0, 0.0)
	want["foot.L"] = Vector3(10.0, 0.0, 0.0)
	want["foot.R"] = Vector3(8.0, 0.0, 0.0)

	# ───────────────────────────────────────── шаг и бег
	_phase = fmod(_phase + delta * (2.6 + 6.0 * w), TAU)
	if w > 0.02:
		_walk(want, w)

	# ───────────────────────────────────────── удар
	if action == "attack":
		_attack(want, action_time, side)
	# ───────────────────────────────────────── уворот
	elif action == "dodge":
		hip_offset = _dodge(want, action_time)
	# ───────────────────────────────────────── полёт (прыжок)
	elif action == "air":
		_air(want)

	_apply(want, hip_offset, delta)


## Дыхание: еле заметное покачивание корпуса, чтобы модель не была статуей.
func _breathe(want: Dictionary, weight: float) -> void:
	var b := sin(_clock * 1.6) * 1.1 * weight
	want["chest"] = Vector3(b, 0.0, 0.0)
	want["head"] = Vector3(-b * 0.5, 0.0, 0.0)
	want["spine"] = Vector3(2.0, 0.0, 0.0)


## Шаг и бег. w — доля скорости: 0 стоит, 1 бежит на полную.
func _walk(want: Dictionary, w: float) -> void:
	var s := sin(_phase)
	var hip_swing := 15.0 * w        # бедро: вперёд-назад
	var knee := 8.0 + 26.0 * w       # колено гнётся ТОЛЬКО назад, поэтому минус

	# ноги
	want["thigh.L"] = Vector3(hip_swing * s, 0.0, 0.0)
	want["thigh.R"] = Vector3(-hip_swing * s, 0.0, 0.0)

	# Колено подгибается, когда нога идёт назад-вверх (перенос).
	var bend_l := maxf(0.0, -s)
	var bend_r := maxf(0.0, s)
	want["shin.L"] = Vector3(-knee * bend_l, 0.0, 0.0)
	want["shin.R"] = Vector3(-knee * bend_r, 0.0, 0.0)

	# Стопа добирает часть подъёма, чтобы не «шаркать» носком.
	want["foot.L"] = Vector3(knee * bend_l * 0.30, 0.0, 0.0)
	want["foot.R"] = Vector3(knee * bend_r * 0.30, 0.0, 0.0)

	# ── РУКИ В ШАГЕ. Здесь была главная ошибка, и пользователь видел её
	# каждый раз, когда шёл: «руки опять опущены».
	#
	# _walk() ПЕРЕЗАПИСЫВАЕТ всё, что стойка поставила, причём углами для
	# ОПУЩЕННЫХ рук: плечо не больше 14°, локоть 45-59°. То есть пока персонаж
	# стоит — руки в стойке у подбородка, а как только он пошёл, они падают
	# вдоль тела. Стойка и шаг были написаны двумя разными людьми, и в кадре
	# побеждал шаг.
	#
	# Теперь шаг качает руку ОТ стойки, а не заменяет её: берём стойку
	# (плечо 30/130) и добавляем небольшое противофазное качание. Локти
	# остаются поднятыми, как в бою.
	var swing := 10.0 * w          # амплитуда качания плеча в шаге
	want["upper_arm.L"] = Vector3(30.0 + swing * s, 20.0, 5.0)
	want["upper_arm.R"] = Vector3(30.0 - swing * s, -20.0, -5.0)
	# Локоть в шаге чуть РАСКРЫВАЕТСЯ (130 -> 118) на замахе руки назад и
	# чуть сжимается вперёд: так качание читается, а кулак не улетает.
	want["forearm.L"] = Vector3(130.0 - 12.0 * w * s, 0.0, 0.0)
	want["forearm.R"] = Vector3(130.0 + 12.0 * w * s, 0.0, 0.0)
	want["hand.L"] = Vector3(0.0, 0.0, 8.0)
	want["hand.R"] = Vector3(0.0, 0.0, -8.0)

	# корпус: наклон вперёд на бегу, легкое покачивание плеч
	want["spine"] = Vector3(6.0 + 7.0 * w, 0.0, 0.0)
	want["chest"] = Vector3(2.0 + 3.0 * w, 8.0 - 4.0 * w * s, 0.0)
	want["hips"] = Vector3(0.0, 4.0 * w * s, 0.0)
	want["head"] = Vector3(-4.0 - 3.0 * w, -8.0 + 2.0 * w * s, 0.0)


## Удар правой рукой: замах, удар, возврат.
##
## Почему углы именно такие. В первой версии рука уходила махом через грудь
## на левую сторону. На модели это давало два видимых дефекта, которые
## пользователь и заметил:
##   1) кисть проходила СКВОЗЬ торс;
##   2) вершины груди, часть веса которых принадлежит плечу, тянулись за
##      рукой — «кусок кожи поднимался».
## Поэтому плечо отведено в СТОРОНУ (ось Z) и держится снаружи корпуса,
## а удар идёт вперёд (ось X), не пересекая среднюю линию тела.
func _attack(want: Dictionary, t: float, side: String = "R") -> void:
	# Сторона удара. Раньше била всегда правая — и было непонятно, почему
	# персонаж бьёт то одной, то другой (это была не смена рук, а разные
	# фазы одной и той же анимации). Теперь сторона приходит из ввода:
	# ЛКМ — левая, ПКМ — правая, как в Dark Souls.
	var arm := "R" if side == "R" else "L"
	var other := "L" if arm == "R" else "R"
	# Для правой руки отведение плеча в сторону — отрицательный Z, для левой
	# положительный. Знак берём из стороны, чтобы не дублировать функцию.
	var out := -1.0 if arm == "R" else 1.0
	var windup := T.ATTACK_WINDUP
	var active_end := windup + T.ATTACK_ACTIVE
	var total := active_end + T.ATTACK_RECOVERY

	# Плечо R: отведение в сторону = ОТРИЦАТЕЛЬНЫЙ Z (проверено расчётом:
	# при z=-35 кисть уходит на X≈-0.45, то есть наружу от корпуса).
	#
	# Числа подобраны не на глаз, а по мере «перепонки»: скрипт
	# assets/heroine/tools/pose_viewer.py считает, во сколько раз
	# растягивается каждое ребро меша. Чем меньше перепонка, тем меньше
	# процент рёбер, растянутых больше чем вдвое.
	#
	#   поза                          рёбер >2x
	#   рука вверх (0/-95)               0.66 %
	#   замах старый (-62/102)           0.23 %
	#   удар на уровне плеча (70/34)     0.38 %
	#   замах (16/-26, локоть 148)       0.063 %
	#   удар (66/-10, локоть 26)         0.157 %
	#   прежний удар (30/65)             0.027 %, но рука оставалась согнутой
	#                                    и читался не удар, а «толчок»
	#
	# Компромисс сознательный: новая поза растягивает рёбра сильнее
	# (0.157 % против 0.027 %), потому что рука полностью выпрямляется —
	# а без выпрямления удара не видно. 0.157 % — это 95 рёбер из 51 000.
	# Корпус скручивается В СТОРОНУ БЬЮЩЕЙ РУКИ, поэтому знак Y у chest и
	# spine тоже зависит от стороны. Иначе левый удар выглядел бы как
	# правый с перепутанной рукой — корпус уходил бы не туда.
	var twist := -1.0 if arm == "R" else 1.0
	var pose_back := {
		# Замах: кулак отведён к уху, локоть не внизу, а в стороне — так
		# виден запас хода. Проверено: кисть уходит на X ±0.26, Y 1.32.
		"upper_arm." + arm: Vector3(16.0, 40.0, -26.0 * out),
		"forearm." + arm: Vector3(148.0, 60.0, 0.0),
		"hand." + arm: Vector3(0.0, 0.0, -6.0 * out),
		"chest": Vector3(4.0, -16.0 * twist, 0.0),
		"spine": Vector3(2.0, -7.0 * twist, 0.0),
		"head": Vector3(0.0, 11.0 * twist, 0.0),
		# вторая рука в замахе прикрывает лицо, а не висит
		"upper_arm." + other: Vector3(10.0, 0.0, 16.0 * out),
		"forearm." + other: Vector3(112.0, 0.0, 0.0),
	}
	var pose_hit := {
		# Скрутка (вторая строка вектора — ось Y, она идёт ВДОЛЬ кости).
		# Знак у обеих рук ОДИНАКОВЫЙ (+40 плечо, +60 предплечье), хотя
		# отведение в сторону (Z) у них зеркальное. Это не описка: проверено
		# перебором, что при зеркальном знаке скрутки правая рука даёт
		# нормаль ладони 159° (то есть смотрит вверх — тыльной стороной
		# вперёд, ровно жалоба пользователя), а с одинаковым — 4°. Причина:
		# скрутка в pose_viewer идёт в осях ПОВОРОТА, а кость правой руки в
		# позе покоя развёрнута на 180° относительно левой.
		# Без неё удар выходил «тыльной стороной ладони»: пользователь описал
		# это как удар в сторону, не похожий на джеб. Расчёт по осям покоя
		# показал: ладонь смотрит наружу-вверх, пальцы вперёд — то есть
		# наружу шла именно тыльная сторона кисти.
		# Перебором 3000 комбинаций найдено, что ладонь разворачивается вниз
		# скруткой плеча на 40° и предплечья на 60° (отклонение нормали от
		# «вниз» 4° вместо 97°). При этом кулак идёт вперёд.
		# Удар: плечо вперёд на 66°, локоть почти распрямлён (26°). Именно
		# РАЗГИБ локтя и есть удар — при старом значении 65° рука оставалась
		# согнутой, и «удара как будто нет». Кисть выходит на 0.56 м вперёд.
		"upper_arm." + arm: Vector3(66.0, 40.0, -10.0 * out),
		"forearm." + arm: Vector3(26.0, 60.0, 0.0),
		"hand." + arm: Vector3(0.0, 0.0, -4.0 * out),
		"chest": Vector3(6.0, 16.0 * twist, 0.0),
		"spine": Vector3(4.0, 8.0 * twist, 0.0),
		"head": Vector3(0.0, -9.0 * twist, 0.0),
		"upper_arm." + other: Vector3(14.0, 0.0, -12.0 * out),
		"forearm." + other: Vector3(108.0, 0.0, 0.0),
	}

	# Замах: плавно ОТ стойки К позе замаха. Удар: от замаха к удару.
	# Возврат: от удара обратно к стойке (а не к нулю — иначе после удара
	# руки падают вниз, и стойка «разваливается» на полсекунды).
	var stance_pose := {
		"upper_arm.L": Vector3(30.0, 20.0, 5.0),
		"upper_arm.R": Vector3(30.0, -20.0, -5.0),
		"forearm.L": Vector3(130.0, 0.0, 0.0),
		"forearm.R": Vector3(130.0, 0.0, 0.0),
		"hand.L": Vector3(0.0, 0.0, 8.0),
		"hand.R": Vector3(0.0, 0.0, -8.0),
		"chest": Vector3(2.0, 8.0, 0.0),
		"spine": Vector3(8.0, 0.0, 0.0),
		"head": Vector3(-4.0, -8.0, 0.0),
	}
	if t < windup:
		_lerp_pose(want, stance_pose, pose_back, smoothstep(0.0, 1.0, t / windup))
	elif t < active_end:
		var u := smoothstep(0.0, 1.0, (t - windup) / T.ATTACK_ACTIVE)
		_lerp_pose(want, pose_back, pose_hit, u)
	elif t <= total:
		var u := smoothstep(0.0, 1.0, (t - active_end) / T.ATTACK_RECOVERY)
		_lerp_pose(want, pose_hit, stance_pose, u)


## Полёт: ноги подобраны, руки разведены для баланса.
## Отдельная поза нужна потому, что при прыжке ноги не должны «шагать»:
## процедурный шаг в воздухе читается как бег по воздуху.
func _air(want: Dictionary) -> void:
	want["thigh.L"] = Vector3(26.0, 0.0, 2.0)
	want["thigh.R"] = Vector3(-14.0, 0.0, -2.0)
	want["shin.L"] = Vector3(-42.0, 0.0, 0.0)
	want["shin.R"] = Vector3(-18.0, 0.0, 0.0)
	want["foot.L"] = Vector3(16.0, 0.0, 0.0)
	want["foot.R"] = Vector3(10.0, 0.0, 0.0)
	want["upper_arm.L"] = Vector3(-18.0, 0.0, -24.0)
	want["upper_arm.R"] = Vector3(-18.0, 0.0, 24.0)
	want["forearm.L"] = Vector3(38.0, 0.0, 0.0)
	want["forearm.R"] = Vector3(38.0, 0.0, 0.0)
	want["spine"] = Vector3(8.0, 0.0, 0.0)
	want["head"] = Vector3(-4.0, 0.0, 0.0)


## Уворот: присед, подбор ног, наклон корпуса. Возвращает смещение таза.
func _dodge(want: Dictionary, t: float) -> Vector3:
	var u := clampf(t / T.DODGE_DURATION, 0.0, 1.0)
	var k := sin(u * PI)   # плавно нарастает и гаснет

	_mix(want, {
		"thigh.L": Vector3(50.0, 0.0, 3.0),
		"thigh.R": Vector3(44.0, 0.0, -3.0),
		"shin.L": Vector3(-70.0, 0.0, 0.0),
		"shin.R": Vector3(-64.0, 0.0, 0.0),
		"foot.L": Vector3(20.0, 0.0, 0.0),
		"foot.R": Vector3(18.0, 0.0, 0.0),
		"spine": Vector3(26.0, 0.0, 0.0),
		"chest": Vector3(8.0, 0.0, 0.0),
		"head": Vector3(-20.0, 0.0, 0.0),
		"upper_arm.L": Vector3(26.0, 0.0, -10.0),
		"upper_arm.R": Vector3(26.0, 0.0, 10.0),
		"forearm.L": Vector3(60.0, 0.0, 0.0),
		"forearm.R": Vector3(60.0, 0.0, 0.0),
	}, k)

	return Vector3(0.0, -0.22 * k, 0.0)


## Смешивает набор углов в цель: u=0 — ничего, u=1 — полностью.
func _mix(want: Dictionary, extra: Dictionary, u: float) -> void:
	if u <= 0.0:
		return
	for bone in extra:
		var add: Vector3 = extra[bone] * u
		want[bone] = want.get(bone, Vector3.ZERO) + add


## Ставит в want АБСОЛЮТНУЮ позу — линейную смесь между from и to.
##
## Отличие от _mix() принципиальное: _mix прибавляет (нужно, чтобы наложить
## покачивание на позу), а здесь нужна именно замена. Для переходов между
## позами (стойка -> замах -> удар -> стойка) сложение не годится: углы
## накапливались бы, и рука уезжала за спину.
func _lerp_pose(want: Dictionary, from: Dictionary, to: Dictionary, u: float) -> void:
	var keys: Dictionary = {}
	for k in from:
		keys[k] = true
	for k in to:
		keys[k] = true
	for k in keys:
		var a: Vector3 = from.get(k, Vector3.ZERO)
		var b: Vector3 = to.get(k, Vector3.ZERO)
		want[k] = a.lerp(b, u)


## Ставит позу БЕЗ сглаживания — для витрины, где нужен точный кадр.
## В игре так делать нельзя: поза переключилась бы рывком за один кадр.
func set_pose_direct(spec: Dictionary) -> void:
	if not _loaded:
		return
	for name in _idx:
		var target: Vector3 = spec.get(name, Vector3.ZERO)
		_bend[name] = target
		var bend := Quaternion(Vector3.RIGHT, deg_to_rad(target.x)) \
			* Quaternion(Vector3.BACK, deg_to_rad(target.z)) \
			* Quaternion(Vector3.UP, deg_to_rad(target.y))
		skeleton.set_bone_pose_rotation(_idx[name], _rest_rot[name] * bend)
	if _idx.has("hips"):
		skeleton.set_bone_pose_position(_idx["hips"], _rest_pos["hips"])


## Переводит «изгиб в градусах» в позу кости и ставит её.
func _apply(want: Dictionary, hip_offset: Vector3, delta: float) -> void:
	# Сглаживание: без него поза переключается рывком за один кадр.
	var rate := 1.0 - exp(-22.0 * delta)

	for name in _idx:
		var target: Vector3 = want.get(name, Vector3.ZERO)
		var cur: Vector3 = _bend[name]
		cur = cur.lerp(target, rate)
		_bend[name] = cur

		# Изгиб вокруг осей кости: сначала X (вперёд-назад), затем Z (в стороны),
		# затем Y (скрутка).
		var bend := Quaternion(Vector3.RIGHT, deg_to_rad(cur.x)) \
			* Quaternion(Vector3.BACK, deg_to_rad(cur.z)) \
			* Quaternion(Vector3.UP, deg_to_rad(cur.y))

		# ГЛАВНОЕ: поза = поворот покоя * изгиб. Без поворота покоя скелет
		# складывается, и руки уезжают за голову.
		skeleton.set_bone_pose_rotation(_idx[name], _rest_rot[name] * bend)

	# Таз: положение позы тоже абсолютное, поэтому смещение прибавляется
	# к положению покоя.
	if _idx.has("hips"):
		skeleton.set_bone_pose_position(_idx["hips"], _rest_pos["hips"] + hip_offset)
