class_name QPExact
extends QP
## QP mit den gegen Qt (aliased) gemessenen Korrekturen; geteilt von Sprites/Vehicles.
##
##  1. Formen: Qt füllt jedes Pixel, dessen Mitte in (x0, x1] liegt; die GPU füllt
##     [x0, x1) -> winziger Versatz +eps statt QPs +0.5 (stimmt nur bei ganzen Zahlen).
##  2. Stifte <= 1 Gerätepixel: QCosmeticStroker - Deckkraft int(256 * Breite * Skala)/256
##     und eigene Pixelwahl (Nachbau von qcosmeticstroker.cpp inkl. Pfade/Bezier).
##  3. Polylinien/Konturen als ein Pfad: dünn -> jedes Pixel einmal; dick und
##     halbtransparent -> Umriss ohne Doppeldeckung an den Stößen; dick und deckend ->
##     Segmente ohne Kappen + Bevel-Join (Qt-Standard), Kappen nur an offenen Enden.
##  4. draw_image: Zielpixel per Pixelmitte wie bei Formen (+eps).

static var eps := 1.0 / 128.0


func _gx() -> Transform2D:
	return Transform2D(xf.x, xf.y, xf.origin + Vector2(eps, eps))


func _thin() -> bool:
	return pen_w <= 0.0 or pen_w * _scale_px() <= 1.0


## Stiftfarbe mit Cosmetic-Deckkraft.
func _cos_col() -> Color:
	var c := pen_col
	if pen_w > 0.0:
		c.a = c.a * clampi(int(256.0 * pen_w * _scale_px()), 0, 256) / 256.0
	return c


## Pixel einzeln im Zielraum füllen.
func _cells(cells: Array[Vector2i], col: Color) -> void:
	if cells.is_empty():
		return
	var it := _seg("")
	var pc := _pc(col)
	RenderingServer.canvas_item_add_set_transform(it, Transform2D.IDENTITY)
	for c in cells:
		RenderingServer.canvas_item_add_rect(it, Rect2(c.x, c.y, 1, 1), pc)
	RenderingServer.canvas_item_add_set_transform(it, _gx())


func _stroke(a: Vector2, b: Vector2) -> void:
	if not pen_on:
		return
	if _thin():
		_cells(_thin_line_cells(a, b), _cos_col())
		return
	super._stroke(a, b)


func draw_point(x: float, y: float) -> void:
	if not pen_on:
		return
	if _thin():
		var c := Vector2i((xf * Vector2(x, y)).floor())
		_cells([c], _cos_col())
		return
	super.draw_point(x, y)


func draw_polyline(pts: PackedVector2Array) -> void:
	if not pen_on or pts.size() < 2:
		return
	if _thin():
		_cells(_st_poly(_dev(pts), false, pen_cap != CAP_FLAT), _cos_col())
		return
	if pen_col.a * opacity >= 1.0:
		_thick_path(pts)
		return
	# Halbtransparent: Strich-Umriss (Segmente + runde Stöße) einmal füllen
	var hw := pen_w * 0.5
	var n := clampi(int(hw * _scale_px() * 3.0), 8, 32)
	var done: Array[PackedVector2Array] = []
	var fills: Array[PackedVector2Array] = []
	for i in pts.size():
		var parts: Array[PackedVector2Array] = []
		var circ := PackedVector2Array()
		for j in n:
			circ.append(pts[i] + Vector2(cos(TAU * j / n), sin(TAU * j / n)) * hw)
		parts.append(circ)
		if i > 0:
			var d := pts[i] - pts[i - 1]
			if d.length() > 0.0001:
				var nr := Vector2(-d.y, d.x).normalized() * hw
				parts.append(PackedVector2Array([pts[i - 1] + nr, pts[i] + nr, pts[i] - nr, pts[i - 1] - nr]))
		for part in parts:
			# nur der noch nicht bedeckte Rest des Teils wird gefüllt
			var pieces: Array[PackedVector2Array] = [part]
			for old in done:
				var nxt: Array[PackedVector2Array] = []
				for pc in pieces:
					var res := Geometry2D.clip_polygons(pc, old)
					for r: PackedVector2Array in res:
						var hole := false
						for o: PackedVector2Array in res:
							if o != r and Geometry2D.is_point_in_polygon(r[0], o):
								hole = true
						if not hole:
							nxt.append(r)
				pieces = nxt
			fills.append_array(pieces)
			done.append(part)
	for f in fills:
		_fill_poly(f, pen_col)


