## Conservative geometric probe for an explicitly marked test ledge.
## Does not move the player or implement climbing; caller must also require
## an airborne approach, validate paths and animate hands/body before use.
extends RefCounted

const MAX_REACH := .90
const MIN_HAND_HEIGHT := 1.20
const MAX_HAND_HEIGHT := 2.35
const LANDING_INSET := .42
const CLEARANCE := .04


static func find_candidate(actor: CharacterBody3D, direction: Vector3) -> Dictionary:
	if not actor.is_inside_tree() or actor.get_world_3d() == null or not direction.is_finite():
		return {}
	var facing := Vector3(direction.x, 0, direction.z).normalized()
	if facing.length_squared() < .5:
		return {}
	var space := actor.get_world_3d().direct_space_state
	var exclude: Array[RID] = [actor.get_rid()]
	var origin := actor.global_position
	var side_query := PhysicsRayQueryParameters3D.create(origin + Vector3.UP * MIN_HAND_HEIGHT,
		origin + Vector3.UP * MIN_HAND_HEIGHT + facing * MAX_REACH, 1, exclude)
	var side := space.intersect_ray(side_query)
	if side.is_empty():
		return {}
	var surface: Node = side.collider
	if not surface.is_in_group("climbable_ledge"):
		return {}
	var normal: Vector3 = side.normal
	if absf(normal.y) > .15 or facing.dot(normal) > -.85:
		return {}
	var inner: Vector3 = side.position - normal * LANDING_INSET
	var top_query := PhysicsRayQueryParameters3D.create(
		Vector3(inner.x, origin.y + MAX_HAND_HEIGHT, inner.z),
		Vector3(inner.x, origin.y + MIN_HAND_HEIGHT, inner.z), 1, exclude)
	var top := space.intersect_ray(top_query)
	if top.is_empty() or top.collider != surface or (top.normal as Vector3).y < .95:
		return {}
	var top_point: Vector3 = top.position
	var collider := actor.get_node_or_null("Collision") as CollisionShape3D
	if collider == null or not (collider.shape is CapsuleShape3D):
		return {}
	var capsule := collider.shape as CapsuleShape3D
	# A single top ray is not enough near a corner or a narrow shelf: sample
	# the footprint so the full capsule has support on this same surface.
	var tangent := Vector3(-normal.z, 0.0, normal.x)
	for offset in [tangent * capsule.radius, -tangent * capsule.radius,
			normal * capsule.radius, -normal * capsule.radius]:
		var sample: Vector3 = top_point + offset
		var support_query := PhysicsRayQueryParameters3D.create(sample + Vector3.UP * .05,
			sample + Vector3.DOWN * .08, 1, exclude)
		var support := space.intersect_ray(support_query)
		if support.is_empty() or support.collider != surface or (support.normal as Vector3).y < .95:
			return {}
	var landing := Vector3(inner.x, top_point.y + CLEARANCE, inner.z)
	var clearance_query := PhysicsShapeQueryParameters3D.new()
	clearance_query.shape = collider.shape
	clearance_query.transform = Transform3D(actor.global_basis, landing + actor.global_basis * collider.position)
	clearance_query.collision_mask = actor.collision_mask
	clearance_query.exclude = exclude
	if not space.intersect_shape(clearance_query, 1).is_empty():
		return {}
	return {"surface": surface, "edge": Vector3(side.position.x, top_point.y, side.position.z),
		"normal": normal, "landing": landing}
