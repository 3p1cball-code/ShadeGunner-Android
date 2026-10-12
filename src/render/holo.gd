class_name Holo
extends RefCounted
## Port von render/holo.py: holografische Ballerinas (Blade Runner 2049).
##
## Die Tänzerin ist ein kleines 3D-Skelett (x seitlich, y nach unten, z zur Kamera),
## das zwischen Ballett-Posen interpoliert und um die Hochachse dreht. Projektion
## orthografisch mit leichter Aufsicht.
##
## Eigene Textur je Hologramm, neu gezeichnet bei 20 fps:
##   _Tex.vpa  Tänzerin in ss-facher Auflösung (Original zeichnet mit Antialiasing;
##             GLES3 kennt kein 2D-MSAA -> Supersampling)
##   _Tex.vpb  Shader: ss x ss mitteln (= Flächendeckung wie Qt-AA), Scanline-Maske
##             (DestinationIn, _mask) und Laufband (SourceAtop) -> fertiges Bild.
## Beide Viewports hängen am Baker (Holo.baker setzen; Baker VOR der Szene).
##
##   Holo.render(p, e, x, base, h, col, t, seed, reflect, alpha, mirror)  # zeichnet additiv

const PLUS := QP.PLUS
const OVER := QP.OVER
const DESIGN_H := DHolo.DESIGN_H
const ARMS := DHolo.ARMS
const LEGS := DHolo.LEGS
const T4 := DHolo.T4
const T6 := DHolo.T6
const KEYS := DHolo.KEYS
const CYCLE := DHolo.CYCLE
const _KP := DHolo._KP
const FPS := DHolo.FPS

static var baker: Baker
## Supersampling-Faktor der Tänzerin-Textur (Antialiasing-Ersatz).
static var ss := 4
static var _TMP := {}       # [seed, w, hh, mirror] -> [tick, _Tex]   eigene Textur je Hologramm

const _HOLO_SHADER := """shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D src : filter_nearest;
uniform int ss = 4;
uniform int step = 2;
uniform float band0 = 0.0;
uniform float band1 = 0.0;
void fragment(){
	ivec2 px = ivec2(FRAGCOORD.xy);
	vec4 acc = vec4(0.0);
	for (int j = 0; j < ss; j++) {
		for (int i = 0; i < ss; i++) {
			acc += texelFetch(src, px * ss + ivec2(i, j), 0);
		}
	}
	vec4 c = acc / float(ss * ss);
	// Scanlines: DestinationIn mit Alpha 105 jede step-te Zeile
	if (px.y % step == 0) {
		c *= 105.0 / 255.0;
	}
	// Laufband: SourceAtop, Weiß mit Alpha 110, Teilabdeckung der Randzeilen (AA)
	float cov = clamp(min(float(px.y + 1), band1) - max(float(px.y), band0), 0.0, 1.0);
	float k = 110.0 / 255.0 * cov;
	c.rgb = vec3(k * c.a) + c.rgb * (1.0 - k);
	COLOR = c;
}
"""
static var _shader: Shader


class _Tex:
	var vpa: SubViewport
	var vpb: SubViewport
	var pa: QP
	var mat: ShaderMaterial
	var img: QImg


static func _add(a: Array, b: Array, k: float = 1.0) -> Array:
	return [float(a[0]) + float(b[0]) * k, float(a[1]) + float(b[1]) * k, float(a[2]) + float(b[2]) * k]


static func _lerp(a: Array, b: Array, u: float) -> Array:
	var out: Array = []
	for i in a.size():
		out.append(float(a[i]) + (float(b[i]) - float(a[i])) * u)
	return out


