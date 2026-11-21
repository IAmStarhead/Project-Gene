## Честная проверка удара кулаком: капсула руки (от плеча до костяшек) против цилиндра торса.
##
## Что исправлено относительно прежней одиночной точки:
##   1. Проверяется ВЕСЬ отрезок руки (от грудины до кулака), поэтому вплотную кулак не
##      «пролетает насквозь» мимо стоящего рядом противника.
##   2. Для гуманоидов берётся реальный анатомический радиус торса (0.24 м), а не широкая
##      физическая капсула 0.34 м для стен — удар больше не цепляет воздух за метр от тела.
##   3. В живой активной фазе учитывается реальная кость кисти (hand.L / hand.R) скелета,
##      а при перескоке кадра (просадка FPS или headless-тест) работает точный вынос reach.
##   4. Возвращается зона попадания (голова / корпус / ноги) — фундамент под травмы конечностей.
extends RefCounted

const T := preload("res://scripts/tuning.gd")
const Moves := preload("res://scripts/move_catalog.gd")

const FIST_RADIUS := 0.11
const KNUCKLE_EXTEND := 0.07
const DEFAULT_BODY_RADIUS := 0.24
const DEFAULT_BODY_HEIGHT := 1.70
const CHEST_HEIGHT := 1.28

const ZONE_LABELS := {
	"head": "голова",
	"torso": "корпус",
	"legs": "ноги",
}


## Возвращает [боевой_радиус_тела, высота_тела] для цели.
static func body_size(node: Node3D) -> Array:
	if not is_instance_valid(node):
		return [DEFAULT_BODY_RADIUS, DEFAULT_BODY_HEIGHT]
	for child in node.get_children():
		var shape_node: CollisionShape3D = null
		if child is CollisionShape3D:
			shape_node = child
		elif child.get_child_count() > 0:
			for grand in child.get_children():
				if grand is CollisionShape3D:
					shape_node = grand
					break
		if shape_node == null or shape_node.shape == null:
			continue
		var shape := shape_node.shape
		if shape is CapsuleShape3D:
			var cap := shape as CapsuleShape3D
			# Узкий анатомический радиус торса вместо широкой капсулы столкновений со стенами.
			return [minf(cap.radius, T.BODY_HIT_RADIUS), cap.height]
		if shape is CylinderShape3D:
			var cyl := shape as CylinderShape3D
			return [cyl.radius, cyl.height]
		if shape is SphereShape3D:
			var sph := shape as SphereShape3D
			return [sph.radius, sph.radius * 2.0]
	return [DEFAULT_BODY_RADIUS, DEFAULT_BODY_HEIGHT]


static func fist_point(origin: Vector3, forward: Vector3, reach: float) -> Vector3:
	var f := _flat_forward(forward)
	return Vector3(origin.x, origin.y + CHEST_HEIGHT, origin.z) + f * reach


## Проверка пересечения отрезка руки атакующего с цилиндром цели.
static func overlaps(
	attacker: Node3D,
	victim: Node3D,
	forward: Vector3,
	reach: float,
	side: String = "R",
	use_live_bone: bool = false,
	attack_kind: String = "straight"
) -> bool:
	return not _test_pair(attacker, victim, _flat_forward(forward), reach, side, use_live_bone, attack_kind).is_empty()


## Подробный поиск ближайшего попадания: {} при промахе, либо {"target", "zone", "distance"}.
static func find_hit(
	attacker: Node3D,
	candidates: Array,
	forward: Vector3,
	reach: float,
	half_angle_deg: float,
	side: String = "L",
	use_live_bone: bool = false,
	attack_kind: String = "straight"
) -> Dictionary:
	if not is_instance_valid(attacker):
		return {}
	var f := _flat_forward(forward)
	var best := {}
	var best_dist := INF

	for node in candidates:
		if node == attacker or not is_instance_valid(node) or not (node is Node3D):
			continue
		var victim := node as Node3D
		if victim.has_method("is_alive") and not bool(victim.call("is_alive")):
			continue
		var to := victim.global_position - attacker.global_position
		to.y = 0.0
		var dist := to.length()
		if dist < 0.001:
			continue
		if rad_to_deg(f.angle_to(to / dist)) > half_angle_deg:
			continue
		var hit := _test_pair(attacker, victim, f, reach, side, use_live_bone, attack_kind)
		if hit.is_empty():
			continue
		if dist < best_dist:
			best_dist = dist
			best = hit

	return best


## Совместимая обёртка: возвращает поражённый Node3D или null.
static func nearest_hit(
	attacker: Node3D,
	candidates: Array,
	forward: Vector3,
	reach: float,
	half_angle_deg: float,
	side: String = "L",
	use_live_bone: bool = false,
	attack_kind: String = "straight"
) -> Node3D:
	var hit := find_hit(attacker, candidates, forward, reach, half_angle_deg, side, use_live_bone, attack_kind)
	return hit.get("target", null) as Node3D


