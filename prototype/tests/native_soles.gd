## Independent dense imported-skin diagnostic. Test/review ONLY, never an
## ankle-offset approximation and never the reduced production support set.
extends RefCounted

static func measure(character: Node3D) -> Dictionary:
	var body: MeshInstance3D = character.appearance.body
	var sk: Skeleton3D = character.skeleton
	var arrays := body.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var transforms: Array[Transform3D] = []
	for i in body.skin.get_bind_count():
		var bone := sk.find_bone(body.skin.get_bind_name(i))
		transforms.append(sk.global_transform*sk.get_bone_global_pose(bone)*body.skin.get_bind_pose(i))
	var soles := Vector2(INF,INF)
	var samples := 0
	for i in points.size():
		if points[i].y >= .09: continue
		var y := 0.0
		for k in 4:
			y += weights[i*4+k]*(transforms[bones[i*4+k]]*points[i]).y
		var side := 0 if points[i].x > 0 else 1
		soles[side] = minf(soles[side],y)
		samples += 1
	return {"left_world_y":soles.x,"right_world_y":soles.y,"vertices":samples,
		"method":"ALL native imported skin vertices with rest Y < .09 m; original four weights and Skin binds; separate left/right minima"}