## Konkrete Punkte einer Schlüsselpose (die Tabelle _KP kommt vorberechnet aus DHolo).
static func _key_pose(key: Array) -> Dictionary:
	var r: float = key[1]
	var pl: float = key[2]
	var lean: float = key[3]
	var al: String = key[4]
	var ar: String = key[5]
	var leg: String = key[6]
	var hip_y := -(22.0 + 3.0 * r) + 6.0 * pl
	var foot_y := -1.2 - 2.2 * r
	var P := {}
	P["hip"] = [0.0, hip_y, 0.0]
	var hs := [-1.6, hip_y, 0.0]
	var hw := [1.6, hip_y, 0.0]
	# Standbein (links)
	var ank := [-0.6, foot_y, 0.4]
	P["hip_s"] = hs
	P["ank_s"] = ank
	P["kn_s"] = [(float(hs[0]) + float(ank[0])) / 2 - 3.2 * pl, (float(hs[1]) + float(ank[1])) / 2, 0.8 + 1.6 * pl]
	P["toe_s"] = [-0.6 + 0.4 * (1 - r), 0.0 if r > 0.5 else -0.4, 0.8 + 2.4 * (1 - r)]
	# Spielbein (rechts)
	P["hip_w"] = hw
	if leg == "ground":
		var fw := [0.4, foot_y, 1.6]
		P["kn_w"] = [(float(hw[0]) + float(fw[0])) / 2 + 3.2 * pl + 0.4, (float(hw[1]) + float(fw[1])) / 2, 1.2 + 1.8 * pl]
		P["ank_w"] = fw
		P["toe_w"] = [0.6 + 0.4 * (1 - r), 0.0 if r > 0.5 else -0.4, 2.0 + 2.2 * (1 - r)]
	else:
		var kf: Array = LEGS[leg]
		var kw := _add(hw, kf[0])
		var fw := _add(hw, kf[1])
		var d := [float(fw[0]) - float(kw[0]), float(fw[1]) - float(kw[1]), float(fw[2]) - float(kw[2])]
		var n := sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
		if n == 0.0:
			n = 1.0
		P["kn_w"] = kw
		P["ank_w"] = fw
		P["toe_w"] = _add(fw, d, 3.0 / n)
	# Oberkörper (Neigung nach vorn = +z)
	var cl := cos(lean)
	var sl := sin(lean)
	var sc := [0.0, hip_y - 14.0 * cl, 14.0 * sl]
	P["waist"] = [0.0, hip_y - 4.6 * cl, 4.6 * sl]
	P["sc"] = sc
	P["head"] = [0.0, float(sc[1]) - 5.2 * cl, float(sc[2]) + 5.2 * sl]
	P["bun"] = [0.0, float(sc[1]) - 7.6 * cl, float(sc[2]) + 7.6 * sl - 1.4]
	for side_def: Array in [["l", al, 1.0], ["r", ar, -1.0]]:
		var side: String = side_def[0]
		var s: float = side_def[2]
		var sh := [float(sc[0]) - 4.2 * s, sc[1], sc[2]]
		var arm: Array = ARMS[side_def[1]]
		var el: Array = arm[0]
		var ha: Array = arm[1]
		P["sh_" + side] = sh
		P["el_" + side] = _add(sh, [float(el[0]) * s, el[1], el[2]])
		P["ha_" + side] = _add(sh, [float(ha[0]) * s, ha[1], ha[2]])
	return P


## [Punkte, Drehwinkel] zur Zeit t (s), zyklisch.
static func pose_at(t: float) -> Array:
	t = Py.mod(t, CYCLE)
	var i := 0
	while i < KEYS.size() - 2 and float(KEYS[i + 1][0]) <= t:
		i += 1
	var t0: float = KEYS[i][0]
	var t1: float = KEYS[i + 1][0]
	var u := 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
	var us := u * u * (3 - 2 * u)
	var a: Dictionary = _KP[i]
	var b: Dictionary = _KP[i + 1]
	var pts := {}
	for k: String in a:
		pts[k] = _lerp(a[k], b[k], us)
	var th0: float = KEYS[i][7]
	var th1: float = KEYS[i + 1][7]
	var th := th0 + (th1 - th0) * (u if th1 != th0 else us)
	return [pts, th]


static func _proj(pt: Array, c: float, s: float) -> Array:
	var x: float = pt[0]
	var y: float = pt[1]
	var z: float = pt[2]
	var X := x * c + z * s
	var Z := -x * s + z * c
	return [X, y + Z * 0.12, Z]


static func _shade(col: Array, k: float) -> Color:
	return QP.c(maxi(0, mini(255, int(float(col[0]) * k))), maxi(0, mini(255, int(float(col[1]) * k))),
		maxi(0, mini(255, int(float(col[2]) * k))))


