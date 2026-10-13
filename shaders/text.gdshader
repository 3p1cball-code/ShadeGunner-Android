shader_type canvas_item;
render_mode unshaded, blend_disabled;
// Optionaler Text-/ASCII-Modus fuer ShadeGunner: die 640x360-Szene wird als
// Zeichenraster gezeichnet.
//
// Pro Zelle:
//   1. mittlere Farbe der Zelle (4x4 Abgriffe, texelFetch)
//   2. naechstliegende Palettenfarbe aus noir16 (wie chain/bayer.gdshader)
//   3. Helligkeit dieser Farbe -> Glyphen-Index (nach Dichte geordnet)
//   4. Glyphe aus dem Zeichen-Atlas (weiße Glyphen, Alpha = Deckung) in der
//      Palettenfarbe auf Schwarz.
//
// Ausgabe ist wieder 640x360, damit die vorhandene CRT-Kette (scene_tex)
// unveraendert darueber laufen kann. u_enabled = 0 reicht die Szene durch.

uniform sampler2D u_scene : filter_nearest, repeat_disable;  // 640x360 Szene
uniform sampler2D u_atlas : filter_nearest, repeat_disable;  // Glyphen-Kachelreihe
uniform vec2 u_res = vec2(640.0, 360.0);
uniform float u_cell_px = 8.0;   // Zellkante in Szenenpixeln
uniform int u_n = 10;            // Anzahl Glyphen im Atlas
uniform float u_gain = 1.0;      // Helligkeitsverstaerkung vor der Gamma-Kurve
uniform float u_gamma = 0.7;     // < 1 hebt dunkle Bereiche an (Nacht-Szene)
uniform int u_enabled = 1;

// noir16 - identisch zu src/config.gd / chain/bayer.gdshader
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
	vec3(0.4784, 0.2902, 0.6588));

vec3 nearest_pal(vec3 c) {
	vec3 best = PAL[0];
	float bd = 1e9;
	for (int i = 0; i < 16; ++i) {
		vec3 d = (c - PAL[i]) * vec3(0.9, 1.1, 0.8);
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = PAL[i]; }
	}
	return best;
}

void fragment() {
	vec3 out_col = texture(u_scene, UV).rgb;
	if (u_enabled == 1) {
		vec2 px = UV * u_res;
		vec2 cf = px / u_cell_px;
		ivec2 cell = ivec2(floor(cf));
		// Zellmittel: 4x4 = 16 Abgriffe ueber die Zellkante
		vec3 sum = vec3(0.0);
		float step_px = u_cell_px * 0.25;
		ivec2 base = cell * int(u_cell_px);
		ivec2 maxp = ivec2(u_res) - ivec2(1, 1);
		for (int j = 0; j < 4; ++j) {
			for (int i = 0; i < 4; ++i) {
				ivec2 p = base + ivec2(int((float(i) + 0.5) * step_px), int((float(j) + 0.5) * step_px));
				sum += texelFetch(u_scene, clamp(p, ivec2(0, 0), maxp), 0).rgb;
			}
		}
		vec3 mean = clamp(sum / 16.0, 0.0, 1.0);
		vec3 pal = nearest_pal(mean);
		float lum = dot(pal, vec3(0.299, 0.587, 0.114));
		lum = clamp(pow(clamp(lum * u_gain, 0.0, 1.0), u_gamma), 0.0, 1.0);
		int ci = clamp(int(floor(lum * float(u_n))), 0, u_n - 1);
		// Glyphe aus der Kachelreihe: Kachel ci, lokale UV innerhalb der Zelle
		vec2 local = cf - floor(cf);
		vec2 auv = vec2((float(ci) + local.x) / float(u_n), local.y);
		float cov = texture(u_atlas, auv).a;
		out_col = pal * cov;
	}
	COLOR = vec4(out_col, 1.0);
}
