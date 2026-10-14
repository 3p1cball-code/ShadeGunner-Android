class_name QGrad
extends RefCounted
## Ersatz für QLinearGradient / QRadialGradient (Spread "Pad", wie Qt-Standard).
##
##   var g := QGrad.linear(x0, y0, x1, y1)      # QLinearGradient(x0, y0, x1, y1)
##   var g := QGrad.radial(cx, cy, r)           # QRadialGradient(cx, cy, r)
##   g.set_color_at(0.0, Color(...))            # setColorAt
##   p.set_brush(g)  /  p.fill_rect(x, y, w, h, g)
##
## Gezeichnet wird über eine 256x1-Verlaufstextur (premultipliziert, gecacht).

enum { LINEAR, RADIAL }

var kind := LINEAR
var p0 := Vector2.ZERO
var p1 := Vector2(1, 0)
var center := Vector2.ZERO
var radius := 1.0
var stops: Array = []          # [[t, Color], ...] sortiert

static var _cache := {}        # Schlüssel -> CanvasTexture


static func linear(x0: float, y0: float, x1: float, y1: float) -> QGrad:
	var g := QGrad.new()
	g.kind = LINEAR
	g.p0 = Vector2(x0, y0)
	g.p1 = Vector2(x1, y1)
	return g


static func radial(cx: float, cy: float, r: float, _fx: float = NAN, _fy: float = NAN) -> QGrad:
	var g := QGrad.new()
	g.kind = RADIAL
	g.center = Vector2(cx, cy)
	g.radius = maxf(0.0001, r)
	return g


func set_color_at(t: float, c: Color) -> void:
	_tex = null
	t = clampf(t, 0.0, 1.0)
	var i := 0
	while i < stops.size():
		var st: float = stops[i][0]
		if is_equal_approx(st, t):
			stops[i][1] = c
			return
		if st > t:
			break
		i += 1
	stops.insert(i, [t, c])        # sortiert einfügen (statt sort_custom je Aufruf)


## Farbe an Parameter t (Pad: außerhalb von 0..1 die Randfarbe), nicht premultipliziert.
func color_at(t: float) -> Color:
	if stops.is_empty():
		return Color(0, 0, 0, 0)
	if t <= float(stops[0][0]):
		return stops[0][1]
	for i in range(1, stops.size()):
		var a: Array = stops[i - 1]
		var b: Array = stops[i]
		if t <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			var u := 0.0 if span <= 0.0 else (t - float(a[0])) / span
			return (a[1] as Color).lerp(b[1], u)
	return stops[stops.size() - 1][1]


## Premultiplizierte Farbe an t - Qt interpoliert Verläufe premultipliziert.
func premul_at(t: float) -> Color:
	if stops.is_empty():
		return Color(0, 0, 0, 0)
	if t <= float(stops[0][0]):
		return _pm(stops[0][1])
	for i in range(1, stops.size()):
		var a: Array = stops[i - 1]
		var b: Array = stops[i]
		if t <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			var u := 0.0 if span <= 0.0 else (t - float(a[0])) / span
			return _pm(a[1]).lerp(_pm(b[1]), u)
	return _pm(stops[stops.size() - 1][1])


static func _pm(c: Color) -> Color:
	return Color(c.r * c.a, c.g * c.a, c.b * c.a, c.a)


## Verlaufsparameter t für einen Punkt (gleicher Koordinatenraum wie die Form).
func t_at(p: Vector2) -> float:
	if kind == LINEAR:
		var d := p1 - p0
		var l2 := d.length_squared()
		return 0.0 if l2 <= 0.0 else (p - p0).dot(d) / l2
	return (p - center).length() / radius


## Radialer Verlauf als 2D-Textur (Quelle deckt uv = (p - c) / r in [-R2, R2]² ab;
## außerhalb gilt der letzte Stopp - wie Pad). Mit Modulation wie texture().
const R2 := 1.08
const N2 := 32
static var _cache2d := {}


func texture2d() -> Texture2D:
	texture()                  # setzt _mod und liefert den Schlüssel-Zustand
	var key: Variant = _key
	var hit: Variant = _cache2d.get(key)
	if hit != null:
		return hit
	var lut: Image = (_tex as CanvasTexture).diffuse_texture.get_image()
	var data := PackedByteArray()
	data.resize(N2 * N2 * 4)
	for j in N2:
		var v := ((j + 0.5) / N2 * 2.0 - 1.0) * R2
		for i in N2:
			var u := ((i + 0.5) / N2 * 2.0 - 1.0) * R2
			var t := minf(1.0, sqrt(u * u + v * v))
			var c := lut.get_pixel(int(round(t * 255.0)), 0)
			var o := (j * N2 + i) * 4
			data[o] = c.r8
			data[o + 1] = c.g8
			data[o + 2] = c.b8
			data[o + 3] = c.a8
	var ct := CanvasTexture.new()
	ct.diffuse_texture = ImageTexture.create_from_image(Image.create_from_data(N2, N2, false, Image.FORMAT_RGBA8, data))
	ct.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	ct.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	if _cache2d.size() > 600:
		_cache2d.clear()
	_cache2d[key] = ct
	return ct


