shader_type canvas_item;
// CRT-Kette: Wölbung, Ecken, Scanlines, Schattenmaske, Bloom, Grain,
// Hum-Balken, Vignette und Konvergenzfehler. Portiert aus
// shadegunner/render/shaders.py (CRT_FRAG), ohne die externen Blur-Pässe -
// der Bloom wird hier direkt mit wenigen Taps aus dem geditherten Bild geholt.

uniform float curve = 0.06;
uniform float corner = 0.03;
uniform float mask_amt = 0.22;
uniform float mask_px = 1.0;
uniform float scan = 0.30;
uniform float scan_period = 3.0;     // Bildschirmpixel pro Scanline-Periode
uniform float bloom_amt = 0.70;
uniform float grain = 0.035;
uniform float hum = 0.02;
uniform float vignette = 0.40;
uniform float aberr = 1.5;
uniform vec2 screen_size = vec2(1280.0, 720.0);
uniform float aspect = 1.777778;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	vec2 n = uv * 2.0 - 1.0;
	// Wölbung (Kissen-Verzerrung)
	vec2 ns = n * (1.0 + curve * vec2(n.y * n.y, n.x * n.x));

	// Ecken: gerundetes Rechteck als SDF, isotrop gerechnet
	vec2 q = vec2(ns.x * aspect, ns.y);
	vec2 half_box = vec2(aspect, 1.0);
	float r = corner / max(0.001, screen_size.y);
	vec2 d = abs(q) - (half_box - r);
	float sdf = length(max(d, vec2(0.0))) - r;
	float face = 1.0 - smoothstep(-0.75 / screen_size.y, 0.75 / screen_size.y, sdf);
	if (sdf > 0.0 && face <= 0.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		// Quelle im Wölbungsraum
		vec2 suv = ns * 0.5 + 0.5;
		vec2 ab = ns * (0.25 + 0.75 * dot(ns, ns)) * aberr / screen_size;
		vec3 col = vec3(
			texture(TEXTURE, suv + ab).r,
			texture(TEXTURE, suv).g,
			texture(TEXTURE, suv - ab).b);

		float lum = dot(col, vec3(0.299, 0.587, 0.114));

		// Scanlines
		float s = 0.5 + 0.5 * cos(6.2831853 * (suv.y * screen_size.y) / scan_period);
		float scanf = (1.0 - scan * (1.0 - s) * (1.0 - 0.6 * lum)) / (1.0 - 0.35 * scan);

		// Schattenmaske (RGB-Streifen)
		int stripe = int(mod(floor(FRAGCOORD.x / mask_px), 3.0));
		vec3 sel = vec3(stripe == 0 ? 1.0 : 0.0, stripe == 1 ? 1.0 : 0.0, stripe == 2 ? 1.0 : 0.0);
		vec3 mask = mix(vec3(1.0), sel, mask_amt) * (1.0 + 0.6 * mask_amt);
		col = col * scanf * mask;

		// Bloom: acht Taps im Kreis, nur die hellen Anteile
		if (bloom_amt > 0.001) {
			float rad = 3.0 / screen_size.y;
			vec3 acc = vec3(0.0);
			for (int i = 0; i < 8; i++) {
				float a = float(i) * 0.785398;
				acc += texture(TEXTURE, suv + vec2(cos(a), sin(a)) * rad).rgb;
			}
			acc /= 8.0;
			col += max(acc - vec3(0.45), vec3(0.0)) * bloom_amt;
		}

		// Überstrahlen zurück in den Bereich
		float mx = max(col.r, max(col.g, col.b));
		if (mx > 1.0) col = mix(col / mx, vec3(1.0), clamp((mx - 1.0) * 0.6, 0.0, 1.0));

		// Grain + Hum-Balken + Vignette + Grundhelligkeit
		col += (hash21(FRAGCOORD.xy + floor(TIME * 60.0)) - 0.5) * grain * (0.3 + lum);
		float bar = pow(0.5 + 0.5 * sin(6.2831853 * (n.y * 0.5 + 0.5 + TIME * 0.12)), 6.0);
		col *= 1.0 - hum * bar;
		col *= 1.0 - vignette * 0.35 * dot(ns, ns);
		col += vec3(0.010, 0.011, 0.013) * (1.0 - 0.3 * dot(ns, ns));
		COLOR = vec4(col * face, 1.0);
	}
}
