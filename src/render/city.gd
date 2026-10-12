class_name City
extends RefCounted
## Prozedurale Stadt pro Zone: Himmel, Skyline-Layer, Häuserfront, Boden.
## 1:1-Port von shadegunner/render/city.py.
##
## Alles Statische wird pro Zone einmal in große Bilder gebacken (welt-verankert,
## kein Wrappen - die Häuserfront scrollt exakt mit der Perspektive der Figuren).
## Alles, was lebt (Neon-Flackern, Laternen, Billboards, Spinner, Fackeln,
## Suchscheinwerfer, Warnlichter), wird als Objektliste gehalten und pro Frame
## von render/scene gezeichnet.
##
## Port-Hinweise:
##   QImage + QPainter        -> City._bake(w, h, func(p: QP): ...)
##   setPixelColor-Bilder     -> City._Pix (CPU, premultipliziert) -> ImageTexture -> QImg
##   Layer / Sign / Lamp      -> innere Klassen City.Layer / City.Sign / City.Lamp
##   self.seed                -> seed_

const C := Config.NOIR16
const VOID := DCity.VOID
const NIGHT := DCity.NIGHT
const NAVY := DCity.NAVY
const INDIGO := DCity.INDIGO
const BLUE := DCity.BLUE
const STEEL := DCity.STEEL
const CRIMSON := DCity.CRIMSON
const SODIUM := DCity.SODIUM
const ASH := DCity.ASH
const PALE := DCity.PALE
const WHITE := DCity.WHITE
const SLATE := DCity.SLATE
const TEAL := DCity.TEAL
const CYAN := DCity.CYAN
const MAGENTA := DCity.MAGENTA
const AMBER := DCity.AMBER
const VIOLET := DCity.VIOLET

const W := Config.RENDER_W
const H := Config.RENDER_H
const FAR_F := DCity.FAR_F        # px Scroll pro Welt-Einheit Kamera
const MID_F := DCity.MID_F
const CLOUD_F := DCity.CLOUD_F
const TPU := DCity.TPU            # Bodentextur: px pro Welt-Einheit

const THEMES := DCity.THEMES
const SHOP_KINDS := DCity.SHOP_KINDS
const SHOP_WORDS := DCity.SHOP_WORDS

static var baker: Baker


# ------------------------------------------------------------------------- Farb-Helfer

static func mul(c: Array, f: float) -> Array:
	return [maxi(0, mini(255, int(float(c[0]) * f))), maxi(0, mini(255, int(float(c[1]) * f))),
		maxi(0, mini(255, int(float(c[2]) * f)))]


static func mix(a: Array, b: Array, t: float) -> Array:
	var a0: float = a[0]
	var a1: float = a[1]
	var a2: float = a[2]
	var b0: float = b[0]
	var b1: float = b[1]
	var b2: float = b[2]
	return [int(a0 + (b0 - a0) * t), int(a1 + (b1 - a1) * t), int(a2 + (b2 - a2) * t)]


static func qc(c: Array, a: float = 255.0) -> Color:
	return QP.rgb(c, a)


## Wie Baker.bake, aber mit QPExact (Pixelmitten-Regel wie Qt aliased; QPs
## +0.5-Versatz stimmt nur für ganzzahlige Koordinaten - Wolken/Nebel/Pyramiden
## liegen gebrochen). Der Viewport hängt am Baker (release/release_all wirken).
static func _bake(w: int, h: int, draw: Callable) -> QImg:
	var vp := SubViewport.new()
	vp.size = Vector2i(maxi(1, w), maxi(1, h))
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	var host := Node2D.new()
	vp.add_child(host)
	baker.add_child(vp)
	var p := QPExact.new(host.get_canvas_item())
	p.begin()
	draw.call(p)
	p.end()
	baker._bakes.append(vp)
	var img := QImg.new(vp.get_texture(), Rect2(0, 0, w, h))
	img.set_meta("vp", vp)
	return img


