extends Node3D
var character: Node3D
var camera: Camera3D
var debug_nodes: Array[MeshInstance3D] = []
var old_id := 0
var current := {"clip":"attack_right", "time":.19, "view":"side", "layer":"both", "play":false}
var full_body: ArrayMesh
var dressed_body: Mesh
var clip_time := .19
func _ready() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(.17,.21,.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(.85,.90,1)
	env.ambient_light_energy = .65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35,-30,0)
	sun.light_energy = 1.15
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20,130,0)
	fill.light_energy = .45
	add_child(fill)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30,30)
	floor_mesh.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.22,.27,.31)
	material.roughness = 1
	floor_mesh.material_override = material
	add_child(floor_mesh)
	character = Node3D.new()
	character.set_script(load("res://scripts/character_anim.gd"))
	add_child(character)
	camera = Camera3D.new()
	camera.fov = 27
	add_child(camera)
	camera.make_current()
	# Recover the ORIGINAL imported body index buffer, not the intentionally
	# culled dress copy. Preserve native morph/skin arrays for fair comparisons.
	var original: Node = load("res://assets/heroine/female_A_rigged_safe.glb").instantiate()
	var source: MeshInstance3D = character.appearance._find_body(original)
	dressed_body = character.appearance.body.mesh
	full_body = ArrayMesh.new()
	full_body.add_blend_shape("RelaxedHands")
	full_body.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	for surface in dressed_body.get_surface_count():
		var arrays: Array = dressed_body.surface_get_arrays(surface)
		arrays[Mesh.ARRAY_INDEX] = source.mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
		full_body.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, dressed_body.surface_get_blend_shape_arrays(surface))
		full_body.surface_set_material(surface, dressed_body.surface_get_material(surface))
	original.free()
	apply(current)
	if OS.has_feature("web"):
		print("REVIEW_READY")
func apply(command: Dictionary) -> void:
	for item in debug_nodes: item.queue_free()
	debug_nodes.clear()
	current = command
	var name: String = current.get("clip","attack_right")
	clip_time = float(current.get("time",.19))
	if current.get("simulate",false):
		character.seek_clip(name, 0)
		var duration: float = character.clip_duration(name)
		var warm := 0
		if current.get("warm",false): warm=ceili(duration*60)
		for i in warm:
			character.seek_clip(name,fmod(i/60.,duration),1./60.)
		for i in floori(clip_time*60):
			character.seek_clip(name,(i+1.)/60.,1./60.)
		character.seek_clip(name,clip_time,1./60.)
	else:
		character.seek_clip(name,clip_time)
	if current.get("magenta",false):
		var skin_material := StandardMaterial3D.new()
		skin_material.albedo_color = Color(1,0,1)
		skin_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		character.appearance.body.material_override = skin_material
	else:
		character.appearance.body.material_override = null
	var layer: String = current.get("layer","both")
	character.appearance.body.visible = layer != "cloth"
	character.appearance.body.mesh = full_body if layer == "skin" else dressed_body
	character.appearance.gown.visible = layer != "skin"
	character.appearance.skirt.visible = layer != "skin"
	if current.has("contact_faces"):
		var original_gown: MeshInstance3D = character.appearance.gown
		var arrays: Array = original_gown.mesh.surface_get_arrays(0)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var selected := PackedInt32Array()
		for face in current["contact_faces"]:
			for k in 3: selected.append(indices[int(face)*3+k])
		arrays[Mesh.ARRAY_INDEX] = selected
		var overlay_mesh := ArrayMesh.new()
		overlay_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var overlay := MeshInstance3D.new()
		overlay.mesh = overlay_mesh
		overlay.skin = original_gown.skin
		overlay.skeleton = original_gown.skeleton
		overlay.transform = original_gown.transform
		var red := StandardMaterial3D.new()
		red.albedo_color = Color(1,.025,.025)
		red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		red.cull_mode = BaseMaterial3D.CULL_DISABLED
		red.grow = true
		red.grow_amount = .0005
		overlay.material_override = red
		original_gown.get_parent().add_child(overlay)
		debug_nodes.append(overlay)
	var close: bool = current.get("close",true)
	var target := Vector3(0,1.27,.05) if close else Vector3(0,.91,.03)
	var offsets := {"front":Vector3(0,.05,1),"back":Vector3(0,.05,-1),"side":Vector3(1,.04,0),"opposite":Vector3(-1,.04,0),"three":Vector3(1,.1,1.5)}
	camera.position = target+(offsets.get(current.get("view","side"),Vector3(1,.1,1.5)) as Vector3).normalized()*(1.8 if close else 4.)
	camera.look_at(target)
	if current.get("normals",false):
		character.skeleton.force_update_all_bone_transforms()
		if layer != "cloth": bake_mesh(character.appearance.body)
		if layer != "skin": bake_mesh(character.appearance.gown)
