shader_type canvas_item;
render_mode unshaded, blend_disabled;
// 1:1 aus shadegunner/render/shaders.py portiert (GLSL 130 -> Godot canvas_item).
// Koordinaten: UV/Pixel mit Ursprung oben links (Godot), im Original unten links.

uniform sampler2D u_scene : filter_linear, repeat_disable;
uniform sampler2D u_bloom : filter_linear, repeat_disable;
uniform vec2 u_res;
uniform vec4 u_rect;        // (x, y, w, h) des Bildes in Fensterpixeln, oben links
uniform float u_curve;
uniform float u_corner;
uniform float u_mask;
uniform float u_mask_px = 1.0;
uniform float u_scan;
uniform float u_scan_period;
uniform float u_bloom_amt;
uniform float u_grain;
uniform float u_hum;
uniform float u_vignette;
uniform float u_aberr;
uniform float u_time;
uniform int u_seed;

float hsh(uvec2 v, uint t) {
	uint h = v.x * 1597334677u ^ v.y * 3812015801u ^ t * 2798796415u;
	h = h * 747796405u + 2891336453u;
	h = (h >> 16u) ^ h;
	h *= 2146121005u;
	h = (h >> 15u) ^ h;
	return float(h & 16777215u) / 16777216.0;
}

void fragment() {
	vec2 p = UV * u_res;
	vec2 n = (p - u_rect.xy) / u_rect.zw * 2.0 - 1.0;
	vec2 ns = n * (1.0 + u_curve * vec2(n.y * n.y, n.x * n.x));
	vec2 d = (abs(ns) - 1.0) * u_rect.zw * 0.5 + u_corner;
	float dist = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - u_corner;
	float face = 1.0 - smoothstep(-0.75, 0.75, dist);
	if (face <= 0.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 src = u_rect.xy + (ns * 0.5 + 0.5) * u_rect.zw;
		vec2 uv = src / u_res;
		vec2 ab = ns * (0.25 + 0.75 * dot(ns, ns)) * u_aberr / u_res;
		vec3 col = vec3(texture(u_scene, uv + ab).r, texture(u_scene, uv).g, texture(u_scene, uv - ab).b);
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		float s = 0.5 + 0.5 * cos(6.2831853 * (src.y - u_rect.y) / u_scan_period);
		float scan = (1.0 - u_scan * (1.0 - s) * (1.0 - 0.6 * lum)) / (1.0 - 0.35 * u_scan);
		int stripe = int(mod(floor(p.x / u_mask_px), 3.0));
		vec3 sel = vec3(stripe == 0 ? 1.0 : 0.0, stripe == 1 ? 1.0 : 0.0, stripe == 2 ? 1.0 : 0.0);
		vec3 mask = mix(vec3(1.0), sel, u_mask) * (1.0 + 0.6 * u_mask);
		col = col * scan * mask + texture(u_bloom, uv).rgb * u_bloom_amt;
		float mx = max(col.r, max(col.g, col.b));
		if (mx > 1.0) col = mix(col / mx, vec3(1.0), clamp((mx - 1.0) * 0.6, 0.0, 1.0));
		col += (hsh(uvec2(p), uint(u_seed)) - 0.5) * u_grain * (0.3 + lum);
		// Brummbalken: im Original laeuft ns.y von unten nach oben
		float bar = pow(0.5 + 0.5 * sin(6.2831853 * (-ns.y * 0.5 + 0.5 + u_time * 0.12)), 6.0);
		col *= 1.0 - u_hum * bar;
		col *= 1.0 - u_vignette * 0.35 * dot(ns, ns);
		col += vec3(0.010, 0.011, 0.013) * (1.0 - 0.3 * dot(ns, ns));
		COLOR = vec4(col * face, 1.0);
	}
}