## uv_at als affine Abbildung (für Transform2D * PackedVector2Array).
func uv_xform() -> Transform2D:
	if kind == LINEAR:
		var d := p1 - p0
		var l2 := d.length_squared()
		if l2 <= 0.0:
			return Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2(0.0, 0.5))
		return Transform2D(Vector2(d.x / l2, 0.0), Vector2(d.y / l2, 0.0), Vector2(-p0.dot(d) / l2, 0.5))
	return Transform2D(Vector2(1.0 / radius, 0.0), Vector2(0.0, 1.0 / radius), -center / radius)


## UV für einen Formpunkt: linear -> (t, 0.5); radial -> (p - c) / r (Shader rechnet die Länge).
func uv_at(p: Vector2) -> Vector2:
	if kind == LINEAR:
		return Vector2(t_at(p), 0.5)
	return (p - center) / radius


## Verlaufstextur + Modulation (premultipliziert). Haben alle Stopps dieselbe Farbe und
## unterscheiden sich nur im Alpha (Lichthöfe, Dampf, Nebel - der häufigste Fall), wird
## nur die Form normiert gecacht (weiß, Alpha / Max-Alpha, auf 1/128 gerastert) und die
## Farbe samt Stärke über die Modulation gesetzt. So teilen sich Verläufe, deren Stärke
## sich jedes Bild ändert, eine Textur - vorher kostete jeder neue Alpha-Wert ein neues
## Bild (256 set_pixel) und der Schlüssel war str(stops).
var _tex: Texture2D = null
var _mod := Color(1, 1, 1, 1)
var _key: Variant = null


func modulate() -> Color:
	if _tex == null:
		texture()
	return _mod


func texture() -> Texture2D:
	if _tex != null:
		return _tex
	# Premultipliziert ist die Farbe eines völlig transparenten Stopps egal.
	var c0 := Color(0, 0, 0, 0)
	for s in stops:
		if (s[1] as Color).a > 0.002:
			c0 = s[1]
			break
	var same := not stops.is_empty()
	var am := 0.0
	for s in stops:
		var c: Color = s[1]
		am = maxf(am, c.a)
		if c.a > 0.002 and (absf(c.r - c0.r) > 0.002 or absf(c.g - c0.g) > 0.002 or absf(c.b - c0.b) > 0.002):
			same = false
	# Schlüssel als Ganzzahl (bis 3 Stopps) - Strings zu bauen kostete je Verlauf mehr als
	# das Zeichnen selbst.
	var key: Variant
	if same and am > 0.0:
		_mod = Color(c0.r * am, c0.g * am, c0.b * am, am)
		if stops.size() <= 3:
			var k := 1
			for s in stops:
				k = k * 262144 + int(float(s[0]) * 1000.0) * 256 + int(round((s[1] as Color).a / am * 128.0))
			key = k
		else:
			var ks := "w"
			for s in stops:
				ks += "%d:%d;" % [int(float(s[0]) * 1000.0), int(round((s[1] as Color).a / am * 128.0))]
			key = ks
	else:
		_mod = Color(1, 1, 1, 1)
		var ks := "c"
		for s in stops:
			var c: Color = s[1]
			ks += "%d:%d,%d,%d,%d;" % [int(float(s[0]) * 1000.0), c.r8, c.g8, c.b8, c.a8]
		key = ks
	_key = key
	var hit: Variant = _cache.get(key)
	if hit != null:
		_tex = hit
		return _tex
	var data := PackedByteArray()
	data.resize(256 * 4)
	for i in 256:
		var pc := premul_at(i / 255.0)
		if same and am > 0.0:
			var a := clampf(round(pc.a / am * 128.0) / 128.0, 0.0, 1.0)
			pc = Color(a, a, a, a)
		data[i * 4] = clampi(int(round(pc.r * 255.0)), 0, 255)
		data[i * 4 + 1] = clampi(int(round(pc.g * 255.0)), 0, 255)
		data[i * 4 + 2] = clampi(int(round(pc.b * 255.0)), 0, 255)
		data[i * 4 + 3] = clampi(int(round(pc.a * 255.0)), 0, 255)
	var img := Image.create_from_data(256, 1, false, Image.FORMAT_RGBA8, data)
	var ct := CanvasTexture.new()
	ct.diffuse_texture = ImageTexture.create_from_image(img)
	ct.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	ct.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	if _cache.size() > 2000:
		_cache.clear()
	_cache[key] = ct
	_tex = ct
	return ct
