class_name Scene
extends RefCounted
## Szenen-Komposition (QP): Stadt + Figuren + Licht + Effekte -> Szenen-Textur.
## 1:1 nach shadegunner/render/scene.py.
##
## Pro Frame:
##   Himmel/Wolken -> Suchscheinwerfer/Spinner -> Skyline fern/mittel (+ Fackeln,
##   Warnlichter, Holo-Billboards, Luftschiff) -> Häuserfront (+ Neon, Laternen)
##   -> nasser Boden (Spiegelungen, Perspektiv-Textur, Lichtkegel) -> Figuren
##   (Schatten, Spiegelbild, Rimlight, Augenreflex) -> Laser/Scan/Leuchtspuren
##   -> Regen, Vordergrund -> Glow-Pass (Leuchtschicht verkleinert/vergrößert,
##   additiv) -> Blitz/Treffer/Blende.
## Danach Bayer-Dither + CRT auf der GPU (CRTChain).
##
## Godot-Aufbau (setup): Im Original zeichnet frame() mit zwei QPaintern in
## self.img (RGB32) und self.emit (ARGB32 premult) und verkleinert emit für den
## Glow auf der CPU. Hier ist jedes "Bild" ein SubViewport:
##
##   parent
##     Baker        (Einmalbilder/Atlanten; muss VOR allen folgenden hängen)
##     SceneEmit    W x H, transparent, jedes Frame geleert  <- Painter e
##     SceneSmall   W//4 x H//4   (Box-Verkleinerung von emit)
##     SceneTiny    W//16 x H//16 (Box-Verkleinerung von small)
##     SceneImg     W x H, opak, wird NIE geleert (wie self.img) <- Painter p
##
## Godot rendert Geschwister-SubViewports in Baumreihenfolge: emit -> small ->
## tiny -> Szene. Der Glow im Szenenbild nutzt also die emit-Texturen desselben
## Frames - wie im Original. CRTChain muss danach im Baum hängen.
##
## Umbenennungen gegenüber Python: self.t -> t_ (Parameter t überall),
## lokale seed -> seed_, lokale img -> im, rng-Parameter -> rng_.

const W := Config.RENDER_W
const H := Config.RENDER_H
const PLUS := QP.PLUS
const OVER := QP.OVER

const _BOX_SHADER := """shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D src : filter_linear, repeat_disable;
uniform vec2 src_size;
uniform vec2 dst_size;
// Flächenmittel wie QImage.scaled(SmoothTransformation) beim Verkleinern:
// 4 bilineare Abgriffe in den Mitten der Teilquadranten -> bei Faktor 4 exakt 4x4-Box.
void fragment() {
	vec2 o = 0.25 / dst_size;
	COLOR = 0.25 * (texture(src, UV + vec2(-o.x, -o.y)) + texture(src, UV + vec2(o.x, -o.y))
		+ texture(src, UV + vec2(-o.x, o.y)) + texture(src, UV + vec2(o.x, o.y)));
}
"""

## Ersatz für das globale `random` des Originals (Luftschiff-Werbung).
static var _grand: PyRandom

var w: int
var h: int
var img: Texture2D            # Szenenbild (self.img) - Textur des Szenen-Viewports
var emit: Texture2D           # Leuchtschicht (self.emit)
var fx: FX
var city: City = null
var _zone_key: Variant = null  # [zone_index, seed, length]
var t_ := 0.0                 # self.t
var spinners: Array = []
var blimp: Variant = null
var bb_frames: Array = []
var screen := {}
var _refl := {}
var _last_cam: Variant = null
var rng: PyRandom
var _gate_open := false
var dark := 0.0               # Stromausfall 0..1 (geglättet)
var sfx: Array = []           # Geräusch-Ereignisse aus der Szene (vorbeifliegende Spinner)
var fog_t := 0.0
var _fog_d := 0.6             # aktuelle Nebeldichte (atmet über die Zeit)
var wisps: Array = []         # Nebelschwaden, die durchs Vordergrundbild ziehen
var _reflk := 1.0             # getattr(self, "_reflk", 1.0)
var _beam_poly: Variant = null

