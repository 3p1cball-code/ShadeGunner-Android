class_name QP
extends RefCounted
## QPainter-Nachbau auf Godots RenderingServer.
##
## Damit lässt sich der QPainter-Code des Originals fast zeilengleich portieren:
##
##   Python                                   GDScript
##   p.setPen(QPen(QColor(r,g,b,a)))          p.set_pen(QP.c(r, g, b, a))
##   pen.setWidthF(w); p.setPen(pen)          p.set_pen(col, w)
##   p.setPen(Qt.PenStyle.NoPen)              p.set_no_pen()
##   p.setBrush(QBrush(QColor(...)))          p.set_brush(col)  /  p.set_brush(QGrad)
##   p.setBrush(Qt.BrushStyle.NoBrush)        p.set_no_brush()
##   p.fillRect(QRectF(x,y,w,h), QColor/grad) p.fill_rect(x, y, w, h, col_or_grad)
##   p.drawRect(QRectF(x,y,w,h))              p.draw_rect(x, y, w, h)
##   p.drawEllipse(QRectF(x,y,w,h))           p.draw_ellipse(x, y, w, h)
##   p.drawEllipse(QPointF(cx,cy), rx, ry)    p.draw_ellipse_c(cx, cy, rx, ry)
##   p.drawLine(QPointF(a), QPointF(b))       p.draw_line(ax, ay, bx, by)
##   p.drawPoint(QPointF(x,y))                p.draw_point(x, y)
##   p.drawPolygon(QPolygonF(pts))            p.draw_polygon(PackedVector2Array)
##   p.drawPolyline(...)                      p.draw_polyline(PackedVector2Array)
##   p.drawChord(QRectF, start16, span16)     p.draw_chord(x, y, w, h, start16, span16)
##   p.drawImage(QRectF(dst), img[, QRectF])  p.draw_image(Rect2(dst), qimg[, Rect2(src)])
##   p.drawImage(x, y, img)                   p.draw_image_at(x, y, qimg)
##   p.setOpacity(o)                          p.set_opacity(o)
##   p.setCompositionMode(PLUS/OVER/...)      p.set_mode(QP.PLUS / QP.OVER / ...)
##   p.setRenderHint(SmoothPixmapTransform,b) p.set_smooth(b)
##   p.save() / p.restore()                   p.save() / p.restore()
##   p.translate / scale / rotate(deg)        gleichnamig
##   p.resetTransform()                       p.reset_transform()
##   p.setClipRect(QRectF) / setClipping(F)   p.set_clip_rect(x,y,w,h) / p.set_clipping(false)
##   p.setClipRegion(Ellipsen/Polygon)        p.set_clip_ellipses([Rect2...]) / p.set_clip_polygon(pts)
##
## Composition: OVER und PLUS laufen beide über premultipliziertes Blending
## (PLUS = Alpha 0 -> rein additiv), also ohne Item-Wechsel. SOURCE/CLEAR
## schreiben ersetzend, DEST_IN multipliziert das Ziel mit dem Quell-Alpha.
## SourceIn/SourceAtop gibt es nicht generisch (Sprites/Fahrzeuge/Holo lösen das
## über Silhouetten bzw. Tönung).
##
## Rasterung ohne Kantenglättung wie im Original (Qt Aliased). Dünne Linien
## (<= 1 px) liegen wie bei Qt auf den Pixelmitten rechts/unterhalb.

enum { OVER, PLUS, SOURCE, CLEAR, DEST_IN }
enum { CAP_FLAT, CAP_SQUARE, CAP_ROUND }

static var _mat_premul: CanvasItemMaterial
static var _mat_disabled: ShaderMaterial
static var _mat_radial: ShaderMaterial
static var _mat_destin: ShaderMaterial
static var _mat_destin_rad: ShaderMaterial
static var _white: ImageTexture

var target := RID()            # Wurzel-Canvas-Item (gehört dem Aufrufer)
var _pool: Array[RID] = []     # wiederverwendete Segment-Items
var _groups: Array[RID] = []   # Clip-Gruppen (Region)
var _used := 0
var _used_groups := 0
var _item := RID()
var _item_key := -1
var _ver := 0                 # steigt bei jeder segmentrelevanten Zustandsänderung
var _item_xf := Transform2D()
var _item_xf_valid := false
var _draw_index := 0

