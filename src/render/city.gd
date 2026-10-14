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
const RED := DCity.RED
const NBLUE := DCity.NBLUE
const GREEN := DCity.GREEN
const SODIUM := DCity.SODIUM
const ASH := DCity.ASH
const PALE := DCity.PALE
const WHITE := DCity.WHITE
const SLATE := DCity.SLATE
const TEAL := DCity.TEAL
const CYAN := DCity.CYAN
const MAGENTA := DCity.MAGENTA
const AMBER := DCity.AMBER

## Bildbreite zur Laufzeit (View.W: 640 ohne View.setup, sonst 480..960); Höhe fest.
## Alle Verwendungen meinen die BILDSCHIRMBREITE (Mitte, Ränder, Kulling, Breitenschleifen,
## Viewport-/Kachelgrößen); der Maßstab hängt an Persp.PPU_NEAR (Basisbreite 640).
static var W: int:
	get: return View.W
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


## Zwei Bilder in EINEM Durchlauf (Fassade + Leuchtschicht). Der draw-Callback
## zeichnet p und e im selben Schritt, damit die Zufallsreihenfolge exakt bleibt.
static func _bake_pair(w: int, h: int, draw: Callable) -> Array:
	var out: Array = []
	var pis: Array = []
	for _i in 2:
		var vp := SubViewport.new()
		vp.size = Vector2i(maxi(1, w), maxi(1, h))
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		var host := Node2D.new()
		vp.add_child(host)
		baker.add_child(vp)
		var q := QPExact.new(host.get_canvas_item())
		q.begin()
		pis.append(q)
		baker._bakes.append(vp)
		out.append(QImg.new(vp.get_texture(), Rect2(0, 0, w, h)))
		out[-1].set_meta("vp", vp)
	draw.call(pis[0], pis[1])
	pis[0].end()
	pis[1].end()
	return out


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
	# Blur-Stufen: Qt verkleinert mit Box-Filter (flächige Mittelung). Godot kann das
	# nicht auf der GPU (bilineares Sampling unterabtastet -> Rand bleibt zu scharf),
	# daher CPU-Resampling (Antialiasing-Filter) und danach bilineares Hochskalieren.
	var layers: Array = [mir]                           # 0 = scharf
	for hw: Array in [[3, 2], [6, 3], [12, 5]]:         # 1 mild, 2 mittel, 3 stark verwischt
		var hf: int = hw[0]
		var wf: int = hw[1]
		var sw := maxi(1, Py.ifloordiv(w, wf))
		var sh := maxi(1, Py.ifloordiv(h, hf))
		var small_tex := _box_down_gpu(mir.tex, w, h, sw, sh)
		var big := _bake(w, h, func(p: QP) -> void:
			p.set_smooth(true)
			p.draw_texture(Rect2(0, 0, w, h), small_tex))
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


## Flächige Mittelung (Box-Filter) wie Qts SmoothTransformation beim Verkleinern -
## auf der GPU, weil ein Readback mitten im Bake noch leer wäre. Der Shader mittelt
## ein Gitter über die Quellfläche JEDES Zielpixels (premultipliziert, linear).
const BOX_SHADER := """
shader_type canvas_item;
render_mode blend_disabled, unshaded;
uniform sampler2D src : filter_nearest, repeat_disable;
uniform vec2 box;
uniform vec2 srcsize;
void fragment() {
	vec2 sp = UV * srcsize;
	vec2 start = sp - box * 0.5;
	vec4 acc = vec4(0.0);
	const int N = 6;
	for (int j = 0; j < N; j++) {
		for (int i = 0; i < N; i++) {
			vec2 o = (vec2(float(i), float(j)) + 0.5) / float(N);
			acc += texture(src, (start + o * box) / srcsize);
		}
	}
	COLOR = acc / float(N * N);
}
"""


static var _box_shader: Shader


static func _box_down_gpu(src: Texture2D, w: int, h: int, sw: int, sh: int) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = Vector2i(maxi(1, sw), maxi(1, sh))
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	var cr := ColorRect.new()
	cr.position = Vector2.ZERO
	cr.size = Vector2(sw, sh)
	var mat := ShaderMaterial.new()
	if _box_shader == null:           # einmal kompilieren, nicht je Aufruf
		_box_shader = Shader.new()
		_box_shader.code = BOX_SHADER
	mat.shader = _box_shader
	mat.set_shader_parameter("src", src)
	mat.set_shader_parameter("box", Vector2(float(w) / sw, float(h) / sh))
	mat.set_shader_parameter("srcsize", Vector2(w, h))
	cr.material = mat
	vp.add_child(cr)
	baker.add_child(vp)
	return vp.get_texture()


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
static func _dragon_sign(_unused_rng: PyRandom) -> Array:
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
	var arm: float
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
var _rng: PyRandom
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
var fires: Array = []                # Feuertonnen [L, y, s, seed] (Props)
var walks: Array = []                # Fußgängerampeln [L, y, ph, sz] (Props)
var spans: Array = []                # Überbauten (Brücken / Überhänge)
var wires: Array = []                # Kabel quer über die Straße
var sebastian_span: Array = []       # [x0, x1] im Fassadenbild (Tyrell-Ende)
var rng_deco: PyRandom
var _derelict := false
var exit_x: float
var exit_L: int = 0
var ground_y0: int = 0
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
	_rng = PyRandom.new(seed_ * 7919 + zone_index * 104729)
	cam_min = -120.0
	cam_max = length + 220.0
	fy = int(Persp.FACADE_Y)
	rng_deco = PyRandom.new(seed_ * 523 + zone_index * 7 + 1)
	exit_x = length
	_sky()
	_clouds()
	_far()
	_mid()
	_spans()
	_facade()
	_holos()
	_wires()
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
			var cx := _rng.uniform(0, w)
			var cy := _rng.uniform(h * 0.15, h * 0.9)
			var r := _rng.uniform(70, 180)
			var a := int(_rng.uniform(0.55, 1.0) * 150)
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
				var cx := _rng.uniform(0, w)
				var cy := _rng.uniform(h * 0.25, h * 0.8)
				var r := _rng.uniform(rmin, rmax)
				var a := int(_rng.uniform(0.35, 1.0) * amax)
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
		d["y"] = _rng.uniform(26, fy * (0.45 if is_far else 0.62))
		d["speed"] = _rng.uniform(8, 16) if is_far else _rng.uniform(18, 34)
		d["dir"] = _rng.choice([-1, 1])
		d["fac"] = FAR_F if is_far else MID_F
		d["n"] = _rng.randint(5, 10)
		d["gap"] = _rng.uniform(28, 70)
		d["ph"] = _rng.uniform(0, 400)
		d["size"] = 1 if is_far else 2
		d["slope"] = _rng.uniform(-0.03, 0.03)
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
				var cx := _rng.uniform(0, cw)
				var cy := _rng.uniform(y0, y1)
				var rw := _rng.uniform(30, 120)
				var rh := _rng.uniform(4, 14)
				var lit := (cy - y0) / maxf(1, (y1 - y0))
				var col := mix(th["cloud"], th["cloud_lit"], lit * 0.8 * _rng.uniform(0.5, 1.0))
				for ox: int in [-cw, 0, cw]:
					p.set_brush(qc(col, int(a * _rng.uniform(0.4, 1.0))))
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
			var bw := _rng.randint(14, 46)
			var bh := _rng.randint(far_h[0], far_h[1])
			var top := base - bh
			var col := mul(fc, _rng.uniform(0.75, 1.15))
			p.fill_rect(x, top, bw, bh, qc(col))
			if _rng.random() < 0.4:
				p.fill_rect(x + Py.ifloordiv(bw, 4), top - _rng.randint(3, 10), maxi(2, Py.ifloordiv(bw, 3)), 10, qc(col))
			if _rng.random() < 0.3:
				var ax := x + _rng.randint(2, bw - 2)
				var ah := _rng.randint(6, 20)
				p.fill_rect(ax, top - ah, 1, ah, qc(col))
				blinks.append(["far", ax + lay.lmin, top - ah, CRIMSON, _rng.random() * 3])
			for wy in range(top + 3, base - 2, 4):
				for wx in range(x + 2, x + bw - 1, 3):
					if _rng.random() < lit_f * 0.35:
						p.fill_rect(wx, wy, 1, 1, qc(mix(col, _wchoice(_rng, win), 0.45)))
			x += bw + _rng.randint(-4, 6)
		# Raffinerie-Schlote mit Fackeln (Hades-Landschaft)
		if th["flames"]:
			for _i in int(lay.width / 260.0) + 2:
				var sx := _rng.randint(0, lay.width)
				var sh := _rng.randint(70, 140)
				p.fill_rect(sx, base - sh, 3, sh, qc(mul(fc, 0.7)))
				p.fill_rect(sx - 1, base - sh, 5, 2, qc(mul(fc, 0.6)))
				flames.append([sx + 1 + lay.lmin, base - sh - 1, _rng.random() * 10, _rng.uniform(0.7, 1.4)])
		if th["pyramid"]:
			# Zwei Tyrell-Pyramiden; die große steht in Richtung Zonenende
			for ws: Array in [[length * 0.85, 1.25], [length * 0.4, 0.8], [length * 0.05, 0.6]]:
				var wx: float = ws[0]
				var size: float = ws[1]
				var L := int(wx * FAR_F) - lay.lmin + Py.ifloordiv(W, 4)
				_pyramid(p, _rng, L, base, int(230 * size), int(150 * size)))
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
			var bw := _rng.randint(24, 70)
			var bh := _rng.randint(mid_h[0], mid_h[1])
			var top := base - bh
			var col := mul(mc, _rng.uniform(0.8, 1.25))
			p.fill_rect(x, top, bw, bh, qc(col))
			p.fill_rect(x, top, 1, bh, qc(mul(col, 1.35)))
			# Stufen (Wedding-cake)
			var top2: int
			if _rng.random() < 0.45:
				var sw := int(bw * _rng.uniform(0.4, 0.7))
				var sh := _rng.randint(10, 40)
				p.fill_rect(x + Py.ifloordiv(bw - sw, 2), top - sh, sw, sh, qc(col))
				top2 = top - sh
			else:
				top2 = top
			# Fenster
			var wc: Array = _wchoice(_rng, win)
			for wy in range(top + 4, base - 2, 4):
				for wx in range(x + 3, x + bw - 2, 3):
					var r := _rng.random()
					if r < lit_f * 0.8:
						var wcol: Array = wc if _rng.random() < 0.7 else _wchoice(_rng, win)
						p.fill_rect(wx, wy, 1, 2, qc(mix(col, wcol, 0.6)))
			# Antenne + Warnlicht
			if _rng.random() < 0.55:
				var ax := x + _rng.randint(3, bw - 3)
				var ah := _rng.randint(8, 26)
				p.fill_rect(ax, top2 - ah, 1, ah, qc(mul(col, 0.9)))
				var bc: Array = CRIMSON if _rng.random() < 0.7 else MAGENTA
				blinks.append(["mid", ax + lay.lmin, top2 - ah, bc, _rng.random() * 3])
			tops.append([x, top2, bw])
			# Holo-Billboards
			if n_bb and _rng.random() < 0.09 * n_bb and bh > 80:
				var bb: Array = _rng.choice([[30, 40], [40, 28], [24, 52], [52, 30]])
				var bbw: int = bb[0]
				var bbh: int = bb[1]
				var bbx := x + Py.ifloordiv(bw - bbw, 2)
				var bby := top + _rng.randint(6, maxi(7, Py.ifloordiv(bh, 3)))
				p.fill_rect(bbx - 1, bby - 1, bbw + 2, bbh + 2, qc(VOID))
				billboards.append([bbx + lay.lmin, bby, bbw, bbh, _rng.randint(0, 99)])
			x += bw + _rng.randint(-6, 10)
		if th["cranes"]:
			for _i in int(lay.width / 220.0) + 1:
				var cx := _rng.randint(0, lay.width)
				_crane(p, lay, _rng, cx, base)
		# Suchscheinwerfer-Ursprünge (von Dächern, schwenken über den Himmel)
		for _i in maxi(1, int(th["searchlights"])) * int(lay.width / 520.0 + 1):
			var sx := _rng.randint(0, lay.width) + lay.lmin
			var sy := base - _rng.randint(30, 110)
			searchlights.append([sx, sy, _rng.uniform(0.18, 0.45), _rng.random() * 6.28]))
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


