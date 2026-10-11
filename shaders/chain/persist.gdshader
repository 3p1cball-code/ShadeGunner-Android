shader_type canvas_item;
render_mode unshaded, blend_disabled;
// 1:1 aus shadegunner/render/shaders.py portiert (GLSL 130 -> Godot canvas_item).
// Koordinaten: UV/Pixel mit Ursprung oben links (Godot), im Original unten links.

uniform sampler2D u_cur : filter_linear, repeat_disable;
uniform sampler2D u_prev : filter_linear, repeat_disable;
uniform vec3 u_decay;
uniform float u_floor;
uniform float u_dtn;
uniform vec3 u_tint;
uniform float u_tint_mix = 0.0;

void fragment() {
	vec3 c = texture(u_cur, UV).rgb;
	vec3 p = texture(u_prev, UV).rgb;
	float keep = pow(mix(0.8, 1.0, smoothstep(0.15, 0.7, max(max(p.r, p.g), p.b))), u_dtn);
	vec3 kept = p * u_decay * keep - u_floor;
	if (u_tint_mix > 0.0) kept = mix(kept, max(max(kept.r, kept.g), kept.b) * u_tint, u_tint_mix);
	COLOR = vec4(max(c, kept), 1.0);
}