# Zustand
var xf := Transform2D.IDENTITY
var opacity := 1.0
var pen_col := Color(0, 0, 0, 1)
var pen_w := 1.0
var pen_cap := CAP_SQUARE
var pen_on := true
var brush: Variant = null      # Color, QGrad oder null
var mode := OVER
var smooth := false
var clip_rect: Variant = null  # Rect2 in Zielkoordinaten
var clip_group := RID()        # aktive Clip-Region (Gruppe)
var tint: Variant = null       # Color: alle Farben durch diese ersetzen (Silhouetten), Alpha bleibt
var _stack: Array = []


static func _init_static() -> void:
	if _mat_premul != null:
		return
	_mat_premul = CanvasItemMaterial.new()
	_mat_premul.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	var sx := Shader.new()
	sx.code = "shader_type canvas_item;\nrender_mode blend_disabled;\n"
	_mat_disabled = ShaderMaterial.new()
	_mat_disabled.shader = sx
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nrender_mode blend_premul_alpha;\nvarying vec4 vc;\nvoid vertex(){ vc = COLOR; }\nvoid fragment(){ COLOR = texture(TEXTURE, vec2(clamp(length(UV), 0.0, 1.0) * 0.996 + 0.002, 0.5)) * vc; }"
	_mat_radial = ShaderMaterial.new()
	_mat_radial.shader = sh
	var sd := Shader.new()
	sd.code = "shader_type canvas_item;\nrender_mode blend_mul;\nvoid fragment(){ COLOR = vec4(COLOR.a); }"
	_mat_destin = ShaderMaterial.new()
	_mat_destin.shader = sd
	var sdr := Shader.new()
	sdr.code = "shader_type canvas_item;\nrender_mode blend_mul;\nvarying vec4 vc;\nvoid vertex(){ vc = COLOR; }\nvoid fragment(){ float a = texture(TEXTURE, vec2(clamp(length(UV), 0.0, 1.0) * 0.996 + 0.002, 0.5)).a * vc.a; COLOR = vec4(a); }"
	_mat_destin_rad = ShaderMaterial.new()
	_mat_destin_rad.shader = sdr
	var wi := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	wi.fill(Color(1, 1, 1, 1))
	_white = ImageTexture.create_from_image(wi)


## Farbe aus 0-255-Werten (QColor(r, g, b, a)).
static func c(r: float, g: float, b: float, a: float = 255.0) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0)


## Farbe aus einem [r, g, b]-Array (Python-Tupel) mit optionalem Alpha 0-255 (qc(c, a)).
static func rgb(t: Array, a: float = 255.0) -> Color:
	return Color(float(t[0]) / 255.0, float(t[1]) / 255.0, float(t[2]) / 255.0, a / 255.0)


# ------------------------------------------------------------------ Lebenszyklus
func _init(root: RID = RID()) -> void:
	_init_static()
	target = root


## Neues Bild beginnen: alle Segmente leeren, Zustand zurücksetzen.
func begin(root: RID = RID()) -> void:
	if root.is_valid():
		target = root
	_used = 0
	_used_groups = 0
	_draw_index = 0
	_item = RID()
	_item_key = -1
	_ver += 1
	xf = Transform2D.IDENTITY
	opacity = 1.0
	pen_col = Color(0, 0, 0, 1)
	pen_w = 1.0
	pen_cap = CAP_SQUARE
	pen_on = true
	brush = null
	mode = OVER
	smooth = false
	clip_rect = null
	clip_group = RID()
	_stack.clear()


## Bild abschließen: übrige Pool-Items leeren (sie zeichnen dann nichts).
func end() -> void:
	for i in range(_used, _pool.size()):
		RenderingServer.canvas_item_clear(_pool[i])
		RenderingServer.canvas_item_set_visible(_pool[i], false)
	for i in range(_used_groups, _groups.size()):
		RenderingServer.canvas_item_clear(_groups[i])
		RenderingServer.canvas_item_set_visible(_groups[i], false)
	_item = RID()
	_item_key = -1


func free_all() -> void:
	for r in _pool:
		RenderingServer.free_rid(r)
	for r in _groups:
		RenderingServer.free_rid(r)
	_pool.clear()
	_groups.clear()


# ------------------------------------------------------------------ Zustand
func save() -> void:
	_stack.append([xf, opacity, pen_col, pen_w, pen_cap, pen_on, brush, mode, smooth, clip_rect, clip_group, tint])


