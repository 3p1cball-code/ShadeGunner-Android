class_name Pixfont
extends RefCounted
## 5x7-Bitmapschrift (render/pixfont.py): Großbuchstaben, Ziffern, Umlaute, HUD-Symbole.
##
## Text wird einmal pro (Text, Farbe, Skala, Schatten) in einen Atlas gebacken und
## danach nur noch als Bildausschnitt gezeichnet (Ersatz für den QImage-Cache).
## Kleinbuchstaben werden als Großbuchstaben gesetzt (Terminal-Look).
##
##   Pixfont.baker = baker                  # einmal setzen (Baker im Baum VOR dem Ziel)
##   Pixfont.draw(p, x, y, "TEXT", rgb, 2)  # gibt die Breite zurück

const GW := DPixfont.GW
const GH := DPixfont.GH
const ADV := DPixfont.ADV
const _CACHE_MAX := 900             # wie pixfont._CACHE_MAX
const SHADOW := [4, 5, 10]          # Standard-Schattenfarbe
const ATLAS_SIZE := 2048

static var GLYPHS: Dictionary = _build_glyphs()
static var baker: Baker
static var _CACHE: Dictionary = {}
static var _atlases: Array = []     # zwei Atlanten im Wechsel (siehe _swap)
static var _cur := 0


static func _build_glyphs() -> Dictionary:
	var g := {}
	for k: String in DPixfont._RAW:
		var rows: Array = []
		for row: String in String(DPixfont._RAW[k]).split("|"):
			var r: Array = []
			for i in row.length():
				r.append(row[i] == "#")
			rows.append(r)
		g[k] = rows
	return g


static func text_width(s: String, scale: int = 1) -> int:
	return s.length() * ADV * scale - scale if s != "" else 0


## str.upper() wie Python (ß -> SS).
static func _upper(s: String) -> String:
	return s.replace("ß", "SS").to_upper()


static func _atlas() -> Baker.Atlas:
	if _atlases.is_empty():
		assert(baker != null, "Pixfont.baker fehlt")
		for _i in 2:
			var a := baker.make_atlas(ATLAS_SIZE)
			# ganz nach vorn: Bakes, die Text verwenden, sehen ihn im selben Frame
			baker.move_child(a.vp, 0)
			_atlases.append(a)
	return _atlases[_cur]


## Cache leeren = auf den anderen Atlas wechseln. Der bisherige bleibt in diesem
## Frame gültig (dort liegen Bilder, die schon gezeichnet wurden).
static func _swap() -> void:
	_CACHE.clear()
	_cur = 1 - _cur
	(_atlases[_cur] as Baker.Atlas).reset()


## Ungeskalte Glyphenpixel als waagerechte Läufe [x, y, len] (wie _base im Original).
static func _runs(s: String) -> Array:
	var w := maxi(1, s.length() * ADV)
	var out: Array = []
	var up := _upper(s)
	for i in up.length():
		var ch := up[i]
		var g: Variant = GLYPHS.get(ch)
		if g == null:
			if ch == " ":
				continue
			g = GLYPHS["?"]
		var ox := i * ADV
		var rows: Array = g
		for y in rows.size():
			var row: Array = rows[y]
			var x := 0
			while x < row.size():
				if row[x] and ox + x < w:
					var x0 := x
					while x < row.size() and row[x] and ox + x < w:
						x += 1
					out.append([ox + x0, y, x - x0])
				else:
					x += 1
	return out


## Text -> QImg (gecacht). Schatten 1 Skalen-Pixel nach rechts unten.
static func render(s: String, rgb: Array, scale: int = 1, shadow: Variant = SHADOW) -> QImg:
	var key := "%s\u0001%s\u0001%d\u0001%s" % [s, rgb, scale, shadow]
	var hit: Variant = _CACHE.get(key)
	if hit != null:
		return hit
	var a := _atlas()
	a.frame_start()
	if _CACHE.size() > _CACHE_MAX:
		_swap()
		a = _atlas()
	var bw := maxi(1, s.length() * ADV) * scale
	var bh := GH * scale
	var ow := bw + (scale if shadow != null else 0)
	var oh := bh + (scale if shadow != null else 0)
	var r: Variant = a.alloc(ow, oh)
	if r == null:
		_swap()
		a = _atlas()
		r = a.alloc(ow, oh)
		if r == null:
			return null
	var rr: Rect2i = r
	var p := a.painter_for(rr)
	var runs := _runs(s)
	if shadow != null:
		var sc: Color = QP.rgb(shadow)
		for run: Array in runs:
			p.fill_rect(int(run[0]) * scale + scale, int(run[1]) * scale + scale, int(run[2]) * scale, scale, sc)
	var col: Color = QP.rgb(rgb)
	for run: Array in runs:
		p.fill_rect(int(run[0]) * scale, int(run[1]) * scale, int(run[2]) * scale, scale, col)
	p.end()
	a.commit()
	var img := QImg.new(a.texture(), Rect2(rr.position.x, rr.position.y, ow, oh))
	_CACHE[key] = img
	return img


## Text mit QP p zeichnen. align: left | center | right. Gibt die Breite zurück.
static func draw(p: QP, x: float, y: float, s: String, rgb: Array, scale: int = 1,
		shadow: Variant = SHADOW, align: String = "left", opacity: float = 1.0) -> int:
	if s == "":
		return 0
	var img := render(s, rgb, scale, shadow)
	var w := text_width(s, scale)
	if align == "center":
		x -= Py.ifloordiv(w, 2)
	elif align == "right":
		x -= w
	if opacity < 1.0:
		p.set_opacity(opacity)
		p.draw_image_at(int(x), int(y), img)
		p.set_opacity(1.0)
	else:
		p.draw_image_at(int(x), int(y), img)
	return w
