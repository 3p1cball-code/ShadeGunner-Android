class_name Props
extends RefCounted
## Requisiten der gegenüberliegenden Straßenseite - 1:1-Port von render/props.py.
##
## Alles hier wird einmal pro Zone in die Häuserfront gebacken (kostet zur Laufzeit
## nichts). Was lebt - Feuer in Tonnen, Fußgängerampeln, Monitore, Warnlampen - wird
## nur als Eintrag in eine Liste der Stadt gelegt und von Scene gezeichnet.
##
## - dicke Säulen: Beton-Monolithen mit Kreide-Graffiti, bauchig gedrehte
##   Ornament-Säulen, Ampeltürme aus Kästen und Kabeln (rote Hand / grüner Pfeil)
## - Verfall: Müllberge, ausgeschlachtete 60er-Wracks, Feuertonnen, Pollerkästen
## - Fassaden: alt + verschnörkelt mit nachgerüsteten Kabeln, oder hypermodern
##
## Eigener Zufallsgenerator, damit die Grundaufteilung der Stadt erhalten bleibt.
## Port-Hinweis: `city` ist eine City oder (beim Ampelturm als Objekt) ein Props.Collect;
## QPainterPath.quadTo (Kabel) wird als Polylinie aus 16 Stücken angenähert.

const RED := DProps.RED
const SODIUM := DProps.SODIUM
const NBLUE := DProps.NBLUE
const PALE := DProps.PALE
const TEAL := DProps.TEAL
const CYAN := DProps.CYAN
const AMBER := DProps.AMBER
const GREEN := DProps.GREEN
const CHALK := DProps.CHALK
const ZONE_PROPS := DProps.ZONE_PROPS
const ZONE_FACADE := DProps.ZONE_FACADE
const WIDTH := DProps.WIDTH
const DERELICT := DProps.DERELICT
const OCCLUDE := DProps.OCCLUDE

# 60er-Jahre-Limousine (Heckflossen), in Zeichen-Einheiten: Länge 50, Höhe ~14
const _CLASSIC := [[0, -4], [1, -7], [6, -8], [14, -8.6], [18, -13.4], [31, -13.6], [36, -9.0], [46, -8.4],
		[49.5, -9.6], [50, -6], [49, -3], [1, -3]]


static func mul(c: Array, f: float) -> Array:
	return City.mul(c, f)


static func mix(a: Array, b: Array, t: float) -> Array:
	return City.mix(a, b, t)


static func qc(c: Array, a: float = 255.0) -> Color:
	return QP.rgb(c, a)


static func _poly(p: QP, pts: Array, col: Array, a: float = 255.0) -> void:
	var pa := PackedVector2Array()
	for q: Variant in pts:
		if q is Vector2:
			pa.append(q)
		else:
			pa.append(Vector2(float(q[0]), float(q[1])))
	p.set_no_pen()
	p.set_brush(qc(col, a))
	p.draw_polygon(pa)


## Durchhängendes Kabel (Parabel; quadTo als Polylinie).
static func _wire(p: QP, x0: float, y0: float, x1: float, y1: float, sag: float, col: Array, a: float = 255.0,
		w: int = 1) -> void:
	p.set_pen(qc(col, a), float(w))
	p.set_no_brush()
	var cx := (x0 + x1) / 2.0
	var cy := maxf(y0, y1) + sag * 2
	var pts := PackedVector2Array()
	var n := 16
	for i in n + 1:
		var t := float(i) / n
		var u := 1.0 - t
		pts.append(Vector2(u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1))
	p.draw_polyline(pts)
	p.set_no_pen()


## Pseudo-Schriftzeichen 5x7 (wie city._glyph, eigener Generator). Gibt [Vector2i, ...].
static func _glyph(rng: PyRandom) -> Array:
	var px := {}
	for _i in rng.randint(3, 5):
		var k := rng.random()
		if k < 0.4:
			var y: int = rng.choice([0, 2, 3, 4, 6])
			var xr: Array = rng.choice([[0, 4], [0, 2], [2, 4], [1, 3]])
			for x in range(int(xr[0]), int(xr[1]) + 1):
				px[Vector2i(x, y)] = true
		elif k < 0.8:
			var x: int = rng.choice([0, 2, 4, 1, 3])
			var yr: Array = rng.choice([[0, 6], [0, 3], [3, 6], [1, 5]])
			for y in range(int(yr[0]), int(yr[1]) + 1):
				px[Vector2i(x, y)] = true
		else:
			var d: int = rng.choice([1, -1])
			for i in 4:
				px[Vector2i(2 + d * (i - 1), 2 + i)] = true
	return px.keys()


## Python-Set-Reihenfolge ist für das Ergebnis egal (jedes Pixel wird gleich gefüllt).


# ============================================================================ Platzierung

## Verteilt die Requisiten über die Häuserfront der Zone.
static func furnish(city: City, p: QP, e: QP, fac: City.Layer, base: int) -> void:
	var z := Py.imod(city.zone, ZONE_PROPS.size())
	var cfg: Dictionary = ZONE_PROPS[z]
	var rng := PyRandom.new(city.seed_ * 7177 + z * 31 + 5)
	var busy := []
	for rx: float in Procgen.ramen_positions(city.length, city.seed_, city.zone):
		var lx := fac.lx(rx * fac.factor) - 88
		busy.append([lx - 14, lx + 190])
	busy.append([city.exit_L - 72, city.exit_L + 72])
	if not city.sebastian_span.is_empty():
		busy.append(city.sebastian_span)
	# Unter den Brücken: Feuertonnen, Müll und Wracks - dort hausen die, die sonst nirgends sind
	for s: Dictionary in city.spans:
		if s["kind"] != "bridge" or z == 4:
			continue
		var a := int(fac.lx(float(s["x0"]) * fac.factor))
		var b := int(fac.lx(float(s["x1"]) * fac.factor))
		var xx := a + rng.randint(0, 6)
		while xx < b - 10:
			var kind: String = rng.choice(["barrel", "barrel", "trash", "wreck", "bins", "barrel"])
			var wr: Array = WIDTH[kind]
			var w := rng.randint(wr[0], wr[1])
			if xx + w > b + 6:
				break
			if not _busy(busy, xx, xx + w):
				_place(city, p, e, fac, rng, kind, xx, base, w)
			xx += w + rng.randint(2, 12)
		busy.append([a - 4, b + 4])
	var wd: Dictionary = cfg["w"]
	var kinds: Array = wd.keys()
	var weights: Array = wd.values()
	var x := rng.randint(10, 60)
	var last := ""
	var der_k: Array = DERELICT.keys()
	var der_w: Array = DERELICT.values()
	var der_from := city.length * (Config.EMPTY_FROM - 0.04) * fac.factor - fac.lmin if z == 4 else 1e9
	var step: Array = cfg["step"]
	while x < fac.width - 40:
		var kind: String
		if x > der_from:
			kind = rng.choices1(der_k, der_w)
		else:
			kind = rng.choices1(kinds, weights)
		if kind == last and kind in ["wreck", "tower", "ornate"]:
			kind = "none"
		var wr: Array = WIDTH[kind]
		var w := rng.randint(wr[0], wr[1])
		if kind != "none" and not _busy(busy, x, x + w):
			_place(city, p, e, fac, rng, kind, x, base, w)
			last = kind
			# Säulen stehen oft in Reihe (Kolonnade wie im Chinatown-Set)
			if kind in ["monolith", "ornate"] and rng.random() < 0.55:
				x += w + rng.randint(40, 70)
				if x < fac.width - 40 and not _busy(busy, x, x + w):
					_place(city, p, e, fac, rng, kind, x, base, w)
		x += w + rng.randint(step[0], step[1])