func restore() -> void:
	if _stack.is_empty():
		return
	var s: Array = _stack.pop_back()
	xf = s[0]
	opacity = s[1]
	pen_col = s[2]
	pen_w = s[3]
	pen_cap = s[4]
	pen_on = s[5]
	brush = s[6]
	mode = s[7]
	smooth = s[8]
	clip_rect = s[9]
	clip_group = s[10]
	tint = s[11]
	_ver += 1


func translate(dx: float, dy: float) -> void:
	xf = xf.translated_local(Vector2(dx, dy))


func scale(sx: float, sy: float) -> void:
	xf = xf.scaled_local(Vector2(sx, sy))


func rotate(deg: float) -> void:
	xf = xf.rotated_local(deg_to_rad(deg))


func reset_transform() -> void:
	xf = Transform2D.IDENTITY


func set_transform(t: Transform2D) -> void:
	xf = t


func transform() -> Transform2D:
	return xf


func set_opacity(o: float) -> void:
	opacity = clampf(o, 0.0, 1.0)


func set_mode(m: int) -> void:
	if m != mode:
		mode = m
		_ver += 1


func set_smooth(on: bool) -> void:
	if on != smooth:
		smooth = on
		_ver += 1


func set_pen(col: Color, width: float = 1.0, cap: int = CAP_SQUARE) -> void:
	pen_on = true
	pen_col = col
	pen_w = width
	pen_cap = cap


func set_pen_width(width: float) -> void:
	pen_w = width


func set_no_pen() -> void:
	pen_on = false


func set_brush(b: Variant) -> void:
	brush = b


func set_no_brush() -> void:
	brush = null


func set_clip_rect(x: float, y: float, w: float, h: float) -> void:
	var r := _aabb([Vector2(x, y), Vector2(x + w, y), Vector2(x, y + h), Vector2(x + w, y + h)])
	if clip_rect != null:
		r = r.intersection(clip_rect)
	clip_rect = r
	_ver += 1


## Clip-Region als Vereinigung von Ellipsen (QRegion(..., Ellipse).united(...)).
func set_clip_ellipses(rects: Array) -> void:
	var g := _new_group()
	var saved_xf := xf
	for r in rects:
		var rr: Rect2 = r
		var pts := _ellipse_pts(rr.position.x, rr.position.y, rr.size.x, rr.size.y)
		RenderingServer.canvas_item_add_set_transform(g, saved_xf)
		RenderingServer.canvas_item_add_polygon(g, pts, PackedColorArray([Color(1, 1, 1, 1)]))
	clip_group = g
	_ver += 1


## Clip-Region als Polygon (QRegion(poly.toPolygon())).
func set_clip_polygon(pts: PackedVector2Array) -> void:
	var g := _new_group()
	RenderingServer.canvas_item_add_set_transform(g, xf)
	_add_polygon_safe(g, pts, PackedColorArray([Color(1, 1, 1, 1)]), PackedVector2Array())
	clip_group = g
	_ver += 1


func set_clipping(on: bool) -> void:
	if not on:
		clip_rect = null
		clip_group = RID()
		_ver += 1


# ------------------------------------------------------------------ Segmente
func _new_group() -> RID:
	var g: RID
	if _used_groups < _groups.size():
		g = _groups[_used_groups]
		RenderingServer.canvas_item_clear(g)
	else:
		g = RenderingServer.canvas_item_create()
		_groups.append(g)
	_used_groups += 1
	RenderingServer.canvas_item_set_parent(g, target)
	RenderingServer.canvas_item_set_visible(g, true)
	RenderingServer.canvas_item_set_draw_index(g, _draw_index)
	_draw_index += 1
	RenderingServer.canvas_item_set_canvas_group_mode(g, RenderingServer.CANVAS_GROUP_MODE_CLIP_ONLY, 0.0, true, 0.0, false)
	_item = RID()
	_item_key = -1
	return g


## Transform für Formen: +0.5 px im Zielraum, weil Qt aliased an den Pixelecken abtastet.
func _gx() -> Transform2D:
	return Transform2D(xf.x, xf.y, xf.origin + Vector2(0.5, 0.5))