# ---------------------------------------------------------------- Häuserfront
func _facade() -> void:
	var fac := Layer.new(Persp.FACADE_PPU, cam_min, cam_max, fy + 1)
	var base := fy + 1
	var style: String = th["style"]
	exit_L = int(exit_x * fac.factor) - fac.lmin
	var gate_l := exit_L - 60
	var gate_r := exit_L + 60
	var gate_done := false
	var pair := _bake_pair(fac.width, fy + 1, func(p: QP, e: QP) -> void:
		var x := 0
		while x < fac.width:
			var r := _rng.random()
			var alley := r < 0.12
			var bw := _rng.randint(18, 40) if alley else (
				_rng.randint(60, 150) if style != "harbor" else _rng.randint(50, 110))
			# Ausgang/Tor am Zonenende frei halten
			if not gate_done and x + bw > gate_l:
				bw = gate_l - x
				if bw >= 12:
					_building(p, e, fac, _rng, x, bw, _rng.randint(int(th["h_range"][0]), int(th["h_range"][1])), base)
				_exit_gate(p, e, fac, gate_l, base)
				gate_done = true
				x = gate_r
				continue
			if alley:
				_alley(p, e, fac, _rng, x, bw, base)
			else:
				var bh := _rng.randint(int(th["h_range"][0]), int(th["h_range"][1]))
				if style == "harbor" and _rng.random() < 0.5:
					_containers(p, e, fac, _rng, x, bw, base)
				else:
					_building(p, e, fac, _rng, x, bw, bh, base)
			x += bw
		# Laternen
		var lx := cam_min + _rng.uniform(20, 80)
		while lx < cam_max:
			var L := lx * fac.factor
			var arm := _rng.randint(10, 18)
			var y := base - _rng.randint(46, 60)
			if String(th["style"]) in ["market", "blocks", "industrial"] and rng_deco.random() < 0.45:
				# V-Doppelleuchte wie im Film: zwei schräge Arme, zwei Köpfe
				var va := _rng.randint(9, 13)
				var vcol := qc([30, 32, 36])
				var x_ := int(fac.lx(L))
				p.fill_rect(x_, y + 8, 2, base - y - 8, vcol)
				p.set_pen(vcol, 2.0)
				p.draw_line(x_ + 1, y + 8, x_ + va, y + 1)
				p.draw_line(x_ + 1, y + 8, x_ - va + 2, y + 1)
				p.set_no_pen()
				var sd := _rng.randint(0, 9999)
				var fl := _rng.random() < 0.18
				lamps.append(Lamp.new(lx, L, y, va, th["lamp"], sd, fl))
				lamps.append(Lamp.new(lx, L, y, -va, th["lamp"], sd + 1, false))
			else:
				_lamp_post(p, fac.lx(L), y, base, arm)
				lamps.append(Lamp.new(lx, L, y, arm, th["lamp"], _rng.randint(0, 9999), _rng.random() < 0.18))
			lx += _rng.uniform(float(th["lamp_every"][0]), float(th["lamp_every"][1]))
		_street_props(p, e, fac, _rng, base)
		if zone == 4:
			Props.sebastian(self, p, e, fac, base)
		Props.furnish(self, p, e, fac, base)
		# Nudelstände an den deterministischen Positionen (Herzen auffüllen)
		for rx: float in Procgen.ramen_positions(length, seed_, zone):
			var blx := fac.lx(rx * fac.factor) - 88
			if 30 <= blx and blx <= fac.width - 200:
				_ramen_booth(p, e, fac, int(blx), base))
	fac.img = pair[0]
	facade = fac
	facade_emit = pair[1]
	# Nasse Fahrbahn reflektiert progressiv: am Kontaktpunkt fast scharf, nach unten
	# zunehmend verwischt und blasser. Körper (Fenster/Fassade) und Neon getrennt.
	facade_refl_body = soft_reflection(fac.img)
	facade_refl = soft_reflection(facade_emit)


func _win_grid(p: QP, e: QP, rng: PyRandom, x: float, top: float, bw: float, bot: float,
		fh: float, ww: float, wh: float, gap: float, dark: Array, col_hint: Variant = null) -> void:
	var lit_p: float = th["lit"]
	var win: Array = th["win"]
	var wc: Array = col_hint if col_hint != null else _wchoice(rng, win)
	var y := top + 6
	while y + wh < bot - 4:
		var xx := x + gap
		while xx + ww < x + bw - gap + 1:
			var r := rng.random()
			if r < lit_p:
				var c: Array = wc if rng.random() < 0.75 else _wchoice(rng, win)
				c = mul(c, rng.uniform(0.55, 0.95))
				p.fill_rect(xx, y, ww, wh, qc(c))
				e.fill_rect(xx, y, ww, wh, qc(mul(c, 0.55)))
				if rng.random() < 0.3:   # Jalousie / Silhouette
					p.fill_rect(xx, y + Py.ifloordiv(int(wh), 2), ww, 1, qc(mul(c, 0.5)))
				if rng.random() < 0.04:
					tvs.append([xx, y, ww, wh, rng.randint(0, 999)])
			else:
				p.fill_rect(xx, y, ww, wh, qc(dark))
				p.fill_rect(xx, y, ww, 1, qc(mul(dark, 1.6)))
			xx += ww + gap
		y += fh