## Nasse-Straße-Reflexion, progressiv: am Kontaktpunkt (oben im gespiegelten Bild)
## fast scharf und kräftig, mit zunehmender Tiefe immer weicher und blasser.
## Aus mehreren Blur-Stufen zu EINEM Bild gebacken.
## Abweichung: Qt-SmoothTransformation (Box-Filter beim Verkleinern) wird hier
## bilinear angenähert.
static func soft_reflection(img: QImg) -> QImg:
	var w := img.width()
	var h := img.height()
	if w < 2 or h < 2:
		return img
	var mir := _bake(w, h, func(p: QP) -> void:
		p.translate(0, h)
		p.scale(1.0, -1.0)
		p.draw_image(Rect2(0, 0, w, h), img))
	var layers: Array = [mir]                           # 0 = scharf
	for hw: Array in [[3, 2], [6, 3], [12, 5]]:         # 1 mild, 2 mittel, 3 stark verwischt
		var hf: int = hw[0]
		var wf: int = hw[1]
		var sw := maxi(1, Py.ifloordiv(w, wf))
		var sh := maxi(1, Py.ifloordiv(h, hf))
		var small := _bake(sw, sh, func(p: QP) -> void:
			p.set_smooth(true)
			p.draw_image(Rect2(0, 0, sw, sh), mir))
		var big := _bake(w, h, func(p: QP) -> void:
			p.set_smooth(true)
			p.draw_image(Rect2(0, 0, w, h), small))
		layers.append(big)
	var tmps: Array = []
	# von hinten (stark verwischt, tief) nach vorn (scharf, Kontaktpunkt)
	for st: Array in [[3, 0.32, 1.00, 0.55], [2, 0.05, 0.80, 0.78], [1, 0.00, 0.52, 0.9], [0, 0.00, 0.26, 1.0]]:
		var idx: int = st[0]
		var s: float = st[1]
		var e: float = st[2]
		var a: float = st[3]
		var src: QImg = layers[idx]
		var tmp := _bake(w, h, func(t: QP) -> void:
			t.draw_image_at(0, 0, src)
			t.set_mode(QP.DEST_IN)
			var grad := QGrad.linear(0, 0, 0, h)
			grad.set_color_at(0.0, QP.c(255, 255, 255, int(255 * a)))
			if s > 0:
				grad.set_color_at(s, QP.c(255, 255, 255, int(255 * a)))
			grad.set_color_at(minf(0.999, e), QP.c(255, 255, 255, 0))
			grad.set_color_at(1.0, QP.c(255, 255, 255, 0))
			t.fill_rect(0, 0, w, h, grad))
		tmps.append(tmp)
	return _bake(w, h, func(op: QP) -> void:
		for t: QImg in tmps:
			op.draw_image_at(0, 0, t))


static func _wchoice(rng: PyRandom, items: Array) -> Variant:
	var tot := 0.0
	for it: Array in items:
		tot += float(it[1])
	var r := rng.random() * tot
	for it: Array in items:
		r -= float(it[1])
		if r <= 0:
			return it[0]
	return (items[-1] as Array)[0]


## bisect.bisect_left / bisect_right für aufsteigend sortierte Zahlenlisten.
static func bisect_left(a: Array, x: float) -> int:
	var lo := 0
	var hi := a.size()
	while lo < hi:
		var m := (lo + hi) >> 1
		if float(a[m]) < x:
			lo = m + 1
		else:
			hi = m
	return lo


static func bisect_right(a: Array, x: float) -> int:
	var lo := 0
	var hi := a.size()
	while lo < hi:
		var m := (lo + hi) >> 1
		if x < float(a[m]):
			hi = m
		else:
			lo = m + 1
	return lo


## Stabile Sortierung (wie Python list.sort(key=...)); sort_custom ist nicht stabil.
static func _stable_sort(items: Array, key: Callable) -> void:
	var dec: Array = []
	for i in items.size():
		dec.append([key.call(items[i]), i, items[i]])
	dec.sort_custom(func(u: Array, v: Array) -> bool:
		var ku: float = u[0]
		var kv: float = v[0]
		if ku != kv:
			return ku < kv
		return int(u[1]) < int(v[1]))
	for i in dec.size():
		items[i] = (dec[i] as Array)[2]


# ------------------------------------------------------------------------- CPU-Pixelbild

## Ersatz für QImage + setPixelColor: premultiplizierte RGBA8-Pixel auf der CPU.
class _Pix:
	var w: int
	var h: int
	var buf: PackedByteArray

	func _init(w_: int, h_: int) -> void:
		w = w_
		h = h_
		buf = PackedByteArray()
		buf.resize(w * h * 4)
		buf.fill(0)

	static func _pm(v: float, a: int) -> int:
		return int((v * a + 127.0) / 255.0)

	## setPixelColor(x, y, QColor(rgb, a)) - ersetzt.
	func set_(x: int, y: int, rgb: Array, a: int = 255) -> void:
		if x < 0 or y < 0 or x >= w or y >= h:
			return
		var o := (y * w + x) * 4
		buf[o] = _pm(rgb[0], a)
		buf[o + 1] = _pm(rgb[1], a)
		buf[o + 2] = _pm(rgb[2], a)
		buf[o + 3] = a

	## SourceOver einer Farbe (QPainter-Pixel).
	func blend(x: int, y: int, rgb: Array, a: int = 255) -> void:
		if x < 0 or y < 0 or x >= w or y >= h:
			return
		var o := (y * w + x) * 4
		var inv := 255 - a
		var src := [_pm(rgb[0], a), _pm(rgb[1], a), _pm(rgb[2], a), a]
		for k in 4:
			buf[o + k] = mini(255, int(src[k]) + _pm(buf[o + k], inv))

	## fillRect(x, y, w, h, QColor) (SourceOver).
	func fill_rect(x: int, y: int, rw: int, rh: int, rgb: Array, a: int = 255) -> void:
		for yy in range(y, y + rh):
			for xx in range(x, x + rw):
				blend(xx, yy, rgb, a)

	## drawRect(x, y, rw, rh) mit 1-px-Stift ohne Pinsel: Umriss über rw+1 x rh+1 Pixel.
	func draw_rect(x: int, y: int, rw: int, rh: int, rgb: Array, a: int = 255) -> void:
		for xx in range(x, x + rw + 1):
			blend(xx, y, rgb, a)
			if rh > 0:
				blend(xx, y + rh, rgb, a)
		for yy in range(y + 1, y + rh):
			blend(x, yy, rgb, a)
			if rw > 0:
				blend(x + rw, yy, rgb, a)

	func to_qimg() -> QImg:
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, buf)
		return QImg.new(ImageTexture.create_from_image(img), Rect2(0, 0, w, h))


