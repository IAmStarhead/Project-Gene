## Сборка одежды в рантайме из JSON, который готовит tools/garment/build_dress.py.
##
## Почему JSON, а не готовый .glb: одежда должна жить вместе с моделью и
## пересобираться при любой правке кроя, а Blender у нас недоступен. Модель
## героини не перезаписывается — платье это отдельный MeshInstance3D.
##
## Что делает:
##   1. читает вершины, нормали, UV и веса;
##   2. строит ArrayMesh;
##   3. вешает ShaderMaterial в стиле селлшейдинга (тот же язык, что у тела,
##      но без контура по краю: на плоской юбке кант читается как грязь);
##   4. возвращает узел, который надо добавить внутрь Character.
extends RefCounted

## Тот же ступенчатый свет, что у персонажа, но с текстурой ткани и без
## контурного канта. Совпадение ступеней важно: одежда и тело должны
## освещаться одинаково, иначе персонаж выглядит склеенным из двух частей.
const GARMENT_SHADER := """
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled;

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform bool use_texture = true;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float softness = 0.02;
uniform float tint_strength = 0.06;

void fragment() {
	vec3 tex = use_texture ? texture(albedo_tex, UV).rgb : vec3(1.0);
	ALBEDO = tex * base_color.rgb;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
	// Легкий уход в тень по нормали: ткань не должна быть идеально плоской.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO *= mix(vec3(1.0), vec3(0.92, 0.94, 0.98), (1.0 - facing) * tint_strength * 4.0);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float s1 = smoothstep(0.00 - softness, 0.00 + softness, ndl);
	float s2 = smoothstep(0.38 - softness, 0.38 + softness, ndl);
	float s3 = smoothstep(0.72 - softness, 0.72 + softness, ndl);
	// Ровно те же ступени, что в TOON_SHADER у персонажа.
	float amount = 0.42 + 0.26 * s1 + 0.18 * s2 + 0.14 * s3;
	DIFFUSE_LIGHT += amount * ATTENUATION * LIGHT_COLOR / PI;
	SPECULAR_LIGHT += s3 * 0.04 * ATTENUATION * LIGHT_COLOR / PI;
}
"""


## Построить меш из JSON. Возвращает null, если файла нет.
static func build_mesh(json_path: String) -> ArrayMesh:
	if not ResourceLoader.exists(json_path):
		push_warning("Garment: нет файла " + json_path)
		return null
	var text := FileAccess.get_file_as_string(json_path)
	if text.is_empty():
		push_warning("Garment: файл пуст " + json_path)
		return null
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Garment: JSON не разобрался " + json_path)
		return null
	var verts: Array = data["vertices"]
	var tris: Array = data["triangles"]

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	positions.resize(verts.size())
	normals.resize(verts.size())
	uvs.resize(verts.size())
	for i in verts.size():
		var v: Dictionary = verts[i]
		var p: Array = v["p"]
		var n: Array = v["n"]
		var uv: Array = v["uv"]
		positions[i] = Vector3(p[0], p[1], p[2])
		normals[i] = Vector3(n[0], n[1], n[2])
		uvs[i] = Vector2(uv[0], uv[1])

	var indices := PackedInt32Array()
	indices.resize(tris.size())
	for i in tris.size():
		indices[i] = int(tris[i])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Готовый материал для платья. Текстура подставляется, если передана.
static func make_material(texture: Texture2D = null) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = GARMENT_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if texture != null:
		mat.set_shader_parameter("albedo_tex", texture)
		mat.set_shader_parameter("use_texture", true)
		mat.set_shader_parameter("base_color", Color(1, 1, 1))
	else:
		mat.set_shader_parameter("use_texture", false)
		mat.set_shader_parameter("base_color", Color(0.945, 0.952, 0.965))
	return mat


## Собрать узел одежды целиком и повесить его внутрь character.
##
## Важно: узел добавляется как ребёнок `Character` — того узла, внутри
## которого живёт Skeleton3D. Иначе платье поедет вместе с телом персонажа,
## но не вместе с его костями, и «прилипнет» к ногам.
static func attach(character: Node, json_path: String, texture_path: String = "") -> MeshInstance3D:
	var mesh := build_mesh(json_path)
	if mesh == null:
		return null
	var tex: Texture2D = null
	if texture_path != "" and ResourceLoader.exists(texture_path):
		tex = load(texture_path) as Texture2D
	var mi := MeshInstance3D.new()
	mi.name = "LabDress"
	mi.mesh = mesh
	mi.material_override = make_material(tex)
	# Одежда должна получать те же тени и свет, что тело, но не обязана
	# отбрасывать тень по каждой вершине: 504 треугольника, дёшево.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	character.add_child(mi)
	return mi