func _building(p: QP, e: QP, fac: Layer, rng: PyRandom, x: float, bw: float, bh: float, base: float) -> void:
	var style: String = th["style"]
	var top := base - bh
	var col := mul(th["building"], rng.uniform(0.8, 1.2))
	var hi := mul(th["building_hi"], rng.uniform(0.85, 1.1))
	var look := Props.facade_look(self, rng_deco) if bw >= 40 and bh >= 70 else "plain"
	# Tyrell: zum Ende hin altes, verlassenes Viertel (Sebastians Straße)
	_derelict = zone == 4 and (fac.lmin + x) / fac.factor > length * (Config.EMPTY_FROM - 0.04)
	if _derelict:
		style = "blocks"
		look = "old" if bw >= 30 else "plain"
	if look == "old":
		col = Props.old_stone(col)
	var g := QGrad.linear(0, top, 0, base)
	g.set_color_at(0, qc(mul(col, 0.8)))
	g.set_color_at(1, qc(mix(col, hi, 0.6)))
	p.fill_rect(x, top, bw, bh, g)
	# Kanten / Gesims
	p.fill_rect(x, top, bw, 2, qc(hi))
	p.fill_rect(x, top, 1, bh, qc(mul(hi, 0.9)))
	p.fill_rect(x + bw - 1, top, 1, bh, qc(mul(col, 0.5)))
	var dark := mul(col, 0.55)
	var shop_h := rng.randint(32, 40) if style != "tyrell" else rng.randint(36, 46)
	if look == "modern":
		Props.modern(p, e, rng_deco, th, x, top, bw, bh, base, shop_h, col, hi)
	elif style == "industrial":
		_win_grid(p, e, rng, x, top, bw, base - shop_h, 14, 6, 3, 5, dark)
		# Rolltor
		var dw := int(bw * rng.uniform(0.35, 0.55))
		var dx := x + rng.randint(4, int(bw - dw - 4))
		p.fill_rect(dx, base - shop_h + 4, dw, shop_h - 4, qc(mul(hi, 0.8)))
		for yy in range(int(base - shop_h + 5), int(base), 2):
			p.fill_rect(dx, yy, dw, 1, qc(mul(hi, 0.55)))
		if rng.random() < 0.5:
			p.fill_rect(dx, base - shop_h + 2, dw, 2, qc(AMBER if rng.random() < 0.5 else [90, 80, 30]))
	elif style == "blocks":
		_win_grid(p, e, rng, x, top, bw, base - shop_h, 11, 4, 5, 3, dark)
		# Balkone
		for yy in range(int(top + 14), int(base - shop_h - 6), 22):
			if rng.random() < 0.6:
				p.fill_rect(x + 3, yy, bw - 6, 2, qc(mul(hi, 1.1)))
				for bx in range(int(x + 4), int(x + bw - 4), 3):
					p.fill_rect(bx, yy - 4, 1, 4, qc(mul(hi, 0.9)))
				if rng.random() < 0.3:  # Wäscheleine
					for bx in range(int(x + 6), int(x + bw - 6), 5):
						p.fill_rect(bx, yy - 7, 2, 3, qc(rng.choice([ASH, CRIMSON, BLUE, PALE])))
		# Satellitenschüsseln
		var sd_lo := top + 8
		var sd_hi := base - shop_h - 10
		var nd := rng.randint(0, 3) if (sd_hi > sd_lo and bw > 10) else 0
		for _i in nd:
			var sx := x + rng.randint(4, int(bw - 6))
			var sy := rng.randint(int(sd_lo), int(sd_hi))
			p.set_no_pen()
			p.set_brush(qc(SLATE))
			p.draw_ellipse(sx, sy, 5, 5)
	elif style == "tyrell" and not _derelict:
		# Monolith: Lichtschlitze statt Fenster
		var step := rng.randint(18, 30)
		for xx in range(int(x + 8), int(x + bw - 8), step):
			p.fill_rect(xx, top + 10, 1, bh - shop_h - 16, qc(mul(PALE, 0.28)))
			e.fill_rect(xx, top + 10, 1, bh - shop_h - 16, qc(mul(PALE, 0.15)))
		var yy := top + rng.randint(14, 30)
		p.fill_rect(x + 2, yy, bw - 4, 1, qc(mul(AMBER, 0.55)))
		e.fill_rect(x + 2, yy, bw - 4, 1, qc(mul(AMBER, 0.35)))
	else:
		_win_grid(p, e, rng, x, top, bw, base - shop_h, rng.choice([12, 14, 16]), rng.randint(4, 6),
			rng.randint(4, 7), rng.randint(3, 5), dark)
	if look == "old":
		Props.ornament(p, e, rng_deco, th, x, top, bw, bh, base, shop_h, col, hi)
	# Feuerleiter
	if look != "modern" and style in ["market", "blocks", "industrial"] and rng.random() < 0.35 and bh > 90:
		var fx := x + rng.randint(6, maxi(7, int(bw - 30)))
		var fw := 22
		p.set_pen(qc(mul(hi, 0.75)), 1.0)
		for yy in range(int(top + 16), int(base - shop_h - 4), 18):
			p.draw_line(fx, yy, fx + fw, yy)
			p.draw_line(fx, yy, fx, yy - 6)
			p.draw_line(fx + fw, yy, fx + fw, yy - 6)
			p.draw_line(fx + 2, yy, fx + fw - 2, yy + 18)
		p.set_no_pen()
	# Klimageräte, Rohre
	var ay_lo := top + 6
	var ay_hi := base - shop_h - 8
	var na := rng.randint(0, 3) if (ay_hi > ay_lo and bw > 12 and look != "modern") else 0
	for _i in na:
		var ax := x + rng.randint(2, int(bw - 10))
		var ay := rng.randint(int(ay_lo), int(ay_hi))
		p.fill_rect(ax, ay, 8, 6, qc(mul(hi, 0.9)))
		p.fill_rect(ax + 1, ay + 1, 6, 4, qc(mul(col, 0.7)))
		for gx in range(int(ax + 2), int(ax + 7), 2):
			p.fill_rect(gx, ay + 1, 1, 4, qc(mul(hi, 0.6)))
		if rng.random() < 0.35:
			vents.append([fac.lmin + ax + 4, ay - 1])
	if rng.random() < 0.4:
		var px_ := x + rng.randint(2, int(bw - 4))
		p.fill_rect(px_, top + 4, 2, bh - 6, qc(mul(hi, 0.7)))
	# Erdgeschoss
	_shopfront(p, e, fac, rng, x, bw, base, shop_h, col, hi)
	# Dach: Tank / Antenne / Schild
	if rng.random() < 0.3 and top > 10:
		var tx := x + rng.randint(4, maxi(5, int(bw - 20)))
		p.fill_rect(tx, top - 12, 14, 12, qc(mul(col, 0.9)))
		p.fill_rect(tx + 2, top - 2, 2, 2, qc(mul(col, 0.6)))
		p.fill_rect(tx + 10, top - 2, 2, 2, qc(mul(col, 0.6)))
	# Neon-Schilder
	var n_signs := 0
	var rate: float = th["sign_rate"]
	while rng.random() < rate * (0.85 if n_signs == 0 else 0.45) and n_signs < 4:
		n_signs += 1
		var color: Array = rng.choice(th["neon"])
		var kind: String = rng.choice(["vertical", "vertical", "text", "text", "arrow"]) if style == "market" else \
			rng.choice(["text", "text", "vertical", "arrow"])
		var word: String = rng.choice(th["words"])
		var sg := _make_sign(rng, color, kind, word)
		var on: QImg = sg[0]
		var off: QImg = sg[1]
		var em: QImg = sg[2]
		if on.width() > bw + 30:
			continue
		var sx := x + rng.randint(-6, maxi(-5, int(bw - on.width() + 6)))
		var sy_min := maxf(top + 4, 4)
		var sy_max := base - shop_h - on.height() - 2
		var sy: float
		if sy_max <= sy_min:
			sy = base - shop_h - on.height() + 2
		else:
			sy = rng.randint(int(sy_min), int(sy_max))
		var mode: String = rng.choice(["steady", "steady", "steady", "buzz", "blink", "dying"]) if style != "tyrell" \
			else "steady"
		# Halterung
		p.fill_rect(sx + Py.ifloordiv(on.width(), 2), sy - 3, 1, 3, qc(SLATE))
		signs.append(Sign.new(fac.lmin + sx, sy, on, off, em, mode, rng.randint(0, 99999), color))
	# Lampions (Markt)
	if style == "market" and rng.random() < 0.4:
		var ly := base - shop_h - rng.randint(2, 8)
		p.set_pen(qc(SLATE), 1.0)
		p.draw_line(x, ly - 3, x + bw, ly - 1)
		p.set_no_pen()
		var lstep := rng.randint(8, 14)
		for k in range(int(x + 4), int(x + bw - 2), lstep):
			lanterns.append([fac.lmin + k, ly + 1, rng.choice([CRIMSON, AMBER, MAGENTA]), rng.random() * 6])