static func zone_label(zone: String) -> String:
	return String(ZONE_LABELS.get(zone, "корпус"))


## Реальный зазор между анатомическими корпусами (для честной отладки F3).
static func surface_gap(attacker: Node3D, victim: Node3D, own_radius: float = DEFAULT_BODY_RADIUS) -> float:
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return INF
	var d := victim.global_position - attacker.global_position
	d.y = 0.0
	var size := body_size(victim)
	return maxf(0.0, d.length() - own_radius - float(size[0]))


static func _test_pair(
	attacker: Node3D,
	victim: Node3D,
	f: Vector3,
	reach: float,
	side: String,
	use_live_bone: bool,
	attack_kind: String = "straight"
) -> Dictionary:
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return {}

	var origin := attacker.global_position
	var hook := attack_kind == "hook"
	var strike_height := 1.10 if hook else CHEST_HEIGHT
	var seg_a := Vector3(origin.x, origin.y + strike_height, origin.z) + f * 0.10
	var seg_b := Vector3(origin.x, origin.y + strike_height, origin.z) + f * reach
	var source := "reach_fallback"

	if use_live_bone:
		var hand := _live_hand_pos(attacker, side)
		if hand.is_finite():
			var rel := hand - origin
			var fwd_proj := rel.x * f.x + rel.z * f.z
			# Используем живую кость кисти, когда рука реально выброшена вперёд в активном кадре.
			if fwd_proj >= (0.25 if hook else 0.44) and fwd_proj <= reach + (0.0 if hook else 0.14):
				seg_b = hand + f * KNUCKLE_EXTEND
				seg_b.y = clampf(seg_b.y, origin.y + 0.65, origin.y + 1.68)
				source = "live_hand"
				if hook:
					# New short hook may curve sideways but may never inherit
					# the straight punch's +.14 m permissive reach tolerance.
					var flat := Vector3(seg_b.x-origin.x, 0, seg_b.z-origin.z).limit_length(reach)
					seg_b.x = origin.x+flat.x
					seg_b.z = origin.z+flat.z

	var target_pos := victim.global_position
	var size := body_size(victim)
	var radius: float = float(size[0])
	var height: float = float(size[1])

	var closest := _closest_on_segment_xz(seg_a, seg_b, target_pos)
	var dx := closest.x - target_pos.x
	var dz := closest.z - target_pos.z
	var horiz := sqrt(dx * dx + dz * dz)
	if horiz > radius + FIST_RADIUS:
		return {}

	var local_y := closest.y - target_pos.y
	if local_y < -FIST_RADIUS or local_y > height + FIST_RADIUS:
		return {}

	var rel_y := clampf(local_y / maxf(height, 0.1), 0.0, 1.0)
	var zone := "torso"
	if rel_y >= 0.83:
		zone = "head"
	elif rel_y < 0.48:
		zone = "legs"

	return {
		"target": victim,
		"zone": zone,
		"distance": horiz,
		# Approximate point on the existing arm segment, NOT an anatomical
		# surface contact or measured normal. Incoming direction is explicitly
		# WORLD, from attacker toward victim (horizontal, unit length).
		"point_world": closest,
		"direction_world": _flat_forward(target_pos-origin),
		"approximate": true, "source": source, "attack_kind": attack_kind,
	}


## Compatible confirmed-contact adapter. Existing dummies/probes retain their
## two-argument contract; the humanoids opt into zone + WORLD direction.
## Return acceptance separately from geometric contact (e.g. dodge i-frames).
static func deliver_hit(victim: Node3D, amount: float, hit: Dictionary) -> bool:
	if not is_instance_valid(victim):
		return false
	if victim.has_method("receive_hit"):
		var accepted: Variant = victim.call("receive_hit", amount, hit)
		return bool(accepted) if accepted is bool else true
	if victim.has_method("take_damage"):
		var direction: Vector3 = hit.get("direction_world", Vector3.ZERO)
		victim.call("take_damage", amount, direction)
		return true
	return false


static func _live_hand_pos(attacker: Node3D, side: String) -> Vector3:
	var ch := attacker.get_node_or_null("Character")
	if ch == null:
		return Vector3(INF, INF, INF)
	var skel_v: Variant = ch.get("skeleton")
	if not (skel_v is Skeleton3D):
		return Vector3(INF, INF, INF)
	var skel := skel_v as Skeleton3D
	var bone_name := "hand.L" if side == "L" else "hand.R"
	var idx := skel.find_bone(bone_name)
	if idx < 0:
		return Vector3(INF, INF, INF)
	return skel.global_transform * skel.get_bone_global_pose(idx).origin


static func _closest_on_segment_xz(a: Vector3, b: Vector3, p: Vector3) -> Vector3:
	var abx := b.x - a.x
	var abz := b.z - a.z
	var len_sq := abx * abx + abz * abz
	if len_sq < 0.00001:
		return b
	var t := clampf(((p.x - a.x) * abx + (p.z - a.z) * abz) / len_sq, 0.0, 1.0)
	return a.lerp(b, t)


