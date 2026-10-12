class_name QPExact
extends QP
## QP mit den gegen Qt (aliased) gemessenen Korrekturen; geteilt von Sprites/Vehicles.
##
##  1. Formen: Qt füllt jedes Pixel, dessen Mitte in (x0, x1] liegt; die GPU füllt
##     [x0, x1) -> winziger Versatz +eps statt QPs +0.5 (stimmt nur bei ganzen Zahlen).
##  2. Stifte <= 1 Gerätepixel: QCosmeticStroker - Deckkraft int(256 * Breite * Skala)/256
##     und eigene Pixelwahl (Festkomma-Nachbau, _qt_line_cells, 0/400 Abweichungen).
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
		_cells(_qt_line_cells(xf * a, xf * b), _cos_col())
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
		var seen := {}
		var cells: Array[Vector2i] = []
		for i in range(1, pts.size()):
			for c in _qt_line_cells(xf * pts[i - 1], xf * pts[i]):
				if not seen.has(c):
					seen[c] = true
					cells.append(c)
		_cells(cells, _cos_col())
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
	var keep := xf
	xf = Transform2D(xf.x, xf.y, xf.origin + Vector2(eps, eps))
	super.draw_image(dst, img, src)
	xf = keep


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
	_outline_closed(pts)


func draw_ellipse(x: float, y: float, w: float, h: float) -> void:
	var pts := _ellipse_pts(x, y, w, h)
	if brush != null:
		_fill_poly(pts, brush)
	_outline_closed(pts)


## Pixelmenge einer dünnen Linie wie QCosmeticStroker (aliased, mit Kappen):
## Endpunkte 26.6-Festkomma (trunkiert), Steigung 16.16, capAdjust um ein halbes
## Pixel, Querachse an der Pixelmitte nur bei positiver Steigung.
static func _qt_line_cells(a: Vector2, b: Vector2) -> Array[Vector2i]:
	var x1 := int(a.x * 64.0)
	var y1 := int(a.y * 64.0)
	var x2 := int(b.x * 64.0)
	var y2 := int(b.y * 64.0)
	var out: Array[Vector2i] = []
	if absi(x2 - x1) < absi(y2 - y1):
		if y1 > y2:
			var tx := x1
			var ty := y1
			x1 = x2
			y1 = y2
			x2 = tx
			y2 = ty
		var inc := ((x2 - x1) << 16) / (y2 - y1)
		var x := x1 << 10
		y1 -= 32
		x -= inc >> 1
		y2 += 32
		var y := (y1 + 32) >> 6
		var ys := (y2 + 32) >> 6
		x += (((y << 6) + (32 if inc > 0 else 0) - y1) * inc) >> 6
		while y < ys:
			out.append(Vector2i(x >> 16, y))
			x += inc
			y += 1
	else:
		if x1 > x2:
			var tx := x1
			var ty := y1
			x1 = x2
			y1 = y2
			x2 = tx
			y2 = ty
		if x2 == x1:
			out.append(Vector2i(x1 >> 6, y1 >> 6))
			return out
		var inc := ((y2 - y1) << 16) / (x2 - x1)
		var yy := y1 << 10
		x1 -= 32
		yy -= inc >> 1
		x2 += 32
		var x := (x1 + 32) >> 6
		var xs := (x2 + 32) >> 6
		yy += (((x << 6) + (32 if inc > 0 else 0) - x1) * inc) >> 6
		while x < xs:
			out.append(Vector2i(x, yy >> 16))
			yy += inc
			x += 1
	return out