func _shopfront(p: QP, e: QP, fac: Layer, rng: PyRandom, x: float, bw: float, base: float,
		sh: float, col: Array, hi: Array) -> void:
	var top := base - sh
	p.fill_rect(x, top, bw, sh, qc(mul(col, 0.7)))
	p.fill_rect(x, top, bw, 2, qc(mul(hi, 1.2)))
	var style: String = "derelict" if _derelict else String(th["style"])
	var kinds: Variant = SHOP_KINDS.get(style)
	if kinds != null:
		# Mehrere Läden nebeneinander, wenn das Haus breit genug ist
		var xx := x
		while xx < x + bw - 24:
			var sw := minf(x + bw - xx, float(rng.randint(46, 84)))
			if x + bw - (xx + sw) < 24:
				sw = x + bw - xx
			_shop(p, e, fac, rng, xx, sw, base, sh, col, hi, String(_wchoice(rng, kinds)))
			xx += sw
		return
	if style == "industrial":
		return
	# Schaufenster
	if rng.random() < 0.85:
		var ww := int(bw * rng.uniform(0.35, 0.6))
		var wx := x + rng.randint(3, maxi(4, int(bw - ww - 14)))
		var wc := mul(_wchoice(rng, th["win"]), rng.uniform(0.45, 0.8)) if rng.random() < 0.75 else mul(col, 0.4)
		p.fill_rect(wx, top + 6, ww, sh - 8, qc(wc))
		e.fill_rect(wx, top + 6, ww, sh - 8, qc(mul(wc, 0.7)))
		# Ware / Silhouetten
		var kstep := rng.randint(3, 6)
		for k in range(int(wx + 2), int(wx + ww - 2), kstep):
			var hgt := rng.randint(2, 8)
			p.fill_rect(k, base - 2 - hgt, 2, hgt, qc(mul(wc, 0.35)))
		if rng.random() < 0.5:
			for k in range(int(wx + 3), int(wx + ww - 3), 5):
				p.fill_rect(k, top + 7, 1, rng.randint(2, 5), qc(mul(wc, 0.5)))
		# Tür
		var dx := wx + ww + 3
		if dx + 8 < x + bw:
			p.fill_rect(dx, top + 8, 8, sh - 8, qc(mul(col, 0.35)))
			p.fill_rect(dx, top + 8, 8, 1, qc(mul(wc, 1.2)))
	else:
		# Rolladen
		for yy in range(int(top + 4), int(base), 2):
			p.fill_rect(x + 4, yy, bw - 8, 1, qc(mul(hi, 0.7 if yy % 4 else 0.5)))
	# Markise
	if rng.random() < (0.55 if style == "market" else 0.25):
		var ac: Array = rng.choice(th["neon"] + [SLATE, CRIMSON])
		var aw := int(bw * rng.uniform(0.5, 0.9))
		var ax := x + Py.ifloordiv(int(bw - aw), 2)
		p.set_brush(qc(mul(ac, 0.45)))
		p.set_no_pen()
		p.draw_polygon(PackedVector2Array([Vector2(ax, top), Vector2(ax + aw, top),
			Vector2(ax + aw + 3, top + 7), Vector2(ax - 3, top + 7)]))
		for k in range(int(ax), int(ax + aw), 6):
			p.fill_rect(k, top + 1, 3, 6, qc(mul(ac, 0.3)))
		p.fill_rect(ax - 3, top + 6, aw + 6, 1, qc(mul(ac, 0.8)))


func _shop(p: QP, e: QP, fac: Layer, rng: PyRandom, x: float, w: float, base: float,
		sh: float, col: Array, hi: Array, kind: String) -> void:
	## Ein Laden im Erdgeschoss: Schild, Schaufenster mit Innenleben, Tür.
	var top := base - sh
	var neon: Array = rng.choice(th["neon"])
	var frame := mul(col, 0.45)
	p.fill_rect(x, top + 2, w, sh - 2, qc(frame))
	p.fill_rect(x, top + 2, 1, sh - 2, qc(mul(hi, 0.8)))
	var word: String = rng.choice(SHOP_WORDS.get(kind, [""]))
	var board_h := 0
	if word != "" and kind != "shutter":
		var tw := Pixfont.text_width(word)
		if tw + 6 <= w - 2:
			board_h = 10
			var bx := x + Py.ifloordiv(int(w - tw - 6), 2)
			p.fill_rect(bx, top + 3, tw + 6, 9, qc([10, 10, 16]))
			p.set_pen(qc(mul(neon, 0.5)), 1.0)
			p.draw_rect(bx, top + 3, tw + 5, 8)
			p.set_no_pen()
			Pixfont.draw(p, bx + 3, top + 4, word, neon, 1, null)
			Pixfont.draw(e, bx + 3, top + 4, word, neon, 1, null)
	var wy := top + 4 + board_h
	var wh := base - 2 - wy
	if wh < 8:
		return
	var door_w := 8 if w > 40 else 0
	var wx0 := x + 3
	var wx1 := x + w - 3 - (door_w + 3 if door_w else 0)
	var ww := wx1 - wx0

	var lit := func(xx: float, yy: float, ww_: float, hh_: float, c: Array, k: float) -> void:
		p.fill_rect(xx, yy, ww_, hh_, qc(c))
		e.fill_rect(xx, yy, ww_, hh_, qc(mul(c, k)))

	if kind == "shutter":
		for yy in range(int(top + 4), int(base), 2):
			p.fill_rect(x + 2, yy, w - 4, 1, qc(mul(hi, 0.65 if yy % 4 else 0.45)))
		# Graffiti
		var gc: Array = rng.choice([GREEN, CYAN, AMBER, NBLUE, RED])
		p.set_pen(qc(mul(gc, 0.7)), 2.0)
		var gx := x + rng.randint(4, maxi(5, int(w - 30)))
		var ng := rng.randint(4, 7)
		var pts := PackedVector2Array()
		for i in ng:
			pts.append(Vector2(gx + i * 4, base - 10 - rng.randint(0, 9)))
		p.draw_polyline(pts)
		p.set_no_pen()
		if rng.random() < 0.4:   # Lichtspalt unten
			lit.call(x + 3, base - 2, w - 6, 1, AMBER, 0.6)
		return
	if kind == "lobby":
		var g := QGrad.linear(0, wy, 0, base)
		g.set_color_at(0, qc(mul(PALE, 0.55)))
		g.set_color_at(1, qc(mul(AMBER, 0.45)))
		p.fill_rect(x + 2, wy, w - 4, wh, g)
		e.fill_rect(x + 2, wy, w - 4, wh, qc(mul(PALE, 0.25)))
		for xx in range(int(x + 2), int(x + w - 2), 12):
			p.fill_rect(xx, wy, 1, wh, qc(mul(col, 0.6)))
		p.fill_rect(x + Py.ifloordiv(int(w), 2) - 10, base - 8, 20, 6, qc([20, 18, 22]))   # Empfang
		p.fill_rect(x + Py.ifloordiv(int(w), 2) - 10, base - 8, 20, 1, qc(AMBER))
		return
	var interiors := {
		"noodle": mix(AMBER, CRIMSON, 0.3), "kiosk": [190, 196, 200], "video": [20, 24, 40],
		"pawn": mul(AMBER, 0.45), "bar": [34, 14, 34], "pharmacy": [150, 210, 200],
		"laundry": [160, 180, 200], "eye": mul(CYAN, 0.6), "animoid": [40, 30, 60],
		"diner": mix(AMBER, PALE, 0.4), "repair": mul(AMBER, 0.5),
	}
	var interior: Array = interiors.get(kind, [120, 120, 140])
	var k_int := rng.uniform(0.55, 0.85)
	lit.call(wx0, wy, ww, wh, mul(interior, k_int), 0.6)
	if kind == "noodle":
		p.fill_rect(wx0, base - 9, ww, 3, qc([26, 16, 18]))           # Theke
		p.fill_rect(wx0, base - 9, ww, 1, qc(mul(AMBER, 0.9)))
		for sx in range(int(wx0 + 3), int(wx1 - 2), 7):               # Hocker
			p.fill_rect(sx, base - 5, 3, 1, qc([40, 30, 30]))
			p.fill_rect(sx + 1, base - 4, 1, 4, qc([40, 30, 30]))
		var ng := rng.randint(1, 3)
		for _k in ng:                                                 # Gäste
			var gx := rng.randint(int(wx0 + 2), maxi(int(wx0 + 3), int(wx1 - 6)))
			p.fill_rect(gx, base - 15, 4, 6, qc([22, 14, 18]))
			p.fill_rect(gx + 1, base - 18, 3, 3, qc([22, 14, 18]))
		vents.append([fac.lmin + wx0 + Py.ifloordiv(int(ww), 2), base - 12])
		var lstep := rng.randint(7, 11)
		for k in range(int(x + 4), int(x + w - 2), lstep):
			lanterns.append([fac.lmin + k, top + board_h + 2, rng.choice([CRIMSON, AMBER]), rng.random() * 6])
	elif kind == "kiosk":
		for yy in range(int(wy + 3), int(base - 3), 4):
			p.fill_rect(wx0 + 1, yy + 2, ww - 2, 1, qc(mul(interior, 0.45)))
			for xx in range(int(wx0 + 2), int(wx1 - 2), 2):
				if rng.random() < 0.7:
					var c: Array = rng.choice([CRIMSON, AMBER, CYAN, MAGENTA, PALE, TEAL])
					p.fill_rect(xx, yy, 1, 2, qc(mul(c, 0.85)))
	elif kind == "video":
		for yy in range(int(wy + 2), int(base - 6), 7):
			for xx in range(int(wx0 + 2), int(wx1 - 6), 8):
				tvs.append([xx, yy, 6, 5, rng.randint(0, 999)])
	elif kind == "pawn":
		for xx in range(int(wx0), int(wx1), 3):
			p.fill_rect(xx, wy, 1, wh, qc(mul(hi, 0.5)))
		for _k in 3:
			var gx := rng.randint(int(wx0 + 2), maxi(int(wx0 + 3), int(wx1 - 5)))
			lit.call(gx, base - 8, 3, 3, rng.choice([AMBER, PALE]), 0.7)
	elif kind == "bar":
		var sc_: Array = rng.choice([MAGENTA, CYAN, AMBER])
		var cx_ := wx0 + Py.ifloordiv(int(ww), 2)
		for q: QP in [p, e]:
			q.set_pen(qc(sc_), 1.0)
			q.set_no_brush()
			q.draw_ellipse(cx_ - 5, wy + 3, 10, 7)
			q.draw_line(cx_ - 2, wy + 10, cx_ + 2, wy + 10)
			q.set_no_pen()
	elif kind == "pharmacy":
		var cx_ := wx0 + Py.ifloordiv(int(ww), 2)
		var cy_ := wy + Py.ifloordiv(int(wh), 2)
		for q: QP in [p, e]:
			q.fill_rect(cx_ - 1, cy_ - 4, 3, 9, qc(TEAL if q == p else mul(TEAL, 1.6)))
			q.fill_rect(cx_ - 4, cy_ - 1, 9, 3, qc(TEAL if q == p else mul(TEAL, 1.6)))
	elif kind == "laundry":
		for xx in range(int(wx0 + 3), int(wx1 - 6), 9):
			p.set_brush(qc([40, 44, 60]))
			p.set_pen(qc(mul(PALE, 0.8)), 1.0)
			p.draw_ellipse(xx, base - 9, 6, 6)
			p.set_no_pen()
	elif kind == "eye":
		var cx_ := wx0 + Py.ifloordiv(int(ww), 2)
		var cy_ := wy + Py.ifloordiv(int(wh), 2)
		for q: QP in [p, e]:
			q.set_no_brush()
			q.set_pen(qc(PALE), 1.0)
			q.draw_ellipse(cx_ - 7, cy_ - 3, 14, 6)
			q.set_no_pen()
			q.fill_rect(cx_ - 1, cy_ - 1, 3, 3, qc(CRIMSON if q == p else AMBER))
	elif kind == "animoid":
		var na := rng.randint(2, 4)
		for _k in na:
			var gx := rng.randint(int(wx0 + 2), maxi(int(wx0 + 3), int(wx1 - 8)))
			p.set_pen(qc(mul(hi, 0.7)), 1.0)
			p.set_no_brush()
			p.draw_rect(gx, base - 12, 7, 9)
			p.set_no_pen()
			lit.call(gx + 2, base - 9, 1, 1, AMBER, 1.0)
			lit.call(gx + 4, base - 9, 1, 1, AMBER, 1.0)
	elif kind == "diner":
		p.fill_rect(wx0, base - 8, ww, 2, qc(mul(interior, 0.4)))
		var ng := rng.randint(1, 4)
		for _k in ng:
			var gx := rng.randint(int(wx0 + 2), maxi(int(wx0 + 3), int(wx1 - 6)))
			p.fill_rect(gx, base - 14, 4, 6, qc(mul(interior, 0.25)))
			p.fill_rect(gx + 1, base - 17, 3, 3, qc(mul(interior, 0.25)))
	elif kind == "repair":
		p.fill_rect(wx0 + 2, base - 7, ww - 4, 2, qc([30, 24, 20]))
		for _k in 4:
			var gx := rng.randint(int(wx0 + 2), maxi(int(wx0 + 3), int(wx1 - 4)))
			p.fill_rect(gx, wy + 2, 1, rng.randint(3, 7), qc([30, 24, 20]))
		lit.call(wx0 + Py.ifloordiv(int(ww), 2), wy + 1, 3, 2, [255, 230, 180], 1.0)
	# Fensterrahmen
	p.fill_rect(wx0, wy, ww, 1, qc(mul(hi, 1.1)))
	# Tür mit Lichtschein
	if door_w:
		var dx := wx1 + 3
		p.fill_rect(dx, base - 22, door_w, 22, qc(mul(col, 0.3)))
		if rng.random() < 0.6:
			lit.call(dx + 1, base - 21, door_w - 2, 20, mul(interior, 0.5), 0.5)
		lit.call(dx, base - 24, door_w, 1, neon, 0.8)
	# Markise
	if kind in ["noodle", "kiosk", "diner", "pawn", "laundry"] and rng.random() < 0.6:
		var ac: Array = rng.choice(th["neon"] + [CRIMSON, SLATE])
		var ay := top + board_h + 3
		p.set_brush(qc(mul(ac, 0.45)))
		p.set_no_pen()
		p.draw_polygon(PackedVector2Array([Vector2(x + 1, ay), Vector2(x + w - 1, ay),
			Vector2(x + w + 2, ay + 6), Vector2(x - 2, ay + 6)]))
		for k in range(int(x), int(x + w), 6):
			p.fill_rect(k, ay + 1, 3, 5, qc(mul(ac, 0.28)))
		p.fill_rect(x - 2, ay + 5, w + 4, 1, qc(mul(ac, 0.85)))


