shader_type canvas_item;
// Nachbearbeitung in EINEM Durchgang: Bayer-Dither gegen noir16 im 640x360-Raster
// plus die CRT-Kette (Wölbung, Scanlines, Schattenmaske, Bloom, Grain, Vignette).
//
// Ein Durchgang statt zwei, weil eine SubViewport-Textur beim Abtasten linear mit
// Faktor ~0.503 ankommt - zweimal abgetastet würde das doppelt korrigiert. Der
// Faktor ist unten als tex_gain fest hinterlegt (gemessen gegen die Referenz).

const vec3 PAL[16] = vec3[16](
	vec3(0.0235, 0.0314, 0.0549), vec3(0.0706, 0.0863, 0.1490), vec3(0.1333, 0.1569, 0.2588),
	vec3(0.2039, 0.2353, 0.3765), vec3(0.2902, 0.3608, 0.5412), vec3(0.4078, 0.5176, 0.6980),
	vec3(0.5412, 0.1255, 0.2196), vec3(0.6118, 0.3294, 0.1569), vec3(0.6353, 0.6588, 0.7059),
	vec3(0.8392, 0.8627, 0.8863), vec3(1.0000, 1.0000, 1.0000), vec3(0.1333, 0.3765, 0.4078),
	vec3(0.2510, 0.8235, 0.8627), vec3(0.8784, 0.2824, 0.5882), vec3(1.0000, 0.5412, 0.1725),
	vec3(0.4784, 0.2902, 0.6588));

uniform vec2 grid = vec2(640.0, 360.0);
uniform float tex_gain = 1.85;      // 1 / 0.503 (SubViewport-Abtastung)
uniform float spread = 0.24;
uniform float contrast = 0.30;
uniform float saturation = 1.22;
uniform float lift = -0.012;
uniform float curve = 0.06;
uniform float corner = 0.03;
uniform float mask_amt = 0.14;
uniform float mask_px = 1.0;
uniform float scan = 0.16;
uniform float scan_period = 2.0;
uniform float bloom_amt = 1.10;
uniform float grain = 0.030;
uniform float hum = 0.02;
uniform float vignette = 0.22;
uniform float aberr = 1.5;
uniform vec2 screen_size = vec2(1280.0, 720.0);
uniform float aspect = 1.777778;

float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

vec3 grade(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = clamp(mix(vec3(l), c, saturation), 0.0, 1.0);
	c = clamp((c + lift) / (1.0 + lift), 0.0, 1.0);
	vec3 s = c * c * (3.0 - 2.0 * c);
	return mix(c, s, contrast);
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void fragment() {
	// --- CRT-Wölbung und Ecken (im Bildschirmraum) ---
	vec2 n = UV * 2.0 - 1.0;
	vec2 ns = n * (1.0 + curve * vec2(n.y * n.y, n.x * n.x));
	vec2 q = vec2(ns.x * aspect, ns.y);
	float r = corner / max(0.001, screen_size.y);
	vec2 d = abs(q) - (vec2(aspect, 1.0) - r);
	float sdf = length(max(d, vec2(0.0))) - r;
	float face = 1.0 - smoothstep(-0.75 / screen_size.y, 0.75 / screen_size.y, sdf);
	if (face <= 0.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 suv = ns * 0.5 + 0.5;
		if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
			COLOR = vec4(0.0, 0.0, 0.0, 1.0);
		} else {
			// --- Dither-Raster ---
			vec2 cell = floor(suv * grid);
			vec2 cuv = (cell + 0.5) / grid;
			vec3 c = grade(clamp(texture(TEXTURE, cuv).rgb * tex_gain, 0.0, 1.0));
			float t = bayer8(cell);
			c = clamp(c + (t - 0.5) * spread, 0.0, 1.0);

			vec3 w = vec3(0.9, 1.1, 0.8);
			int best = 0;
			float bd = 1e9;
			for (int i = 0; i < 16; i++) {
				vec3 dd = (c - PAL[i]) * w;
				float dq = dot(dd, dd);
				if (dq < bd) { bd = dq; best = i; }
			}
			vec3 col = PAL[best];

			float lum = dot(col, vec3(0.299, 0.587, 0.114));

			// --- Bloom: helle Nachbarzellen ---
			if (bloom_amt > 0.001) {
				vec3 acc = vec3(0.0);
				for (int i = 0; i < 8; i++) {
					float a = float(i) * 0.785398;
					vec2 off = vec2(cos(a), sin(a)) * 3.0;
					vec2 buv = (cell + off + 0.5) / grid;
					acc += clamp(texture(TEXTURE, buv).rgb * tex_gain, 0.0, 1.0);
				}
				acc /= 8.0;
				col += max(acc - vec3(0.4), vec3(0.0)) * bloom_amt;
			}

			// --- Scanlines, Schattenmaske, Konvergenz ---
			float s = 0.5 + 0.5 * cos(6.2831853 * (suv.y * screen_size.y) / scan_period);
			float scanf = (1.0 - scan * (1.0 - s) * (1.0 - 0.6 * lum)) / (1.0 - 0.35 * scan);
			int stripe = int(mod(floor(FRAGCOORD.x / mask_px), 3.0));
			vec3 sel = vec3(stripe == 0 ? 1.0 : 0.0, stripe == 1 ? 1.0 : 0.0, stripe == 2 ? 1.0 : 0.0);
			vec3 mask = mix(vec3(1.0), sel, mask_amt) * (1.0 + 0.6 * mask_amt);
			col = col * scanf * mask;

			float mx = max(col.r, max(col.g, col.b));
			if (mx > 1.0) col = mix(col / mx, vec3(1.0), clamp((mx - 1.0) * 0.6, 0.0, 1.0));

			col += (hash21(FRAGCOORD.xy + floor(TIME * 60.0)) - 0.5) * grain * (0.3 + lum);
			float bar = pow(0.5 + 0.5 * sin(6.2831853 * (n.y * 0.5 + 0.5 + TIME * 0.12)), 6.0);
			col *= 1.0 - hum * bar;
			col *= 1.0 - vignette * 0.35 * dot(ns, ns);
			col += vec3(0.010, 0.011, 0.013) * (1.0 - 0.3 * dot(ns, ns));
			COLOR = vec4(col * face, 1.0);
		}
	}
}