# ------------------------------------------------------------------------- Bausteine

## Welt-verankertes Bild: Layer-Koordinate L = Welt-x * factor.
class Layer:
	var factor: float
	var lmin: int
	var width: int
	var height: int
	var y: float
	var img: QImg

	func _init(factor_: float, cam_min: float, cam_max: float, height_: int, y_: float = 0) -> void:
		factor = factor_
		lmin = int(cam_min * factor - City.W * 0.5 - 40)
		width = int((cam_max - cam_min) * factor + City.W + 80)
		height = height_
		y = y_
		img = null    # wird vom Erzeuger gebacken (City._bake(width, height, ...))

	## Layer-Koordinate -> Bildpixel.
	func lx(L: float) -> float:
		return L - lmin

	func screen_x(L: float, cam: float) -> float:
		return L - cam * factor + City.W * 0.5

	func draw(p: QP, cam: float, img_: QImg = null, dy: float = 0, opacity: float = 1.0) -> void:
		var im: QImg = img_ if img_ != null else img
		var x := lmin - cam * factor + City.W * 0.5
		var sx := maxf(0.0, -x)
		var sw := minf(im.width() - sx, City.W + 2)
		if sw <= 0:
			return
		if opacity < 1.0:
			p.set_opacity(opacity)
		p.draw_image(Rect2(int(x + sx), y + dy, int(sw), im.height()), im,
			Rect2(int(sx), 0, int(sw), im.height()))
		if opacity < 1.0:
			p.set_opacity(1.0)


## Neon-Schild mit Flacker-Verhalten. Bilder: an / aus / emit.
class Sign:
	var L: float
	var y: float
	var on: QImg
	var off: QImg
	var emit: QImg
	var mode: String
	var seed_: int
	var w: int
	var h: int
	var color: Array

	func _init(L_: float, y_: float, on_: QImg, off_: QImg, emit_: QImg, mode_: String, seed__: int,
			color_: Array) -> void:
		L = L_
		y = y_
		on = on_
		off = off_
		emit = emit_
		mode = mode_
		seed_ = seed__
		color = color_
		w = on.width()
		h = on.height()

	func lit(t: float) -> float:
		var k := int(t * 18.0)
		var n := City._hash(k, seed_)
		if mode == "steady":
			return 1.0 if n > 0.004 else 0.0
		if mode == "buzz":
			var burst := City._hash(int(t * 0.7), seed_ + 7) < 0.25
			return 0.0 if (burst and n < 0.45) else 1.0
		if mode == "blink":
			return 1.0 if Py.imod(int(t * 1.6 + Py.imod(seed_, 7)), 2) == 0 else 0.0
		if mode == "dying":
			return 1.0 if n < 0.35 or City._hash(int(t * 2.0), seed_) < 0.2 else 0.0
		return 1.0


static func _hash(i: int, s: int) -> float:
	var h := (i * 374761393 + s * 668265263) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((h ^ (h >> 16)) & 0xFFFF) / 65535.0


## Pseudo-Kanji 5x7 als Menge gesetzter Pixel (Dictionary Vector2i -> true).
static func _glyph(rng: PyRandom) -> Dictionary:
	var px := {}
	var strokes := rng.randint(3, 5)
	for _i in strokes:
		var kind := rng.random()
		if kind < 0.4:
			var y: int = rng.choice([0, 2, 3, 4, 6])
			var xx: Array = rng.choice([[0, 4], [0, 2], [2, 4], [1, 3]])
			for x in range(int(xx[0]), int(xx[1]) + 1):
				px[Vector2i(x, y)] = true
		elif kind < 0.8:
			var x: int = rng.choice([0, 2, 4, 1, 3])
			var yy: Array = rng.choice([[0, 6], [0, 3], [3, 6], [1, 5]])
			for y in range(int(yy[0]), int(yy[1]) + 1):
				px[Vector2i(x, y)] = true
		else:
			var d: int = rng.choice([1, -1])
			for i in 4:
				px[Vector2i(2 + d * (i - 1), 2 + i)] = true
	return px


