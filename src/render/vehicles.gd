class_name Vehicles
extends RefCounted
## Port von render/vehicles.py: Bodenfahrzeuge und Straßen-Hindernisse als gecachte
## Pixelbilder (Seitenansicht).
##
## Gezeichnet in Design-Einheiten (Boden bei y = 0, Fahrtrichtung +x) direkt in
## Zielgröße. Jedes Bild kommt mit einer Leuchtschicht (emit) für den Glow-Pass.
## Lebende Teile (Blaulicht, Feuer, Lichtkegel) zeichnet die Szene.
##
## Benutzung (Vehicles.baker und Pixfont.baker einmal setzen; Baker VOR der Szene):
##   spinner_image(ppx, police, d, far) -> [img, emit, ax, ay_mitte: float, ay_boden: int]
##   vehicle_image(kind, seed, ppu, rim, d) -> [img, emit, ax, ay, length_px: float]
##   obstacle_image(kind, seed, ppu, rim)  -> [img, emit, ax, ay]
##   headlight(p, x, y, d, ppu, gy, length, col, a)   (zeichnet direkt)
## img/emit sind QImg (Atlas-Ausschnitte, bei d < 0 gespiegelt), ax/ay = Anker im Bild.
## Cache = ExactCache (Atlas-Paare, Umriss per Shader); Rasterregeln wie Qt (QPExact).

const C := DVehicles.C
const CYAN := DVehicles.CYAN
const MAGENTA := DVehicles.MAGENTA
const AMBER := DVehicles.AMBER
const VIOLET := DVehicles.VIOLET
const TEAL := DVehicles.TEAL
const PALE := DVehicles.PALE
const WHITE := DVehicles.WHITE
const CRIMSON := DVehicles.CRIMSON
const VEH_SCALE := DVehicles.VEH_SCALE
const BODY := DVehicles.BODY
const UNDERGLOW := DVehicles.UNDERGLOW
const ACCENT := DVehicles.ACCENT
const LIVERY := DVehicles.LIVERY
const BUS_OP := DVehicles.BUS_OP
const BUS_ROUTE := DVehicles.BUS_ROUTE
const TAXI_SIGN := DVehicles.TAXI_SIGN
const VARIANTS := DVehicles.VARIANTS
const HEAD := DVehicles.HEAD
const TAIL := DVehicles.TAIL
const WIN := DVehicles.WIN
const CHROME := DVehicles.CHROME
const SPIN_L := DVehicles.SPIN_L
const SPIN_BAR := DVehicles.SPIN_BAR
const SPIN_NOSE := DVehicles.SPIN_NOSE
const SPIN_TAIL := DVehicles.SPIN_TAIL

## Vom Spiel zu setzen.
static var baker: Baker
static var atlas_size := 2048
static var _CACHE := {}
static var _cache_obj: ExactCache


static func _q(c: Array, a: float = 255.0) -> Color:
	return QP.c(int(c[0]), int(c[1]), int(c[2]), a)


## Helligkeit leicht streuen (k = -3..3), damit gleiche Palettenfarben nicht gleich wirken.
static func _tint(c: Array, k: int) -> Array:
	return _mul(c, 1.0 + 0.10 * k)


static func _mul(c: Array, f: float) -> Array:
	return [maxi(0, mini(255, int(float(c[0]) * f))), maxi(0, mini(255, int(float(c[1]) * f))),
		maxi(0, mini(255, int(float(c[2]) * f)))]