func _seg(kind: String) -> RID:
	# kind: "" (normal), "rad" (radialer Verlauf), "lin" (linearer Verlauf/Textur)
	var key := _ver * 2 + (1 if kind == "rad" else 0)
	if _item.is_valid() and key == _item_key:
		if not _item_xf_valid or _item_xf != xf:
			RenderingServer.canvas_item_add_set_transform(_item, _gx())
			_item_xf = xf
			_item_xf_valid = true
		return _item
	var it: RID
	if _used < _pool.size():
		it = _pool[_used]
		RenderingServer.canvas_item_clear(it)
	else:
		it = RenderingServer.canvas_item_create()
		_pool.append(it)
	_used += 1
	var parent := clip_group if clip_group.is_valid() else target
	RenderingServer.canvas_item_set_parent(it, parent)
	RenderingServer.canvas_item_set_visible(it, true)
	RenderingServer.canvas_item_set_draw_index(it, _draw_index)
	_draw_index += 1
	RenderingServer.canvas_item_set_default_texture_filter(it,
		RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR if smooth else RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	RenderingServer.canvas_item_set_default_texture_repeat(it, RenderingServer.CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)
	var mat: Material = _mat_premul
	match mode:
		SOURCE, CLEAR:
			mat = _mat_disabled
		DEST_IN:
			mat = _mat_destin_rad if kind == "rad" else _mat_destin
		_:
			if kind == "rad":
				mat = _mat_radial
	RenderingServer.canvas_item_set_material(it, mat.get_rid())
	if clip_rect != null:
		RenderingServer.canvas_item_set_custom_rect(it, true, clip_rect)
		RenderingServer.canvas_item_set_clip(it, true)
	else:
		RenderingServer.canvas_item_set_clip(it, false)
		RenderingServer.canvas_item_set_custom_rect(it, false)
	RenderingServer.canvas_item_add_set_transform(it, _gx())
	_item = it
	_item_key = key
	_item_xf = xf
	_item_xf_valid = true
	return it


## Farbe für das aktuelle Blending (premultipliziert; PLUS -> Alpha 0).
func _pc(col: Color) -> Color:
	if tint != null:
		var tc: Color = tint
		col = Color(tc.r, tc.g, tc.b, col.a * tc.a)
	var a := col.a * opacity
	match mode:
		PLUS:
			return Color(col.r * a, col.g * a, col.b * a, 0.0)
		CLEAR:
			return Color(0, 0, 0, 0)
		DEST_IN:
			return Color(a, a, a, a)
		_:
			return Color(col.r * a, col.g * a, col.b * a, a)


## Modulation für (premultiplizierte) Texturen.
func _tm() -> Color:
	var o := opacity
	match mode:
		PLUS:
			return Color(o, o, o, 0.0)
		DEST_IN:
			return Color(o, o, o, o)
		_:
			return Color(o, o, o, o)


func _aabb(pts: Array) -> Rect2:
	var p0: Vector2 = xf * (pts[0] as Vector2)
	var r := Rect2(p0, Vector2.ZERO)
	for p in pts:
		r = r.expand(xf * (p as Vector2))
	return r


func _scale_px() -> float:
	return sqrt(absf(xf.determinant()))


# ------------------------------------------------------------------ Füllungen
func _fill_poly(pts: PackedVector2Array, fill: Variant) -> void:
	if pts.size() < 3 or fill == null:
		return
	if fill is QGrad:
		var g: QGrad = fill
		var it := _seg("rad" if g.kind == QGrad.RADIAL else "lin")
		var uvs := PackedVector2Array()
		for p in pts:
			uvs.append(g.uv_at(p))
		_add_polygon_safe(it, pts, PackedColorArray([_tm()]), uvs, g.texture().get_rid())
	else:
		var it := _seg("")
		_add_polygon_safe(it, pts, PackedColorArray([_pc(fill)]), PackedVector2Array())


func _add_polygon_safe(it: RID, pts: PackedVector2Array, cols: PackedColorArray,
		uvs: PackedVector2Array, tex: RID = RID()) -> void:
	# Konvexe/einfache Polygone direkt; scheitert die Triangulierung (Selbstschnitt),
	# als Fächer zeichnen (Qt füllt OddEven, das kommt dem am nächsten).
	var tri := Geometry2D.triangulate_polygon(pts)
	if tri.is_empty():
		var idx := PackedInt32Array()
		for i in range(1, pts.size() - 1):
			idx.append_array([0, i, i + 1])
		tri = idx
	var colors := cols
	if cols.size() == 1:
		colors = PackedColorArray()
		colors.resize(pts.size())
		colors.fill(cols[0])
	if not uvs.is_empty() and not tex.is_valid():
		tex = _white.get_rid()
	RenderingServer.canvas_item_add_triangle_array(it, tri, pts, colors, uvs, PackedInt32Array(), PackedFloat32Array(), tex)


func fill_rect(x: float, y: float, w: float, h: float, fill: Variant) -> void:
	if fill == null:
		return
	if fill is QGrad:
		_fill_poly(PackedVector2Array([Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)]), fill)
		return
	var it := _seg("")
	RenderingServer.canvas_item_add_rect(it, Rect2(x, y, w, h).abs(), _pc(fill))