## Erzeugt [on, off, emit] Bilder für ein Neon-Schild.
static func _make_sign(rng: PyRandom, color: Array, kind: String, word: Variant = null) -> Array:
	var w: int
	var h: int
	var pts: Array = []    # Vector2i
	if kind == "vertical":
		var n := rng.randint(3, 6)
		w = 11
		h = n * 9 + 4
		var glyphs: Array = []
		for _i in n:
			glyphs.append(_glyph(rng))
		for i in glyphs.size():
			for g: Vector2i in (glyphs[i] as Dictionary):
				pts.append(Vector2i(3 + g.x, 3 + i * 9 + g.y))
	elif kind == "text":
		var wd: String = word if (word != null and String(word) != "") else "BAR"
		var tw := Pixfont.text_width(wd)
		w = tw + 8
		h = 13
		# pixfont.render(word, weiß, 1, shadow=None): gesetzte Pixel = Glyphen-Läufe
		for run: Array in Pixfont._runs(wd):
			for k in int(run[2]):
				pts.append(Vector2i(4 + int(run[0]) + k, 3 + int(run[1])))
	else:  # arrow/chevrons
		w = 22
		h = 11
		for k in 3:
			for i in 4:
				pts.append(Vector2i(3 + k * 6 + i, 1 + i + 1))
				pts.append(Vector2i(3 + k * 6 + i, 9 - i - 1))
	var bw := rng.random() < 0.6

	var build := func(state: String) -> QImg:
		var img := _Pix.new(w, h)
		if state != "emit":
			img.fill_rect(0, 0, w, h, [8, 8, 14], 235)
			img.draw_rect(0, 0, w - 1, h - 1, mul(color, 0.25 if state == "off" else 0.45))
		var col: Array = color if state != "off" else mul(color, 0.22)
		var core: Array = mix(color, WHITE, 0.55) if state != "off" else col
		for q: Vector2i in pts:
			img.set_(q.x, q.y, core if state == "on" and (q.x + q.y) % 3 == 0 else col)
		if state != "off" and bw:
			img.draw_rect(1, 1, w - 3, h - 3, color, 255 if state == "emit" else 200)
		return img.to_qimg()

	return [build.call("on"), build.call("off"), build.call("emit")]


## Neon-Drache (hellblau) wie über dem White Dragon. Rückgabe [on, off, emit,
## Zungen-Anker]: die rote Zunge flackert live (render/scene).
static func _dragon_sign(_rng: PyRandom) -> Array:
	var w := 66
	var h := 24
	var col := [150, 220, 236]
	var pts := {}
	# Körper: S-Kurve, nach hinten schmaler werdend, endet in einer Schwanzlocke
	var prev := Vector2i.ZERO
	for i in range(0, 220):
		var u := i / 219.0
		var x := 15 + u * 44
		var y := 12 + 6.5 * sin(u * PI * 2.0) * (1.0 - 0.35 * u)
		var cur := Vector2i(Py.round(x), Py.round(y))
		pts[cur] = true
		if u < 0.55:
			pts[Vector2i(cur.x, cur.y + 2)] = true      # Bauchlinie: Doppelrohr vorn
		prev = cur
	var cx := prev.x
	var cy := prev.y
	for i in 14:
		var a := i / 13.0 * PI * 1.5
		pts[Vector2i(Py.round(cx + 2 + 3 * sin(a)), Py.round(cy - 3 + 3 * cos(a)))] = true
	# Rückenzacken
	for x in range(20, 56, 5):
		var u := (x - 15) / 44.0
		var y := 12 + 6.5 * sin(u * PI * 2.0) * (1.0 - 0.35 * u)
		pts[Vector2i(x, Py.round(y) - 2)] = true
	# Beine mit Krallen
	for x0: int in [24, 44]:
		var u := (x0 - 15) / 44.0
		var y := Py.round(12 + 6.5 * sin(u * PI * 2.0) * (1.0 - 0.35 * u)) + 3
		for k in 3:
			pts[Vector2i(x0 - k, y + k)] = true
		pts[Vector2i(x0 - 3, y + 3)] = true
		pts[Vector2i(x0 - 1, y + 3)] = true
	# Kopf (blickt nach links): Schnauze, Kiefer, Horn, Auge
	var head := [[5, 9], [6, 8], [7, 8], [8, 7], [9, 7], [10, 7], [11, 8], [12, 9], [13, 10], [14, 11],
		[4, 10], [4, 11], [5, 12], [6, 12], [7, 13], [8, 13], [9, 13], [10, 13], [11, 13], [12, 13],
		[13, 12], [10, 6], [11, 5], [12, 4], [13, 4], [12, 6], [8, 5], [7, 4]]
	for q: Array in head:
		pts[Vector2i(q[0], q[1])] = true
	var eye := Vector2i(9, 9)
	pts.erase(eye)

	var build := func(state: String) -> QImg:
		var img := _Pix.new(w, h)
		var c: Array = col if state != "off" else mul(col, 0.22)
		var core := mix(col, WHITE, 0.6)
		for q: Vector2i in pts:
			if 0 <= q.x and q.x < w and 0 <= q.y and q.y < h:
				img.set_(q.x, q.y, core if state == "on" and (q.x * 3 + q.y) % 4 == 0 else c)
		if state != "off":
			img.set_(eye.x, eye.y, [255, 80, 90])
		return img.to_qimg()

	return [build.call("on"), build.call("off"), build.call("emit"), [4, 11]]


