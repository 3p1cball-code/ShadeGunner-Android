shader_type canvas_item;
render_mode unshaded, blend_disabled;
// 1:1 aus shadegunner/render/shaders.py portiert (GLSL 130 -> Godot canvas_item).
// Koordinaten: UV/Pixel mit Ursprung oben links (Godot), im Original unten links.

uniform sampler2D u_src : filter_linear, repeat_disable;
uniform vec2 u_dir;
uniform int u_prep = 0;
const float W[7] = float[7](0.137023, 0.129618, 0.109719, 0.083109, 0.056332, 0.034167, 0.018544);

void fragment() {
	vec3 acc = vec3(0.0);
	for (int i = -6; i <= 6; ++i) {
		vec3 s = texture(u_src, UV + u_dir * float(i)).rgb;
		if (u_prep == 1) s *= s;
		acc += s * W[i < 0 ? -i : i];
	}
	COLOR = vec4(acc, 1.0);
}
