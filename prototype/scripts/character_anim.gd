## Единый проигрыватель анимаций для героини, клона и витрины.
##
## Ключи запечены на НАШ скелет в assets/heroine/animations/motion_set.tres.
## Источник: tools/animation/build_motion_set.py. Blender не нужен.
## В AnimationLibrary — обычные rotation_3d / position_3d треки, не углы,
## подобранные отдельно для игры и отдельно для витрины.
##
## Почему не сглаживаем каждую кость каждый кадр: такой low-pass опаздывал
## за ударом. Теперь SLERP только между ключами и при СМЕНЕ состояния;
## к активному кадру атаки переход уже закончен. Фаза шага идёт от реально
## пройденного расстояния ПОСЛЕ move_and_slide(), не от настенных часов.
extends Node3D

const Appearance := preload("res://scripts/character_appearance.gd")
const T := preload("res://scripts/tuning.gd")
const MODEL_PATH := "res://assets/heroine/female_A_rigged_safe.glb"
const MOTIONS: AnimationLibrary = preload("res://assets/heroine/animations/motion_set.tres")

var appearance: Node3D
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
var _model: Node
var _loaded := false
var _bone_names: PackedStringArray = []
var _rotation_tracks: Dictionary = {}
var _position_tracks: Dictionary = {}
var _upper_body: Array[int] = []
var _hips_index := -1
var _clock := 0.0
var _phase := 0.0
var _gait_blend := 0.0
var _sprint_blend := 0.0
var _move_weight := 0.0
var _directional_blend := 0.0
# +Z forward / +X anatomical left / -X right / -Z back, L1-normalised.
var _direction_weights := Vector4(1, 0, 0, 0)
var _combat_mode := true
var _combat_blend := 1.0
var _takeoff_pose: Dictionary = {}
var _air_from_relaxed := false
var _air_time := 0.0
var _air_launched := false
var _air_launch_speed := 0.0
var _land_time := 100.0
var _hit_time := 100.0
var _hit_zone := "unknown"
var _hit_direction := Vector3(0, 0, -1) # model-local incoming attacker -> victim
var _was_grounded := true
var _state := ""
var _last_pose: Dictionary = {}
var _transition_from: Dictionary = {}
var _transition_elapsed := 1.0
var _transition_length := 0.10


func _ready() -> void:
	if not load_character(MODEL_PATH):
		push_warning("Не удалось загрузить модель/анимации — оставлена капсула")