class Lamp:
	var x: float
	var L: float
	var y: float
	var arm: Variant
	var color: Array
	var seed_: int
	var flicker: bool

	func _init(x_: float, L_: float, y_: float, arm_: Variant, color_: Array, seed__: int, flicker_: bool) -> void:
		x = x_
		L = L_
		y = y_
		arm = arm_
		color = color_
		seed_ = seed__
		flicker = flicker_

	func level(t: float) -> float:
		if not flicker:
			return 1.0
		var n := City._hash(int(t * 14), seed_)
		if City._hash(int(t * 0.5), seed_ + 3) < 0.35:
			return 0.15 if n < 0.5 else 1.0
		return 1.0


# ------------------------------------------------------------------------- Stadt

var zone: int
var th: Dictionary
var length: float
var seed_: int
var rng: PyRandom
var cam_min: float
var cam_max: float
var fy: int
var signs: Array = []
var lamps: Array = []
var vents: Array = []
var blinks: Array = []
var billboards: Array = []
var flames: Array = []
var lanterns: Array = []
var tvs: Array = []
var searchlights: Array = []
var ramen_spots: Array = []
var exit_x: float
var _tv_x: Array = []
var _sign_x: Array = []
var _lan_x: Array = []
# Teil 1
var sky: QImg
var cloud_layers: Array = []     # [img, y, factor]
var far: Layer
var mid: Layer
var fog_layers: Array = []
var bank: QImg
var cloud: QImg
var air: Array = []
# Teil 2/3 (_facade, _holos, _ground)
var facade: Variant = null
var facade_emit: Variant = null
var facade_refl: Variant = null
var facade_refl_body: Variant = null
var gate: Variant = null
var ground: Variant = null
var g_wmin: Variant = null
var holos: Array = []
var manholes: Array = []
var puddles: Array = []


func _init(zone_index: int, length_: float, seed__: int) -> void:
	zone = zone_index
	th = THEMES[zone_index % THEMES.size()]
	length = length_
	seed_ = seed__
	rng = PyRandom.new(seed_ * 7919 + zone_index * 104729)
	cam_min = -120.0
	cam_max = length + 220.0
	fy = int(Persp.FACADE_Y)
	exit_x = length
	_sky()
	_clouds()
	_far()
	_mid()
	_facade()
	_holos()
	_ground()
	_fog_tex()
	_cloud_bank()
	_cloud_tile()
	_air()
	# Für schnelles Culling: nach Layer-x sortiert (stabil wie Python)
	_stable_sort(tvs, func(v: Array) -> float: return float(v[0]))
	_tv_x = tvs.map(func(v: Array) -> float: return float(v[0]))
	_stable_sort(signs, func(s: Sign) -> float: return s.L)
	_sign_x = signs.map(func(s: Sign) -> float: return s.L)
	_stable_sort(lanterns, func(v: Array) -> float: return float(v[0]))
	_lan_x = lanterns.map(func(v: Array) -> float: return float(v[0]))


## Ausschnitt einer nach keys sortierten Liste mit lo <= key <= hi.
func visible(items: Array, keys: Array, lo: float, hi: float) -> Array:
	return items.slice(bisect_left(keys, lo), bisect_right(keys, hi))


# ---------------------------------------------------------------- Nebel / Luftverkehr

## Großflächige, dichtere Nebelwolken (eine Kachel): für ziehende Schwaden.
func _cloud_bank() -> void:
	var w := W * 3
	var h := 260
	var col := mix(mix(th["fog"], th["sky_hor"], 0.5), PALE, 0.28)
	bank = _bake(w, h, func(p: QP) -> void:
		p.set_no_pen()
		for _i in 46:
			var cx := rng.uniform(0, w)
			var cy := rng.uniform(h * 0.15, h * 0.9)
			var r := rng.uniform(70, 180)
			var a := int(rng.uniform(0.55, 1.0) * 150)
			for ox: int in [-w, 0, w]:
				var g := QGrad.radial(cx + ox, cy, r)
				g.set_color_at(0.0, qc(col, a))
				g.set_color_at(0.55, qc(col, int(a * 0.4)))
				g.set_color_at(1.0, qc(col, 0))
				p.set_brush(g)
				p.save()
				p.translate(cx + ox, cy)
				p.scale(1.0, 0.5)
				p.translate(-(cx + ox), -cy)
				p.draw_ellipse(cx + ox - r, cy - r, 2 * r, 2 * r)
				p.restore())


