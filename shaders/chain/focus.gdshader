shader_type canvas_item;
render_mode unshaded, blend_disabled;
// 1:1 aus shadegunner/render/shaders.py portiert (GLSL 130 -> Godot canvas_item).
// Koordinaten: UV/Pixel mit Ursprung oben links (Godot), im Original unten links.

uniform sampler2D u_src : filter_linear, repeat_disable;
uniform vec2 u_dir;
uniform float u_sigma;

void fragment() {
	float s = max(u_sigma, 0.05);
	float tap = max(1.0, s * 0.5);
	vec3 acc = texture(u_src, UV).rgb;
	float wsum = 1.0;
	for (int i = 1; i <= 4; ++i) {
		float d = float(i) * tap;
		float w = exp(-0.5 * d * d / (s * s));
		acc += (texture(u_src, UV + u_dir * d).rgb + texture(u_src, UV - u_dir * d).rgb) * w;
		wsum += 2.0 * w;
	}
	COLOR = vec4(acc / wsum, 1.0);
}