static func _pa(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in pts:
		out.append(Vector2(float(q[0]), float(q[1])))
	return out


static func _poly(p: QP, pts: Array, col: Array, a: float = 255.0) -> void:
	p.set_no_pen()
	p.set_brush(_q(col, a))
	p.draw_polygon(_pa(pts))


static func _rect(p: QP, x: float, y: float, w: float, h: float, col: Array, a: float = 255.0) -> void:
	p.fill_rect(x, y, w, h, _q(col, a))


static func _ell(p: QP, x: float, y: float, w: float, h: float, col: Array, a: float = 255.0) -> void:
	p.set_no_pen()
	p.set_brush(_q(col, a))
	p.draw_ellipse(x, y, w, h)


static func _line(p: QP, x0: float, y0: float, x1: float, y1: float, col: Array, wd: float = 0.6) -> void:
	p.set_pen(_q(col), wd)        # QPen-Standard: SquareCap
	p.draw_line(x0, y0, x1, y1)
	p.set_no_pen()


static func _wheel(p: QP, x: float, r: float, skirt: Variant = null, cover: Variant = null) -> void:
	p.set_no_pen()
	p.set_brush(_q([8, 8, 12]))
	p.draw_ellipse(x - r, -2 * r, 2 * r, 2 * r)
	if cover != null:     # Radkappe/Scheibe (Mead: geschlossene Räder)
		p.set_brush(_q(cover))
		p.draw_ellipse(x - r * 0.72, -r * 1.72, r * 1.44, r * 1.44)
		p.set_brush(_q(_mul(cover, 1.5)))
		p.draw_ellipse(x - r * 0.2, -r * 1.2, r * 0.4, r * 0.4)
	else:
		p.set_brush(_q([60, 62, 72]))
		p.draw_ellipse(x - r * 0.45, -r * 1.45, r * 0.9, r * 0.9)
	if skirt != null:
		_rect(p, x - r - 0.5, -2 * r - 0.5, 2 * r + 1, r * 1.15, skirt)
		_rect(p, x - r - 0.5, -r * 0.85 - 0.5, 2 * r + 1, 0.5, _mul(skirt, 0.5))


## Schriftzug auf der Karosserie (wird bei d < 0 vorgespiegelt, weil das
## ganze Bild danach gespiegelt wird).
static func _stencil(p: QP, word: String, x: float, y: float, width: float, col: Array, d: int,
		max_sc: float = 1.0) -> void:
	var img := Pixfont.render(word, col, 1, null)
	if img == null:
		return
	var sc := minf(max_sc, width / maxi(1, img.width()))
	var tot := absf(p.transform().x.x)
	if tot == 0.0:
		tot = 1.0     # auf ganze Bildpunkte schnappen: scharfe Schrift
	if sc * tot >= 0.75:
		sc = maxi(1, Py.round(sc * tot)) / tot
	p.save()
	if d < 0:
		p.translate(x + img.width() * sc, y)
		p.scale(-sc, sc)
	else:
		p.translate(x, y)
		p.scale(sc, sc)
	p.draw_image_at(0, 0, img)
	p.restore()


static func _lamps(p: QP, e: QP, xs: Array, y: float, w: float, h: float, col: Array) -> void:
	for q: QP in [p, e]:
		for x: Variant in xs:
			_rect(q, float(x), y, w, h, col)


# ---------------------------------------------------------------------------- Spinner

## Spinner nach Syd Mead: geschlossenes Lift-Fahrzeug mit Kapsel-Kanzel über dem
## vorderen Viertel, zwei kugeligen Radgondeln vor dem Bug, verdecktem Heck.
static func _draw_spinner(p: QP, e: QP, police: bool, rnd: int, rim: Array, d: int = 1, detail: bool = true) -> void:
	var body: Array = [70, 82, 104] if police else ([[44, 50, 62], [58, 44, 54], [40, 60, 66]][rnd % 3] as Array)
	var dark := _mul(body, 0.5)
	var hi := _mul(body, 1.5)
	var glow: Array = TAIL if police else UNDERGLOW[(rnd >> 8) % UNDERGLOW.size()]
	# Unterboden-Glühen (Polizei rot) + Turbinenauslässe
	for q: QP in [p, e]:
		_rect(q, -25, -3.4, 42, 1.0, glow)
		_rect(q, -27, -5.0, 3.0, 1.2, _mul(AMBER, 0.8))
	# verdecktes Hinterrad (nur ein Schlitz)
	_rect(p, -24, -4.2, 12, 1.4, [8, 8, 12])
	# Rumpf: hohes Heck mit Turbinendeck, Dach fällt zur Kanzel, Bug taucht ab
	var hull := [[-31, -4.6], [-31.4, -12.8], [-29.5, -15.6], [-9, -16.6], [-4, -16.8], [16, -13.4], [23, -10.6],
		[27.2, -8.8], [27.6, -6.2], [22, -4.4], [-29, -3.6]]
	_poly(p, hull, body)
	# dunkle Seitenschürze
	_poly(p, [[-31, -8.2], [21, -8.2], [23.5, -5.6], [22, -4.4], [-29, -3.6], [-31, -4.6]], _mul(body, 0.62))
	# Kanzel (Kapsel über dem vorderen Viertel)
	var can := [[-7, -16.6], [-1, -20.6], [8, -20.6], [15.5, -15.6], [22.4, -10.8], [12, -11.4], [-5, -12.8]]
	_poly(p, can, WIN)
	_line(p, -0.5, -20.2, 8, -20.2, _mul(rim, 0.95), 0.8)
	_line(p, 9, -19.6, 15.5, -15.0, _mul(rim, 0.7), 0.6)
	_line(p, 4.5, -20.4, 9.5, -11.6, _mul(body, 0.9), 0.9)        # Mittelstrebe
	_ell(p, 0.5, -18.6, 3.2, 3.4, [12, 14, 22])                     # Pilot
	for q: QP in [p, e]:
		_rect(q, 6.5, -14.4, 3.0, 0.8, _mul(CYAN, 0.6))           # HUD-Schimmer im Glas
	# Turbinen-Lamellen am Heck + Kantenlicht
	for i in 6:
		_rect(p, -28 + i * 2.4, -14.4, 1.2, 3.8, dark)
	_rect(p, -29, -15.8, 21, 0.8, _mul(rim, 0.85))
	_rect(p, -31, -8.6, 52, 0.6, hi)
	# Radgondel vorn (kugelig, ragt vor den Bug)
	_rect(p, 17, -7.2, 7, 2.2, dark)
	_ell(p, 20.2, -9.4, 9.2, 9.0, _mul(body, 0.8))
	_ell(p, 21.0, -5.4, 7.6, 5.4, [8, 8, 12])
	_ell(p, 22.6, -8.6, 3.6, 2.0, _mul(rim, 0.6))
	# Lichtbalken + Mittelscheinwerfer (live: Szene)
	var bx: float = SPIN_BAR[0]
	var by: float = SPIN_BAR[1]
	var bw: float = SPIN_BAR[2]
	var bh: float = SPIN_BAR[3]
	if police:
		_rect(p, bx, by, bw, bh, [20, 20, 30])
		_rect(p, bx + 3.5, by - 1.2, 3, 1.2, [30, 30, 40])
	var nx: float = SPIN_NOSE[0]
	for q: QP in [p, e]:
		_rect(q, nx - 1.2, -9.4, 1.4, 1.2, HEAD)            # überbaute Lichtleiste
		_rect(q, nx - 1.6, -7.8, 1.6, 0.9, HEAD)
		_rect(q, 24.5, -11.2, 1.4, 0.8, AMBER)
		_rect(q, -31.6, -12.0, 1.0, 3.2, TAIL)
		_rect(q, -31.6, -7.4, 1.0, 1.2, TAIL)
	if police and detail:
		_stencil(p, "POLICE", -26.5, -12.4, 15.0, [226, 230, 236], d, 0.5)
		_stencil(p, "44", 2.0, -7.6, 4.0, [226, 230, 236], d, 0.45)
		for i in 5:                                              # Warnstreifen
			_poly(p, [[8 + i * 2, -5.0], [9 + i * 2, -7.6], [10 + i * 2, -7.6], [9 + i * 2, -5.0]],
				[220, 180, 40] if i % 2 == 0 else [14, 14, 18])
		for q: QP in [p, e]:
			_rect(q, -20, -4.4, 1.6, 0.9, [90, 140, 255])
			_rect(q, 10, -4.4, 1.6, 0.9, TAIL)


static func _ec() -> ExactCache:
	if _cache_obj == null:
		_cache_obj = ExactCache.new(_CACHE)
		_cache_obj.atlas_size = atlas_size
	_cache_obj.ensure(baker)
	_cache_obj.settle()
	return _cache_obj


## Gemeinsamer Ablauf: zwei rohe Bilder (img, emit) w x hh, Ursprung (ax, ay), Skala sc;
## draw(p, e) zeichnet; danach Umriss (+ optional Dunst f vor dem Umriss).
## Rückgabe [img, emit] oder [] bei vollem Atlas.
static func _bake(w: int, hh: int, ax: float, ay: float, sc: float, draw: Callable, haze: float = 0.0,
		haze_rgb: Array = [0, 0, 0]) -> Array:
	var ec := _ec()
	var slots := ec.alloc(w, hh, 2)
	if slots.is_empty():
		return []
	var p := ec.painter(slots[0])
	var e := ec.painter(slots[1])
	for q: QP in [p, e]:
		q.translate(ax, ay)
		q.scale(sc, sc)
	draw.call(p, e)
	var img := _outline(slots[0], slots[2], haze, haze_rgb)
	return [img, ec.raw_img(slots[1])]


## Umriss: vier um 1 px versetzte Silhouetten (4, 5, 10), dann das Bild raw[src] -> fin[dst].
## haze: SourceAtop-Dunst aufs Bild vor dem Umriss (ferne Spinner), 0 = keiner.
static func _outline(src: Rect2i, dst: Rect2i, haze: float = 0.0, haze_rgb: Array = [0, 0, 0]) -> QImg:
	var o := [4, 5, 10]
	return _ec().finish(src, dst, [[o, 255, -1, 0], [o, 255, 1, 0], [o, 255, 0, -1], [o, 255, 0, 1]],
		haze, haze_rgb, false)


## Gecachtes Spinner-Sprite. ppx = Bildpunkte pro Zeichen-Einheit.
## Rückgabe [img, emit, ax, ay_mitte, ay_boden]: Anker am Rumpfzentrum (y = -10) bzw. am Boden.
static func spinner_image(ppx: float, police: bool, d: int = 1, far: bool = false) -> Array:
	var kpx := maxf(0.25, Py.round(ppx * 8) / 8.0)
	var key := ["s", kpx, police, d, far]
	var hit: Variant = _CACHE.get(key)
	if hit != null:
		return hit
	var w := int(64 * kpx) + 8
	var hh := int(24 * kpx) + 8
	var ax := w / 2
	var ayg := hh - 3
	var ec := _ec()
	if _CACHE.size() > 600:
		ec.swap()
	var rim: Array = [150, 160, 190] if not far else [70, 76, 100]
	var res := _bake(w, hh, ax, ayg, kpx, func(p: QP, e: QP) -> void:
		_draw_spinner(p, e, police, 1 if not far else 2, rim, d, kpx >= 0.9),
		150.0 / 255.0 if far else 0.0, [16, 18, 30])      # ferne Spinner: in den Dunst getaucht
	if res.is_empty():
		return [null, null, ax, ayg - 10 * kpx, ayg]
	var img: QImg = res[0]
	var em: QImg = res[1]
	if d < 0:
		img = img.mirror()
		em = em.mirror()
		ax = w - 1 - ax
	var out := [img, em, ax, ayg - 10 * kpx, ayg]
	_CACHE[key] = out
	return out

# ---------------------------------------------------------------------------- Bodenverkehr

## Deckard-Sedan: ausgemusterter Flug-Sedan, Klappen entfernt, Lichtmuster behalten.
static func _sedan(p: QP, e: QP, body: Array, glow: Array, rim: Array, accent: Array, style: int, livery: String,
		d: int) -> void:
	for q: QP in [p, e]:
		_rect(q, -23, -2.6, 46, 1.0, glow)
	_poly(p, [[-29, -4], [-29.6, -10.6], [-27, -12.2], [-15.5, -12.8], [-11.5, -18.8], [5, -19.4], [9, -18.8],
		[15, -13.0], [26, -11.8], [29.2, -9.8], [29.6, -5.2], [27, -3.6], [-27, -3.6]], body)
	_poly(p, [[-13, -13.0], [-10.2, -18.0], [4.6, -18.5], [8.2, -17.8], [13.2, -13.0]], WIN)
	_rect(p, -2.4, -18.4, 1.3, 5.6, body)                                # B-Säule
	_line(p, 12.6, -13.4, 9.6, -16.6, [12, 12, 16], 0.5)                # überbaute Wischer
	_line(p, 8.4, -13.4, 5.6, -16.4, [12, 12, 16], 0.5)
	_rect(p, -10.6, -18.9, 15.4, 0.7, _mul(rim, 0.9))
	_rect(p, -28, -12.4, 13, 0.7, _mul(rim, 0.7))
	_rect(p, 14, -12.0, 12, 0.6, _mul(rim, 0.6))
	# Gullwing-Fuge + entfernte Luftleitklappen (Vertiefungen)
	_rect(p, -12.6, -12.6, 0.5, 7.6, _mul(body, 0.45))
	_rect(p, 6.4, -12.6, 0.5, 7.6, _mul(body, 0.45))
	for x0: float in [-26.0, 16.5]:
		_rect(p, x0, -10.4, 8.5, 2.6, _mul(body, 0.5))
		_rect(p, x0, -10.4, 8.5, 0.5, _mul(rim, 0.5))
	_rect(p, -29.4, -6.6, 59, 1.5, CHROME)                              # Stoßleiste
	_rect(p, -29.4, -6.6, 59, 0.5, _mul(rim, 1.0))
	# Variante: Zierlinie / Zweifarbdach / Schweller / Türdecal / Doppelstreifen
	if style == 0:
		_rect(p, -27, -8.8, 53.5, 1.1, accent)
	elif style == 1:
		_rect(p, -12.8, -18.9, 21.8, 1.0, accent)
		_rect(p, -27, -8.8, 53.5, 0.5, _mul(accent, 0.75))
	elif style == 2:
		_rect(p, -27.5, -5.3, 52.5, 1.5, accent)
	elif style == 3:
		_stencil(p, livery, -25.0, -11.2, 15.0, accent, d, 0.5)
	else:
		_rect(p, -27, -9.7, 53.5, 0.6, accent)
		_rect(p, -27, -7.9, 53.5, 0.6, accent)
	_wheel(p, -18, 3.6, body)
	_wheel(p, 18, 3.6, body)
	_lamps(p, e, [27.6, 28.4], -10.6, 0.7, 1.0, HEAD)                   # Lichtmuster vorn
	_lamps(p, e, [26.6, 27.6, 28.6], -8.8, 0.7, 0.8, HEAD)
	_lamps(p, e, [-29.8], -11.2, 1.0, 3.0, TAIL)
	_lamps(p, e, [-29.4, -27.8, -26.2], -5.6, 0.9, 0.7, TAIL)
	for q: QP in [p, e]:
		_rect(q, 24, -11.4, 1.4, 0.6, AMBER)


## Metrokab: hoher Glas-Dom über kastigem Unterbau, Schachbrettband, Dachlampe.
static func _metrokab(p: QP, e: QP, body: Array, glow: Array, rim: Array, d: int, accent: Array, style: int) -> void:
	for q: QP in [p, e]:
		_rect(q, -22, -2.6, 44, 1.0, glow)
	_poly(p, [[-28, -4], [-28.4, -11], [-25, -12.4], [22, -12.4], [27.4, -10.2], [28.2, -5.6], [26, -3.6],
		[-26, -3.6]], body)
	_poly(p, [[-20, -12.2], [-18.4, -19.4], [-12.6, -23.0], [6.2, -23.0], [14.4, -20.0], [21.6, -12.2]], WIN)
	_rect(p, -12.6, -24.0, 18.8, 1.2, [22, 22, 28])                    # Dach-Kappe
	_line(p, -12, -22.4, 6, -22.4, _mul(rim, 0.9), 0.7)
	_line(p, 6.4, -22.2, 14.4, -19.4, _mul(rim, 0.6), 0.6)
	_rect(p, -3.2, -23.0, 1.2, 10.6, [22, 22, 28])                     # Mittelstrebe
	_ell(p, -11.5, -19.6, 3.6, 3.8, [14, 14, 20])                      # Fahrgast
	_ell(p, 7.0, -19.4, 3.4, 3.6, [14, 14, 20])                        # Fahrer
	for q: QP in [p, e]:
		_rect(q, 10.5, -15.8, 3.0, 0.8, _mul(AMBER, 0.6))             # Taxameter-Schimmer
	if style != 3:                                                      # Schachbrettband (nicht immer)
		for i in 20:
			var x := -27 + i * 2.7
			_rect(p, x, -9.2 + (0.0 if i % 2 else 1.1), 1.35, 1.1, [14, 14, 18])
			_rect(p, x + 1.35, -9.2 + (1.1 if i % 2 else 0.0), 1.35, 1.1, [14, 14, 18])
	if style in [0, 2, 4]:                                              # Zierlinie
		_rect(p, -28, -8.7, 53, 0.9, accent)
	_rect(p, -28, -12.6, 50, 0.6, _mul(rim, 0.8))
	_rect(p, -28.4, -6.0, 56.6, 1.2, [24, 24, 30])
	var sign_col: Array = accent if style in [1, 4] else AMBER          # Dachschild
	_rect(p, -7, -27.0, 11, 3.0, [16, 16, 22])
	for q: QP in [p, e]:
		_rect(q, -6.2, -26.4, 9.4, 1.8, sign_col)
	_stencil(p, TAXI_SIGN[style % TAXI_SIGN.size()], -5.8, -26.5, 7.0, [30, 20, 10], d, 0.4)
	_wheel(p, -17, 3.4, body)
	_wheel(p, 17, 3.4, null, _mul(body, 0.7))
	_lamps(p, e, [26.6, 27.4], -10.0, 0.8, 1.4, HEAD)
	_lamps(p, e, [-28.6], -10.6, 1.0, 2.6, TAIL)


## Sebastians Laster: Panzer aus überlappenden, ausgemusterten Deflektorplatten.
static func _armadillo(p: QP, e: QP, body: Array, rim: Array, rnd: int, accent: Array, livery: String, d: int) -> void:
	var hl := 46.0
	for q: QP in [p, e]:
		_rect(q, -hl + 4, -2.2, 2 * hl - 8, 1.0, AMBER)
	_rect(p, -hl, -8.0, 2 * hl, 3.6, [20, 20, 24])                     # Fahrgestell
	var x0 := -hl
	var x1 := 21.0
	var n := 7
	var pw := (x1 - x0) / n
	var tints := [body, _mul(body, 0.85), [70, 54, 44], _mul(body, 1.12), [58, 62, 70], _mul(accent, 0.72),
		_mul(body, 1.25)]
	var top := func(x: float) -> float:
		var u := (x - x0) / (x1 - x0)
		return -9.0 - 22.5 * pow(maxf(0.0, sin(PI * minf(1.0, maxf(0.0, u)))), 0.55)
	for i in n:
		var a := x0 + i * pw
		var b := x0 + (i + 1) * pw + 1.6
		var c: Array = tints[(rnd >> i) % tints.size()]
		var pts := [[a, -7.6]]
		for k in 5:
			var xx := a + (b - a) * k / 4
			pts.append([xx, top.call(xx)])
		pts.append([b, -7.6])
		_poly(p, pts, c)
		var ta: float = top.call(a + 0.5)
		_rect(p, a, ta, 1.0, -7.6 - ta, _mul(c, 0.5))                  # Überlappungsschatten
		_line(p, b - 0.6, float(top.call(b - 0.6)) + 0.4, b - 0.6, -8.0, _mul(rim, 0.75), 0.6)   # Kantenlicht
		for yy: float in [-10.0, float(top.call((a + b) / 2)) + 3.0]:
			_rect(p, (a + b) / 2, yy, 0.6, 0.6, _mul(c, 1.6))           # Nieten
	_stencil(p, livery, -hl + 8.0, -22.0, 34.0, _mul(PALE, 0.7), d, 0.9)   # Firmenaufschrift
	_rect(p, -42, -10.2, 20, 1.4, _mul(accent, 0.8))                  # Spanngurt
	_rect(p, -hl + 2, -9.0, 62, 0.8, [96, 96, 108])                    # nachgerüstetes Rohr
	for x in range(int(-hl) + 6, 18, 9):
		_rect(p, x, -9.4, 1.2, 1.6, [120, 120, 130])
	for i in 6:                                                         # Warnstreifen
		_poly(p, [[-hl + i * 2, -4.6], [-hl + 1 + i * 2, -8.0], [-hl + 2 + i * 2, -8.0], [-hl + 1 + i * 2, -4.6]],
			[220, 180, 40] if i % 2 == 0 else [14, 14, 18])
	# Kabine
	var cab := _mul(body, 1.15)
	_poly(p, [[20, -5], [20, -24.5], [30, -25.5], [40, -17], [46, -13.5], [46, -5]], cab)
	_poly(p, [[24, -23], [30, -24], [37.6, -17], [24, -16.4]], WIN)
	_rect(p, 20, -25.0, 10, 0.8, _mul(rim, 0.9))
	for y: float in [-12.0, -10.4, -8.8]:
		_rect(p, 41, y, 5, 0.6, [24, 24, 28])                            # Kühlergrill
	_rect(p, 18.2, -31.0, 1.6, 24.0, [60, 60, 66])                    # Auspuff-Stack
	for q: QP in [p, e]:
		_rect(q, 18.2, -31.6, 1.6, 0.8, AMBER)
	for x: float in [-hl + 10, -hl + 21, 33.0]:
		_wheel(p, x, 4.2, null, [40, 40, 46])
	_lamps(p, e, [hl - 2], -11.5, 2.0, 2.4, HEAD)
	_lamps(p, e, [-hl], -11.0, 1.4, 3.4, TAIL)
	_lamps(p, e, [-30.0, -18.0, -6.0], float(top.call(-30.0)) - 0.4, 1.2, 0.8, AMBER)
	_lamps(p, e, [22.0, 26.0], -26.2, 2.0, 0.8, AMBER)


## Aerial-Limousine: lang, lackschwarz, Schlitzfenster, Radgondeln vorn, Goldlinie.
static func _limo(p: QP, e: QP, body: Array, rim: Array, _d: int, accent: Array) -> void:
	for q: QP in [p, e]:
		_rect(q, -36, -2.4, 64, 0.9, VIOLET)
	_poly(p, [[-42, -4], [-42.4, -10.4], [-38, -12.8], [-10, -13.6], [-4, -16.6], [18, -16.6], [28, -12.6],
		[38, -10.6], [42, -8.2], [42.2, -5.2], [37, -3.6], [-40, -3.6]], body)
	_poly(p, [[-3, -15.6], [17, -15.6], [24, -13.0], [-1, -13.0]], [30, 24, 50])
	_rect(p, -22, -12.4, 9, 1.3, [30, 24, 50])                          # Opernfenster
	_rect(p, -38, -13.0, 76, 0.6, _mul(rim, 0.9))
	_rect(p, -4, -16.8, 22, 0.6, _mul(rim, 1.0))
	_poly(p, [[-42, -10.4], [-41, -17.5], [-38.6, -17.5], [-37, -12.6]], _mul(body, 1.3))   # Heckflosse
	_rect(p, -42, -8.8, 80, 0.7, accent)                                # Zierlinie
	for q: QP in [p, e]:
		_rect(q, 2.0, -8.9, 18, 0.5, _mul(accent, 0.8))
	_poly(p, [[-27, -9.6], [-25.2, -12.0], [-23.4, -9.6]], _mul(accent, 1.05))   # Tyrell-Pyramide
	# Radgondel vorn, Hinterrad verkleidet
	_ell(p, 29.0, -9.0, 9.0, 8.6, _mul(body, 1.6))
	_ell(p, 29.8, -5.2, 7.4, 5.2, [8, 8, 12])
	_rect(p, -32, -4.4, 12, 1.2, [8, 8, 12])
	_lamps(p, e, [41.0], -9.6, 1.2, 1.0, HEAD)
	_lamps(p, e, [40.0], -7.4, 2.0, 0.6, HEAD)
	for q: QP in [p, e]:
		_rect(q, -42.4, -9.8, 1.2, 5.0, TAIL)
		_rect(q, -40, -5.0, 14, 0.6, TAIL)


static func _bike(p: QP, e: QP, body: Array, glow: Array, rim: Array, accent: Array) -> void:
	for q: QP in [p, e]:
		_rect(q, -11, -1.6, 22, 0.9, glow)
	_wheel(p, -10, 4.0, null, _mul(body, 1.3))
	_wheel(p, 10, 4.0, null, _mul(body, 1.3))
	for q: QP in [p, e]:           # Leuchtring in der Radscheibe
		q.set_pen(_q(glow), 0.5)
		q.set_no_brush()
		for x: float in [-10.0, 10.0]:
			q.draw_ellipse(x - 2.6, -6.6, 5.2, 5.2)
		q.set_no_pen()
	_poly(p, [[-15, -6], [-6, -11.4], [7, -12.6], [15.4, -8.4], [13, -5], [-12, -4.5]], body)
	_poly(p, [[-13, -6.0], [-5.5, -10.4], [6, -11.4], [12, -8.4], [10.5, -6.6], [-11, -5.6]], _mul(accent, 0.85))
	_rect(p, -6, -11.6, 13, 0.8, _mul(rim, 0.9))
	_poly(p, [[6, -12.4], [11, -15.4], [13.6, -11.2]], [40, 50, 80])     # Windschild
	# Fahrer, nach vorn gebeugt
	_poly(p, [[-6, -10.5], [-1, -19.5], [5, -18.5], [6, -12]], [24, 24, 32])
	_ell(p, 2.5, -24.0, 5.6, 5.2, [30, 30, 40])
	for q: QP in [p, e]:
		_rect(q, 5.5, -22.6, 2.4, 1.2, glow)          # Visier
		_rect(q, 14.2, -9, 1.6, 1.6, HEAD)
		_rect(q, -14.6, -7, 1.2, 1.4, TAIL)


## Stadtbus (aus Meads Formensprache extrapoliert): Fensterband voller Fahrgäste.
static func _bus(p: QP, e: QP, body: Array, rim: Array, rnd: int, d: int, accent: Array, livery: String) -> void:
	for q: QP in [p, e]:
		_rect(q, -54, -2.4, 108, 1.0, TEAL)
	_poly(p, [[-60, -4], [-60.4, -33], [-57, -36], [50, -36], [56, -33.4], [60, -26], [60.4, -6], [58, -3.6],
		[-58, -3.6]], body)
	_rect(p, -40, -38.4, 22, 2.6, _mul(body, 0.7))                     # Dachaggregate
	_rect(p, 6, -38.0, 14, 2.2, _mul(body, 0.7))
	_rect(p, -57, -36.2, 107, 0.7, _mul(rim, 0.9))
	var warm := [196, 150, 92]
	var cool := [150, 176, 200]
	for i in 10:
		var x := -55 + i * 9.6
		var lit := (rnd >> i) & 3
		var c: Array = warm if lit == 0 else (cool if lit == 1 else [40, 50, 70])
		_rect(p, x, -30, 8.2, 9.0, c)
		if lit != 2:
			_rect(e, x, -30, 8.2, 9.0, _mul(c, 0.4))
		if (rnd >> (i + 3)) & 1:                                       # Fahrgast-Silhouetten
			_ell(p, x + 2.0, -26.6, 3.2, 3.4, [16, 16, 22])
			_rect(p, x + 1.2, -23.4, 4.8, 2.6, [16, 16, 22])
	_rect(p, -57, -31.0, 107, 1.0, _mul(body, 0.6))
	_poly(p, [[50, -33.6], [55.6, -33], [59.2, -26], [59.2, -20], [50, -20]], WIN)   # Front
	_rect(p, 34, -19.4, 8, 15.0, [34, 40, 56])                         # Tür
	for q: QP in [p, e]:
		_rect(q, 34.6, -18.8, 6.8, 0.8, _mul(PALE, 0.7))
	_rect(p, -52, -18.6, 70, 7.0, _mul(accent, 0.45))                  # Werbeband
	for q: QP in [p, e]:
		_rect(q, -52, -18.6, 70, 0.8, _mul(accent, 1.0))
	_rect(p, -52, -12.0, 70, 0.7, _mul(accent, 0.8))
	_stencil(p, livery, -48, -17.4, 40.0, _mul(PALE, 0.85), d, 0.9)
	_rect(p, 30, -35.4, 18, 3.4, [12, 12, 16])                          # Linienanzeige
	var route: String = BUS_ROUTE[(rnd >> 5) % BUS_ROUTE.size()]
	_stencil(p, route, 31, -34.8, 16.0, AMBER, d, 0.45)
	_stencil(e, route, 31, -34.8, 16.0, AMBER, d, 0.45)
	_rect(p, -60, -8.0, 120, 1.2, [24, 24, 30])
	_wheel(p, -44, 4.6, body)
	_wheel(p, 40, 4.6, body)
	_lamps(p, e, [58.6], -12.0, 1.6, 2.2, HEAD)
	_lamps(p, e, [-60.8], -12.0, 1.2, 4.0, TAIL)
	_lamps(p, e, [-56.0, -20.0, 16.0, 46.0], -37.0, 1.4, 0.8, AMBER)


static func _draw_vehicle(p: QP, e: QP, kind: String, seed_: int, rim: Array, d: int = 1) -> void:
	var rnd := (seed_ * 2654435761) & 0xFFFFFFFF
	var pal: Array = BODY[kind]
	var body := _tint(pal[rnd % pal.size()], ((rnd >> 4) % 7) - 3)
	var glow: Array = UNDERGLOW[(rnd >> 8) % UNDERGLOW.size()]
	var accent: Array = ACCENT[(rnd >> 13) % ACCENT.size()]
	var style := (rnd >> 17) % 5
	var livery: String = LIVERY[(rnd >> 3) % LIVERY.size()]
	if kind == "police":
		p.save()
		e.save()
		for q: QP in [p, e]:
			q.scale(60.0 / SPIN_L, 1.0)
		_draw_spinner(p, e, true, rnd, rim, d)
		p.restore()
		e.restore()
	elif kind == "car":
		_sedan(p, e, body, glow, rim, accent, style, livery, d)
	elif kind == "taxi":
		_metrokab(p, e, body, glow, rim, d, accent, style)
	elif kind == "truck":
		_armadillo(p, e, body, rim, rnd, accent, livery, d)
	elif kind == "limo":
		_limo(p, e, body, rim, d, accent)
	elif kind == "bike":
		_bike(p, e, body, glow, rim, accent)
	elif kind == "bus":
		_bus(p, e, body, rim, rnd, d, accent, livery)


## [img, emit, ax, ay, length_px]: Anker = Boden-Mitte des Fahrzeugs (Fahrtrichtung d).
static func vehicle_image(kind: String, seed_: int, ppu: float, rim: Array, d: int = 1) -> Array:
	var kpx := Py.round(ppu * 8) / 8.0
	var key := ["v", kind, Py.imod(seed_, VARIANTS), kpx, rim, d]
	var hit: Variant = _CACHE.get(key)
	if hit != null:
		return hit
	var dims: Array = DSim.VEHICLES[kind]
	var L: float = dims[0]
	var h: float = dims[1]
	var w := int(L * kpx) + 8
	var hh := int((h + 8) * kpx) + 6
	var ax := w / 2
	var ay := hh - 3
	var ec := _ec()
	if _CACHE.size() > 1000:
		ec.swap()
	var res := _bake(w, hh, ax, ay, kpx * VEH_SCALE, func(p: QP, e: QP) -> void:
		_draw_vehicle(p, e, kind, Py.imod(seed_, VARIANTS), rim, d))
	if res.is_empty():
		return [null, null, ax, ay, L * kpx]
	var img: QImg = res[0]
	var em: QImg = res[1]
	if d < 0:
		img = img.mirror()
		em = em.mirror()
		ax = w - 1 - ax
	var out := [img, em, ax, ay, L * kpx]
	_CACHE[key] = out
	return out

# ---------------------------------------------------------------------------- Hindernisse

static func _draw_obstacle(p: QP, e: QP, kind: String, seed_: int, rim: Array) -> void:
	var rnd := (seed_ * 2246822519) & 0xFFFFFFFF
	if kind == "barrier":
		for x: float in [-9.0, 9.0]:
			_poly(p, [[x - 3, 0], [x - 0.6, -9], [x + 0.6, -9], [x + 3, 0], [x + 2, 0], [x, -7], [x - 2, 0]],
				[60, 60, 70])
		_rect(p, -11, -9.5, 22, 3.6, [214, 220, 226])
		for i in range(-11, 11, 4):
			_poly(p, [[i, -5.9], [i + 2, -9.5], [i + 4, -9.5], [i + 2, -5.9]], [200, 40, 60])
		_rect(p, -11, -9.5, 22, 0.8, _mul(rim, 1.0))
		_rect(p, -1, -12, 2, 2.4, [40, 40, 40])      # Blinklampe (leuchtet live)
	elif kind == "crates":
		var cols := [[92, 70, 52], [60, 70, 90], [50, 80, 70]]
		var c: Array = cols[rnd % 3]
		_rect(p, -9, -6, 18, 6, c)
		_rect(p, -7, -11, 12, 5, _mul(c, 1.15))
		for r: Array in [[-9, -6, 18, 6], [-7, -11, 12, 5]]:
			var x: float = r[0]
			var y: float = r[1]
			var w: float = r[2]
			var h: float = r[3]
			_rect(p, x, y, w, 0.7, _mul(rim, 0.8))
			_rect(p, x + 0.5, y + h * 0.5, w - 1, 0.6, _mul(c, 0.6))
		var word: String = ["OFF", "TYR", "XX"][rnd % 3]
		var img := Pixfont.render(word, _mul(PALE, 0.5), 1, null)
		p.save()
		p.translate(-5, -5)
		p.scale(0.5, 0.5)
		p.draw_image_at(0, 0, img)
		p.restore()
	elif kind == "bins":
		_rect(p, 1, -8, 7, 8, [40, 60, 56])
		_rect(p, 0.5, -8.6, 8, 1.2, _mul(rim, 0.7))
		p.set_no_pen()
		for b: Array in [[-6.0, -2.6, 3.0], [-2.0, -3.0, 3.4], [-4.0, -5.2, 2.6]]:
			var x: float = b[0]
			var y: float = b[1]
			var r: float = b[2]
			p.set_brush(_q([22, 22, 28]))
			p.draw_ellipse(x - r, y - r * 0.8, 2 * r, r * 1.7)
			p.set_brush(_q(_mul(rim, 0.6)))
			p.draw_ellipse(x - r * 0.4, y - r * 0.7, r * 0.5, r * 0.4)
	elif kind == "barrel":
		_rect(p, -4, -9, 8, 9, [66, 44, 36])
		for y: float in [-7.5, -3.5]:
			_rect(p, -4, y, 8, 0.8, [90, 60, 46])
		_rect(p, -4, -9, 1.0, 9, _mul(rim, 0.7))
		for q: QP in [p, e]:
			_rect(q, -3.4, -9.4, 6.8, 1.0, AMBER)   # Glut am Rand
	elif kind == "vending":
		var col: Array = [CYAN, MAGENTA, AMBER, CRIMSON][rnd % 4]
		_rect(p, -6, -20, 12, 20, [30, 32, 44])
		_rect(p, -6, -20, 12, 0.8, _mul(rim, 0.8))
		for qa: Array in [[p, 255.0], [e, 200.0]]:
			var q: QP = qa[0]
			var a: float = qa[1]
			_rect(q, -5, -19, 7, 12, _mul(col, 0.55), a)
			for y: float in [-18.0, -15.0, -12.0]:
				_rect(q, -4.5, y, 6, 1.4, _mul(col, 1.1), a)
			_rect(q, 3, -17, 2, 2, [255, 250, 230], a)
		_rect(p, -5, -5, 7, 2.4, [10, 10, 14])


## [img, emit, ax, ay]: Anker = Boden-Mitte.
static func obstacle_image(kind: String, seed_: int, ppu: float, rim: Array) -> Array:
	var kpx := Py.round(ppu * 8) / 8.0
	var key := ["o", kind, Py.imod(seed_, 5), kpx, rim]
	var hit: Variant = _CACHE.get(key)
	if hit != null:
		return hit
	var w := int(30 * kpx) + 6
	var hh := int(26 * kpx) + 6
	var ax := w / 2
	var ay := hh - 3
	var res := _bake(w, hh, ax, ay, kpx, func(p: QP, e: QP) -> void:
		_draw_obstacle(p, e, kind, Py.imod(seed_, 5), rim))
	if res.is_empty():
		return [null, null, ax, ay]
	var out := [res[0], res[1], ax, ay]
	_CACHE[key] = out
	return out


## Lichtkegel vor dem Fahrzeug: Strahl in der Luft + Lichtfleck auf der Fahrbahn.
static func headlight(p: QP, x: float, y: float, d: int, ppu: float, gy: float, length: float = 150.0,
		col: Array = [255, 240, 210], a: float = 70.0) -> void:
	var tip := x + d * length * ppu
	var g := QGrad.linear(x, y, tip, y)
	g.set_color_at(0, QP.rgb(col, a))
	g.set_color_at(1, QP.rgb(col, 0))
	p.set_no_pen()
	p.set_brush(g)
	p.draw_polygon(PackedVector2Array([Vector2(x, y - 1), Vector2(tip, y - 10 * ppu), Vector2(tip, gy + 4 * ppu),
		Vector2(x, y + 1)]))


## Alles verwerfen (wie _CACHE.clear()).
static func clear_cache() -> void:
	if _cache_obj == null:
		_CACHE.clear()
	else:
		_cache_obj.swap()
