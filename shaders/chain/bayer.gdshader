shader_type canvas_item;
render_mode unshaded, blend_disabled;
// 1:1 aus shadegunner/render/shaders.py portiert (GLSL 130 -> Godot canvas_item).
// Koordinaten: UV/Pixel mit Ursprung oben links (Godot), im Original unten links.

uniform sampler2D u_frame : filter_nearest, repeat_disable;  // Szene, ein Pixel pro Dither-Zelle
uniform sampler2D u_hud : filter_nearest, repeat_disable;    // HUD, premultipliziert
uniform vec2 u_res;
uniform vec2 u_origin;
uniform vec2 u_cell;
uniform vec2 u_grid;
uniform int u_order = 3;
uniform float u_spread = 0.24;
uniform int u_pal_off = 0;
uniform int u_pal_n = 16;
uniform float u_hud_scale = 2.0;
uniform int u_has_hud = 0;
uniform float u_contrast = 0.3;
uniform float u_sat = 1.22;
uniform float u_lift = -0.012;

const vec3 PAL[32] = vec3[32](
	vec3(0.0235, 0.0314, 0.0549),
	vec3(0.0706, 0.0863, 0.1490),
	vec3(0.1333, 0.1569, 0.2588),
	vec3(0.2039, 0.2353, 0.3765),
	vec3(0.2902, 0.3608, 0.5412),
	vec3(0.4078, 0.5176, 0.6980),
	vec3(0.5412, 0.1255, 0.2196),
	vec3(0.6118, 0.3294, 0.1569),
	vec3(0.6353, 0.6588, 0.7059),
	vec3(0.8392, 0.8627, 0.8863),
	vec3(1.0000, 1.0000, 1.0000),
	vec3(0.1333, 0.3765, 0.4078),
	vec3(0.2510, 0.8235, 0.8627),
	vec3(0.8784, 0.2824, 0.5882),
	vec3(1.0000, 0.5412, 0.1725),
	vec3(0.4784, 0.2902, 0.6588),
	vec3(0.0000, 0.0000, 0.0000),
	vec3(0.0000, 0.0000, 0.6667),
	vec3(0.0000, 0.6667, 0.0000),
	vec3(0.0000, 0.6667, 0.6667),
	vec3(0.6667, 0.0000, 0.0000),
	vec3(0.6667, 0.0000, 0.6667),
	vec3(0.6667, 0.3333, 0.0000),
	vec3(0.6667, 0.6667, 0.6667),
	vec3(0.3333, 0.3333, 0.3333),
	vec3(0.3333, 0.3333, 1.0000),
	vec3(0.3333, 1.0000, 0.3333),
	vec3(0.3333, 1.0000, 1.0000),
	vec3(1.0000, 0.3333, 0.3333),
	vec3(1.0000, 0.3333, 1.0000),
	vec3(1.0000, 1.0000, 0.3333),
	vec3(1.0000, 1.0000, 1.0000));

vec3 nearest_pal(vec3 c, int off, int n) {
	vec3 best = PAL[off];
	float bd = 1e9;
	for (int i = 0; i < 32; ++i) {
		if (i >= n) break;
		vec3 q = PAL[off + i];
		vec3 d = (c - q) * vec3(0.9, 1.1, 0.8);
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = q; }
	}
	return best;
}

float bayer(ivec2 p, int k) {
	int v = 0; int x = p.x; int y = p.y;
	for (int i = 0; i < k; ++i) {
		v = (v << 2) | (((x ^ y) & 1) << 1) | (y & 1);
		x = x >> 1; y = y >> 1;
	}
	return (float(v) + 0.5) / float(1 << (2 * k));
}

vec3 grade(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = clamp(mix(vec3(l), c, u_sat), 0.0, 1.0);
	c = clamp((c + u_lift) / (1.0 + u_lift), 0.0, 1.0);
	vec3 s = c * c * (3.0 - 2.0 * c);
	return mix(c, s, u_contrast);
}

void fragment() {
	vec2 p = UV * u_res - u_origin;
	vec2 cf = p / u_cell;
	if (any(lessThan(cf, vec2(0.0))) || any(greaterThanEqual(cf, u_grid))) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		ivec2 cell = ivec2(floor(cf));
		vec3 c = grade(texelFetch(u_frame, cell, 0).rgb);
		float t = bayer(cell, u_order);
		vec3 col = nearest_pal(clamp(c + (t - 0.5) * u_spread, 0.0, 1.0), u_pal_off, u_pal_n);
		if (u_has_hud == 1) {
			vec4 hud = texelFetch(u_hud, ivec2(floor(cf * u_hud_scale)), 0);
			col = hud.rgb + col * (1.0 - hud.a);
		}
		COLOR = vec4(col, 1.0);
	}
}