## Deckender dicker Pfad: Segmente flach, Stöße als Bevel, Kappen nur an offenen Enden.
func _thick_path(pts: PackedVector2Array) -> void:
	var it := _seg("")
	var col := _pc(pen_col)
	var hw := pen_w * 0.5
	var closed := pts.size() > 2 and pts[0].is_equal_approx(pts[pts.size() - 1])
	var nrm: Array[Vector2] = []
	for i in range(1, pts.size()):
		var d := pts[i] - pts[i - 1]
		nrm.append(Vector2(-d.y, d.x).normalized() * hw if d.length() > 0.0001 else Vector2.ZERO)
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var nr := nrm[i - 1]
		if nr == Vector2.ZERO:
			continue
		var u := Vector2(nr.y, -nr.x)
		if not closed and pen_cap == CAP_SQUARE:
			if i == 1:
				a -= u
			if i == pts.size() - 1:
				b += u
		RenderingServer.canvas_item_add_polygon(it, PackedVector2Array([a + nr, b + nr, b - nr, a - nr]), PackedColorArray([col]))
	# Bevel-Stöße
	var n := nrm.size()
	for i in range(0, n - 1 + (1 if closed else 0)):
		var n0 := nrm[i]
		var n1 := nrm[(i + 1) % n]
		var c := pts[i + 1]
		if n0 == Vector2.ZERO or n1 == Vector2.ZERO:
			continue
		for sgn: float in [1.0, -1.0]:
			var tri := PackedVector2Array([c, c + n0 * sgn, c + n1 * sgn])
			if absf((tri[1] - tri[0]).cross(tri[2] - tri[0])) > 1e-9:
				RenderingServer.canvas_item_add_polygon(it, tri, PackedColorArray([col]))
	if not closed and pen_cap == CAP_ROUND:
		_dot_shape(it, pts[0], hw, col)
		_dot_shape(it, pts[pts.size() - 1], hw, col)


func draw_image(dst: Rect2, img: QImg, src: Rect2 = Rect2()) -> void:
	if img == null or img.tex == null:
		return
	var s := src if src.size != Vector2.ZERO else Rect2(Vector2.ZERO, img.region.size)
	var axis := xf.x.y == 0.0 and xf.y.x == 0.0
	if axis and (xf.x.x != 1.0 or xf.y.y != 1.0 or dst.size != s.size):
		_scaled_image(dst, img, s)
		return
	var keep := xf
	xf = Transform2D(xf.x, xf.y, xf.origin + Vector2(eps, eps))
	super.draw_image(dst, img, src)
	xf = keep


static func _qround(d: float) -> int:
	return int(d + (0.5 if d >= 0.0 else -0.5))     # Qt: halb weg von 0