# ------------------------------------------------------------------ Linien
func _stroke(a: Vector2, b: Vector2) -> void:
	if not pen_on:
		return
	var it := _seg("")
	var col := _pc(pen_col)
	var spx := pen_w * _scale_px()
	if pen_w <= 0.0 or spx <= 1.0:
		# Kosmetischer 1-px-Strich auf den Pixelmitten (Qt Aliased): im Zielraum zeichnen
		var ta := xf * a
		var tb := xf * b
		RenderingServer.canvas_item_add_set_transform(it, Transform2D.IDENTITY)
		var o := Vector2(0.5, 0.5)
		if ta.is_equal_approx(tb):
			RenderingServer.canvas_item_add_rect(it, Rect2(ta.floor(), Vector2.ONE), col)
		else:
			RenderingServer.canvas_item_add_line(it, ta.floor() + o, tb.floor() + o, col, -1.0, false)
			RenderingServer.canvas_item_add_rect(it, Rect2(tb.floor(), Vector2.ONE), col)
		RenderingServer.canvas_item_add_set_transform(it, _gx())
		return
	var d := b - a
	var l := d.length()
	var hw := pen_w * 0.5
	if l < 0.0001:
		_dot_shape(it, a, hw, col)
		return
	var u := d / l
	if pen_cap == CAP_SQUARE:
		a -= u * hw
		b += u * hw
	var nrm := Vector2(-u.y, u.x) * hw
	var quad := PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm])
	RenderingServer.canvas_item_add_polygon(it, quad, PackedColorArray([col]))
	if pen_cap == CAP_ROUND:
		_dot_shape(it, a, hw, col)
		_dot_shape(it, b, hw, col)


func _dot_shape(it: RID, p: Vector2, r: float, col: Color) -> void:
	if pen_cap == CAP_ROUND:
		var n := clampi(int(r * _scale_px() * 3.0), 8, 32)
		var pts := PackedVector2Array()
		for i in n:
			var a := TAU * i / n
			pts.append(p + Vector2(cos(a), sin(a)) * r)
		RenderingServer.canvas_item_add_polygon(it, pts, PackedColorArray([col]))
	else:
		RenderingServer.canvas_item_add_rect(it, Rect2(p - Vector2(r, r), Vector2(2 * r, 2 * r)), col)


func draw_line(ax: float, ay: float, bx: float, by: float) -> void:
	_stroke(Vector2(ax, ay), Vector2(bx, by))


func draw_line_v(a: Vector2, b: Vector2) -> void:
	_stroke(a, b)


func draw_lines(segs: Array) -> void:
	# [[a: Vector2, b: Vector2], ...]
	for s in segs:
		_stroke(s[0], s[1])


func draw_polyline(pts: PackedVector2Array) -> void:
	for i in range(1, pts.size()):
		_stroke(pts[i - 1], pts[i])


func draw_point(x: float, y: float) -> void:
	if not pen_on:
		return
	var it := _seg("")
	var col := _pc(pen_col)
	var spx := pen_w * _scale_px()
	if pen_w <= 0.0 or spx <= 1.0:
		var tp := (xf * Vector2(x, y)).floor()
		RenderingServer.canvas_item_add_set_transform(it, Transform2D.IDENTITY)
		RenderingServer.canvas_item_add_rect(it, Rect2(tp, Vector2.ONE), col)
		RenderingServer.canvas_item_add_set_transform(it, _gx())
		return
	_dot_shape(it, Vector2(x, y), pen_w * 0.5, col)


func draw_points(pts: PackedVector2Array) -> void:
	for p in pts:
		draw_point(p.x, p.y)