static func _busy(busy: Array, a: float, b: float) -> bool:
	for ab: Array in busy:
		if float(ab[0]) < b and a < float(ab[1]):
			return true
	return false


static func _place(city: Object, p: QP, e: QP, fac: Object, rng: PyRandom, kind: String, x: float, base: float,
		w: float) -> void:
	var oc: Array = OCCLUDE[kind]
	var mx: float = oc[0]
	var top := 0.0 if oc[1] == null else base - float(oc[1])
	e.set_mode(QP.CLEAR)
	e.fill_rect(x + mx, top, w - 2 * mx, base - top, Color(0, 0, 0, 0))
	e.set_mode(QP.OVER)
	match kind:
		"monolith":
			monolith(city, p, e, fac, rng, x, base, w)
		"bins":
			bins(city, p, e, fac, rng, x, base, w)
		"ornate":
			ornate(city, p, e, fac, rng, x, base, w)
		"tower":
			tower(city, p, e, fac, rng, x, base, w)
		"trash":
			trash(city, p, e, fac, rng, x, base, w)
		"wreck":
			wreck(city, p, e, fac, rng, x, base, w)
		"barrel":
			barrel(city, p, e, fac, rng, x, base, w)
		"bollard":
			bollard(city, p, e, fac, rng, x, base, w)


# ============================================================================ Säulen