func _street_props(p: QP, e: QP, fac: Layer, rng: PyRandom, base: float) -> void:
	## Gehweg-Möbel auf Fassadenebene: Vidphon-Zellen, Zeitungsautomaten, Imbisskarren.
	var x := rng.randint(30, 120)
	while x < fac.width - 40:
		var kind: String = rng.choice(["phone", "news", "cart", "hydrant", "none", "none"])
		if absf(x + 10 - exit_L) < 90:
			kind = "none"
		if kind == "phone":
			p.fill_rect(x, base - 30, 12, 30, qc([26, 30, 40]))
			p.fill_rect(x + 2, base - 27, 8, 16, qc(mul(CYAN, 0.4)))
			e.fill_rect(x + 2, base - 27, 8, 16, qc(mul(CYAN, 0.35)))
			p.fill_rect(x, base - 31, 12, 2, qc(mul(th["building_hi"], 1.3)))
			Pixfont.draw(p, x + 1, base - 9, "TEL", PALE, 1, null)
		elif kind == "news":
			for k in 2:
				var c: Array = rng.choice([CRIMSON, BLUE, AMBER])
				p.fill_rect(x + k * 7, base - 9, 6, 9, qc(mul(c, 0.6)))
				p.fill_rect(x + k * 7 + 1, base - 8, 4, 3, qc(mul(PALE, 0.6)))
		elif kind == "cart":
			var c: Array = rng.choice(th["neon"])
			p.fill_rect(x, base - 12, 22, 9, qc([40, 34, 36]))
			p.fill_rect(x + 1, base - 3, 3, 3, qc(VOID))
			p.fill_rect(x + 18, base - 3, 3, 3, qc(VOID))
			p.fill_rect(x - 2, base - 22, 26, 2, qc(mul(c, 0.6)))
			p.fill_rect(x + 1, base - 20, 1, 8, qc(SLATE))
			p.fill_rect(x + 20, base - 20, 1, 8, qc(SLATE))
			for q: QP in [p, e]:
				q.fill_rect(x + 2, base - 12, 18, 1, qc(c))
			vents.append([fac.lmin + x + 11, base - 13])
		elif kind == "hydrant":
			p.fill_rect(x, base - 6, 4, 6, qc([120, 30, 40]))
			p.fill_rect(x - 1, base - 5, 6, 1, qc([150, 40, 50]))
		x += rng.randint(90, 220)