## Skaliertes Bild wie QRasterPaintEngine::drawImage (aliased) + qt_scale_image_32bit:
## Zielrechteck auf ganze Pixel (setX hält die rechte Kante), Abtastung 16.16-Festkomma.
## Gegen Qt geprüft (400 Zufallsfälle inkl. Spiegelung, 0 Abweichungen).
func _scaled_image(dst: Rect2, img: QImg, s: Rect2) -> void:
	var x := xf.x.x * dst.position.x + xf.origin.x
	var y := xf.y.y * dst.position.y + xf.origin.y
	var w := xf.x.x * dst.size.x
	var h := xf.y.y * dst.size.y
	var tx := _qround(x)
	var ty := _qround(y)
	var tw := _qround(x + w - tx)
	var th := _qround(y + h - ty)
	if tw == 0 or th == 0:
		return
	var sx := s.size.x / tw
	var sy := s.size.y / th
	var ix := int(65536.0 * sx)
	var iy := int(65536.0 * sy)
	var nx := tx if tw >= 0 else tx + tw
	var ny := ty if th >= 0 else ty + th
	var x0 := nx
	var y0 := ny
	var x1 := nx + absi(tw)
	var y1 := ny + absi(th)
	if clip_rect != null:
		var cr: Rect2 = clip_rect
		x0 = maxi(x0, int(cr.position.x))
		y0 = maxi(y0, int(cr.position.y))
		x1 = mini(x1, int(cr.end.x))
		y1 = mini(y1, int(cr.end.y))
	if x1 <= x0 or y1 <= y0:
		return
	var wc := x1 - x0
	var hc := y1 - y0
	var basex: int
	var srcy: int
	if sx < 0:
		basex = int(s.end.x * 65536) + floori((x0 + 0.5 - (tx + tw)) * sx * 65536) + 1
	else:
		basex = int(s.position.x * 65536) + ceili((x0 + 0.5 - tx) * sx * 65536) - 1
	if sy < 0:
		srcy = int(s.end.y * 65536) + floori((y0 + 0.5 - (ty + th)) * sy * 65536) + 1
	else:
		srcy = int(s.position.y * 65536) + ceili((y0 + 0.5 - ty) * sy * 65536) - 1
	var iw := int(img.region.size.x)
	var ih := int(img.region.size.y)
	basex &= 0xFFFFFFFF
	srcy &= 0xFFFFFFFF
	if (srcy >> 16) >= ih and iy < 0:
		srcy = (srcy + iy) & 0xFFFFFFFF
		hc -= 1
	if (basex >> 16) >= iw and ix < 0:
		basex = (basex + ix) & 0xFFFFFFFF
		wc -= 1
	var yend := ((srcy + iy * (hc - 1)) & 0xFFFFFFFF) >> 16
	if yend >= ih:
		hc -= 1
	var xend := ((basex + ix * (wc - 1)) & 0xFFFFFFFF) >> 16
	if xend >= iw:
		wc -= 1
	var it := _seg("")
	var tex := img.tex.get_rid()
	var mod := _tm()
	var org := img.region.position
	RenderingServer.canvas_item_add_set_transform(it, Transform2D.IDENTITY)
	for j in hc:
		var v := srcy >> 16
		var su := basex
		for i in wc:
			var u := su >> 16
			if img.mirrored:
				u = iw - 1 - u
			RenderingServer.canvas_item_add_texture_rect_region(it, Rect2(x0 + i, y0 + j, 1, 1), tex,
				Rect2(org.x + u, org.y + v, 1, 1), mod, false, true)
			su = (su + ix) & 0xFFFFFFFF
		srcy = (srcy + iy) & 0xFFFFFFFF
	RenderingServer.canvas_item_add_set_transform(it, _gx())


## Kontur als geschlossener Pfad (Qt strichelt den Pfad am Stück).
func _outline_closed(pts: PackedVector2Array) -> void:
	if not pen_on or pts.size() < 2:
		return
	var c := pts.duplicate()
	c.append(pts[0])
	draw_polyline(c)


func draw_polygon(pts: PackedVector2Array) -> void:
	if brush != null:
		_fill_poly(pts, brush)
	if pen_on and pts.size() >= 2 and _thin():
		_cells(_st_poly(_dev(pts), true, pen_cap != CAP_FLAT), _cos_col())
		return
	_outline_closed(pts)


func draw_ellipse(x: float, y: float, w: float, h: float) -> void:
	var pts := _ellipse_pts(x, y, w, h)
	if brush != null:
		_fill_poly(pts, brush)
	if pen_on and _thin():
		_cells(_st_ellipse(xf, x, y, w, h), _cos_col())
		return
	_outline_closed(pts)