## Beton-Monolith, der oben im Dunkel verschwindet; Kreide-Graffiti (Schriftzeichen).
static func monolith(city: Object, p: QP, _e: QP, _fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var th: Dictionary = city.th
	var clean: bool = th["style"] == "tyrell"
	var sw := w - 8                                   # Schaftbreite unten
	var cx := x + w / 2.0
	var c := mix(th["building_hi"], [60, 64, 62], 0.5)
	c = mul(c, rng.uniform(0.8, 1.05) * (0.7 if clean else 1.0))
	var ph := rng.randint(9, 14)
	var top_w := sw - 4
	var g := QGrad.linear(0, 0, 0, base)
	g.set_color_at(0.0, qc(mul(c, 0.25)))
	g.set_color_at(0.55, qc(mul(c, 0.6)))
	g.set_color_at(1.0, qc(c))
	p.set_no_pen()
	p.set_brush(g)
	p.draw_polygon(PackedVector2Array([Vector2(cx - top_w / 2, 0), Vector2(cx + top_w / 2, 0),
		Vector2(cx + sw / 2, base - ph), Vector2(cx - sw / 2, base - ph)]))
	# Schattenseite + Streiflicht (Neon von der Straße)
	_poly(p, [[cx + top_w / 2 - 3, 0], [cx + top_w / 2, 0], [cx + sw / 2, base - ph], [cx + sw / 2 - 4, base - ph]],
		mul(c, 0.45), 200)
	var rim := mul(th["rim"], 0.5)
	for y in range(int(base * 0.35), int(base - ph)):
		var k := (y - base * 0.35) / (base * 0.65)
		var xl := cx - top_w / 2 + (sw - top_w) / 2 * (y / (base - ph))
		p.fill_rect(int(xl), y, 1, 1, qc(rim, int(60 + 120 * k)))
	# Sockel (Pyramidenstumpf)
	_poly(p, [[cx - sw / 2 - 1, base - ph], [cx + sw / 2 + 1, base - ph], [x + w, base], [x, base]], mul(c, 0.9))
	p.fill_rect(int(cx - sw / 2 - 1), base - ph, sw + 2, 1, qc(mul(c, 1.35)))
	_poly(p, [[cx + sw / 2 - 2, base - ph], [cx + sw / 2 + 1, base - ph], [x + w, base], [x + w - 5, base]],
		mul(c, 0.55))
	# Fugen
	var y := base - ph - rng.randint(14, 22)
	while y > 20:
		var xl := cx - top_w / 2 + (sw - top_w) / 2 * (y / (base - ph))
		p.fill_rect(int(xl) + 1, y, int(top_w + (sw - top_w) * y / (base - ph)) - 2, 1, qc(mul(c, 0.7)))
		y -= rng.randint(16, 26)
	if clean:
		# Tyrell: polierter Stein, eine bernsteinfarbene Lichtfuge
		for qk: Array in [[p, 0.7], [_e, 0.45]]:
			(qk[0] as QP).fill_rect(int(cx) - 1, 30, 1, base - ph - 34, qc(mul(AMBER, qk[1])))
		return
	# Schmutzfahnen
	for _i in rng.randint(2, 5):
		var sx := int(cx - sw / 2 + rng.uniform(2, sw - 2))
		var sy := rng.randint(int(base * 0.4), int(base - ph - 6))
		p.fill_rect(sx, sy, 1, rng.randint(6, 24), qc(mul(c, 0.55), 160))
	# Kreide-Graffiti: Spalten aus Schriftzeichen, unregelmäßig, blass
	for col in rng.choice([1, 2, 2]):
		var gx := int(cx - sw / 2 + 2 + col * (sw / 2 - 1))
		var gy := base - ph - 10 - rng.randint(0, 8)
		for _i in rng.randint(3, 7):
			var a := rng.randint(70, 150)
			for pxy: Vector2i in _glyph(rng):
				if pxy.x < sw / 2 - 2:
					p.fill_rect(gx + pxy.x, gy - 7 + pxy.y, 1, 1, qc(CHALK, a))
			gy -= 9
			if gy < base * 0.45:
				break
	if rng.random() < 0.4:        # Kritzelei
		p.set_pen(qc(CHALK, 90), 1.0)
		var y0 := base - ph - rng.randint(4, 16)
		p.draw_line(cx - sw / 2 + 2, y0, cx + sw / 2 - 3, y0 - rng.randint(-3, 3))
		p.set_no_pen()
	# Plakatfetzen
	if rng.random() < 0.35:
		var px_ := int(cx - sw / 2 + rng.uniform(1, sw - 8))
		var py_ := rng.randint(int(base * 0.6), int(base - ph - 12))
		var pc: Array = rng.choice([[170, 160, 130], [150, 60, 50], [90, 120, 120]])
		p.fill_rect(px_, py_, rng.randint(5, 8), rng.randint(6, 10), qc(mul(pc, 0.55)))


## Ein bauchiger Säulenring von y nach oben (hseg Zeilen). tex: 'twist' (gedrehte
## Kanneluren), 'lobes' (große runde Wülste), 'carved' (geschnitzte Knollen).
## Gibt [neues_y, rows] (rows = [[yy, half], ...]).
static func _bulb(p: QP, cx: float, y: float, hseg: int, half_max: float, stone: Array, tex: String,
		rng: PyRandom, min_r: float = 0.55) -> Array:
	var twist: float = rng.choice([0.8, -0.8, 1.0])
	var n_lobe: int = rng.choice([5, 6])
	var rows := []
	for j in hseg:
		var t := float(j) / maxi(1, hseg - 1)
		var half := half_max * (min_r + (1.0 - min_r) * pow(sin(PI * t), 0.8))
		var yy := y - j - 1
		rows.append([yy, half])
		var x0 := int(cx - half)
		var x1 := int(cx + half)
		var vert := 0.72 + 0.28 * sin(PI * t)
		for xx in range(x0, x1 + 1):
			var u := maxf(-1.0, minf(1.0, (xx - cx) / maxf(1.0, half)))
			var a := asin(u)
			var light := (0.42 + 0.62 * maxf(0.0, 1.0 - (u + 0.38) * (u + 0.38))) * vert
			if tex == "twist":
				if Py.mod((xx - cx) + j * twist, 4.0) < 1.4:
					light *= 0.58
			elif tex == "lobes":
				var lob := maxf(0.0, cos(a * n_lobe))
				light *= 0.32 + 0.95 * lob * (0.45 + 0.55 * sin(PI * t))
			else:  # carved
				var rr := Py.mod(t * 2.0, 1.0)
				var off := 0.0 if t < 0.5 else PI / 7
				var lump := maxf(0.0, cos(a * 7 + off)) * sin(PI * rr)
				light *= 0.3 + 0.95 * lump
			p.fill_rect(xx, yy, 1, 1, qc(mul(stone, light)))
	return [y - hseg, rows]


## Ornament-Säule wie im Chinatown-Set: mehrere bauchige Ringe übereinander -
## unten gedreht und mit Plakatfetzen beklebt, darüber große runde Wülste, oben eine
## Krone aus geschnitzten Knollen; dann der schlanke Schaft ins Dunkel.
static func ornate(city: Object, p: QP, _e: QP, _fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var th: Dictionary = city.th
	var stone := mul(rng.choice([[110, 84, 62], [100, 80, 64], [86, 76, 64]]), rng.uniform(0.85, 1.05))
	var rim: Array = th["rim"]
	var cx := x + w / 2.0
	var half_max := w / 2.0 - 1
	var u := w / 36.0
	var plinth := maxi(4, int(5 * u))

	var collar := func(y_: float, half: float) -> float:
		p.fill_rect(int(cx - half), y_ - 2, int(2 * half), 2, qc(mul(stone, 0.45)))
		for bx in range(int(cx - half) + 1, int(cx + half), 2):
			p.fill_rect(bx, y_ - 2, 1, 1, qc(mul(stone, 1.15)))
		return y_ - 2

	p.fill_rect(x + 1, base - plinth, w - 2, plinth, qc(mul(stone, 0.7)))
	p.fill_rect(x + 1, base - plinth, w - 2, 1, qc(mul(stone, 1.15)))
	var y := base - plinth
	var r := _bulb(p, cx, y, int(rng.randint(20, 24) * u), half_max * 0.88, stone, "twist", rng, 0.6)
	y = r[0]
	var rows_a: Array = r[1]
	# Plakatfetzen auf dem unteren Ring
	for _i in rng.randint(2, 4):
		var n := rows_a.size()
		var row: Array = rows_a[rng.randrange(Py.ifloordiv(n, 5), maxi(Py.ifloordiv(n, 5) + 1, Py.ifloordiv(n * 4, 5)))]
		var yy: float = row[0]
		var half: float = row[1]
		var pw := rng.randint(3, 5)
		var ph := rng.randint(4, 7)
		var px := cx + rng.uniform(-half * 0.8, half * 0.4)
		var pc := mul(rng.choice([[190, 170, 150], [170, 110, 120], [120, 140, 160], [200, 190, 140]]), 0.55)
		p.fill_rect(int(px), int(yy - ph / 2.0), pw, ph, qc(pc, 210))
		p.fill_rect(int(px), int(yy - ph / 2.0) + 1, 1, ph - 2, qc(mul(pc, 0.6), 200))
	y = collar.call(y, half_max * 0.62)
	r = _bulb(p, cx, y, int(rng.randint(11, 14) * u), half_max * 0.95, stone, "lobes", rng, 0.6)
	y = r[0]
	y = collar.call(y, half_max * 0.7)
	r = _bulb(p, cx, y, int(rng.randint(12, 15) * u), half_max, stone, "carved", rng, 0.72)
	y = r[0]
	# Kapitell
	p.fill_rect(int(cx - half_max * 0.9), y - 3, int(half_max * 1.8), 3, qc(mul(stone, 0.8)))
	p.fill_rect(int(cx - half_max * 0.9), y - 3, int(half_max * 1.8), 1, qc(mul(stone, 1.2)))
	y -= 3
	# Schaft ins Dunkel
	var sw := int(w * 0.42)
	var g := QGrad.linear(0, 0, 0, y)
	g.set_color_at(0.0, qc(mul(stone, 0.1)))
	g.set_color_at(1.0, qc(mul(stone, 0.5)))
	p.fill_rect(int(cx - sw / 2.0), 0, sw, y, g)
	p.fill_rect(int(cx - sw / 2.0), int(y * 0.4), 1, int(y * 0.6), qc(mul(rim, 0.4), 140))
	# Streiflicht (Neonseite)
	p.fill_rect(int(cx - half_max * 0.9), base - plinth - 16, 1, 10, qc(mul(rim, 0.55), 150))


## Kasten mit schräger Blende (Visier) zur Seite: wie die Ampelköpfe im Film.
static func _hood_box(p: QP, x: float, y: float, w: float, h: float, col: Array, side: int, hood: bool = true) -> void:
	p.fill_rect(x, y, w, h, qc(col))
	p.fill_rect(x, y, w, 1, qc(mul(col, 1.45)))
	p.fill_rect(x + (w - 1 if side < 0 else 0.0), y, 1, h, qc(mul(col, 1.25)))
	p.fill_rect(x + (0.0 if side < 0 else w - 1), y, 1, h, qc(mul(col, 0.55)))
	p.fill_rect(x + 1, y + h - 2, w - 2, 1, qc(mul(col, 0.6)))
	if hood:
		var ex := x + (w if side > 0 else 0.0)
		_poly(p, [[ex, y - 1], [ex + side * 6, y - 4], [ex + side * 6, y], [ex, y + h * 0.6]], mul(col, 0.85))
		_poly(p, [[ex + side * 6, y - 4], [ex + side * 7, y - 4], [ex + side * 7, y + 1], [ex + side * 6, y]],
			mul(col, 0.5))


## Ampelturm (Syd Mead): massiver gerippter Sockel mit Aufklebern, darauf Kästen mit
## schrägen Blenden, ein Kasten mit runder Signallampe, ein Monitor, Kabel - und oben
## die Fußgängerampel (grüner Pfeil / rote Hand) mit eigener Blende.
static func tower(city: Object, p: QP, _e: QP, fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var th: Dictionary = city.th
	var rim: Array = th["rim"]
	var cx := x + Py.ifloordiv(int(w), 2)
	var rust := [[96, 46, 32], [80, 44, 36], [70, 56, 46], [90, 62, 40]]
	var rc := func() -> Array: return mul(rng.choice(rust), rng.uniform(0.75, 1.0))
	# Sockel: dick, mit Rippen und Aufkleber-Streifen
	var pw := rng.randint(12, 15)
	var ph := rng.randint(34, 42)
	var px := cx - Py.ifloordiv(pw, 2)
	var col := mul([44, 30, 26], rng.uniform(0.8, 1.1))
	p.fill_rect(px, base - ph, pw, ph, qc(col))
	for xx in range(int(px + 1), int(px + pw - 1), 2):
		p.fill_rect(xx, base - ph + 2, 1, ph - 3, qc(mul(col, 0.6)))
	p.fill_rect(px, base - ph, 1, ph, qc(mul(rim, 0.35)))
	for _i in rng.randint(2, 4):                    # Aufkleber mit Schriftzeichen
		var sx := px + rng.randint(1, pw - 3)
		var sy := base - rng.randint(6, ph - 4)
		var sc: Array = rng.choice([[170, 40, 40], [190, 180, 160], [200, 170, 60]])
		for j in rng.randint(3, 8):
			if rng.random() < 0.7:
				p.fill_rect(sx, sy - j, rng.choice([1, 2]), 1, qc(mul(sc, 0.75)))
	p.fill_rect(px - 2, base - 3, pw + 4, 3, qc([24, 22, 22]))
	# unterer Kasten links am Sockel
	var lb := [px - rng.randint(10, 13), base - ph + rng.randint(8, 14), rng.randint(10, 13), rng.randint(12, 15)]
	_hood_box(p, lb[0], lb[1], lb[2], lb[3], rc.call(), -1, false)
	p.fill_rect(lb[0] + 2, lb[1] + 3, lb[2] - 4, 1, qc([20, 18, 18]))
	# mittlere Ebene: links Blendenkasten, Mitte Kasten mit runder Lampe, rechts Blendenkasten
	var my := base - ph - rng.randint(1, 3)
	var cbw := rng.randint(11, 13)
	var cbh := rng.randint(10, 12)
	var cbx := cx - Py.ifloordiv(cbw, 2)
	var cc: Array = rc.call()
	_hood_box(p, cbx, my - cbh, cbw, cbh, cc, 1, false)
	p.set_no_pen()
	p.set_brush(qc(mul(cc, 0.6)))
	p.draw_ellipse(cx - 3.5, my - cbh + 2.5, 7, 7)
	var lamp_c: Array = rng.choice([RED, AMBER])
	(city.blinks as Array).append(["fac", fac.lmin + cx, my - cbh + 6, lamp_c, rng.random() * 3])
	for _i in 2:                                     # rote Pinselzeichen
		p.fill_rect(cbx + rng.randint(1, cbw - 2), my - rng.randint(2, cbh - 1), 1, 2, qc([150, 40, 36]))
	var bw_l := rng.randint(11, 14)
	var bh_l := rng.randint(9, 12)
	_hood_box(p, cbx - bw_l, my - bh_l - rng.randint(2, 5), bw_l, bh_l, rc.call(), -1)
	var bw_r := rng.randint(11, 14)
	var bh_r := rng.randint(9, 12)
	var ry := my - bh_r - rng.randint(0, 3)
	_hood_box(p, cbx + cbw, ry, bw_r, bh_r, rc.call(), 1)
	for bxy: Array in [[cbx + cbw + 3, ry + 3], [cbx + cbw + 6, ry + 3]]:   # Schraubdeckel
		p.fill_rect(bxy[0], bxy[1], 2, 2, qc([24, 20, 18]))
	# Mast + Fußgängerampel
	var top := my - cbh - rng.randint(12, 18)
	p.fill_rect(cx - 1, top, 3, my - cbh - top, qc([30, 28, 28]))
	var sw_ := 19
	var sh_ := 11
	var sx2 := cx - 7
	var sy2 := top - sh_
	p.fill_rect(sx2 - 1, sy2 - 1, sw_ + 2, sh_ + 2, qc([30, 24, 22]))
	(city.walks as Array).append([fac.lmin + sx2 + 1, sy2 + 1, rng.uniform(0, 8), 8])
	_hood_box(p, sx2 + sw_ + 1, sy2 - 1, rng.randint(8, 11), sh_ + 2, rc.call(), 1)
	p.fill_rect(sx2 - 1, sy2 + sh_ + 1, sw_ + 2, 2, qc([22, 20, 20]))
	# Monitor in einem der Kästen
	if rng.random() < 0.6:
		var mx: float = lb[0] + 2
		var my2: float = lb[1] + 5
		p.fill_rect(mx - 1, my2 - 1, lb[2] - 2, 7, qc([18, 18, 22]))
		(city.tvs as Array).append([mx, my2, lb[2] - 4, 5, rng.randint(0, 999)])
	# Kabel hängen herab
	for _i in rng.randint(3, 5):
		var x0 := cx + rng.randint(-12, 14)
		var y0 := my - rng.randint(2, 14)
		_wire(p, x0, y0, cx + rng.randint(-10, 10), base - rng.randint(0, 6), rng.uniform(2, 6), [14, 12, 12], 235)


# ============================================================================ Verfall

## Müllberg: Papier, Säcke, Kisten, Reifen, Paletten.
static func trash(city: Object, p: QP, _e: QP, _fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var th: Dictionary = city.th
	var items := []
	for _i in int(w * rng.uniform(1.0, 1.5)):
		var u := rng.random()
		var hx := rng.uniform(0, w)
		# Haufen: in der Mitte höher
		var hmax := 3 + minf(20, w * 0.36) * pow(sin(PI * hx / w), 1.5)
		var hy := rng.uniform(0, hmax)
		items.append([hy, u, x + hx, base - hy])
	# oben zuerst, vorne zuletzt (stabil wie Python sort)
	City._stable_sort(items, func(it: Array) -> float: return -float(it[0]))
	for it: Array in items:
		var u: float = it[1]
		var ix: float = it[2]
		var iy: float = it[3]
		if u < 0.35:      # Säcke
			var c := mul(rng.choice([[30, 32, 34], [40, 44, 40], [26, 30, 40]]), rng.uniform(0.8, 1.2))
			var r := rng.uniform(2.5, 4.5)
			p.set_no_pen()
			p.set_brush(qc(c))
			p.draw_ellipse(ix - r, iy - r * 1.4, r * 2, r * 1.6)
			p.fill_rect(int(ix - r * 0.4), int(iy - r * 1.3), 1, 1, qc(mul(c, 2.0)))
		elif u < 0.7:     # Papier, Zeitungen
			var c := mul(rng.choice([[180, 176, 160], [150, 154, 150], [120, 110, 90], [170, 120, 90]]),
				rng.uniform(0.5, 0.85))
			var ww := rng.randint(2, 5)
			var hh := rng.randint(1, 3)
			_poly(p, [[ix, iy - hh], [ix + ww, iy - hh - rng.uniform(-1, 1)], [ix + ww + 1, iy], [ix - 1, iy]], c)
		elif u < 0.82:    # Kiste
			var c := mul([90, 70, 46], rng.uniform(0.5, 0.8))
			var s := rng.randint(4, 6)
			p.fill_rect(int(ix), int(iy - s), s, s, qc(c))
			p.fill_rect(int(ix), int(iy - s), s, 1, qc(mul(c, 1.4)))
		elif u < 0.92:    # Reifen
			p.set_no_brush()
			p.set_pen(qc([16, 16, 18]), 2.0)
			p.draw_ellipse(ix - 3, iy - 6, 6, 6)
			p.set_no_pen()
		else:             # Palette, schräg angelehnt
			var c := mul([110, 92, 64], 0.5)
			for k in 4:
				p.fill_rect(int(ix + k * 2), int(iy - 7 + k), 1, 7 - k, qc(c))
	# nasser Glanz obenauf (Neon)
	for _i in int(w / 6.0):
		p.fill_rect(x + rng.uniform(2, w - 2), base - rng.uniform(2, 10), 1, 1,
			qc(mul(rng.choice(th["neon"]), 0.5), 180))


## Ausgeschlachtetes Wrack einer 60er-Limousine: aufgebockt, ohne Räder, Rost,
## zerbrochene Scheiben, Kabelgedärm aus dem Motorraum.
static func wreck(_city: Object, p: QP, _e: QP, _fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var paint := mul(rng.choice([[70, 92, 96], [100, 80, 56], [62, 66, 84], [112, 92, 72], [88, 50, 44]]),
		rng.uniform(0.45, 0.65))
	var k := w / 50.0
	var flip := rng.random() < 0.5
	var tilt := rng.uniform(-1.5, 1.5)
	var lift := rng.randint(0, 2)
	var P := func(px: float, py: float) -> Vector2:
		var xx := (50 - px) if flip else px
		return Vector2(x + xx * k, base - lift + py * k + tilt * (px / 50.0 - 0.5))
	# Blöcke statt Räder
	for bpx: float in [8.0, 40.0]:
		var b: Vector2 = P.call(bpx, -2)
		p.fill_rect(int(b.x) - 2, int(b.y), 5, base - int(b.y), qc([40, 38, 36]))
	var body := []
	for pt: Array in _CLASSIC:
		body.append(P.call(float(pt[0]), float(pt[1])))
	_poly(p, body, paint)
	# Unterkante dunkel, Chromleiste
	_poly(p, [P.call(1, -5), P.call(49, -5), P.call(49, -3), P.call(1, -3)], mul(paint, 0.5))
	var a: Vector2 = P.call(2, -6.2)
	var b2: Vector2 = P.call(48, -6.6)
	p.fill_rect(minf(a.x, b2.x), a.y, absf(b2.x - a.x), 1, qc([110, 112, 110], 160))
	# Fenster: dunkel, zersplittert
	_poly(p, [P.call(19, -12.6), P.call(30.5, -12.8), P.call(34.5, -9.2), P.call(15, -9.0)], [10, 12, 14])
	for _i in 3:
		var s: Vector2 = P.call(rng.uniform(17, 32), rng.uniform(-12, -9.5))
		p.fill_rect(int(s.x), int(s.y), 1, rng.randint(1, 2), qc([150, 170, 170], 150))
	# Rostflecken
	for _i in rng.randint(4, 8):
		var s: Vector2 = P.call(rng.uniform(2, 48), rng.uniform(-8, -4))
		p.fill_rect(int(s.x), int(s.y), rng.randint(1, 4), rng.randint(1, 2), qc(mul(SODIUM, rng.uniform(0.45, 0.8))))
	# offene Haube, Kabel quellen heraus
	var h1: Vector2 = P.call(46, -8.4)
	var h2: Vector2 = P.call(36, -9.0)
	_poly(p, [h2, h1, Vector2(h1.x + (-3 if flip else 3), h1.y - 7 * k)], mul(paint, 0.8))
	for _i in rng.randint(3, 6):
		var ex := h1.x + rng.uniform(-6, 6) * k
		_wire(p, (h1.x + h2.x) / 2, h1.y - 1, ex, base - rng.randint(0, 3), rng.uniform(1, 3),
			rng.choice([[30, 30, 32], [90, 40, 30], [60, 70, 50]]), 230)
	# zertrümmerte Scheinwerfer
	var l: Vector2 = P.call(49, -7)
	p.fill_rect(int(l.x) - 1, int(l.y), 2, 2, qc([60, 62, 60]))


## Feuertonne: rostiges Fass, oben die (lebende) Flamme.
static func barrel(city: Object, p: QP, e: QP, fac: Object, rng: PyRandom, x: float, base: float, _w: float) -> void:
	var c := mul([70, 44, 32], rng.uniform(0.7, 1.0))
	p.fill_rect(x + 1, base - 11, 7, 11, qc(c))
	for yy: float in [base - 9, base - 4]:
		p.fill_rect(x + 1, yy, 7, 1, qc(mul(c, 1.4)))
	p.fill_rect(x + 1, base - 11, 7, 1, qc(mul(AMBER, 0.6)))
	p.fill_rect(x + 1, base - 11, 1, 11, qc(mul(AMBER, 0.35)))
	e.fill_rect(x + 1, base - 11, 7, 1, qc(mul(AMBER, 0.5)))
	(city.fires as Array).append([fac.lmin + x + 4.5, base - 11, rng.uniform(0.8, 1.2), rng.randint(0, 9999)])


## Gelber Pollerkasten mit roter/grüner Lampe obenauf (Chinatown).
static func bollard(city: Object, p: QP, _e: QP, fac: Object, rng: PyRandom, x: float, base: float, _w: float) -> void:
	var c := mul([176, 150, 60], rng.uniform(0.5, 0.7))
	p.fill_rect(x + 1, base - 12, 6, 12, qc(c))
	p.fill_rect(x + 1, base - 12, 6, 1, qc(mul(c, 1.4)))
	p.fill_rect(x + 6, base - 12, 1, 12, qc(mul(c, 0.6)))
	p.fill_rect(x + 2, base - 8, 4, 2, qc([30, 28, 24]))
	var col: Array = rng.choice([RED, RED, GREEN])
	(city.blinks as Array).append(["fac", fac.lmin + x + 4, base - 14, col, rng.random() * 3])
	p.fill_rect(x + 3, base - 14, 2, 2, qc(mul(col, 0.4)))


## Zwei, drei Blechmülltonnen, manche mit schiefem Deckel, Müll daneben.
static func bins(city: Object, p: QP, _e: QP, _fac: Object, rng: PyRandom, x: float, base: float, w: float) -> void:
	var th: Dictionary = city.th
	var n := maxi(2, Py.ifloordiv(int(w), 8))
	var xx := x
	for _i in n:
		var c := mul(rng.choice([[70, 74, 72], [58, 66, 70], [76, 70, 60], [60, 56, 50]]), rng.uniform(0.6, 0.9))
		var h := rng.randint(8, 10)
		p.fill_rect(xx, base - h, 6, h, qc(c))
		for yy in range(int(base - h + 2), int(base), 3):
			p.fill_rect(xx, yy, 6, 1, qc(mul(c, 1.3)))
		p.fill_rect(xx + 5, base - h, 1, h, qc(mul(c, 0.55)))
		p.fill_rect(xx, base - h, 1, h, qc(mul(th["rim"], 0.35)))
		if rng.random() < 0.5:
			_poly(p, [[xx - 1, base - h], [xx + 7, base - h - 2], [xx + 7, base - h - 1], [xx - 1, base - h + 1]],
				mul(c, 1.15))
		else:
			for _k in 3:
				p.fill_rect(xx + rng.randint(0, 4), base - h - rng.randint(1, 2), 2, 1,
					qc(mul(rng.choice([[170, 166, 150], [120, 108, 88], [40, 40, 44]]), 0.7)))
		xx += 7 + rng.randint(0, 2)
	for _k in rng.randint(1, 4):
		p.fill_rect(x + rng.uniform(-3, w), base - 1, rng.randint(2, 3), 1,
			qc(mul([160, 156, 140], rng.uniform(0.4, 0.7))))


## J. F. Sebastians Haus (Bradbury) am Ende der letzten Zone: alter Backsteinbau mit
## Rundbogenfenstern, Gesims, vergittertem Bogeneingang - und davor die dicken,
## gedrehten Ornament-Säulen. Hier steht ROY.
static func sebastian(city: City, p: QP, e: QP, fac: City.Layer, base: int) -> void:
	var rx := int((city.length - Config.ROY_STAND) * fac.factor) - fac.lmin     # Eingang = ROYs Platz
	var x1 := city.exit_L - 62
	var x0 := x1 - 240
	var top := 12
	city.sebastian_span = [x0 - 4, x1 + 4]
	var L0 := fac.lmin + x0
	var L1 := fac.lmin + x1
	var inside := func(L: float, ww: float = 0.0) -> bool: return L + ww > L0 and L < L1
	city.signs = city.signs.filter(func(s: City.Sign) -> bool: return not inside.call(s.L, s.w))
	city.tvs = city.tvs.filter(func(v: Array) -> bool: return not inside.call(float(v[0]) + fac.lmin, float(v[2])))
	city.lanterns = city.lanterns.filter(func(v: Array) -> bool: return not inside.call(float(v[0])))
	city.blinks = city.blinks.filter(func(b: Array) -> bool: return b[0] != "fac" or not inside.call(float(b[1])))
	city.vents = city.vents.filter(func(v: Array) -> bool: return not inside.call(float(v[0])))
	city.lamps = city.lamps.filter(func(lp: City.Lamp) -> bool: return not inside.call(lp.L - 20, 40))
	city.fires = city.fires.filter(func(f: Array) -> bool: return not inside.call(float(f[0])))
	city.walks = city.walks.filter(func(w_: Array) -> bool: return not inside.call(float(w_[0]), 14))
	e.set_mode(QP.CLEAR)
	e.fill_rect(x0, 0, x1 - x0, base + 1, Color(0, 0, 0, 0))
	e.set_mode(QP.OVER)
	var rng := PyRandom.new(city.seed_ * 17 + 1982)
	var w := x1 - x0
	var brick := [66, 40, 34]
	var stone := [104, 90, 74]
	var g := QGrad.linear(0, top, 0, base)
	g.set_color_at(0.0, qc(mul(brick, 0.45)))
	g.set_color_at(1.0, qc(brick))
	p.fill_rect(x0, top, w, base - top, g)
	# Mauerwerk
	var i := 0
	for y in range(top + 2, base, 3):
		p.fill_rect(x0, y, w, 1, qc(mul(brick, 0.62), 150))
		for x in range(x0 + (3 if i % 2 else 0), x1, 6):
			p.fill_rect(x, y - 2, 1, 2, qc(mul(brick, 0.7), 110))
		i += 1
	# Kranzgesims mit Zahnschnitt, Ecklisenen
	p.fill_rect(x0 - 3, top - 4, w + 6, 6, qc(mul(stone, 0.8)))
	p.fill_rect(x0 - 3, top - 4, w + 6, 1, qc(stone))
	for x in range(x0 - 2, x1 + 2, 3):
		p.fill_rect(x, top + 2, 1, 3, qc(mul(brick, 0.4)))
	for x: int in [x0, x1 - 5]:
		p.fill_rect(x, top, 5, base - top, qc(mul(stone, 0.55)))
		p.fill_rect(x, top, 1, base - top, qc(mul(stone, 0.8)))
	# Rundbogenfenster, vier Geschosse
	var ground := base - 46
	var seb := [rng.randint(0, 3), rng.randint(2, 8)]          # Sebastians Fenster: Licht, Spielzeug
	for row in 4:
		var y := top + 12 + row * 24
		if y + 16 > ground:
			break
		p.fill_rect(x0 + 4, y + 19, w - 8, 2, qc(mul(stone, 0.6)))         # Gurtgesims
		var col := 0
		for x in range(x0 + 12, x1 - 12, 14):
			var lit: bool = row == int(seb[0]) and col == int(seb[1])
			var dim := rng.random() < 0.12
			var c: Array = mul([255, 170, 90], 0.55) if lit else (mul([255, 160, 80], 0.18) if dim else [12, 10, 12])
			p.set_no_pen()
			p.set_brush(qc(mul(stone, 0.7)))
			p.draw_ellipse(x - 1, y - 1, 10, 8)
			p.fill_rect(x - 1, y + 3, 10, 14, qc(mul(stone, 0.7)))
			var qs: Array = [[p, 1.0], [e, 0.6]] if lit else [[p, 1.0]]
			for qk: Array in qs:
				var q: QP = qk[0]
				q.set_no_pen()
				q.set_brush(qc(mul(c, qk[1])))
				q.draw_ellipse(x, y, 8, 7)
				q.fill_rect(x, y + 3, 8, 13, qc(mul(c, qk[1])))
			p.fill_rect(x + 4, y + 2, 1, 14, qc(mul(stone, 0.45)))      # Sprosse
			if lit:                                       # Spielzeugsilhouetten im Fenster
				p.fill_rect(x + 1, y + 10, 2, 5, qc([40, 24, 20]))
				p.fill_rect(x + 1, y + 9, 2, 1, qc([40, 24, 20]))
				p.fill_rect(x + 5, y + 12, 2, 3, qc([40, 24, 20]))
				p.fill_rect(x + 5, y + 10, 1, 2, qc([40, 24, 20]))
			elif not dim and rng.random() < 0.2:          # zerbrochen
				p.fill_rect(x + 2, y + 6, 3, 1, qc([70, 80, 84], 160))
			col += 1
	# Steinband über dem Erdgeschoss mit eingemeißeltem Namen
	p.fill_rect(x0, ground - 6, w, 6, qc(mul(stone, 0.85)))
	p.fill_rect(x0, ground - 6, w, 1, qc(stone))
	var word := "BRADBURY"
	var tw := Pixfont.text_width(word)
	Pixfont.draw(p, rx - Py.ifloordiv(tw, 2), ground - 5, word, mul(stone, 0.5), 1, null)
	p.set_no_pen()
	# Erdgeschoss: vernagelte Schaufenster, Bogeneingang mit Gitter
	p.fill_rect(x0, ground, w, base - ground, qc(mul(brick, 0.7)))
	var xs := []
	for x in range(x0 + 8, rx - 26, 30):
		xs.append(x)
	for x in range(rx + 26, x1 - 20, 30):
		xs.append(x)
	for x: int in xs:
		p.fill_rect(x, ground + 8, 22, 30, qc([24, 20, 18]))
		for k in 4:
			var y := ground + 10 + k * 7 + rng.randint(-1, 1)
			p.fill_rect(x - 1, y, 24, 3, qc(mul([92, 70, 50], rng.uniform(0.5, 0.8))))
	var aw := 32
	var ax := rx - Py.ifloordiv(aw, 2)
	p.set_brush(qc(mul(stone, 0.75)))
	p.draw_ellipse(ax - 3, ground - 2, aw + 6, 22)
	p.fill_rect(ax - 3, ground + 9, aw + 6, base - ground - 9, qc(mul(stone, 0.75)))
	var gi := QGrad.linear(0, ground, 0, base)
	gi.set_color_at(0, qc([40, 24, 16]))
	gi.set_color_at(1, qc([120, 70, 34]))
	for q: QP in [p, e]:
		q.set_no_pen()
		var br: Variant = gi if q == p else qc([120, 70, 34], 90)
		q.set_brush(br)
		q.draw_ellipse(ax, ground + 1, aw, 18)
		q.fill_rect(ax, ground + 10, aw, base - ground - 10, br)
	for x in range(ax + 2, ax + aw, 3):                       # schmiedeeisernes Gitter
		p.fill_rect(x, ground + 4, 1, base - ground - 4, qc([16, 12, 10]))
	p.fill_rect(ax, ground + 16, aw, 1, qc([16, 12, 10]))
	# Wandleuchten neben dem Eingang
	for x: int in [ax - 8, ax + aw + 5]:
		for q: QP in [p, e]:
			q.fill_rect(x, ground + 6, 3, 4, qc([255, 190, 120]))
		p.fill_rect(x + 1, ground + 10, 1, 3, qc([30, 26, 22]))
	# die dicken, gedrehten Säulen davor
	var cw := 36
	for x: int in [rx - 24 - cw, rx + 24]:
		_place(city, p, e, fac, rng, "ornate", x, base, cw)
	_place(city, p, e, fac, rng, "ornate", x0 + 4, base, 32)
	_place(city, p, e, fac, rng, "ornate", x1 - 36, base, 32)
	_place(city, p, e, fac, rng, "trash", rx - 26 - cw - 40, base, 34)
	_place(city, p, e, fac, rng, "barrel", rx + 26 + cw + 8, base, 9)


## Stellvertreter für Stadt/Fassade, wenn ein Turm als eigenes Objekt gezeichnet wird:
## sammelt die lebenden Teile (Ampel, Warnlampe) relativ zum Fußpunkt.
class Collect:
	var lmin := 0
	var th: Dictionary
	var walks: Array = []
	var blinks: Array = []
	var tvs: Array = []
	var fires: Array = []

	func _init(th_: Dictionary) -> void:
		th = th_


## Ampelturm als freistehendes Objekt. scale = Pixel pro Fassaden-Pixel. Gibt
## [img, emit, ax, ay, walks, blinks] (img mit Umriss wie vehicles._outline) -
## walks/blinks in unskalierten Einheiten relativ zum Fußpunkt.
## Gecacht im Fahrzeug-Cache (gleicher Atlas, gleiche Lebensdauer).
static func tower_sprite(seed_: int, scale: float, th: Dictionary) -> Array:
	var key := ["tower", seed_, scale, th["rim"]]
	var hit: Variant = Vehicles._CACHE.get(key)
	if hit != null:
		return hit
	var rng := PyRandom.new(seed_)
	var W_ := int(76 * scale) + 4
	var H_ := int(116 * scale) + 4
	var ax := Py.ifloordiv(W_, 2)
	var ay := H_ - 2
	var col := Collect.new(th)
	var res := Vehicles._bake(W_, H_, ax, ay, scale, func(p: QP, e: QP) -> void:
		var wr: Array = WIDTH["tower"]
		var w := rng.randint(wr[0], wr[1])
		tower(col, p, e, col, rng, Py.ifloordiv(-w, 2), 0, w))
	if res.is_empty():
		return []
	var out := [res[0], res[1], ax, ay, col.walks, col.blinks]
	Vehicles._CACHE[key] = out
	return out


# ============================================================================ Fassaden

## Charakter eines Hauses: 'old' (verschnörkelt, nachgerüstet), 'modern' oder 'plain'.
static func facade_look(city: City, rng: PyRandom) -> String:
	var f: Array = ZONE_FACADE[Py.imod(city.zone, ZONE_FACADE.size())]
	var po: float = f[0]
	var pm: float = f[1]
	var r := rng.random()
	return "old" if r < po else ("modern" if r < po + pm else "plain")


## Alte Häuser: wärmerer, dunklerer Stein.
static func old_stone(col: Array) -> Array:
	return mix(col, [58, 46, 40], 0.45)


## Verschnörkelter Altbau: Kranzgesims mit Zahnschnitt, Pilaster, Gurtgesimse,
## Rosetten - und darüber, nachgerüstet, Kabel, Leitungen, Verteilerkästen.
static func ornament(p: QP, e: QP, rng: PyRandom, _th: Dictionary, x: float, top: float, bw: float, bh: float,
		base: float, shop_h: float, col: Array, hi: Array) -> void:
	var stone_hi := mix(hi, [120, 100, 80], 0.35)
	var dark := mul(col, 0.5)
	# Kranzgesims
	p.fill_rect(x - 2, top - 2, bw + 4, 4, qc(mul(stone_hi, 0.9)))
	p.fill_rect(x - 2, top - 2, bw + 4, 1, qc(mul(stone_hi, 1.3)))
	for k in range(int(x - 1), int(x + bw + 1), 3):
		p.fill_rect(k, top + 2, 1, 2, qc(dark))
	# Attika-Ornament
	if rng.random() < 0.6 and bw > 30:
		var cx := x + Py.ifloordiv(int(bw), 2)
		_poly(p, [[cx - 10, top - 2], [cx, top - 9], [cx + 10, top - 2]], mul(stone_hi, 0.8))
		p.fill_rect(cx - 1, top - 7, 2, 2, qc(mul(stone_hi, 1.3)))
	# Pilaster
	var n := maxi(2, Py.ifloordiv(int(bw), 26))
	for i in n + 1:
		var px := x + 1 + int(i * (bw - 4) / n)
		p.fill_rect(px, top + 4, 3, bh - shop_h - 4, qc(mul(col, 1.15)))
		p.fill_rect(px, top + 4, 1, bh - shop_h - 4, qc(mul(stone_hi, 0.9)))
		p.fill_rect(px - 1, top + 4, 5, 2, qc(mul(stone_hi, 1.1)))          # Kapitell
	# Gurtgesimse + Rosetten
	var yy := top + rng.randint(18, 26)
	while yy < base - shop_h - 6:
		p.fill_rect(x, yy, bw, 1, qc(mul(stone_hi, 0.75)))
		p.fill_rect(x, yy + 1, bw, 1, qc(dark))
		yy += rng.randint(22, 34)
	for k in range(int(x + 6), int(x + bw - 4), 12):
		p.fill_rect(k, top + 6, 2, 2, qc(mul(stone_hi, 1.1)))
	# --- nachgerüstet: Kabel, Rohre, Kästen (die Zukunft hängt an der Vergangenheit)
	for _i in rng.randint(2, 5):
		var x0 := x + rng.uniform(0, bw * 0.4)
		var x1 := x + rng.uniform(bw * 0.6, bw)
		var y0 := rng.uniform(top + 8, base - shop_h - 4)
		var y1 := y0 + rng.uniform(-10, 10)
		_wire(p, x0, y0, x1, y1, rng.uniform(1, 5), [12, 12, 14], 220)
	for _i in rng.randint(1, 3):
		var px := x + rng.randint(3, maxi(4, int(bw - 5)))
		p.fill_rect(px, top + 6, 2, bh - 8, qc([40, 42, 44]))
		for y2 in range(int(top + 10), int(base - 4), 12):
			p.fill_rect(px - 1, y2, 4, 1, qc([60, 62, 64]))
	for _i in rng.randint(1, 3):
		var bx := x + rng.randint(2, maxi(3, int(bw - 8)))
		var by := rng.randint(int(top + 10), maxi(int(top + 11), int(base - shop_h - 10)))
		p.fill_rect(bx, by, 6, 7, qc([50, 52, 50]))
		p.fill_rect(bx, by, 6, 1, qc([86, 88, 86]))
		if rng.random() < 0.5:
			var c: Array = rng.choice([GREEN, RED, AMBER])
			for q: QP in [p, e]:
				q.fill_rect(bx + 4, by + 2, 1, 1, qc(c))


## Hypermoderner Bau: Glasfassade mit feinen Sprossen, ganze Etagen hell, Lichtband an
## der Kante. Glatt, ohne Feuerleiter und Klimakästen.
static func modern(p: QP, e: QP, rng: PyRandom, th: Dictionary, x: float, top: float, bw: float, bh: float,
		base: float, shop_h: float, col: Array, _hi: Array) -> void:
	var glass_top := mul(mix(col, [20, 40, 54], 0.6), 0.9)
	var glass_bot := mix(col, [40, 70, 84], 0.5)
	var g := QGrad.linear(0, top, 0, base - shop_h)
	g.set_color_at(0.0, qc(glass_top))
	g.set_color_at(1.0, qc(glass_bot))
	p.fill_rect(x + 2, top + 3, bw - 4, bh - shop_h - 3, g)
	var fh: int = rng.choice([6, 7, 8])
	var lit_floor := mix(PALE, rng.choice([CYAN, AMBER, PALE]), 0.3)
	var yy := top + 4
	while yy < base - shop_h - 2:
		p.fill_rect(x + 2, yy, bw - 4, 1, qc(mul(glass_top, 0.6)))
		if rng.random() < float(th["lit"]) * 0.9:
			var c := mul(lit_floor, rng.uniform(0.35, 0.6))
			p.fill_rect(x + 3, yy + 1, bw - 6, fh - 2, qc(c))
			e.fill_rect(x + 3, yy + 1, bw - 6, fh - 2, qc(mul(c, 0.4)))
		yy += fh
	for k in range(int(x + 4), int(x + bw - 2), rng.choice([4, 5, 6])):
		p.fill_rect(k, top + 3, 1, bh - shop_h - 3, qc(mul(glass_top, 0.7), 200))
	# Spiegelung: diagonaler Lichtstreif
	var s := rng.uniform(0, bw)
	_poly(p, [[x + s, top + 3], [x + s + 6, top + 3], [x + s - 14, base - shop_h], [x + s - 20, base - shop_h]],
		mix(glass_bot, PALE, 0.25), 60)
	# Lichtband
	var c2: Array = rng.choice([CYAN, GREEN, NBLUE, PALE])
	for qk: Array in [[p, 0.85], [e, 0.8]]:
		var q: QP = qk[0]
		var k: float = qk[1]
		q.fill_rect(x + 1, top + 1, bw - 2, 1, qc(mul(c2, k)))
		if rng.random() < 0.5:
			q.fill_rect(x + 1, top + 1, 1, bh - shop_h, qc(mul(c2, k * 0.7)))
