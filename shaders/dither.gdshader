shader_type canvas_item;
// Bayer-Dither gegen noir16 + Grading - der CPU/GPU-Zwilling von
// shadegunner/render/sodither.py und shaders.py.
//
// Laeuft auf einer 640x360-Flaeche (SubViewport-Groesse), damit die
// Dither-Zelle exakt ein Spielpixel ist.

uniform vec3 pal[16];
uniform float spread = 0.24;
uniform float contrast = 0.30;
uniform float saturation = 1.22;
uniform float lift = -0.012;

// 8x8-Bayer ohne Array (klassische Verschachtelung)
float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

void fragment() {
	vec3 c = texture(TEXTURE, UV).rgb;

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
		vec3 d = (c - pal[i]) * w;
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = i; }
	}
	COLOR = vec4(pal[best], 1.0);
}