# ------------------------------------------------------------------ Formen
func draw_rect(x: float, y: float, w: float, h: float) -> void:
	if brush != null:
		fill_rect(x, y, w, h, brush)
	if pen_on:
		var a := Vector2(x, y)
		var b := Vector2(x + w, y)
		var cc := Vector2(x + w, y + h)
		var d := Vector2(x, y + h)
		_stroke(a, b)
		_stroke(b, cc)
		_stroke(cc, d)
		_stroke(d, a)


func _ellipse_pts(x: float, y: float, w: float, h: float, a0: float = 0.0, span: float = TAU) -> PackedVector2Array:
	var cx := x + w * 0.5
	var cy := y + h * 0.5
	var rx := absf(w) * 0.5
	var ry := absf(h) * 0.5
	var per := (rx + ry) * PI * _scale_px()
	var n := clampi(int(per / 2.0), 10, 96)
	var full := absf(span - TAU) < 0.0001
	var pts := PackedVector2Array()
	var cnt := n if full else n + 1
	for i in cnt:
		var t := a0 + span * float(i) / float(n)
		# Qt-Winkel: 0 = 3 Uhr, positiv gegen den Uhrzeigersinn (y nach unten -> -sin)
		pts.append(Vector2(cx + rx * cos(t), cy - ry * sin(t)))
	return pts


func draw_ellipse(x: float, y: float, w: float, h: float) -> void:
	var pts := _ellipse_pts(x, y, w, h)
	if brush != null:
		_fill_poly(pts, brush)
	if pen_on:
		for i in pts.size():
			_stroke(pts[i], pts[(i + 1) % pts.size()])


func draw_ellipse_c(cx: float, cy: float, rx: float, ry: float) -> void:
	draw_ellipse(cx - rx, cy - ry, 2.0 * rx, 2.0 * ry)


## drawChord: Winkel in 1/16 Grad wie bei Qt.
func draw_chord(x: float, y: float, w: float, h: float, start16: float, span16: float) -> void:
	var pts := _ellipse_pts(x, y, w, h, deg_to_rad(start16 / 16.0), deg_to_rad(span16 / 16.0))
	if brush != null:
		_fill_poly(pts, brush)
	if pen_on:
		for i in pts.size():
			_stroke(pts[i], pts[(i + 1) % pts.size()])


func draw_polygon(pts: PackedVector2Array) -> void:
	if brush != null:
		_fill_poly(pts, brush)
	if pen_on:
		for i in pts.size():
			_stroke(pts[i], pts[(i + 1) % pts.size()])


## Gefülltes Polygon ohne Kontur mit fester Farbe (häufigstes Muster: NoPen + Brush).
func fill_polygon(pts: PackedVector2Array, fill: Variant) -> void:
	_fill_poly(pts, fill)


# ------------------------------------------------------------------ Bilder
func draw_image(dst: Rect2, img: QImg, src: Rect2 = Rect2()) -> void:
	if img == null or img.tex == null:
		return
	var s := src if src.size != Vector2.ZERO else Rect2(Vector2.ZERO, img.region.size)
	var sr := Rect2(img.region.position + s.position, s.size)
	var it := _seg("")
	var t := xf
	if img.mirrored:
		# gespiegelt: Quelle von rechts lesen, Ziel über einen Spiegel-Transform
		sr = Rect2(Vector2(img.region.position.x + img.region.size.x - s.position.x - s.size.x,
			img.region.position.y + s.position.y), s.size)
		t = xf * Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2(2.0 * dst.position.x + dst.size.x, 0.0))
	RenderingServer.canvas_item_add_set_transform(it, t)
	RenderingServer.canvas_item_add_texture_rect_region(it, dst, img.tex.get_rid(), sr, _tm(), false, true)
	RenderingServer.canvas_item_add_set_transform(it, _gx())


func draw_image_at(x: float, y: float, img: QImg) -> void:
	if img == null:
		return
	draw_image(Rect2(x, y, img.width(), img.height()), img)


## Textur direkt (z. B. ein ViewportTexture) gestreckt zeichnen.
func draw_texture(dst: Rect2, tex: Texture2D, src: Rect2 = Rect2()) -> void:
	if tex == null:
		return
	var s := src if src.size != Vector2.ZERO else Rect2(Vector2.ZERO, tex.get_size())
	var it := _seg("")
	RenderingServer.canvas_item_add_set_transform(it, xf)
	RenderingServer.canvas_item_add_texture_rect_region(it, dst, tex.get_rid(), s, _tm(), false, true)
	RenderingServer.canvas_item_add_set_transform(it, _gx())
