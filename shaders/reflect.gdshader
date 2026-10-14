shader_type canvas_item;
render_mode blend_premul_alpha;
// Nasse-Straße-Reflexion eines Atlas-Bildes beim Zeichnen (statt pro Bild ~12 Viewports
// zu backen wie City.soft_reflection): senkrecht gespiegelt, am Kontaktpunkt (oben) fast
// scharf und kräftig, nach unten zunehmend verwischt und blasser. Nachbau der vier
// Ebenen aus render/city.py soft_reflection (scharf / mild / mittel / stark verwischt,
// je mit eigenem Alpha-Verlauf, von hinten nach vorn übereinander).
uniform vec4 reg;              // Quellbereich im Atlas (UV): x0, y0, x1, y1
uniform float flip_x = 0.0;    // Quelle waagerecht gespiegelt (QImg.mirrored)
varying vec4 vc;

void vertex() {
	vc = COLOR;
}

vec4 box(sampler2D tex, vec2 m, vec2 st, vec2 size) {
	vec4 acc = vec4(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 l = clamp(m + vec2(float(i), float(j)) * size / 3.0 * st, vec2(0.0), vec2(1.0));
			acc += texture(tex, mix(reg.xy, reg.zw, l));
		}
	}
	return acc / 9.0;
}

float prof(float v, float a, float s, float e) {
	return a * (v < s ? 1.0 : clamp(1.0 - (v - s) / (e - s), 0.0, 1.0));
}

void fragment() {
	vec2 l = (UV - reg.xy) / (reg.zw - reg.xy);
	float v = l.y;                                       // 0 = Kontaktpunkt
	vec2 m = vec2(flip_x > 0.5 ? 1.0 - l.x : l.x, 1.0 - l.y);
	vec2 st = TEXTURE_PIXEL_SIZE / (reg.zw - reg.xy);    // ein Quellpixel in lokalen Koordinaten
	vec4 c0 = texture(TEXTURE, mix(reg.xy, reg.zw, clamp(m, vec2(0.0), vec2(1.0))));
	vec4 c1 = box(TEXTURE, m, st, vec2(2.0, 3.0));
	vec4 c2 = box(TEXTURE, m, st, vec2(3.0, 6.0));
	vec4 c3 = box(TEXTURE, m, st, vec2(5.0, 12.0));
	float a3 = prof(v, 0.55, 0.32, 0.999);
	float a2 = prof(v, 0.78, 0.05, 0.80);
	float a1 = prof(v, 0.90, 0.0, 0.52);
	float a0 = prof(v, 1.00, 0.0, 0.26);
	vec4 acc = c3 * a3;
	acc = c2 * a2 + acc * (1.0 - c2.a * a2);
	acc = c1 * a1 + acc * (1.0 - c1.a * a1);
	acc = c0 * a0 + acc * (1.0 - c0.a * a0);
	COLOR = acc * vc;
}
