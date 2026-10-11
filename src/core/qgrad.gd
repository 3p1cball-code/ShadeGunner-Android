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
	for s in stops:
		if is_equal_approx(float(s[0]), t):
			s[1] = c
			return
	stops.append([clampf(t, 0.0, 1.0), c])
	stops.sort_custom(func(a, b): return float(a[0]) < float(b[0]))


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
	var pm := func(c: Color) -> Color: return Color(c.r * c.a, c.g * c.a, c.b * c.a, c.a)
	if t <= float(stops[0][0]):
		return pm.call(stops[0][1])
	for i in range(1, stops.size()):
		var a: Array = stops[i - 1]
		var b: Array = stops[i]
		if t <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			var u := 0.0 if span <= 0.0 else (t - float(a[0])) / span
			return (pm.call(a[1]) as Color).lerp(pm.call(b[1]), u)
	return pm.call(stops[stops.size() - 1][1])


## Verlaufsparameter t für einen Punkt (gleicher Koordinatenraum wie die Form).
func t_at(p: Vector2) -> float:
	if kind == LINEAR:
		var d := p1 - p0
		var l2 := d.length_squared()
		return 0.0 if l2 <= 0.0 else (p - p0).dot(d) / l2
	return (p - center).length() / radius


## UV für einen Formpunkt: linear -> (t, 0.5); radial -> (p - c) / r (Shader rechnet die Länge).
func uv_at(p: Vector2) -> Vector2:
	if kind == LINEAR:
		return Vector2(t_at(p), 0.5)
	return (p - center) / radius


func texture() -> Texture2D:
	var key := str(stops)
	if _cache.has(key):
		return _cache[key]
	var img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in 256:
		img.set_pixel(i, 0, premul_at(i / 255.0))
	var ct := CanvasTexture.new()
	ct.diffuse_texture = ImageTexture.create_from_image(img)
	ct.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	ct.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	if _cache.size() > 2000:
		_cache.clear()
	_cache[key] = ct
	return ct
