shader_type canvas_item;
// Bayer-Dither gegen noir16 + Grading - der CPU/GPU-Zwilling von
// shadegunner/render/sodither.py und shaders.py.
//
// Palette fest eingebettet (erzeugt aus src/palette.gd, damit es nur eine
// Quelle der Wahrheit gibt). Laeuft auf einer 640x360-Flaeche (SubViewport-Groesse), damit die
// Dither-Zelle exakt ein Spielpixel ist.

const vec3 PAL[16] = vec3[16](
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
	vec3(0.4784, 0.2902, 0.6588)
);
// Die SubViewport-Textur kommt beim Abtasten in einem linearen Raum an. Der
// Exponent ist gegen die Python-Referenz kalibriert (sample -> Szene), damit
// Grading und Palette wieder im sRGB-Raum arbeiten.
uniform float tex_gain = 1.988;
uniform int dbg_mode = 0;
// Die SubViewport-Textur wird linear mit Faktor ~0.503 abgetastet (gemessen).
// tex_gain = 1/0.503 stellt den sRGB-Raum wieder her, in dem Palette und Grading leben.
vec3 decode_tex(vec3 c) {
	return clamp(c * tex_gain, 0.0, 1.0);
}

uniform float spread = 0.24;
uniform float contrast = 0.30;
uniform float saturation = 1.22;
uniform float lift = -0.012;

// 8x8-Bayer ohne Array (klassische Verschachtelung)
float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

void fragment() {
	if (dbg_mode == 1) { COLOR = texture(TEXTURE, UV); return; }
	vec3 c = decode_tex(texture(TEXTURE, UV).rgb);

	// Grading wie im Shader-Pfad: Saettigung, Schwarzpunkt, S-Kurve
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = clamp(lum + (c - lum) * saturation, 0.0, 1.0);
	c = clamp((c + lift) / (1.0 + lift), 0.0, 1.0);
	vec3 s = c * c * (3.0 - 2.0 * c);
	c = c + (s - c) * contrast;

	// Bayer-Schwelle in Spielepixeln
	vec2 px = FRAGCOORD.xy;
	c = clamp(c + (bayer8(px) - 0.5) * spread, 0.0, 1.0);

	// naechste Palettenfarbe (Gewichtung wie im Auge: Gruen zaehlt am meisten)
	vec3 w = vec3(0.9, 1.1, 0.8);
	int best = 0;
	float bd = 1e9;
	for (int i = 0; i < 16; i++) {
		vec3 d = (c - PAL[i]) * w;
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = i; }
	}
	COLOR = vec4(PAL[best], 1.0);
}