func _ramen_booth(p: QP, e: QP, fac: Layer, x: float, base: float) -> void:
	## Nudelbar im Stil des White Dragon (Blade Runner): offene Theke mit Hockern,
	## Gäste von hinten, Koch hinter dem Tresen, Menü-Täfelchen, nackte Glühbirnen,
	## Noren, rote Papierlaternen, Plastikvorhänge, Neon-Drache auf dem Dach.
	var rng := _rng
	var w := 176
	var L0 := fac.lmin + x
	var roof := base - 62                     # Oberkante Vordach
	var lip := base - 55                      # Vorderkante Vordach
	var top_c := base - 18                    # Thekenplatte
	var wood := [74, 46, 30]
	var wood_hi := [150, 100, 60]
	var wood_dk := [34, 20, 16]
	var spot := {"L": L0, "w": w, "base": base, "bulbs": [], "seats": [], "drips": [], "lanterns": []}
	# Alles Lebende der Häuser hinter der Bude entfernen
	var X0 := L0 - 28
	var X1 := L0 + w + 22
	var Y0 := base - 98

	var inside := func(L: float, y: float, ww: float, hh: float) -> bool:
		return L + ww > X0 and L < X1 and y + hh > Y0

	signs = signs.filter(func(s: Sign) -> bool: return not inside.call(s.L, s.y, s.w, s.h))
	tvs = tvs.filter(func(v: Array) -> bool: return not inside.call(float(v[0]), float(v[1]), float(v[2]), float(v[3])))
	lanterns = lanterns.filter(func(v: Array) -> bool: return not inside.call(float(v[0]), float(v[1]), 0.0, 0.0))
	blinks = blinks.filter(func(b: Array) -> bool: return String(b[0]) != "fac" or not inside.call(float(b[1]), float(b[2]), 0.0, 0.0))
	vents = vents.filter(func(v: Array) -> bool: return not inside.call(float(v[0]), float(v[1]), 0.0, 0.0))
	lamps = lamps.filter(func(lp: Lamp) -> bool: return not inside.call(lp.L - lp.arm - 6, lp.y - 6, lp.arm + 12, 12))
	e.set_mode(QP.CLEAR)
	e.fill_rect(x - 28, Y0, w + 50, base - Y0 + 1, QP.c(0, 0, 0, 0))
	e.set_mode(QP.OVER)
	# Rückwand: warmes, aber gedämpftes Innenlicht (kein Ausbrennen im Dither)
	var g := QGrad.linear(0, lip, 0, top_c)
	g.set_color_at(0.0, qc([40, 22, 20]))
	g.set_color_at(0.6, qc([86, 48, 28]))
	g.set_color_at(1.0, qc([112, 62, 32]))
	p.fill_rect(x + 6, lip, w - 12, top_c - lip, g)
	# Menü-Täfelchen (Holzschilder mit Pinselzeichen)
	var tx := x + 12
	while tx < x + w - 18:
		var red := rng.random() < 0.25
		p.fill_rect(tx, base - 46, 7, 8, qc([150, 40, 50] if red else [190, 172, 140]))
		p.fill_rect(tx, base - 46, 7, 1, qc([190, 70, 80] if red else [214, 198, 170]))
		var ink := [232, 224, 210] if red else [52, 28, 20]
		for gq: Vector2i in _glyph(rng):
			if gq.y < 5 and gq.x < 5:
				p.fill_rect(tx + 1 + gq.x, base - 45 + gq.y, 1, 1, qc(ink))
		tx += 10
	# Regal: Schalen-Stapel, Flaschen, Dosen
	p.fill_rect(x + 10, base - 34, w - 20, 1, qc(wood_hi))
	p.fill_rect(x + 10, base - 33, w - 20, 1, qc(wood_dk))
	var sx_ := x + 14
	while sx_ < x + w - 20:
		var k := rng.random()
		if k < 0.35:
			var nj := rng.randint(2, 4)
			for j in nj:
				p.fill_rect(sx_, base - 36 - j * 2, 6, 2, qc([214, 214, 220] if j % 2 == 0 else [180, 182, 192]))
			sx_ += 8
		elif k < 0.7:
			var hgt := rng.randint(5, 8)
			var c: Array = rng.choice([[40, 70, 50], [90, 50, 30], [60, 40, 70]])
			p.fill_rect(sx_, base - 34 - hgt, 2, hgt, qc(c))
			p.fill_rect(sx_, base - 34 - hgt, 1, hgt, qc(mul(c, 1.8)))
			sx_ += 4
		else:
			sx_ += 5
	# Suppentopf (links) und Wok-Station (rechts) hinter der Theke
	var px_ := x + 22
	p.fill_rect(px_, base - 30, 18, 12, qc([120, 124, 134]))
	p.fill_rect(px_, base - 30, 18, 2, qc([190, 194, 204]))
	p.fill_rect(px_ + 2, base - 28, 2, 10, qc([160, 164, 176]))
	p.fill_rect(px_ - 2, base - 27, 2, 2, qc([90, 92, 100]))
	p.fill_rect(px_ + 18, base - 27, 2, 2, qc([90, 92, 100]))
	var wx_ := x + w - 46
	p.set_no_pen()
	p.set_brush(qc([30, 30, 36]))
	p.draw_chord(wx_, base - 26, 18, 10, 180 * 16, 180 * 16)
	p.fill_rect(wx_ + 17, base - 23, 7, 1, qc([70, 50, 30]))
	spot["pot"] = [L0 + px_ - x + 9, base - 31]
	spot["wok"] = [L0 + wx_ - x + 9, base - 21]
	# Theke: helle Platte mit warmem Kantenlicht, Lamellenfront, Fußleiste
	p.fill_rect(x + 2, top_c, w - 4, 2, qc(wood_hi))
	p.fill_rect(x + 2, top_c + 2, w - 4, 1, qc([96, 62, 38]))
	for qa: Array in [[p, 255], [e, 110]]:
		var q: QP = qa[0]
		q.fill_rect(x + 4, top_c, w - 8, 1, qc([230, 170, 100], qa[1]))
	p.fill_rect(x + 4, top_c + 3, w - 8, 12, qc(wood))
	for k in range(int(x + 6), int(x + w - 6), 4):
		p.fill_rect(k, top_c + 3, 1, 12, qc(wood_dk))
	p.fill_rect(x + 4, base - 4, w - 8, 1, qc([150, 154, 166]))
	# Hocker + Gäste (von hinten). Der Hocker in der Mitte bleibt frei
	var n := 6
	var free := Py.ifloordiv(n, 2)
	var xs: Array = []
	for i in n:
		xs.append(x + 16 + i * Py.ifloordiv(int(w - 32), n - 1))
	var coats := [[40, 44, 60], [70, 40, 46], [60, 56, 50], [30, 50, 58], [90, 74, 50], [24, 24, 30]]
	for i in n:
		var sx: float = xs[i]
		p.fill_rect(sx - 1, base - 9, 1, 8, qc([150, 154, 166]))
		p.fill_rect(sx - 3, base - 1, 5, 1, qc([110, 114, 126]))
		p.fill_rect(sx - 4, base - 11, 8, 2, qc([150, 30, 44]))
		p.fill_rect(sx - 4, base - 11, 8, 1, qc([200, 60, 70]))
		(spot["seats"] as Array).append(L0 + sx - x)
		if i == free or rng.random() < 0.3:
			continue
		var c: Array = rng.choice(coats)
		# Rumpf (leicht nach vorn gebeugt), Schultern mit warmem Gegenlicht
		p.set_brush(qc(c))
		p.draw_polygon(PackedVector2Array([Vector2(sx - 5, base - 11), Vector2(sx - 6, base - 22), Vector2(sx - 3, base - 25),
			Vector2(sx + 4, base - 25), Vector2(sx + 6, base - 21), Vector2(sx + 5, base - 11)]))
		p.fill_rect(sx - 3, base - 25, 7, 1, qc(mix(c, AMBER, 0.55)))
		p.fill_rect(sx - 6, base - 21, 1, 9, qc(mul(c, 0.6)))
		var hair: Array = rng.choice([[20, 16, 14], [60, 40, 30], [140, 130, 120], [14, 14, 18]])
		p.set_brush(qc(hair))
		p.draw_ellipse(sx - 3, base - 31, 6, 6)
		p.fill_rect(sx - 2, base - 31, 4, 1, qc(mix(hair, AMBER, 0.5)))
		var hat := rng.random()
		if hat < 0.3:        # Hut mit Krempe
			p.fill_rect(sx - 5, base - 29, 10, 1, qc([26, 24, 26]))
			p.fill_rect(sx - 3, base - 33, 6, 4, qc([26, 24, 26]))
		elif hat < 0.45:     # Kapuze
			p.set_brush(qc(mul(c, 0.9)))
			p.draw_ellipse(sx - 4, base - 32, 8, 8)
		if rng.random() < 0.35:   # angelehnter Schirm mit Leuchtschaft
			var uc: Array = rng.choice([CYAN, MAGENTA, AMBER])
			for q: QP in [p, e]:
				q.set_pen(qc(uc), 1.0)
				q.draw_line(sx + 6, base - 1, sx + 9, base - 16)
				q.set_no_pen()
		spot["bowls"] = (spot.get("bowls", []) as Array) + [L0 + sx - x]
	spot["cook"] = L0 + float(xs[free]) - x
	# Vordach: Wellblech mit Lippe, Regen tropft von der Kante
	p.fill_rect(x - 6, roof, w + 12, lip - roof, qc([70, 34, 40]))
	for k in range(int(x - 6), int(x + w + 6), 3):
		p.fill_rect(k, roof, 1, lip - roof, qc([96, 48, 52]))
	p.fill_rect(x - 8, lip - 1, w + 16, 2, qc([40, 18, 24]))
	p.fill_rect(x - 6, roof, w + 12, 1, qc(mul(th["rim"], 0.8)))
	var drips: Array = []
	for k in range(-4, w + 6, 7):
		drips.append(L0 + k)
	spot["drips"] = drips
	spot["lip"] = lip + 1
	# Noren (geteilter Stoffvorhang) mit je einem Zeichen
	var nw := Py.ifloordiv(int(w - 8), 6)
	for i in 6:
		var nx := x + 4 + i * nw
		var c: Array = [34, 38, 92] if i % 2 == 0 else [120, 28, 46]
		p.fill_rect(nx + 1, lip + 1, nw - 2, 8, qc(c))
		p.fill_rect(nx + 1, lip + 8, nw - 2, 1, qc(mul(c, 0.6)))
		for gq: Vector2i in _glyph(rng):
			if gq.y < 6:
				p.fill_rect(nx + Py.ifloordiv(nw, 2) - 2 + gq.x, lip + 2 + gq.y, 1, 1, qc([214, 214, 222]))
		if i:
			(spot["bulbs"] as Array).append([L0 + nx - x, lip + 4])
	# Nackte Glühbirnen in den Noren-Spalten
	for bl: Array in spot["bulbs"]:
		var bx_ := float(bl[0]) - L0 + x
		p.fill_rect(bx_, lip + 1, 1, 3, qc([20, 16, 14]))
		for q: QP in [p, e]:
			q.fill_rect(bx_ - 1, float(bl[1]), 3, 3, qc([255, 226, 170]))
	# Rote Papierlaternen (Chōchin) an beiden Ecken
	for lx_: float in [x - 5, x + w - 2]:
		for qa: Array in [[p, 255], [e, 220]]:
			var q: QP = qa[0]
			q.set_no_pen()
			q.set_brush(qc([200, 40, 50], qa[1]))
			q.draw_ellipse(lx_ - 4, lip + 1, 9, 12)
		p.fill_rect(lx_ - 3, lip + 1, 7, 1, qc([20, 14, 14]))
		p.fill_rect(lx_ - 3, lip + 12, 7, 1, qc([20, 14, 14]))
		for gq: Vector2i in _glyph(rng):
			if gq.y < 6 and gq.x < 4:
				p.fill_rect(lx_ - 1 + gq.x, lip + 3 + gq.y, 1, 1, qc([30, 10, 12]))
		(spot["lanterns"] as Array).append([L0 + lx_ - x, lip + 7])
	# Seitliche Plastikvorhänge (durchscheinend, mit Lichtkanten)
	for sx0: float in [x, x + w - 7]:
		p.fill_rect(sx0, lip + 1, 7, base - lip - 2, qc([190, 200, 214], 38))
		for k in range(int(sx0 + 1), int(sx0 + 7), 3):
			p.fill_rect(k, lip + 1, 1, base - lip - 2, qc([214, 220, 226], 50))
	# Kisten + Tonne links
	p.fill_rect(x - 22, base - 10, 12, 10, qc([84, 62, 44]))
	p.fill_rect(x - 20, base - 17, 9, 7, qc([96, 72, 50]))
	p.fill_rect(x - 22, base - 10, 12, 1, qc([130, 100, 70]))
	p.fill_rect(x - 8, base - 9, 5, 9, qc([50, 70, 64]))
	# Gerüst + Neon-Drache auf dem Vordach (Zunge flackert live)
	var dr := _dragon_sign(rng)
	var on: QImg = dr[0]
	var off: QImg = dr[1]
	var em: QImg = dr[2]
	var tongue: Array = dr[3]
	var dx := x + Py.ifloordiv(int(w - on.width()), 2)
	var dy := roof - on.height() - 3
	p.fill_rect(dx + 6, dy + on.height() - 2, 1, roof - dy - on.height() + 2, qc([50, 50, 60]))
	p.fill_rect(dx + on.width() - 7, dy + on.height() - 2, 1, roof - dy - on.height() + 2, qc([50, 50, 60]))
	signs.append(Sign.new(fac.lmin + dx, dy, on, off, em, "steady", rng.randint(0, 99999), [150, 220, 236]))
	spot["tongue"] = [fac.lmin + dx + tongue[0], dy + tongue[1]]
	var rs := _make_sign(rng, AMBER, "text", "RAMEN")
	var rx_ := x + w - (rs[0] as QImg).width() - 2
	signs.append(Sign.new(fac.lmin + rx_, roof - (rs[0] as QImg).height() - 2, rs[0], rs[1], rs[2], "buzz", rng.randint(0, 99999), AMBER))
	# hohes Banner mit Kana am Pfosten rechts
	var bx := x + w + 10
	p.fill_rect(bx, roof - 4, 2, base - roof + 4, qc([74, 52, 34]))
	p.fill_rect(bx - 9, roof - 2, 9, 54, qc([124, 28, 52]))
	p.fill_rect(bx - 9, roof - 2, 9, 1, qc([190, 70, 90]))
	for i in 3:
		for gq: Vector2i in _glyph(rng):
			p.fill_rect(bx - 7 + gq.x, roof + 2 + i * 15 + gq.y, 1, 1, qc([228, 228, 234]))
	ramen_spots.append(spot)