func _process(delta: float) -> void:
	if not OS.has_feature("web"): return
	var path := "/cmd%d.json" % (old_id+1)
	if not FileAccess.file_exists(path):
		if current.get("play",false):
			clip_time=fmod(clip_time+delta,character.clip_duration(current.get("clip","attack_right")))
			character.seek_clip(current.get("clip","attack_right"),clip_time,delta)
		return
	var command = JSON.parse_string(FileAccess.get_file_as_string(path))
	if command is Dictionary and int(command.get("id",-1)) != old_id:
		old_id = int(command.get("id",-1))
		apply(command)
		# A JavaScript RAF is NOT proof the Godot skeleton/framebuffer has
		# rendered this command. Acknowledge only after native post-draw.
		await RenderingServer.frame_post_draw
		var h: Vector3 = character.skeleton.get_bone_pose_position(character.skeleton.find_bone("hips"))
		var rotations: Array = []
		for i in character.skeleton.get_bone_count():
			var q: Quaternion = character.skeleton.get_bone_pose_rotation(i)
			rotations.append([q.x,q.y,q.z,q.w])
		print("REVIEW_FRAME:",JSON.stringify({"id":old_id,"command":current,
			"camera":str(camera.global_transform),"hips":[h.x,h.y,h.z],"rotations":rotations,
			"body_visible":character.appearance.body.visible,"gown_visible":character.appearance.gown.visible,
			"full_skin":character.appearance.body.mesh == full_body,
			"model_sha256":FileAccess.get_sha256("res://assets/heroine/female_A_rigged_safe.glb"),
			"appearance_sha256":FileAccess.get_sha256("res://assets/heroine/appearance/lab_uniform.json"),
			"motion_set_sha256":FileAccess.get_sha256("res://assets/heroine/animations/motion_set.json"),
			"runtime_sha256":FileAccess.get_sha256("res://scripts/character_appearance.gd"),
			"controller_sha256":FileAccess.get_sha256("res://scripts/character_anim.gd")}))
		print("REVIEW_DONE:",old_id)
	if current.get("play",false):
		clip_time=fmod(clip_time+delta,character.clip_duration(current.get("clip","attack_right")))
		character.seek_clip(current.get("clip","attack_right"),clip_time,delta)

func bake_mesh(instance: MeshInstance3D) -> void:
	var transforms: Array[Transform3D] = []
	for i in instance.skin.get_bind_count():
		var bone: int = instance.skin.get_bind_bone(i)
		if bone < 0: bone=character.skeleton.find_bone(instance.skin.get_bind_name(i))
		transforms.append(character.skeleton.get_bone_global_pose(bone)*instance.skin.get_bind_pose(i))
	var mesh := ArrayMesh.new()
	for surface in instance.mesh.get_surface_count():
		var arrays: Array = instance.mesh.surface_get_arrays(surface)
		var p: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		for i in p.size():
			var v := Vector3.ZERO
			for k in 4: v += transforms[bones[i*4+k]]*p[i]*w[i*4+k]
			p[i] = v
		var normal := PackedVector3Array()
		normal.resize(p.size())
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var weld := {}
		for face in indices.size()/3:
			var a:=indices[face*3]
			var b:=indices[face*3+1]
			var c:=indices[face*3+2]
			var n: Vector3 = (p[c]-p[a]).cross(p[b]-p[a])
			for i in [a,b,c]: normal[i] += n
		for i in p.size():
			var key := Vector3i((p[i]*100000).round())
			weld[key] = weld.get(key,Vector3.ZERO)+normal[i]
		for i in p.size(): normal[i]=weld[Vector3i((p[i]*100000).round())].normalized()
		arrays[Mesh.ARRAY_VERTEX] = p
		arrays[Mesh.ARRAY_NORMAL] = normal
		arrays[Mesh.ARRAY_TANGENT] = null
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		mesh.surface_set_material(surface,instance.mesh.surface_get_material(surface))
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = instance.material_override
	node.transform = instance.transform
	instance.get_parent().add_child(node)
	debug_nodes.append(node)
	instance.visible = false