func _dev(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in pts:
		out.append(xf * v)
	return out


# ------------------------------------------------------------------ QCosmeticStroker
# Nachbau von qcosmeticstroker.cpp (Qt 6.11, aliased): 26.6-Endpunkte, 16.16-Steigung,
# Kappen, Stoßpixel-Logik (lastPixel/lastDir), Bezier-Abflachung. Gegen Qt geprüft:
# je 300 Zufalls-Polylinien/-Polygone/-Ellipsen, 0 Abweichungen.
const _INT_MIN := -2147483648
const _TB := 1
const _BT := 2
const _LR := 4
const _RL := 8
const _VMASK := 3
const _HMASK := 12
const _CAPB := 1
const _CAPE := 2


class _Stroker:
	var last := Vector2i(-2147483648, -2147483648)
	var ldir := 0
	var laxis := false
	var cells: Array[Vector2i] = []
	var seen := {}

	func put(x: int, y: int) -> void:
		var c := Vector2i(x, y)
		if not seen.has(c):
			seen[c] = true
			cells.append(c)


static func _fdiv(x: int, y: int) -> int:
	return x * 65536 / y      # GDScript: ganzzahlig, Richtung 0 wie C


static func _swapcaps(c: int) -> int:
	return ((c & _CAPB) << 1) | ((c & _CAPE) >> 1)


static func _f26(v: float) -> int:
	return int(v * 64.0)


## drawLine-Template (aliased). Gibt didDraw zurück.
static func _st_line(s: _Stroker, a: Vector2, b: Vector2, caps: int) -> bool:
	var did := absf(b.x - a.x) + absf(b.y - a.y) >= 1.0
	var x1 := _f26(a.x)
	var y1 := _f26(a.y)
	var x2 := _f26(b.x)
	var y2 := _f26(b.y)
	var last := s.last
	var vert := absi(x2 - x1) < absi(y2 - y1)
	if not vert and x1 == x2:
		return true
	# Haupt-/Querachse vertauschen, damit ein Code beide Richtungen abdeckt
	var m1 := y1 if vert else x1
	var m2 := y2 if vert else x2
	var q1 := x1 if vert else y1
	var q2 := x2 if vert else y2
	var d := _TB if vert else _LR
	var sw := false
	if m1 > m2:
		sw = true
		var t := m1
		m1 = m2
		m2 = t
		t = q1
		q1 = q2
		q2 = t
		caps = _swapcaps(caps)
		d = _BT if vert else _RL
	var inc := _fdiv(q2 - q1, m2 - m1)
	var q := q1 << 10
	if (s.ldir ^ (_VMASK if vert else _HMASK)) == d:
		caps |= _CAPE if sw else _CAPB
	if caps & _CAPB:
		m1 -= 32
		q -= inc >> 1
	if caps & _CAPE:
		m2 += 32
	var m := (m1 + 32) >> 6
	var ms := (m2 + 32) >> 6
	var rnd := 32 if inc > 0 else 0
	var lm := s.last.y if vert else s.last.x
	if (caps & _CAPB) and lm == m + 1:
		m += 1
	if m != ms:
		q += (((m << 6) + rnd - m1) * inc) >> 6
		var first := _mk(vert, m, q >> 16)
		last = _mk(vert, ms - 1, (q + (ms - m - 1) * inc) >> 16)
		if sw:
			var t2 := first
			first = last
			last = t2
		var axis := absi(inc) < (1 << 14)
		var lp := s.last
		if lp.x > _INT_MIN:
			if first == lp:
				if sw:
					ms -= 1
				else:
					m += 1
					q += inc
			elif s.ldir != d and (((axis and s.laxis) and lp.x != first.x and lp.y != first.y)
					or absi(lp.x - first.x) > 1 or absi(lp.y - first.y) > 1):
				if sw:
					ms += 1
				else:
					m -= 1
					q -= inc
			elif s.ldir == d and absi(lp.x - first.x) <= 1 and absi(lp.y - first.y) > 1:
				q += inc >> 1
				var lq := (q >> 16) if sw else ((q + (ms - m - 1) * inc) >> 16)
				last = Vector2i(lq, last.y) if vert else Vector2i(last.x, lq)
		s.ldir = d
		s.laxis = axis
		while true:
			if vert:
				s.put(q >> 16, m)
			else:
				s.put(m, q >> 16)
			q += inc
			m += 1
			if m >= ms:
				break
		did = true
	s.last = last
	return did


static func _mk(vert: bool, m: int, q: int) -> Vector2i:
	return Vector2i(q, m) if vert else Vector2i(m, q)


## calculateLastPoint: Stoßpixel des schließenden Segments vorab bestimmen.
static func _st_calc_last(s: _Stroker, a: Vector2, b: Vector2) -> void:
	var x1 := _f26(a.x)
	var y1 := _f26(a.y)
	var x2 := _f26(b.x)
	var y2 := _f26(b.y)
	var vert := absi(x2 - x1) < absi(y2 - y1)
	if not vert and x1 == x2:
		return
	var m1 := y1 if vert else x1
	var m2 := y2 if vert else x2
	var q1 := x1 if vert else y1
	var q2 := x2 if vert else y2
	var sw := m1 > m2
	if sw:
		var t := m1
		m1 = m2
		m2 = t
		t = q1
		q1 = q2
		q2 = t
	var inc := _fdiv(q2 - q1, m2 - m1)
	var q := q1 << 10
	var m := (m1 + 32) >> 6
	var ms := (m2 + 32) >> 6
	if m != ms:
		q += (((m << 6) + (32 if inc > 0 else 0) - m1) * inc) >> 6
		if sw:
			s.last = _mk(vert, m, q >> 16)
			s.ldir = _BT if vert else _RL
		else:
			s.last = _mk(vert, ms - 1, (q + (ms - m - 1) * inc) >> 16)
			s.ldir = _TB if vert else _LR
		s.laxis = absi(inc) < (1 << 14)


## Einfacher Polygonpfad (drawPolyline / Kontur von drawPolygon mit implicit_close).
static func _st_poly(pts: PackedVector2Array, implicit_close: bool, draw_caps: bool) -> Array[Vector2i]:
	var s := _Stroker.new()
	var n := pts.size()
	var p := pts[0]
	var closed := implicit_close or pts[0] == pts[n - 1]
	var caps := _CAPB if (not closed and draw_caps) else 0
	if closed:
		var p2 := pts[n - 2] if (pts[0] == pts[n - 1] and n > 2) else pts[n - 1]
		_st_calc_last(s, p2, p)
	for i in range(1, n):
		if not closed and draw_caps and i == n - 1:
			caps |= _CAPE
		var moved := _st_line(s, p, pts[i], caps)
		# Lücken-Fix für dünne Stifte: fallengelassene Punkte überspringen (nicht am Anfang/Ende)
		if moved or i == 1 or i == n - 1:
			p = pts[i]
		caps = 0
	if implicit_close:
		_st_line(s, p, pts[0], 0)
	return s.cells


## splitCubic auf einem umgekehrten Punktpuffer ab Index o (o+3 = Start).
static func _split_cubic(P: PackedVector2Array, o: int) -> void:
	P[o + 6] = P[o + 3]
	var c := P[o + 1]
	var d := P[o + 2]
	var a := (P[o] + c) * 0.5
	P[o + 1] = a
	var b := (P[o + 3] + d) * 0.5
	P[o + 5] = b
	c = (c + d) * 0.5
	a = (a + c) * 0.5
	P[o + 2] = a
	b = (b + c) * 0.5
	P[o + 4] = b
	P[o + 3] = (a + b) * 0.5


static func _st_cubic_sub(s: _Stroker, P: PackedVector2Array, o: int, level: int, caps: int) -> void:
	if level:
		var dx := P[o + 3].x - P[o].x
		var dy := P[o + 3].y - P[o].y
		var ln := 0.25 * (absf(dx) + absf(dy))
		if (absf(dx * (P[o].y - P[o + 2].y) - dy * (P[o].x - P[o + 2].x)) >= ln
				or absf(dx * (P[o].y - P[o + 1].y) - dy * (P[o].x - P[o + 1].x)) >= ln):
			_split_cubic(P, o)
			level -= 1
			_st_cubic_sub(s, P, o + 3, level, caps & _CAPB)
			_st_cubic_sub(s, P, o, level, caps & _CAPE)
			return
	_st_line(s, P[o + 3], P[o], caps)


## Geschlossene Ellipsenkontur wie QPaintEngineEx::drawEllipse (4 Bezier, KAPPA).
static func _st_ellipse(xf_: Transform2D, x: float, y: float, w: float, h: float) -> Array[Vector2i]:
	const K := 0.5522847498
	var w2 := w / 2
	var h2 := h / 2
	var w2k := w2 * K
	var h2k := h2 * K
	var pts := [Vector2(x + w, y + h2),
		Vector2(x + w, y + h2 + h2k), Vector2(x + w2 + w2k, y + h), Vector2(x + w2, y + h),
		Vector2(x + w2 - w2k, y + h), Vector2(x, y + h2 + h2k), Vector2(x, y + h2),
		Vector2(x, y + h2 - h2k), Vector2(x + w2 - w2k, y), Vector2(x + w2, y),
		Vector2(x + w2 + w2k, y), Vector2(x + w, y + h2 - h2k), Vector2(x + w, y + h2)]
	var dv: Array[Vector2] = []
	for v: Vector2 in pts:
		dv.append(xf_ * v)
	var s := _Stroker.new()
	_st_calc_last(s, dv[11], dv[12])
	for k in 4:
		var P := PackedVector2Array()
		P.resize(3 * 6 + 4)
		P[3] = dv[k * 3]
		P[2] = dv[k * 3 + 1]
		P[1] = dv[k * 3 + 2]
		P[0] = dv[k * 3 + 3]
		_st_cubic_sub(s, P, 0, 6, 0)
	return s.cells


## Einzelne dünne Linie (QCosmeticStroker::drawLine).
func _thin_line_cells(a: Vector2, b: Vector2) -> Array[Vector2i]:
	var ta := xf * a
	var tb := xf * b
	if ta == tb:
		return [Vector2i(ta.floor())]
	var s := _Stroker.new()
	_st_line(s, ta, tb, (_CAPB | _CAPE) if pen_cap != CAP_FLAT else 0)
	return s.cells