func _holos() -> void:
	## Holografische Ballerinas: riesige hinter der Häuserfront (Mittel-Layer),
	## kleine auf Projektorsockeln am Gehweg (Fassaden-Layer).
	var hr := PyRandom.new(seed_ * 613 + zone * 29 + 3)
	holos = []
	var cols := [[170, 236, 255], [246, 150, 222], [190, 164, 255], [150, 255, 224]]
	if zone == 4:
		cols = [[255, 206, 130], [255, 230, 190]]
	var n_giant: int = [1, 1, 2, 1, 2][zone % 5]
	var n_street: int = [1, 2, 4, 2, 3][zone % 5]
	var span := cam_max - cam_min
	for i in n_giant:
		var wx := cam_min + span * (i + hr.uniform(0.25, 0.75)) / n_giant
		holos.append({"kind": "giant", "L": wx * MID_F, "base": fy - hr.randint(4, 26),
			"h": hr.uniform(112, 134), "col": hr.choice(cols), "seed": hr.randint(0, 999),
			"mirror": hr.random() < 0.5})
	var fac: Layer = facade
	var busy: Array = []
	for sp: Dictionary in ramen_spots:
		busy.append([float(sp["L"]) - 40, float(sp["L"]) + float(sp["w"]) + 40])
	busy.append([fac.lmin + exit_L - 90, fac.lmin + exit_L + 90])
	var tries := 0
	while _count_street() < n_street and tries < 200:
		tries += 1
		var wx := hr.uniform(cam_min + 120, cam_max - 160)
		var L := wx * fac.factor
		if _in_busy(busy, L):
			continue
		busy.append([L - 60, L + 60])
		holos.append({"kind": "street", "L": L, "base": fy + 3, "h": hr.uniform(74, 88),
			"col": hr.choice(cols), "seed": hr.randint(0, 999), "mirror": hr.random() < 0.5})


func _count_street() -> int:
	var n := 0
	for h: Dictionary in holos:
		if String(h["kind"]) == "street":
			n += 1
	return n


static func _in_busy(busy: Array, L: float) -> bool:
	for ab: Array in busy:
		if float(ab[0]) <= L and L <= float(ab[1]):
			return true
	return false


## Überbauten zum Durchgehen: Brücken (Pfeiler auf der anderen Straßenseite) und
## überhängende Gebäude (Unterseite mit Neonröhren, hängenden Schildern). Lage aus
## Procgen.span_layout (die Sim stellt Tonnen/Wracks darunter). Höhe der Unterseite in
## Welt-Einheiten (Kamera steht bei ~141 u).
func _spans() -> void:
	spans = []
	for Ld: Dictionary in Procgen.span_layout(length, seed_, zone, exit_x):
		var rng := PyRandom.new(int(Ld["seed"]))
		var kind: String = Ld["kind"]
		var x0: float = Ld["x0"]
		var x1: float = Ld["x1"]
		var w := x1 - x0
		var neon: Array = th["neon"]
		var tubes := []
		for _i in rng.randint(2, 4):
			tubes.append(rng.choice(neon.slice(0, 4)))
		var signs_ := []
		if kind == "overhang":
			for _k in rng.randint(1, 3):
				var f := rng.uniform(0.1, 0.8)
				var c: Array = rng.choice(neon)
				var word: String = rng.choice(th["words"])
				var drop := rng.randint(14, 40)
				var sd := rng.randint(0, 999)
				signs_.append([f, c, word, drop, sd])
		# breite Brücken stehen auf mehreren Pfeilern
		var fs: Array = [0.5] if w < 110 else ([0.25, 0.75] if w < 170 else [0.15, 0.5, 0.85])
		var piers := []
		for f: float in fs:
			piers.append(x0 + w * f)
		var hu := rng.uniform(146, 154) if kind == "bridge" else rng.uniform(144, 150)
		var tt := 34.0 + w * 0.08 if kind == "bridge" else 400.0
		var col := mul(th["building_hi"], rng.uniform(0.6, 0.85))
		spans.append({"kind": kind, "x0": x0, "x1": x1, "hu": hu, "t": tt, "col": col, "tubes": tubes,
				"signs": signs_, "seed": Ld["seed"], "piers": piers if kind == "bridge" else []})
	_stable_sort(spans, func(s: Dictionary) -> float: return float(s["x0"]))


## Kabel quer über die Straße: mittlerer Abstand (u) je Zone, Anteil Bündel
const WIRE_GAP := [[260, 0.35], [300, 0.3], [190, 0.5], [240, 0.4], [520, 0.15]]


## Kabel, die quer über die Straße hängen: von hoch oben an der Häuserfront über die
## Fahrbahn bis über die Kamera hinweg, mit Durchhang. Einzeln oder als Bündel, dünn bis
## dick. Nicht unter Brücken/Überhängen.
func _wires() -> void:
	var rng := PyRandom.new(seed_ * 271 + zone * 5 + 3)
	var wg: Array = WIRE_GAP[Py.imod(zone, WIRE_GAP.size())]
	var gap: float = wg[0]
	var p_bundle: float = wg[1]
	wires = []
	var x := cam_min + rng.uniform(40, gap)
	while x < cam_max:
		var under := false
		for s: Dictionary in spans:
			if float(s["x0"]) - 30 < x and x < float(s["x1"]) + 30:
				under = true
				break
		if not under:
			var bundle := rng.random() < p_bundle
			var n := rng.randint(2, 4) if bundle else 1
			var base_w: float = rng.uniform(0.9, 1.6) if bundle else rng.choice([0.5, 0.7, 1.0, 1.6, 2.4])
			var h0 := rng.uniform(150, 200)
			var dx := rng.uniform(-60, 60)
			var sag := rng.uniform(40, 75)
			var strands := []
			for j in n:
				var dh := j * rng.uniform(1.5, 3.0)
				var sdx := rng.uniform(-2, 2)
				var dsag := rng.uniform(-4, 6)
				var sw := base_w * rng.uniform(0.7, 1.2)
				strands.append({"dh": dh, "dx": sdx, "dsag": dsag, "w": sw})
			var h1 := h0 + rng.uniform(-10, 30)
			var col: Array = rng.choice([[8, 9, 11], [12, 12, 14], [10, 10, 10]])
			wires.append({"x": x, "dx": dx, "h0": h0, "h1": h1, "sag": sag, "strands": strands,
					"col": col, "seed": rng.randint(0, 9999)})
		x += rng.uniform(0.5, 1.5) * gap
	_stable_sort(wires, func(w_: Dictionary) -> float: return float(w_["x"]))