## Eine einzelne, weiche Nebelwolke (mit hellem Kern) - Baustein für ziehende Schwaden.
func _cloud_tile() -> void:
	var w := 260
	var h := 172
	var col := mix(mix(th["fog"], th["sky_hor"], 0.45), PALE, 0.36)
	var r2 := PyRandom.new(4242)
	cloud = _bake(w, h, func(p: QP) -> void:
		p.set_no_pen()
		for _i in 8:
			var cx := r2.uniform(w * 0.22, w * 0.78)
			var cy := r2.uniform(h * 0.32, h * 0.72)
			var r := r2.uniform(46, 96)
			var g := QGrad.radial(cx, cy, r)
			g.set_color_at(0.0, qc(col, 130))
			g.set_color_at(0.5, qc(col, 58))
			g.set_color_at(1.0, qc(col, 0))
			p.set_brush(g)
			p.save()
			p.translate(cx, cy)
			p.scale(1.0, 0.6)
			p.translate(-cx, -cy)
			p.draw_ellipse(cx - r, cy - r, 2 * r, 2 * r)
			p.restore())


## Kachelbare Nebelschwaden (weiche Flecken), zwei Dichten.
func _fog_tex() -> void:
	fog_layers = []
	for spec: Array in [[90, 70, 70, 20, 60], [60, 90, 90, 14, 44]]:
		var h: int = spec[0]
		var n: int = spec[1]
		var amax: int = spec[2]
		var rmin: float = spec[3]
		var rmax: float = spec[4]
		var w := W * 2
		var col := mix(mix(th["fog"], th["sky_hor"], 0.45), PALE, 0.2)
		var img := _bake(w, h, func(p: QP) -> void:
			p.set_no_pen()
			for _i in n:
				var cx := rng.uniform(0, w)
				var cy := rng.uniform(h * 0.25, h * 0.8)
				var r := rng.uniform(rmin, rmax)
				var a := int(rng.uniform(0.35, 1.0) * amax)
				for ox: int in [-w, 0, w]:
					var g := QGrad.radial(cx + ox, cy, r)
					g.set_color_at(0, qc(col, a))
					g.set_color_at(1, qc(col, 0))
					p.set_brush(g)
					p.save()
					p.translate(cx + ox, cy)
					p.scale(1.0, 0.38)
					p.translate(-(cx + ox), -cy)
					p.draw_ellipse(cx + ox - r, cy - r, 2 * r, 2 * r)
					p.restore())
		fog_layers.append(img)


## Luftstraßen: Ketten aus Spinner-Lichtern in mehreren Höhen (fern = langsam/klein).
func _air() -> void:
	var n_lanes: int = 2 + int(th["spinners"])
	air = []
	for i in n_lanes:
		var is_far := i % 2 == 0
		var d := {}
		d["y"] = rng.uniform(26, fy * (0.45 if is_far else 0.62))
		d["speed"] = rng.uniform(8, 16) if is_far else rng.uniform(18, 34)
		d["dir"] = rng.choice([-1, 1])
		d["fac"] = FAR_F if is_far else MID_F
		d["n"] = rng.randint(5, 10)
		d["gap"] = rng.uniform(28, 70)
		d["ph"] = rng.uniform(0, 400)
		d["size"] = 1 if is_far else 2
		d["slope"] = rng.uniform(-0.03, 0.03)
		air.append(d)


# ---------------------------------------------------------------- Himmel
func _sky() -> void:
	sky = _bake(W, fy + 4, func(p: QP) -> void:
		var g := QGrad.linear(0, 0, 0, fy)
		g.set_color_at(0.0, qc(th["sky_top"]))
		g.set_color_at(0.55, qc(th["sky_mid"]))
		g.set_color_at(1.0, qc(th["sky_hor"]))
		p.fill_rect(0, 0, W, fy + 4, g))


func _clouds() -> void:
	cloud_layers = []
	var specs := [[8, 70, 150], [40, 120, 120]]
	for li in specs.size():
		var y0: float = specs[li][0]
		var y1: float = specs[li][1]
		var a: float = specs[li][2]
		var cw := W * 2
		var img := _bake(cw, 150, func(p: QP) -> void:
			p.set_no_pen()
			for _i in 90:
				var cx := rng.uniform(0, cw)
				var cy := rng.uniform(y0, y1)
				var rw := rng.uniform(30, 120)
				var rh := rng.uniform(4, 14)
				var lit := (cy - y0) / maxf(1, (y1 - y0))
				var col := mix(th["cloud"], th["cloud_lit"], lit * 0.8 * rng.uniform(0.5, 1.0))
				for ox: int in [-cw, 0, cw]:
					p.set_brush(qc(col, int(a * rng.uniform(0.4, 1.0))))
					p.draw_ellipse(cx + ox - rw / 2, cy - rh / 2, rw, rh))
		cloud_layers.append([img, 6.0 + li * 5.0, CLOUD_F * (1 + li)])


