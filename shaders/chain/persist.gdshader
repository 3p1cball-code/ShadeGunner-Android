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

float trail(vec2 q) {                         // wie viel heller als das aktuelle Bild (= Spur)
	vec3 d = texture(u_prev, q).rgb - texture(u_cur, q).rgb;
	return max(max(d.r, d.g), d.b);
}

void fragment() {
	vec2 uv = UV;
	vec3 c = texture(u_cur, uv).rgb;
	vec3 p = texture(u_prev, uv).rgb;
	// Ausfadende Spuren werden mit jedem Frame etwas weicher (wiederholter kleiner Blur
	// wächst von selbst mit dem Alter). Nur wo hier oder nebenan wirklich eine Spur ist -
	// ein stehendes Bild bekommt so keinen Dauer-Halo.
	vec2 res_px = vec2(textureSize(u_cur, 0));
	vec2 o = max(1.0, res_px.y / 720.0) / res_px;
	float tr = max(max(trail(uv + vec2(o.x, 0.0)), trail(uv - vec2(o.x, 0.0))),
			max(trail(uv + vec2(0.0, o.y)), trail(uv - vec2(0.0, o.y))));
	tr = max(tr, max(max(p.r - c.r, p.g - c.g), p.b - c.b));
	if (tr > 0.01) {
		vec3 nb = 0.25 * (texture(u_prev, uv + vec2(o.x, 0.0)).rgb + texture(u_prev, uv - vec2(o.x, 0.0)).rgb
				+ texture(u_prev, uv + vec2(0.0, o.y)).rgb + texture(u_prev, uv - vec2(0.0, o.y)).rgb);
		p = mix(p, nb, (1.0 - pow(0.72, u_dtn)) * smoothstep(0.01, 0.08, tr));
	}
	float keep = pow(mix(0.8, 1.0, smoothstep(0.15, 0.7, max(max(p.r, p.g), p.b))), u_dtn);
	// nahezu weiße Stellen ziehen länger nach (wie überhellter Phosphor)
	float white = smoothstep(0.72, 0.95, min(min(p.r, p.g), p.b));
	vec3 kept = p * pow(u_decay, vec3(mix(1.0, 0.55, white))) * keep - u_floor * (1.0 - 0.7 * white);
	if (u_tint_mix > 0.0) kept = mix(kept, max(max(kept.r, kept.g), kept.b) * u_tint, u_tint_mix);
	COLOR = vec4(max(c, kept), 1.0);
}