func load_character(path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var packed := load(path) as PackedScene
	if packed == null:
		return false
	var instance := packed.instantiate()
	var found := _find_skeleton(instance)
	if found == null:
		instance.free()
		return false
	if is_instance_valid(appearance):
		appearance.free()
	if is_instance_valid(_model):
		_model.free()
	if is_instance_valid(animation_player):
		animation_player.free()
	_model = instance
	add_child(instance)
	skeleton = found
	_bone_names.clear()
	_upper_body.clear()
	for i in skeleton.get_bone_count():
		var bone := skeleton.get_bone_name(i)
		_bone_names.append(bone)
		if not bone.begins_with("thigh.") and not bone.begins_with("shin.") \
				and not bone.begins_with("foot.") and not bone.begins_with("toe.") and bone != "hips":
			_upper_body.append(i)
	_hips_index = skeleton.find_bone("hips")
	if _hips_index < 0 or not _bind_tracks():
		return false

	appearance = Node3D.new()
	appearance.set_script(Appearance)
	appearance.name = "LaboratoryAppearance"
	add_child(appearance)
	appearance.install(self, skeleton, instance)

	# Библиотеку видно у AnimationPlayer в удалённом инспекторе Godot.
	# Сам player не пишет позу: ниже мы сэмплируем его нативные треки и
	# смешиваем их явно (дистанционная фаза и разные тайминги клона).
	animation_player = AnimationPlayer.new()
	animation_player.name = "MotionLibrary"
	add_child(animation_player)
	animation_player.root_node = animation_player.get_path_to(skeleton)
	animation_player.add_animation_library("motion", MOTIONS)
	animation_player.active = false
	var fallback := get_node_or_null("Fallback") as Node3D
	if fallback != null:
		fallback.visible = false
	_loaded = true
	seek_clip("guard", 0.0)
	return true


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _bind_tracks() -> bool:
	_rotation_tracks.clear()
	_position_tracks.clear()
	for clip_name in MOTIONS.get_animation_list():
		var clip := MOTIONS.get_animation(clip_name)
		var rotations: Array[int] = []
		for bone in _bone_names:
			var track := clip.find_track(NodePath(".:" + bone), Animation.TYPE_ROTATION_3D)
			if track < 0:
				push_error("В %s нет кости %s" % [clip_name, bone])
				return false
			rotations.append(track)
		_rotation_tracks[clip_name] = rotations
		var hip_track := clip.find_track(NodePath(".:hips"), Animation.TYPE_POSITION_3D)
		if hip_track < 0:
			return false
		_position_tracks[clip_name] = hip_track
	return true


func clip_duration(clip_name: StringName) -> float:
	return MOTIONS.get_animation(clip_name).length if MOTIONS.has_animation(clip_name) else 0.0


func sample_clip(clip_name: StringName, time: float) -> Dictionary:
	if not _loaded or not MOTIONS.has_animation(clip_name):
		return {}
	var clip := MOTIONS.get_animation(clip_name)
	var at := clampf(time, 0.0, clip.length)
	var rotations: Array[Quaternion] = []
	for track in _rotation_tracks[clip_name]:
		rotations.append(clip.rotation_track_interpolate(track, at).normalized())
	return {"rotations": rotations,
		"hips": clip.position_track_interpolate(_position_tracks[clip_name], at)}


## Витрина и автотесты получают ТОЧНЫЙ кадр тех же треков, без low-pass.
func seek_clip(clip_name: StringName, time: float, preview_delta: float = 0.0) -> void:
	var pose := sample_clip(clip_name, time)
	if not pose.is_empty():
		_last_pose = pose
		_apply_pose(pose)
		if appearance != null:
			appearance.set_hands(1.0 if str(clip_name).ends_with("_relaxed") else 0.0)
			if preview_delta > 0.0:
				appearance.update_pose(preview_delta)
			elif preview_delta == 0.0:
				appearance.reset_cloth()


## Перевод игрового времени в клип: подготовка / активная фаза / возврат.
## У клона другая длительность подготовки, но контакт совпадает с уроном.
func attack_clip_name(side: String, kind: String = "straight") -> String:
	return "attack_body_hook" if kind == "hook" else "attack_right" if side == "R" else "attack_left"


func attack_clip_time(time: float, timing: Vector3, side: String = "R", kind: String = "straight") -> float:
	var clip := MOTIONS.get_animation(attack_clip_name(side, kind))
	var windup: float = clip.get_meta("windup")
	var active_end: float = clip.get_meta("active_end")
	if time <= timing.x:
		return clampf(time / maxf(timing.x, 0.001), 0.0, 1.0) * windup
	if time <= timing.x + timing.y:
		return windup + (time - timing.x) / maxf(timing.y, 0.001) * (active_end - windup)
	return active_end + clampf((time - timing.x - timing.y) / maxf(timing.z, 0.001), 0.0, 1.0) \
		* (clip.length - active_end)


## Вызывать ПОСЛЕ физического перемещения.
## local_velocity — в осях модели (+Z вперёд), context.distance — реально
## пройденные метры; grounded, vertical_speed, attack_timing — от физики.
func update_motion(delta: float, local_velocity: Vector3, action: String,
		action_time: float, side: String = "R", context: Dictionary = {}) -> void:
	if not _loaded:
		return
	_clock += delta
	_hit_time += delta
	_land_time += delta
	var grounded: bool = context.get("grounded", true)
	_combat_mode = context.get("combat", true)
	_combat_blend = move_toward(_combat_blend, 1.0 if _combat_mode else 0.0, delta * 3.0)
	if grounded and not _was_grounded:
		_land_time = 0.0
	if not grounded:
		# Явный импульс также перезапускает визуальный взлёт при coyote-jump,
		# когда персонаж уже кадр-два не касается пола. Сход с края НЕ прыжок.
		if _was_grounded or context.get("jump_started", false):
			_air_time = 0.0
			_takeoff_pose = _last_pose
			_air_from_relaxed = not _combat_mode
			_air_launch_speed = float(context.get("vertical_speed", 0.0))
			_air_launched = _air_launch_speed > 1.0
		else:
			_air_time += delta
	_was_grounded = grounded

	var planar := Vector2(local_velocity.x, local_velocity.z).length()
	_directional_blend = move_toward(_directional_blend, 1.0 if context.get("directional", false) else 0.0, delta*6.0)
	if planar > .03:
		var desired := Vector4(maxf(local_velocity.z, 0), maxf(local_velocity.x, 0), maxf(-local_velocity.x, 0), maxf(-local_velocity.z, 0))
		desired /= maxf(absf(local_velocity.x)+absf(local_velocity.z), .000001)
		_direction_weights = _direction_weights.lerp(desired, 1.0-exp(-delta*12.0))
	var walk := MOTIONS.get_animation("walk")
	var run := MOTIONS.get_animation("run")
	var relaxed_walk := MOTIONS.get_animation("walk_relaxed")
	var relaxed_run := MOTIONS.get_animation("run_relaxed")
	var stance := smoothstep(0.0, 1.0, _combat_blend)
	var walk_stride := lerpf(float(relaxed_walk.get_meta("stride")), float(walk.get_meta("stride")), stance)
	var walk_speed := lerpf(float(relaxed_walk.get_meta("speed")), float(walk.get_meta("speed")), stance)
	var run_stride := lerpf(float(relaxed_run.get_meta("stride")), float(run.get_meta("stride")), stance)
	var run_speed := lerpf(float(relaxed_run.get_meta("speed")), float(run.get_meta("speed")), stance)
	# Player has explicit walk/jog/sprint controls; the clone retains its own
	# slower combat walk/run calibration and doesn't inherit Shift/Alt input.
	walk_speed = float(context.get("walk_speed", walk_speed))
	run_speed = float(context.get("jog_speed", run_speed))
	var sprint_speed: float = context.get("sprint_speed", T.RUN_SPEED)
	# New directional cycles have metre-calibrated tiers for both actors;
	# clone speeds remain its own physical 1.65/3.4, not player input modes.
	walk_speed = lerpf(walk_speed, T.WALK_SPEED, _directional_blend)
	run_speed = lerpf(run_speed, T.JOG_SPEED, _directional_blend)
	var directional_max := sprint_speed if context.has("sprint_speed") else lerpf(T.DIRECTIONAL_RUN_SPEED, T.RUN_SPEED, _direction_weights.x)
	sprint_speed = lerpf(sprint_speed, directional_max, _directional_blend)
	var want_gait := smoothstep(walk_speed + .20, run_speed, planar)
	var want_sprint := smoothstep(run_speed + .30, sprint_speed, planar)
	_gait_blend = move_toward(_gait_blend, want_gait, delta * 4.0)
	_sprint_blend = move_toward(_sprint_blend, want_sprint, delta * 4.0)
	_move_weight = move_toward(_move_weight, smoothstep(0.03, 0.6, planar), delta * 7.5)
	if grounded and action != "attack" and action != "dodge":
		var distance: float = context.get("distance", planar * delta)
		var stride := lerpf(lerpf(walk_stride, run_stride, _gait_blend),
			float(MOTIONS.get_animation("sprint_relaxed").get_meta("stride")), _sprint_blend)
		if _directional_blend > 0.0:
			stride = lerpf(stride, _directional_stride(), _directional_blend)
		# Backward locomotion has its OWN authored positive-time contact
		# sequence, not a reversed forward run. No phase reset on lock/R.
		var direction := -1.0 if local_velocity.z < -0.05 and _directional_blend <= .001 else 1.0
		_phase = fposmod(_phase + distance * direction / stride, 1.0)

	# На земле атака целиком заменяет позу передвижения; сэмплировать
	# и смешивать её заранее в каждом боевом тике было лишней работой.
	# Для воздуха и остальных состояний сохраняем прежний путь без изменений.
	var pose: Dictionary = {} if action == "attack" and grounded else _locomotion_pose()
	var state := "ground"
	if action == "attack":
		var kind: String = context.get("attack_kind", "straight")
		state = "attack_"+side+("_hook" if kind == "hook" else "")
		var timing: Vector3 = context.get("attack_timing", Vector3(T.ATTACK_WINDUP, T.ATTACK_ACTIVE, T.ATTACK_RECOVERY))
		var attack_pose := sample_clip(attack_clip_name(side, kind),
			attack_clip_time(action_time, timing, side, kind))
		pose = attack_pose if grounded else _replace_upper(_air_pose(context), attack_pose)
	elif action == "dodge":
		state = "dodge"
		pose = sample_dodge(action_time, context.get("dodge_direction", Vector3(0, 0, 1)))
		if not _combat_mode:
			pose = _blend_pose(pose, _locomotion_pose(), smoothstep(.38, T.DODGE_DURATION, action_time))
	elif not grounded:
		state = "air"
		pose = _air_pose(context)
	elif _land_time < clip_duration("land"):
		state = "land"
		var landing := sample_clip("land", _land_time)
		# На бегу амортизируем в основном корпусом, не перебиваем шаг целиком.
		var recover := _move_weight * .7
		if not _combat_mode:
			# После амортизации возвращаемся в обычную стойку, не поднимаем
			# кулаки к лицу на последних кадрах посадки. Боевой клип не меняем.
			recover = maxf(recover, smoothstep(.10, clip_duration("land"), _land_time))
		pose = _blend_pose(landing, pose, recover)

	if state != _state or (state == "air" and context.get("jump_started", false)):
		_transition_from = _last_pose
		_transition_elapsed = 0.0
		_transition_length = .055 if state in ["air", "land", "dodge"] else .075 if state.begins_with("attack") else .12
		_state = state
	_transition_elapsed += delta
	if not _transition_from.is_empty() and _transition_elapsed < _transition_length:
		pose = _blend_pose(_transition_from, pose, smoothstep(0.0, _transition_length, _transition_elapsed))

	if _hit_time < clip_duration("hit"):
		pose = _add_hit(pose, .35 if action == "attack" else 1.0)
	_apply_pose(pose)
	if appearance != null and grounded and state in ["ground", "dodge"]:
		# Floor-safe clips can still penetrate when SLERP-blended: the foot
		# describes an arc, not the IK target line. Stabilise the resulting
		# actual sole, not the Character node or a guessed ankle height.
		var lift := maxf(0.0, .001-appearance.sole_height())
		if lift > 0.0:
			pose["hips"] += Vector3.UP*lift
			skeleton.set_bone_pose_position(_hips_index, pose["hips"])
	_last_pose = pose
	if appearance != null:
		var open_hand := 0.0 if action == "attack" else 1.0-_combat_blend
		appearance.set_hands(move_toward(appearance.hand_open, open_hand, delta*12.0))
		appearance.update_pose(delta, grounded, grounded and planar < .03 and action == ""
			and _hit_time >= clip_duration("hit") and context.get("cache_idle_cloth", true))


func sample_dodge(time: float, direction: Vector3) -> Dictionary:
	var along := sample_clip("dodge" if direction.z >= 0.0 else "dodge_back", time)
	if absf(direction.x) < .001:
		return along
	var across := sample_clip("dodge_left" if direction.x > 0.0 else "dodge_right", time)
	return _blend_pose(along, across, absf(direction.x)/(absf(direction.x)+absf(direction.z)))


func _locomotion_pose() -> Dictionary:
	var ordinary := _locomotion_set(false)
	var legacy := ordinary
	if _combat_blend > 0.0:
		legacy = _blend_pose(ordinary, _locomotion_set(true), smoothstep(0.0, 1.0, _combat_blend))
	if _directional_blend <= 0.0:
		return legacy
	var directional := _directional_pose()
	# Lock alone doesn't toggle R/T: retain relaxed hands/upper-body when
	# the player deliberately stays in ordinary stance while targeting.
	if _combat_blend < 1.0:
		directional = _blend_pose(_relaxed_target_upper(directional, ordinary), directional, smoothstep(0, 1, _combat_blend))
	return _blend_pose(legacy, directional, smoothstep(0, 1, _directional_blend))


func _relaxed_target_upper(base: Dictionary, ordinary: Dictionary) -> Dictionary:
	var result := _replace_upper(base, ordinary)
	# Target-facing steps have a LOWER, wider pelvis than the accepted free
	# walk. Copying its lowered arms unchanged made the open left hand cut
	# the dress on the fifth sampled Alt-side-step frame. A quiet 4-degree
	# abduction is specific to this relaxed target-facing blend: no larger
	# skirt/sleeve, new mask, raised guard, or edit to the ordinary free clips.
	for side in ["L", "R"]:
		var bone := skeleton.find_bone("upper_arm."+side)
		var parent := skeleton.get_bone_parent(bone)
		var parent_rotation := Quaternion.IDENTITY
		while parent >= 0:
			parent_rotation = result["rotations"][parent]*parent_rotation
			parent = skeleton.get_bone_parent(parent)
		var angle := deg_to_rad(4.0)*_move_weight*(1.0 if side == "L" else -1.0)
		var spread := Quaternion(Vector3.BACK, angle)
		result["rotations"][bone] = (parent_rotation.inverse()*spread*parent_rotation*result["rotations"][bone]).normalized()
	return result


func _directional_stride() -> float:
	var total := 0.0
	var names := ["forward", "left", "right", "back"]
	for i in 4:
		var walk := float(MOTIONS.get_animation("combat_"+names[i]+"_walk").get_meta("stride"))
		var jog := float(MOTIONS.get_animation("combat_"+names[i]+"_jog").get_meta("stride"))
		var sprint := float(MOTIONS.get_animation("combat_"+names[i]+"_sprint").get_meta("stride"))
		total += _direction_weights[i]*lerpf(lerpf(walk, jog, _gait_blend), sprint, _sprint_blend)
	return total


func _directional_pose() -> Dictionary:
	var result: Dictionary = {}
	var total := 0.0
	var names := ["forward", "left", "right", "back"]
	for i in 4:
		var weight := _direction_weights[i]
		if weight < .00001:
			continue
		var prefix: String = "combat_"+names[i]+"_"
		var gait := _blend_pose(sample_clip(prefix+"walk", _phase*clip_duration(prefix+"walk")),
			sample_clip(prefix+"jog", _phase*clip_duration(prefix+"jog")), _gait_blend)
		gait = _blend_pose(gait, sample_clip(prefix+"sprint", _phase*clip_duration(prefix+"sprint")), _sprint_blend)
		total += weight
		result = gait if result.is_empty() else _blend_pose(result, gait, weight/total)
	return _blend_pose(sample_clip("guard", fposmod(_clock, clip_duration("guard"))), result, _move_weight)


func _locomotion_set(combat: bool) -> Dictionary:
	var idle_name := "guard" if combat else "idle_relaxed"
	var walk_name := "walk" if combat else "walk_relaxed"
	var run_name := "run" if combat else "run_relaxed"
	var idle := sample_clip(idle_name, fposmod(_clock, clip_duration(idle_name)))
	var gait := _blend_pose(sample_clip(walk_name, _phase * clip_duration(walk_name)),
		sample_clip(run_name, _phase * clip_duration(run_name)), _gait_blend)
	gait = _blend_pose(gait, sample_clip("sprint_relaxed", _phase*clip_duration("sprint_relaxed")), _sprint_blend)
	return _blend_pose(idle, gait, _move_weight)


func _air_pose(context: Dictionary) -> Dictionary:
	var vertical: float = context.get("vertical_speed", 0.0)
	var takeoff := clip_duration("jump_start")
	if _air_launched and _air_time < takeoff and vertical > 0.0:
		if _air_from_relaxed and not _takeoff_pose.is_empty():
			# Из обычного шага/бега идём сразу к разгибанию прыжка,
			# а не делаем промежуточный рывок в боевую защиту.
			return _blend_pose(_takeoff_pose, sample_clip("jump_start", takeoff),
				smoothstep(0.0, takeoff, _air_time))
		return sample_clip("jump_start", _air_time)
	if _air_launched and vertical > 0.0:
		# Прогресс после разгибания до вершины траектории; не зацикливаем
		# короткий клип и не держим один неподвижный кадр в воздухе.
		var remaining_speed := maxf(.1, _air_launch_speed - T.GRAVITY * takeoff)
		var rise := clampf(1.0 - vertical / remaining_speed, 0.0, 1.0)
		return sample_clip("jump_up", rise * clip_duration("jump_up"))
	var impact_speed := sqrt(2.0 * T.GRAVITY_FALL * T.JUMP_HEIGHT)
	var fall := clampf(-vertical / impact_speed, 0.0, 1.0)
	if not _air_launched:
		fall = maxf(fall, .7)  # Сошли с уступа: не изображаем подбор ног при взлёте.
	var floor_distance: float = context.get("floor_distance", -1.0)
	if floor_distance >= 0.0:
		# На высокой площадке контакт раньше, чем на исходном полу. Луч
		# используется ТОЛЬКО для позы, не двигает тело и не меняет коллизии.
		var speed := maxf(0.0, -vertical)
		var until_contact := (sqrt(speed*speed + 2.0*T.GRAVITY_FALL*floor_distance) - speed) / T.GRAVITY_FALL
		fall = maxf(fall, 1.0 - clampf(until_contact / .18, 0.0, 1.0))
	return sample_clip("jump_down", fall * clip_duration("jump_down"))


## Телепорт/новый тест: не переносим фазу шага и отдачу из прошлой жизни.
func reset_motion(combat: bool = true) -> void:
	_combat_mode = combat
	_combat_blend = 1.0 if combat else 0.0
	_takeoff_pose = {}
	_air_from_relaxed = false
	_phase = 0.0
	_clock = 0.0
	_gait_blend = 0.0
	_sprint_blend = 0.0
	_move_weight = 0.0
	_directional_blend = 0.0
	_direction_weights = Vector4(1, 0, 0, 0)
	_air_time = 0.0
	_air_launched = false
	_air_launch_speed = 0.0
	_land_time = 100.0
	_hit_time = 100.0
	_hit_zone = "unknown"
	_hit_direction = Vector3(0, 0, -1)
	_was_grounded = true
	_state = ""
	_transition_from = {}
	_transition_elapsed = 1.0
	seek_clip("guard" if combat else "idle_relaxed", 0.0)


## Визуальная реакция без введения нового игрового оглушения.
## incoming_world is FROM attacker TOWARD victim, in WORLD coordinates.
## Zone/zero/non-finite direction fallback is safe; no gameplay stun/state.
func play_hit(zone: String = "unknown", incoming_world: Vector3 = Vector3.ZERO) -> void:
	_hit_time = 0.0
	_hit_zone = zone if zone in ["head", "torso", "legs"] else "unknown"
	_hit_direction = Vector3(0, 0, -1)
	if incoming_world.is_finite() and incoming_world.length_squared() > .00001:
		_hit_direction = global_basis.inverse()*incoming_world
		_hit_direction.y = 0
		_hit_direction = _hit_direction.normalized() if _hit_direction.length_squared() > .00001 else Vector3(0, 0, -1)


func _reaction_pose() -> Dictionary:
	if _hit_zone not in ["head", "torso"]:
		return sample_clip("hit", _hit_time) # legs have NO dedicated leg response yet
	var prefix := "hit_"+_hit_zone+"_"
	var along := sample_clip(prefix+("front" if _hit_direction.z <= 0 else "back"), _hit_time)
	var across := sample_clip(prefix+("left" if _hit_direction.x <= 0 else "right"), _hit_time)
	var amount := absf(_hit_direction.x)/maxf(absf(_hit_direction.x)+absf(_hit_direction.z), .000001)
	return _blend_pose(along, across, amount)


func _add_hit(pose: Dictionary, weight: float) -> Dictionary:
	var reaction := _reaction_pose()
	var reference := sample_clip("guard", 0.0)
	var result := _blend_pose(pose, pose, 0.0)
	for i in _upper_body:
		var rest: Quaternion = reference["rotations"][i]
		var value: Quaternion = reaction["rotations"][i]
		var difference := rest.inverse() * value
		var amount := weight*(.5 if _hit_zone == "legs" else 1.0)
		var name := _bone_names[i]
		if name.begins_with("shoulder.") or name.begins_with("upper_arm.") \
				or name.begins_with("forearm.") or name.begins_with("hand."):
			# The hit clip is authored relative to GUARD. Applying its arm
			# delta at full strength to lowered ordinary arms swung a forearm
			# through the waist during the first four combat-entry ticks.
			# Keep the torso/head flinch immediate; blend only this guard-
			# relative arm delta with the stance it actually belongs to.
			amount *= _combat_blend
		result["rotations"][i] = (pose["rotations"][i] * Quaternion.IDENTITY.slerp(difference, amount)).normalized()
	return result


func _replace_upper(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := _blend_pose(base, base, 0.0)
	for i in _upper_body:
		result["rotations"][i] = overlay["rotations"][i]
	return result


func _blend_pose(a: Dictionary, b: Dictionary, weight: float) -> Dictionary:
	var rotations: Array[Quaternion] = []
	for i in _bone_names.size():
		var from: Quaternion = a["rotations"][i]
		rotations.append(from.slerp(b["rotations"][i], weight).normalized())
	var hip: Vector3 = a["hips"]
	return {"rotations": rotations, "hips": hip.lerp(b["hips"], weight)}


func _apply_pose(pose: Dictionary) -> void:
	for i in _bone_names.size():
		skeleton.set_bone_pose_rotation(i, pose["rotations"][i])
	skeleton.set_bone_pose_position(_hips_index, pose["hips"])


## Совместимость со старыми вызовами; новый код передаёт update_motion().
func update_anim(delta: float, speed_ratio: float, action: String,
		action_time: float, side: String = "R") -> void:
	update_motion(delta, Vector3(0, 0, speed_ratio * T.RUN_SPEED), action, action_time,
		side, {"grounded": action != "air"})