## Tänzerin in Design-Einheiten (Füße bei y = 0) auf Painter p zeichnen.
static func draw_dancer(p: QP, t: float, col: Array, wk: float = 1.0) -> void:
	var pt: Array = pose_at(t)
	var pts: Dictionary = pt[0]
	var th: float = pt[1]
	var c := cos(th)
	var s := sin(th)
	var Q := {}
	for k: String in pts:
		Q[k] = _proj(pts[k], c, s)
	var items: Array = []     # [z, Reihenfolge, Art, Daten] - Reihenfolge macht die Sortierung stabil
	var seg := func(a: String, b: String, w: float) -> void:
		var z := (float(Q[a][2]) + float(Q[b][2])) * 0.5
		items.append([z, items.size(), "line", [Q[a], Q[b], w * wk]])
	seg.call("hip_s", "kn_s", 2.4)
	seg.call("kn_s", "ank_s", 1.7)
	seg.call("ank_s", "toe_s", 1.2)
	seg.call("hip_w", "kn_w", 2.4)
	seg.call("kn_w", "ank_w", 1.7)
	seg.call("ank_w", "toe_w", 1.2)
	for sd: String in ["l", "r"]:
		seg.call("sh_" + sd, "el_" + sd, 1.5)
		seg.call("el_" + sd, "ha_" + sd, 1.2)
	# Mieder: Schultern -> Taille (wird bei Seitenansicht schmal)
	var zt: float = Q["sc"][2]
	items.append([zt, items.size(), "poly", [Q["sh_l"], Q["sh_r"], _add(Q["waist"], [1.9 * c, 0, 0]),
		_add(Q["waist"], [-1.9 * c, 0, 0])]])
	items.append([zt, items.size(), "line", [Q["sc"], Q["head"], 1.2]])
	items.append([float(Q["head"][2]) + 0.5, items.size(), "head", [Q["head"], Q["bun"]]])
	# Tutu: hintere Hälfte hinter, vordere Hälfte vor den Beinen
	var hip: Array = Q["hip"]
	items.append([-6.0, items.size(), "tutu", [hip, th, false]])
	items.append([6.0, items.size(), "tutu", [hip, th, true]])
	items.sort_custom(func(x: Array, y: Array) -> bool:
		return float(x[0]) < float(y[0]) or (float(x[0]) == float(y[0]) and int(x[1]) < int(y[1])))
	p.set_no_pen()
	for it: Array in items:
		var z: float = it[0]
		var kind: String = it[2]
		var d: Array = it[3]
		var k := 0.72 + 0.28 * maxf(-1.0, minf(1.0, z / 9.0))
		if kind == "line":
			var a: Array = d[0]
			var b: Array = d[1]
			p.set_pen(_shade(col, k), float(d[2]), QP.CAP_ROUND)
			p.draw_line(a[0], a[1], b[0], b[1])
			p.set_no_pen()
		elif kind == "poly":
			p.set_brush(_shade(col, k))
			var poly := PackedVector2Array()
			for q: Array in d:
				poly.append(Vector2(float(q[0]), float(q[1])))
			p.draw_polygon(poly)
		elif kind == "head":
			var h: Array = d[0]
			var bun: Array = d[1]
			p.set_brush(_shade(col, 1.0))
			p.draw_ellipse_c(h[0], h[1], 2.7, 3.0)
			p.draw_ellipse_c(bun[0], bun[1], 1.4, 1.2)
		else:
			var hp: Array = d[0]
			var ang: float = d[1]
			var front: bool = d[2]
			var R := 10.5
			var yc := float(hp[1]) + 0.8
			var a0 := 0.0 if front else PI
			var a1 := PI if front else 2 * PI
			var n := 14
			var top: Array = []
			for i in n + 1:
				var aa := a0 + (a1 - a0) * i / n
				top.append(Vector2(R * cos(aa), yc + 0.12 * R * sin(aa)))
			var poly := PackedVector2Array()
			for v: Vector2 in top:
				poly.append(v)
			for i in range(top.size() - 1, -1, -1):
				var v: Vector2 = top[i]
				poly.append(Vector2(v.x * 0.9, v.y + 1.8))
			p.set_brush(_shade(col, 1.0 if front else 0.6))
			p.draw_polygon(poly)
			# Falten drehen mit (zeigt die Pirouette)
			p.set_pen(_shade(col, 0.5 if front else 0.35), 0.7)
			for i in 12:
				var aa := ang + i * PI / 6
				if (sin(aa) > 0) != front:
					continue
				var x := R * cos(aa)
				var y := yc + 0.12 * R * sin(aa)
				p.draw_line(x * 0.3, yc + 0.3 * (y - yc), x, y + 1.2)
			p.set_no_pen()


static func _hash(i: int, s: int) -> float:
	var h := (i * 374761393 + s * 668265263) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((h ^ (h >> 16)) & 0xFFFF) / 65535.0


## Scanline-Maske: im Original ein gecachtes Maskenbild (Alpha 105 jede step-te Zeile)
## für DestinationIn. Hier Shader-Parameter des Ausgabe-Passes.
static func _mask(t: _Tex, step_: int) -> void:
	t.mat.set_shader_parameter("step", step_)