# ---------------------------------------------------------------- ferne Skyline
func _far() -> void:
	var lay := Layer.new(FAR_F, cam_min, cam_max, fy + 2)
	var base := fy + 2
	var fc: Array = th["far"]
	var far_h: Array = th["far_h"]
	var win: Array = th["win"]
	var lit_f: float = th["lit"]
	lay.img = _bake(lay.width, lay.height, func(p: QP) -> void:
		var x := 0
		while x < lay.width:
			var bw := rng.randint(14, 46)
			var bh := rng.randint(far_h[0], far_h[1])
			var top := base - bh
			var col := mul(fc, rng.uniform(0.75, 1.15))
			p.fill_rect(x, top, bw, bh, qc(col))
			if rng.random() < 0.4:
				p.fill_rect(x + Py.ifloordiv(bw, 4), top - rng.randint(3, 10), maxi(2, Py.ifloordiv(bw, 3)), 10, qc(col))
			if rng.random() < 0.3:
				var ax := x + rng.randint(2, bw - 2)
				var ah := rng.randint(6, 20)
				p.fill_rect(ax, top - ah, 1, ah, qc(col))
				blinks.append(["far", ax + lay.lmin, top - ah, CRIMSON, rng.random() * 3])
			for wy in range(top + 3, base - 2, 4):
				for wx in range(x + 2, x + bw - 1, 3):
					if rng.random() < lit_f * 0.35:
						p.fill_rect(wx, wy, 1, 1, qc(mix(col, _wchoice(rng, win), 0.45)))
			x += bw + rng.randint(-4, 6)
		# Raffinerie-Schlote mit Fackeln (Hades-Landschaft)
		if th["flames"]:
			for _i in int(lay.width / 260.0) + 2:
				var sx := rng.randint(0, lay.width)
				var sh := rng.randint(70, 140)
				p.fill_rect(sx, base - sh, 3, sh, qc(mul(fc, 0.7)))
				p.fill_rect(sx - 1, base - sh, 5, 2, qc(mul(fc, 0.6)))
				flames.append([sx + 1 + lay.lmin, base - sh - 1, rng.random() * 10, rng.uniform(0.7, 1.4)])
		if th["pyramid"]:
			# Zwei Tyrell-Pyramiden; die große steht in Richtung Zonenende
			for ws: Array in [[length * 0.85, 1.25], [length * 0.4, 0.8], [length * 0.05, 0.6]]:
				var wx: float = ws[0]
				var size: float = ws[1]
				var L := int(wx * FAR_F) - lay.lmin + Py.ifloordiv(W, 4)
				_pyramid(p, rng, L, base, int(230 * size), int(150 * size)))
	far = lay


func _pyramid(p: QP, rng_: PyRandom, cx: int, base: int, half: int, hgt: int) -> void:
	var col := mul(th["far"], 1.25)
	var poly := PackedVector2Array([Vector2(cx - half, base), Vector2(cx - half * 0.12, base - hgt),
		Vector2(cx + half * 0.12, base - hgt), Vector2(cx + half, base)])
	p.set_no_pen()
	p.set_brush(qc(col))
	p.draw_polygon(poly)
	# Schattenseite
	p.set_brush(qc(mul(col, 0.65)))
	p.draw_polygon(PackedVector2Array([Vector2(cx + half * 0.12, base - hgt), Vector2(cx + half, base),
		Vector2(cx + half * 0.35, base)]))
	# Fensterreihen: goldene Punkte in den Terrassen
	for row in range(4, hgt - 2, 4):
		var y := base - row
		var f := float(row) / hgt
		var hw := half * (1 - f) + half * 0.12 * f
		for x in range(int(cx - hw) + 2, int(cx + hw) - 1, 3):
			if rng_.random() < 0.35:
				p.fill_rect(x, y, 1, 1, qc(AMBER if rng_.random() < 0.7 else PALE))
	blinks.append(["far", cx + far_lmin_hint(), base - hgt - 2, AMBER, 0.0])


func far_lmin_hint() -> int:
	return int(cam_min * FAR_F - W * 0.5 - 40)