# Godot-Ziele
var baker: Baker
var p: QP
var e: QP
var _scene_vp: SubViewport
var _emit_vp: SubViewport
var _small_vp: SubViewport
var _tiny_vp: SubViewport
var _small_tex: Texture2D
var _tiny_tex: Texture2D
var _first := true


func _init(w_: int = W, h_: int = H) -> void:
	w = w_
	h = h_
	fx = FX.new(1)
	rng = PyRandom.new(5)
	if _grand == null:
		_grand = PyRandom.new(0)


static func _hash(i: int, s: int) -> float:
	var hh := (i * 374761393 + s * 668265263) & 0xFFFFFFFF
	hh = ((hh ^ (hh >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((hh ^ (hh >> 16)) & 0xFFFF) / 65535.0


static func mul(c: Array, f: float) -> Array:
	return [clampi(int(float(c[0]) * f), 0, 255), clampi(int(float(c[1]) * f), 0, 255),
		clampi(int(float(c[2]) * f), 0, 255)]


static func mix(a: Array, b: Array, k: float) -> Array:
	var a0: float = a[0]
	var a1: float = a[1]
	var a2: float = a[2]
	var b0: float = b[0]
	var b1: float = b[1]
	var b2: float = b[2]
	return [int(a0 + (b0 - a0) * k), int(a1 + (b1 - a1) * k), int(a2 + (b2 - a2) * k)]


## getattr(obj, name, default)
static func _wget(o: Variant, name: String, dflt: Variant) -> Variant:
	if o == null or not (o is Object):
		return dflt
	var v: Variant = (o as Object).get(name)
	return dflt if v == null else v


static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v) != ""
	return true


# ------------------------------------------------------------------ Godot-Aufbau
## Baut Leucht-, Glow- und Szenen-Viewport unter parent (Reihenfolge s. Kopf).
## Ohne baker_ wird ein eigener Baker als erstes Kind angelegt; ein übergebener
## Baker muss bereits VOR diesen Knoten im Baum hängen. Liefert die Szenentextur.
func setup(parent: Node, baker_: Baker = null) -> Texture2D:
	if baker_ == null:
		baker_ = Baker.new()
		baker_.name = "Baker"
		parent.add_child(baker_)
	baker = baker_

	_emit_vp = _make_vp("SceneEmit", w, h, true, SubViewport.CLEAR_MODE_ALWAYS)
	var eh := Node2D.new()
	_emit_vp.add_child(eh)
	parent.add_child(_emit_vp)
	e = QP.new(eh.get_canvas_item())
	emit = _emit_vp.get_texture()

	var sw := Py.ifloordiv(W, 4)
	var sh := Py.ifloordiv(H, 4)
	_small_vp = _make_box("SceneSmall", emit, Vector2(w, h), sw, sh)
	parent.add_child(_small_vp)
	_small_tex = _small_vp.get_texture()
	var tw := Py.ifloordiv(W, 16)
	var th_ := Py.ifloordiv(H, 16)
	_tiny_vp = _make_box("SceneTiny", _small_tex, Vector2(sw, sh), tw, th_)
	parent.add_child(_tiny_vp)
	_tiny_tex = _tiny_vp.get_texture()

	_scene_vp = _make_vp("SceneImg", w, h, false, SubViewport.CLEAR_MODE_ONCE)
	var ph := Node2D.new()
	_scene_vp.add_child(ph)
	parent.add_child(_scene_vp)
	p = QP.new(ph.get_canvas_item())
	img = _scene_vp.get_texture()
	return img


static func _make_vp(name: String, vw: int, vh: int, transparent: bool, clear: int) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = name
	vp.size = Vector2i(vw, vh)
	vp.disable_3d = true
	vp.transparent_bg = transparent
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = clear as SubViewport.ClearMode
	return vp


static func _make_box(name: String, src: Texture2D, src_size: Vector2, dw: int, dh: int) -> SubViewport:
	var vp := _make_vp(name, dw, dh, true, SubViewport.CLEAR_MODE_ALWAYS)
	var sh := Shader.new()
	sh.code = _BOX_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("src", src)
	m.set_shader_parameter("src_size", src_size)
	m.set_shader_parameter("dst_size", Vector2(dw, dh))
	var cr := ColorRect.new()
	cr.position = Vector2.ZERO
	cr.size = Vector2(dw, dh)
	cr.material = m
	vp.add_child(cr)
	return vp


# --------------------------------------------------------------------- Billboards
static func _billboard_frames(bk: Baker, brng: PyRandom, bw: int, bh: int, kind: String) -> Array:
	var frames: Array = []
	if kind == "face":
		var hair := [14, 10, 20]
		for blink: bool in [false, false, false, true]:
			var draw := func(q: QP) -> void:
				var g := QGrad.linear(0, 0, 0, bh)
				g.set_color_at(0, QP.rgb([60, 14, 50]))
				g.set_color_at(1, QP.rgb([150, 40, 110]))
				q.fill_rect(0, 0, bw, bh, g)
				var cx := bw * 0.5
				var cy := bh * 0.52
				var fw := bw * 0.42
				var fh := bh * 0.5
				q.set_no_pen()
				q.set_brush(QP.rgb(hair))
				q.draw_ellipse(cx - fw * 0.75, cy - fh * 0.78, fw * 1.5, fh * 1.25)
				q.set_brush(QP.rgb([236, 226, 230]))
				q.draw_ellipse(cx - fw / 2, cy - fh / 2, fw, fh)
				q.set_brush(QP.rgb(hair))
				q.draw_rect(cx - fw * 0.55, cy - fh * 0.62, fw * 1.1, fh * 0.28)
				var ey := cy - fh * 0.05
				q.set_brush(QP.rgb([20, 10, 20]))
				for ex: float in [cx - fw * 0.22, cx + fw * 0.22]:
					if blink:
						q.draw_rect(ex - 2, ey, 4, 1)
					else:
						q.draw_rect(ex - 2, ey - 1, 4, 2)
				q.set_brush(QP.rgb([200, 20, 60]))
				q.draw_rect(cx - 2.5, cy + fh * 0.25, 5, 2)
			frames.append(bk.bake(bw, bh, draw))
	elif kind == "logo":
		var word: String = brng.choice(["TYRELL", "NEXUS", "SHIMATA", "ATARU"])
		for k in range(4):
			var draw := func(q: QP) -> void:
				q.fill_rect(0, 0, bw, bh, QP.rgb([10, 20, 40]))
				var col: Array = [DScene.CYAN, DScene.AMBER, DScene.WHITE, DScene.MAGENTA][k]
				q.set_pen(QP.rgb(col))
				q.draw_rect(2, 2, bw - 5, bh - 5)
				# Pyramiden-/Ring-Emblem
				var cx := bw / 2.0
				var cy := bh * 0.4
				var r := mini(bw, bh) * 0.22
				if k % 2 == 0:
					q.draw_polygon(PackedVector2Array([Vector2(cx - r, cy + r * 0.7), Vector2(cx, cy - r),
						Vector2(cx + r, cy + r * 0.7)]))
				else:
					q.draw_ellipse_c(cx, cy, r, r)
				var txt := word.substr(0, maxi(1, Py.ifloordiv(bw - 4, 6)))
				# pixfont.draw(p, w // 2, int(h * 0.72), txt, col, 1, None, "center") - die
				# Glyphenläufe direkt, damit das gebackene Bild nicht vom Schrift-Atlas abhängt.
				var x0 := Py.ifloordiv(bw, 2) - Py.ifloordiv(Pixfont.text_width(txt, 1), 2)
				var y0 := int(bh * 0.72)
				var cc := QP.rgb(col)
				for run: Array in Pixfont._runs(txt):
					q.fill_rect(x0 + int(run[0]), y0 + int(run[1]), int(run[2]), 1, cc)
			frames.append(bk.bake(bw, bh, draw))
	else:  # Kanji-Säule
		for k in range(4):
			var draw := func(q: QP) -> void:
				q.fill_rect(0, 0, bw, bh, QP.rgb([30, 8, 30]))
				var col: Array = [DScene.MAGENTA, DScene.CYAN, DScene.AMBER, DScene.VIOLET][(k + brng.randint(0, 3)) % 4]
				var cc := QP.rgb(col)
				for gy in range(3, bh - 7, 9):
					for gx in range(3, bw - 5, 8):
						for _i in range(4):
							var x0 := gx + brng.randint(0, 4)
							var y0 := gy + brng.randint(0, 6)
							if brng.random() < 0.5:
								q.fill_rect(x0, y0, brng.randint(1, 4), 1, cc)
							else:
								q.fill_rect(x0, y0, 1, brng.randint(1, 5), cc)
			frames.append(bk.bake(bw, bh, draw))
	return frames


# ------------------------------------------------------------------ Zone
func ensure_zone(zone_index: int, seed_: int, length: Variant = null) -> void:
	if length == null:
		length = (DSim.ZONES[zone_index] as Dictionary)["length"]
	var key := [zone_index, seed_, length]
	if _zone_key != null and key == _zone_key:
		return
	_zone_key = key
	city = City.new(zone_index, float(length), seed_)
	var th: Dictionary = city.th
	fx.set_rain(th["rain"])
	var zr := PyRandom.new(seed_ + 77)
	for fr: Array in bb_frames:      # Godot: alte gebackene Bilder freigeben
		for im: QImg in fr:
			baker.release(im)
	bb_frames = []
	for bb: Array in city.billboards:
		var kind: String = zr.choice(["face", "logo", "kanji"])
		bb_frames.append(_billboard_frames(baker, zr, int(bb[2]), int(bb[3]), kind))
	spinners = []
	for _i in range(int(th["spinners"])):
		_spawn_spinner(zr, true)
	blimp = null
	if th["blimp"]:
		blimp = {"x": zr.uniform(0, W), "y": zr.uniform(28, 60), "ad": zr.choice(DScene.ADS), "off": 0.0}
	_refl.clear()
	_last_cam = null


func _spawn_spinner(rng_: PyRandom, initial: bool = false) -> void:
	var near := rng_.random() < 0.35
	var s := rng_.uniform(1.0, 1.6) if near else rng_.uniform(0.45, 0.8)
	var d: int = rng_.choice([-1, 1])
	var x: float = rng_.uniform(0, W) if initial else (-40.0 if d > 0 else W + 40.0)
	var vx := d * rng_.uniform(30, 70) * s
	var y := rng_.uniform(14, Persp.FACADE_Y * (0.55 if near else 0.75))
	var ph := rng_.random() * 6
	var police := rng_.random() < 0.4
	var bob := rng_.random() * 6
	spinners.append({"x": x, "y": y, "vx": vx, "s": s, "near": near, "ph": ph, "police": police, "bob": bob})
	if near and not initial:
		sfx.append(["spinner", d, s])


# ------------------------------------------------------------------ Events
func consume(_world: Variant, events: Array) -> void:
	for ev: Array in events:
		var k: String = ev[0]
		if k == "shot":
			var sx: float = ev[1]
			var sd: float = ev[2]
			var ex: float = ev[3]
			var ed: float = ev[4]
			var hit: Variant = ev[5]
			fx.tracer(sx, sd, ex, ed, hit)
			var yo := -Persp.figure_h(ed) * 0.62
			fx.impact(ex, ed, yo, [255, 220, 160], 10 if _truthy(hit) else 6, hit != null)
		elif k == "hurt":
			fx.hurt = 1.0
			fx.trauma = minf(1.0, fx.trauma + 0.6)
		elif k == "kill":
			fx.trauma = minf(1.0, fx.trauma + 0.25)
