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
##   QImage + QPainter        -> City.baker.bake(w, h, func(p: QP): ...)
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
	var mir := baker.bake(w, h, func(p: QP) -> void:
		p.translate(0, h)
		p.scale(1.0, -1.0)
		p.draw_image(Rect2(0, 0, w, h), img))
	var layers: Array = [mir]                           # 0 = scharf
	for hw: Array in [[3, 2], [6, 3], [12, 5]]:         # 1 mild, 2 mittel, 3 stark verwischt
		var hf: int = hw[0]
		var wf: int = hw[1]
		var sw := maxi(1, Py.ifloordiv(w, wf))
		var sh := maxi(1, Py.ifloordiv(h, hf))
		var small := baker.bake(sw, sh, func(p: QP) -> void:
			p.set_smooth(true)
			p.draw_image(Rect2(0, 0, sw, sh), mir))
		var big := baker.bake(w, h, func(p: QP) -> void:
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
		var tmp := baker.bake(w, h, func(t: QP) -> void:
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
	return baker.bake(w, h, func(op: QP) -> void:
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
		img = null    # wird vom Erzeuger gebacken (City.baker.bake(width, height, ...))

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