# ---------------------------------------------------------------- mittlere Skyline
func _mid() -> void:
	var lay := Layer.new(MID_F, cam_min, cam_max, fy + 2)
	var base := fy + 2
	var mc: Array = th["mid"]
	var mid_h: Array = th["mid_h"]
	var win: Array = th["win"]
	var lit_f: float = th["lit"]
	var n_bb: int = th["billboards"]
	lay.img = _bake(lay.width, lay.height, func(p: QP) -> void:
		var x := 0
		var tops: Array = []
		while x < lay.width:
			var bw := rng.randint(24, 70)
			var bh := rng.randint(mid_h[0], mid_h[1])
			var top := base - bh
			var col := mul(mc, rng.uniform(0.8, 1.25))
			p.fill_rect(x, top, bw, bh, qc(col))
			p.fill_rect(x, top, 1, bh, qc(mul(col, 1.35)))
			# Stufen (Wedding-cake)
			var top2: int
			if rng.random() < 0.45:
				var sw := int(bw * rng.uniform(0.4, 0.7))
				var sh := rng.randint(10, 40)
				p.fill_rect(x + Py.ifloordiv(bw - sw, 2), top - sh, sw, sh, qc(col))
				top2 = top - sh
			else:
				top2 = top
			# Fenster
			var wc: Array = _wchoice(rng, win)
			for wy in range(top + 4, base - 2, 4):
				for wx in range(x + 3, x + bw - 2, 3):
					var r := rng.random()
					if r < lit_f * 0.8:
						var wcol: Array = wc if rng.random() < 0.7 else _wchoice(rng, win)
						p.fill_rect(wx, wy, 1, 2, qc(mix(col, wcol, 0.6)))
			# Antenne + Warnlicht
			if rng.random() < 0.55:
				var ax := x + rng.randint(3, bw - 3)
				var ah := rng.randint(8, 26)
				p.fill_rect(ax, top2 - ah, 1, ah, qc(mul(col, 0.9)))
				var bc: Array = CRIMSON if rng.random() < 0.7 else MAGENTA
				blinks.append(["mid", ax + lay.lmin, top2 - ah, bc, rng.random() * 3])
			tops.append([x, top2, bw])
			# Holo-Billboards
			if n_bb and rng.random() < 0.09 * n_bb and bh > 80:
				var bb: Array = rng.choice([[30, 40], [40, 28], [24, 52], [52, 30]])
				var bbw: int = bb[0]
				var bbh: int = bb[1]
				var bbx := x + Py.ifloordiv(bw - bbw, 2)
				var bby := top + rng.randint(6, maxi(7, Py.ifloordiv(bh, 3)))
				p.fill_rect(bbx - 1, bby - 1, bbw + 2, bbh + 2, qc(VOID))
				billboards.append([bbx + lay.lmin, bby, bbw, bbh, rng.randint(0, 99)])
			x += bw + rng.randint(-6, 10)
		if th["cranes"]:
			for _i in int(lay.width / 220.0) + 1:
				var cx := rng.randint(0, lay.width)
				_crane(p, lay, rng, cx, base)
		# Suchscheinwerfer-Ursprünge (von Dächern, schwenken über den Himmel)
		for _i in maxi(1, int(th["searchlights"])) * int(lay.width / 520.0 + 1):
			var sx := rng.randint(0, lay.width) + lay.lmin
			var sy := base - rng.randint(30, 110)
			searchlights.append([sx, sy, rng.uniform(0.18, 0.45), rng.random() * 6.28]))
	mid = lay


func _crane(p: QP, lay: Layer, rng_: PyRandom, cx: int, base: int) -> void:
	var col := qc(mul(th["mid"], 0.75))
	var h := rng_.randint(90, 140)
	p.fill_rect(cx, base - h, 4, h, col)
	p.fill_rect(cx - 50, base - h, 90, 3, col)
	p.fill_rect(cx - 50, base - h + 3, 10, 6, col)
	p.set_pen(col, 1.0)
	for i in range(0, h, 8):
		p.draw_line(cx, base - i, cx + 4, base - i - 8)
	p.draw_line(cx + 2, base - h - 12, cx - 48, base - h)
	p.draw_line(cx + 2, base - h - 12, cx + 38, base - h)
	p.fill_rect(cx + 1, base - h - 14, 2, 14, col)
	var hook := rng_.randint(cx - 40, cx + 30)
	p.draw_line(hook, base - h + 3, hook, base - h + rng_.randint(20, 60))
	p.set_no_pen()
	blinks.append(["mid", cx + 2 + lay.lmin, base - h - 15, CRIMSON, rng_.random() * 3])
	blinks.append(["mid", cx - 48 + lay.lmin, base - h - 1, CRIMSON, rng_.random() * 3])


# ---------------------------------------------------------------- Häuserfront (TEIL 2/3)
func _facade() -> void:
	pass  # TEIL 2/3


func _win_grid(_p: QP, _e: Variant, _rng: PyRandom, _x: float, _top: float, _bw: float, _bot: float,
		_fh: float, _ww: float, _wh: float, _gap: float, _dark: float, _col_hint: Variant = null) -> void:
	pass  # TEIL 2/3


func _building(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _x: float, _bw: float, _bh: float,
		_base: float) -> void:
	pass  # TEIL 2/3


func _shopfront(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _x: float, _bw: float, _base: float,
		_sh: float, _col: Array, _hi: Array) -> void:
	pass  # TEIL 2/3


func _shop(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _x: float, _w: float, _base: float,
		_sh: float, _col: Array, _hi: Array, _kind: String) -> void:
	pass  # TEIL 2/3


func _street_props(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _base: float) -> void:
	pass  # TEIL 2/3


func _ramen_booth(_p: QP, _e: Variant, _fac: Variant, _x: float, _base: float) -> void:
	pass  # TEIL 2/3


func _holos() -> void:
	pass  # TEIL 2/3


func _alley(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _x: float, _bw: float, _base: float) -> void:
	pass  # TEIL 2/3


func _containers(_p: QP, _e: Variant, _fac: Variant, _rng: PyRandom, _x: float, _bw: float, _base: float) -> void:
	pass  # TEIL 2/3


func _exit_gate(_p: QP, _e: Variant, _fac: Variant, _x: float, _base: float) -> void:
	pass  # TEIL 2/3


func _lamp_post(_p: QP, _x: float, _y: float, _base: float, _arm: Variant) -> void:
	pass  # TEIL 2/3


func _ground() -> void:
	pass  # TEIL 2/3


func draw_ground(_p: QP, _cam: float) -> void:
	pass  # TEIL 2/3