static func _flat_forward(forward: Vector3) -> Vector3:
	var f := Vector3(forward.x, 0.0, forward.z)
	return f.normalized() if f.length_squared() > 0.0001 else Vector3.FORWARD


## NEW legs-only contact path. A bounded 120 Hz sweep of the SAME native
## animation tracks across the intersected active interval, not a fist ray
## and not an aim-by-zone. The small foot / distal-shin capsules are an
## approximation, explicitly reported as such. Old punch geometry is intact.
static func find_kick_hit(attacker: Node3D, candidates: Array, forward: Vector3,
		kind: String, previous_time: float, time: float) -> Dictionary:
	if not is_instance_valid(attacker) or not Moves.is_kick(kind): return {}
	var ch := attacker.get_node_or_null("Character")
	if ch == null or not ch.has_method("sample_joint_transforms"): return {}
	var profile := Moves.profile(kind)
	var timing: Vector3 = profile.timing
	var begin := maxf(previous_time,timing.x)
	var end := minf(time,timing.x+timing.y)
	if end < begin: return {}
	var sk: Skeleton3D = ch.skeleton
	var side: String = profile.side
	var shin := sk.find_bone("shin."+side)
	var foot := sk.find_bone("foot."+side)
	var toe := sk.find_bone("toe."+side)
	if mini(shin,mini(foot,toe)) < 0: return {}
	var samples := maxi(1,ceili((end-begin)*120.0))
	var f := _flat_forward(forward)
	var best: Dictionary = {}
	var best_distance := INF
	# Max 18 samples for the current .12/.14 s windows, even after a long
	# frame. Entry/exit times are included exactly; no extrapolated hits.
	for step in samples+1:
		var at := lerpf(begin,end,float(step)/samples)
		var joints: Array[Transform3D] = ch.sample_joint_transforms(profile.clip,at)
		var knee: Vector3 = ch.global_transform*joints[shin].origin
		var ankle: Vector3 = ch.global_transform*joints[foot].origin
		var toe_point: Vector3 = ch.global_transform*joints[toe].origin
		var segments: Array = [[ankle,toe_point,.085,"foot"]]
		if kind != "front_kick":
			segments.append([knee.lerp(ankle,.50),ankle,.070,"distal_shin"])
		for node in candidates:
			if node == attacker or not is_instance_valid(node) or not (node is Node3D): continue
			var victim := node as Node3D
			if victim.has_method("is_alive") and not bool(victim.call("is_alive")): continue
			var to := victim.global_position-attacker.global_position
			to.y = 0
			var distance := to.length()
			if distance < .001 or distance > float(profile.reach)+float(body_size(victim)[0])+.10: continue
			if rad_to_deg(f.angle_to(to/distance)) > T.ATTACK_ANGLE: continue
			for segment in segments:
				var hit := _leg_segment_hit(attacker,victim,segment[0],segment[1],segment[2],float(profile.reach))
				if hit.is_empty() or distance >= best_distance: continue
				hit.merge({"attack_kind":kind,"source":"authored_leg_sweep","sample_time":at,
					"effector":segment[3],"side":side})
				best = hit
				best_distance = distance
	return best


static func _leg_segment_hit(attacker: Node3D, victim: Node3D, a: Vector3,
		b: Vector3, radius: float, reach: float) -> Dictionary:
	# Hard radial envelope belongs ONLY to new moves. Never inherit the
	# straight punch's permissive +.14 m live-bone tolerance.
	for point in [a,b]:
		if Vector2(point.x-attacker.global_position.x,point.z-attacker.global_position.z).length() > reach+.035:
			return {}
	var target := victim.global_position
	var size := body_size(victim)
	var closest := _closest_on_segment_xz(a,b,target)
	var distance := Vector2(closest.x-target.x,closest.z-target.z).length()
	if distance > float(size[0])+radius: return {}
	var local_y := closest.y-target.y
	if local_y < -radius or local_y > float(size[1])+radius: return {}
	# The segment is blocked by laboratory geometry. World layer only: do
	# not let the victim's physics capsule occlude its own confirmed contact.
	if attacker.is_inside_tree() and attacker.get_world_3d() != null:
		var origin := attacker.global_position+Vector3(0,maxf(.12,closest.y-attacker.global_position.y),0)
		var query := PhysicsRayQueryParameters3D.create(origin,closest,1)
		if not attacker.get_world_3d().direct_space_state.intersect_ray(query).is_empty(): return {}
	var ratio := clampf(local_y/maxf(.1,float(size[1])),0,1)
	return {"target":victim,"zone":"head" if ratio >= .83 else "legs" if ratio < .48 else "torso",
		"distance":distance,"point_world":closest,"direction_world":_flat_forward(target-attacker.global_position),
		"approximate":true}