func _alley(p: QP, e: QP, fac: Layer, rng: PyRandom, x: float, bw: float, base: float) -> void:
	# Gasse: tiefer, dunkel, Dampf, evtl. Zaun
	p.fill_rect(x, 0, bw, base, qc(mul(th["building"], 0.45)))
	p.fill_rect(x + 2, base - 50, bw - 4, 50, qc(mul(th["building"], 0.3)))
	if rng.random() < 0.6:
		for k in range(int(x), int(x + bw), 3):
			p.fill_rect(k, base - 22, 1, 22, qc(mul(th["building_hi"], 0.7)))
		p.fill_rect(x, base - 22, bw, 1, qc(mul(th["building_hi"], 0.9)))
	vents.append([fac.lmin + x + Py.ifloordiv(int(bw), 2), base - 10])
	if rng.random() < 0.5:
		var c: Array = rng.choice(th["neon"])
		p.fill_rect(x + Py.ifloordiv(int(bw), 2) - 1, base - 70, 2, 30, qc(mul(c, 0.6)))
		e.fill_rect(x + Py.ifloordiv(int(bw), 2) - 1, base - 70, 2, 30, qc(mul(c, 0.6)))


func _containers(p: QP, _e: QP, fac: Layer, rng: PyRandom, x: float, bw: float, base: float) -> void:
	var cols := [[110, 40, 40], [40, 70, 90], [90, 80, 50], [50, 60, 70], [30, 70, 70]]
	var y := base
	var n := rng.randint(2, 5)
	for _i in n:
		var ch := 22
		var cw := bw - rng.randint(0, 20)
		var c := mul(rng.choice(cols), 0.55)
		var cx := x + rng.randint(0, int(bw - cw))
		p.fill_rect(cx, y - ch, cw, ch, qc(c))
		for k in range(int(cx + 1), int(cx + cw - 1), 3):
			p.fill_rect(k, y - ch + 2, 1, ch - 4, qc(mul(c, 0.7)))
		p.fill_rect(cx, y - ch, cw, 1, qc(mul(c, 1.4)))
		if rng.random() < 0.3:
			var txt: String = rng.choice(["TYRELL", "SHIMATA", "OFF-WORLD", "NEXUS"])
			var img := Pixfont.render(txt, mul(PALE, 0.5), 1, null)
			if img.width() < cw - 4:
				p.draw_image_at(cx + 3, y - ch + 8, img)
		y -= ch
	if rng.random() < 0.5:
		blinks.append(["fac", fac.lmin + x + Py.ifloordiv(int(bw), 2), y - 2, AMBER, rng.random() * 3])


func _exit_gate(p: QP, _e: QP, fac: Layer, x: float, base: float) -> void:
	var col := mul(th["building"], 1.3)
	p.fill_rect(x, 0, 120, base, qc(mul(col, 0.8)))
	p.fill_rect(x + 20, base - 70, 80, 70, qc(VOID))
	p.fill_rect(x + 18, base - 72, 84, 2, qc(mul(col, 1.6)))
	for k in range(int(base - 66), int(base), 6):
		p.fill_rect(x + 24, k, 72, 1, qc(mul(col, 0.6)))
	var label := "TYRELL CORP" if String(th["style"]) == "tyrell" else "U-BAHN"
	gate = {"L": fac.lmin + x, "y": base - 92, "w": 120, "label": label, "door": [fac.lmin + x + 20, base - 70, 80, 70]}


func _lamp_post(p: QP, x: float, y: float, base: float, arm: float) -> void:
	var col := qc([30, 32, 44])
	p.fill_rect(int(x), y, 2, base - y, col)
	p.fill_rect(int(x), y, arm, 2, col)
	p.fill_rect(int(x) + arm - 3, y + 2, 5, 2, qc([50, 52, 64]))


func _ground() -> void:
	var y0 := fy
	var y1 := H
	var rows := y1 - y0
	# Weltbreite des Bildes in Tiefe 0 (bei 640 genau VIEW_SPAN_NEAR / SCALE_FAR)
	var span_far := Config.VIEW_SPAN_NEAR * W / Config.RENDER_W / Config.SCALE_FAR
	var wmin := cam_min - span_far
	var wmax := cam_max + span_far
	g_wmin = wmin
	var gw := int((wmax - wmin) * TPU)
	var asph: Array = th["asphalt"]
	var curb_row := int(Persp.ground_y(0.0) - y0)

	var img := _bake(gw, rows, func(p: QP) -> void:
		# Gehweg
		var side := mix(asph, th["building_hi"], 0.5)
		p.fill_rect(0, 0, gw, curb_row, qc(side, 235))
		for wx in range(int(wmin), int(wmax), 22):
			p.fill_rect(int((wx - wmin) * TPU), 0, 1, curb_row, qc(mul(side, 0.7), 235))
		p.fill_rect(0, curb_row - 2, gw, 2, qc(mul(side, 1.5)))
		p.fill_rect(0, curb_row, gw, 1, qc(mul(asph, 0.5)))
		# Asphalt mit Körnung
		p.fill_rect(0, curb_row + 1, gw, rows - curb_row - 1, qc(asph, 205))
		var ns := int(gw * rows / 60.0)
		for _i in ns:
			var gx := _rng.randrange(gw)
			var gy := _rng.randrange(curb_row + 1, rows)
			p.fill_rect(gx, gy, _rng.choice([1, 2, 3]), 1, qc(mul(asph, _rng.choice([0.6, 1.35, 1.6])), 220))
		# Rinnstein (nass)
		p.fill_rect(0, curb_row + 1, gw, 2, qc(mul(asph, 0.5), 120))
		# Fahrbahnmarkierung
		var lane := int(Persp.ground_y(0.52) - y0)
		for wx in range(int(wmin), int(wmax), 70):
			p.fill_rect(int((wx - wmin) * TPU), lane, int(34 * TPU), 2, qc(mul(ASH, 0.55), 230))
		# Zebrastreifen
		var cw_x := wmin + _rng.uniform(200, 500)
		while cw_x < wmax:
			for k in 7:
				var sx := int((cw_x + k * 9 - wmin) * TPU)
				p.fill_rect(sx, curb_row + 3, int(5 * TPU), rows - curb_row - 3, qc(mul(ASH, 0.3), 140))
			cw_x += _rng.uniform(700, 1300)
		# Kanaldeckel (mit Dampf)
		manholes = []
		var mx := wmin + _rng.uniform(80, 200)
		while mx < wmax:
			var d := _rng.uniform(0.2, 0.85)
			var rr := int(Persp.ground_y(d) - y0)
			p.set_no_pen()
			p.set_brush(qc(mul(asph, 0.55)))
			p.draw_ellipse(int((mx - wmin) * TPU) - 14, rr - 3, 28, 6)
			p.set_brush(qc(mul(asph, 1.5)))
			p.draw_ellipse(int((mx - wmin) * TPU) - 11, rr - 2, 22, 4)
			manholes.append([mx, d])
			mx += _rng.uniform(260, 520)
		# Pfützen: fast transparent -> Spiegelung kommt durch
		puddles = []
		var np := int((wmax - wmin) / 11.0)
		for _i in np:
			var px_ := _rng.uniform(0, gw)
			var r := _rng.randint(curb_row + 3, rows - 2)
			var pw := _rng.uniform(24, 92) * (0.5 + r / float(rows))
			var ph := maxf(3, int(_rng.uniform(3.0, 7.0) * (0.6 + r / float(rows))))
			p.set_mode(QP.SOURCE)
			p.set_brush(qc([26, 34, 52], 70))
			p.draw_ellipse(px_, r, pw, ph)
			p.set_mode(QP.OVER)
			# "Himmel" im Wasser: heller Schimmer oben auf der Pfütze
			p.fill_rect(int(px_ + pw * 0.12), r, int(pw * 0.78), 1, qc([120, 150, 190], 150))
			p.fill_rect(int(px_ + pw * 0.28), r + 1, int(pw * 0.5), 1, qc([70, 96, 130], 90))
			puddles.append([wmin + px_ / TPU + pw / (2 * TPU), Persp.depth_at_y(y0 + r), pw / (2 * TPU), maxf(2.0, ph)])
		# Risse
		p.set_pen(qc(mul(asph, 0.55), 220), 1.0)
		var nc := int((wmax - wmin) / 40.0)
		for _i in nc:
			var cx_ := _rng.uniform(0, gw)
			var cy_ := float(_rng.randint(curb_row + 3, rows - 2))
			var nk := _rng.randint(2, 5)
			for _k in nk:
				var nx := cx_ + _rng.uniform(-14, 14)
				var ny := cy_ + _rng.uniform(-2, 2)
				p.draw_line(cx_, cy_, nx, ny)
				cx_ = nx
				cy_ = ny)
	ground = img
	ground_y0 = y0


func draw_ground(p: QP, cam: float) -> void:
	## Mode-7-artiger Perspektivboden: pro Zeile ein Ausschnitt in Weltkoordinaten.
	var img: QImg = ground
	var y0 := ground_y0
	var rows := img.height()
	var r := 0
	var dsts: Array = []
	var srcs: Array = []
	while r < rows:
		var band := 2 if r < rows * 0.45 else 1     # nahe am Horizont ändert sich die Skala kaum
		band = mini(band, rows - r)
		var y := y0 + r
		var d := Persp.depth_at_y(y + band * 0.5)
		var k := Persp.ppu(d)
		var wl := cam - (W * 0.5) / k
		var sx := (wl - float(g_wmin)) * TPU
		var sw := W / k * TPU
		dsts.append(Rect2(0, y, W, band))
		srcs.append(Rect2(sx, r, sw, band))
		r += band
	p.draw_image_rects(img, dsts, srcs)    # ein Aufruf statt ~200 draw_image