static func _new_tex(w: int, hh: int) -> _Tex:
	assert(baker != null, "Holo.baker muss gesetzt sein")
	if _shader == null:
		_shader = Shader.new()
		_shader.code = _HOLO_SHADER
	var t := _Tex.new()
	t.vpa = SubViewport.new()
	t.vpa.size = Vector2i(w * ss, hh * ss)
	t.vpa.transparent_bg = true
	t.vpa.disable_3d = true
	t.vpa.render_target_update_mode = SubViewport.UPDATE_DISABLED
	t.vpa.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	var ha := Node2D.new()
	t.vpa.add_child(ha)
	baker.add_child(t.vpa)
	t.pa = QP.new(ha.get_canvas_item())
	t.vpb = SubViewport.new()
	t.vpb.size = Vector2i(w, hh)
	t.vpb.transparent_bg = true
	t.vpb.disable_3d = true
	t.vpb.render_target_update_mode = SubViewport.UPDATE_DISABLED
	t.vpb.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	var rect := ColorRect.new()
	rect.size = Vector2(w, hh)
	t.mat = ShaderMaterial.new()
	t.mat.shader = _shader
	t.mat.set_shader_parameter("src", t.vpa.get_texture())
	t.mat.set_shader_parameter("ss", ss)
	rect.material = t.mat
	t.vpb.add_child(rect)
	baker.add_child(t.vpb)       # nach vpa -> im selben Frame danach gerendert
	t.img = QImg.new(t.vpb.get_texture(), Rect2(0, 0, w, hh))
	return t


static func _free_tex(t: _Tex) -> void:
	t.pa.free_all()
	t.vpa.queue_free()
	t.vpb.queue_free()


## Hologramm der Höhe h px mit Fußpunkt (x, base) additiv zeichnen.
static func render(p: QP, e: QP, x: float, base: float, h: float, col: Array, t: float, seed_: int,
		reflect: float = 0.0, alpha: float = 0.62, mirror: bool = false) -> void:
	var s := h / DESIGN_H
	var w := int(h * 1.05) + 6
	var hh := int(h * 1.08) + 6
	var key := [seed_, w, hh, mirror]
	var tick := int(t * FPS)
	var ent: Variant = _TMP.get(key)
	if ent == null:
		if _TMP.size() > 32:
			for old: Array in _TMP.values():
				_free_tex(old[1])
			_TMP.clear()
		ent = [null, _new_tex(w, hh)]
		_TMP[key] = ent
	var tx: _Tex = ent[1]
	if ent[0] != tick:
		ent[0] = tick
		var q := tx.pa
		q.begin()
		q.scale(ss, ss)
		q.translate(w / 2.0, hh - 3)
		q.scale(-s if mirror else s, s)
		draw_dancer(q, tick / FPS + seed_ * 0.37, col, maxf(1.0, minf(1.6, 150.0 / maxf(1.0, h))))
		q.end()
		# Scanlines (eine Maske) + wanderndes Helligkeitsband (Ausgabe-Pass)
		_mask(tx, 2 if h < 90 else 3)
		var band := Py.mod(t * 38.0 + seed_ * 17, hh + 30) - 15
		tx.mat.set_shader_parameter("band0", band)
		tx.mat.set_shader_parameter("band1", band + maxf(2.0, h * 0.06))
		tx.vpa.render_target_update_mode = SubViewport.UPDATE_ONCE
		tx.vpb.render_target_update_mode = SubViewport.UPDATE_ONCE
	var img := tx.img
	# Flackern, Aussetzer, Glitch
	var a := alpha * (0.9 + 0.1 * sin(t * 23.0 + seed_))
	if _hash(int(t * 9), seed_) < 0.035:
		a *= 0.25
	var glitch := _hash(int(t * 7), seed_ + 3) < 0.06
	var x0 := int(x - w / 2.0)
	var y0 := int(base - hh + 3)
	p.set_mode(PLUS)
	# Projektionslicht am Fußpunkt
	var rg := QGrad.radial(x, base, h * 0.35)
	rg.set_color_at(0, QP.c(col[0], col[1], col[2], int(70 * a)))
	rg.set_color_at(1, QP.c(0, 0, 0, 0))
	p.save()
	p.translate(x, base)
	p.scale(1.0, 0.22)
	p.translate(-x, -base)
	p.fill_rect(x - h * 0.35, base - h * 0.35, h * 0.7, h * 0.7, rg)
	p.restore()
	for qo: Array in [[p, a], [e, a * 0.32]]:
		var q: QP = qo[0]
		q.set_opacity(qo[1])
		if glitch:
			for row in range(0, hh, 4):
				var off := int((_hash(row + int(t * 30), seed_) - 0.5) * h * 0.08)
				var rh := mini(4, hh - row)     # Qt beschneidet die Quelle am Bildrand
				q.draw_image(Rect2(x0 + off, y0 + row, w, rh), img, Rect2(0, row, w, rh))
		else:
			q.draw_image_at(x0, y0, img)
		q.set_opacity(1.0)
	if reflect > 0.0:
		p.set_opacity(a * reflect)
		p.save()      # img.mirrored(False, True) an (x0, int(base) - 3)
		p.translate(x0, int(base) - 3 + hh)
		p.scale(1.0, -1.0)
		p.draw_image_at(0, 0, img)
		p.restore()
		p.set_opacity(1.0)
	p.set_mode(OVER)
