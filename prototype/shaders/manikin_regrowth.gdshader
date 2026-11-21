shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform bool use_texture = false;
uniform bool use_vertex_color = false;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float roughness_value = 0.7;
uniform vec3 growth_axis = vec3(0.0, -1.0, 0.0);
uniform float growth_near = 0.0;
uniform float growth_far = 1.0;
uniform float growth_progress : hint_range(0.0, 1.0) = 0.0;
varying float along_limb;

void vertex() {
	along_limb = dot(VERTEX, growth_axis);
}

void fragment() {
	if (along_limb > mix(growth_near, growth_far, growth_progress)) {
		discard;
	}
	vec4 surface = base_color;
	if (use_texture) {
		surface *= texture(albedo_tex, UV);
	}
	if (use_vertex_color) {
		surface *= COLOR;
	}
	ALBEDO = surface.rgb;
	ROUGHNESS = roughness_value;
}
