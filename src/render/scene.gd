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
var _p: QP
var _e: QP
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
	_e = QP.new(eh.get_canvas_item())
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
	_p = QP.new(ph.get_canvas_item())
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


# ------------------------------------------------------------------ Frame
## Zeichnet ein Bild in die Szenen-/Leucht-Viewports und liefert die Szenentextur
## (self.img). Godot rendert es am Ende dieses Frames.
func frame(world: Variant, dt: float = 1.0 / 60.0, show_player: bool = true, fade: float = 0.0,
		power: float = 1.0, cam_override: Variant = null) -> Texture2D:
	var zi: int = world.zone_index
	if city == null or int((_zone_key as Array)[0]) != zi:
		ensure_zone(zi, int(_wget(world, "seed", 0)), world.length)
	t_ += dt
	var t := t_
	var th: Dictionary = city.th
	var seed_: int = int(_wget(world, "seed", 0))
	_reflk = 0.6 + 0.7 * float(th["rain"])     # Regen verstärkt die Spiegelung
	var cam: float = world.camera_x if cam_override == null else cam_override
	var cam_dx := 0.0 if _last_cam == null else (cam - float(_last_cam)) * Persp.PPU_NEAR * 0.6
	_last_cam = cam

	fx.update_rain(dt, cam_dx)
	fx.update_steam(dt)
	fx.update_combat(dt)
	if fx.update_weather(dt, th["rain"]):
		sfx.append(["thunder"])

	# self.emit.fill(0): der Leucht-Viewport wird jedes Frame geleert.
	var p := _p
	var e := _e
	p.begin()
	e.begin()
	if _first:      # RGB32-Bild startet schwarz (Viewport-Clearfarbe wäre grau)
		p.fill_rect(0, 0, W, H, Color(0, 0, 0, 1))
		_first = false
	var sh: Array = fx.shake()
	var sx_: float = sh[0]
	var sy_: float = sh[1]
	p.translate(sx_, sy_)
	e.translate(sx_, sy_)

	_gate_open = world.exit_open() if (world is Object and (world as Object).has_method("exit_open")) else false
	var goal := 1.0 if float(_wget(world, "blackout_t", 0.0)) > 0 else 0.0
	dark += (goal - dark) * minf(1.0, dt * (6.0 if goal > dark else 1.6))
	if dark < 0.01:
		dark = 0.0
	_sky(p, e, cam, t)
	city.far.draw(p, cam)
	_far_life(p, e, cam, t)
	# Nebel atmet über die Zeit: mal dünn, mal zieht eine dichte Bank durch. Die
	# ferne Skyline liegt immer stärker im Dunst als die Front (Luftperspektive).
	fog_t += dt
	var slow := 0.5 + 0.5 * sin(fog_t * 0.07 + seed_ * 0.017)
	var bank := pow(maxf(0.0, sin(fog_t * 0.09 + 2.4)), 5)
	var fog_amt: float = th["fog_amt"]
	_fog_d = fog_amt * (0.85 + 1.15 * slow) + bank * 1.1 * fog_amt + 0.06
	var fd := _fog_d
	_fog(p, 0, 24, 168, cam * DScene.MID_F * 1.4 + t * 5.0, minf(1.0, fd * 0.9))     # hinter der Skyline
	_air_traffic(p, e, cam, t, true)
	_searchlights(p, cam, t)
	_blimp(p, e, dt, t)
	city.mid.draw(p, cam)
	_mid_life(p, e, cam, t)
	_air_traffic(p, e, cam, t, false)
	_spinners(p, e, dt, t, false)
	_holos(p, e, cam, t, "giant")
	_fog_band(p)
	_fog(p, 0, Persp.FACADE_Y - 122, 128, cam * DScene.MID_F * 1.4 + t * 5.0, minf(1.0, fd * 1.5))
	city.facade.draw(p, cam)
	city.facade.draw(e, cam, city.facade_emit, 0, 0.8 * (1.0 - dark))
	_facade_life(p, e, cam, t, dt)
	_street(p, e, cam, t)
	_holos(p, e, cam, t, "street")
	_ramen(p, e, world, cam, t, dt)
	_shout_fx(p, e, world, cam, t)
	_fog(p, 1, Persp.FACADE_Y - 28, 72, cam * Persp.ppu(0.0) + t * 9.0, minf(1.0, fd * 0.7))
	_actors(p, e, world, cam, t, show_player)
	if dark > 0:
		p.fill_rect(0, 0, W, H, QP.c(2, 3, 10, int(165 * dark)))
		_glints(p, e, world, cam, true)
		_flashlight(p, e, world, cam)
	_vehicle_lights(p, e, world, cam, t)
	_combat(p, e, world, cam, t)
	fx.draw_steam(p, cam, city.facade.factor)
	_patrol(p, e, world, cam, t)
	_spinners(p, e, dt, t, true)
	fx.draw_rain(p, mix(th["fog"], DScene.PALE, 0.55))
	_beam_rain(p)
	_fog(p, 1, H - 70, 78, cam * Persp.ppu(1.15) + t * 14.0, minf(1.0, fd * 0.42))
	# Ganzflächiger Nebelschleier: bei dichter Lage verschwimmt auch der Vordergrund
	# (Vordergrund liegt "näher an der Kamera", also über allem anderen).
	_fog_img(p, city.bank, -30, H + 70, cam * Persp.ppu(1.0) * 0.6 + t * 7.0, minf(0.46, fd * 0.34))
	_wisps(p, dt, cam)
	_foreground(p, cam)
	e.end()

	# Glow-Pass: small/tiny sind die (in Baumreihenfolge vorher gerenderten)
	# Box-Verkleinerungen der Leuchtschicht dieses Frames.
	p.reset_transform()
	p.set_mode(PLUS)
	p.set_smooth(true)
	var gb := 0.85 + 0.5 * minf(1.5, _fog_d)   # Lichter bluten im Nebel
	p.set_opacity(minf(1.0, gb))
	p.draw_texture(Rect2(0, 0, W, H), _small_tex)
	p.set_opacity(minf(1.0, gb * 0.85))
	p.draw_texture(Rect2(0, 0, W, H), _tiny_tex)
	p.set_opacity(1.0)
	p.set_smooth(false)
	if fx.lightning > 0:
		p.set_opacity(fx.lightning * 0.22)
		p.fill_rect(0, 0, W, H, QP.rgb([200, 210, 255]))
		p.set_opacity(1.0)
	p.set_mode(OVER)
	if fx.hurt > 0:
		var g := QGrad.radial(W / 2.0, H / 2.0, W * 0.7)
		g.set_color_at(0.5, QP.c(0, 0, 0, 0))
		g.set_color_at(1.0, QP.c(160, 20, 40, int(200 * fx.hurt)))
		p.fill_rect(0, 0, W, H, g)
	if fade > 0:
		p.fill_rect(0, 0, W, H, QP.c(0, 0, 0, int(255 * minf(1.0, fade))))
	if power < 1.0:
		_power_on(p, power)
	p.end()
	return img


# ------------------------------------------------------------------ Himmel
func _sky(p: QP, e: QP, cam: float, t: float) -> void:
	var th: Dictionary = city.th
	p.draw_image_at(0, 0, city.sky)
	if fx.lightning > 0:
		p.set_opacity(fx.lightning * 0.5)
		p.fill_rect(0, 0, W, int(Persp.FACADE_Y), QP.rgb(mix(th["cloud_lit"], [200, 200, 255], 0.5)))
		p.set_opacity(1.0)
	for cl: Array in city.cloud_layers:
		var im: QImg = cl[0]
		var speed: float = cl[1]
		var fac: float = cl[2]
		var off := Py.mod(t * speed + cam * fac, im.width())
		var x := -off
		p.draw_image_at(int(x), 0, im)
		if x + im.width() < W:
			p.draw_image_at(int(x + im.width()), 0, im)
	if fx.bolt != null:
		var pts := PackedVector2Array()
		for pt: Array in fx.bolt:
			pts.append(Vector2(float(pt[0]), float(pt[1])))
		for q: QP in [p, e]:
			q.set_pen(QP.c(230, 236, 255, 255), 1)
			q.draw_polyline(pts)
	_spinners(p, e, 0.0, t, null)


func _far_life(p: QP, e: QP, cam: float, t: float) -> void:
	var far: City.Layer = city.far
	# Fackeln (Hades)
	for fl: Array in city.flames:
		var L: float = fl[0]
		var y: float = fl[1]
		var ph: float = fl[2]
		var sc: float = fl[3]
		var x: float = far.screen_x(L, cam)
		if x < -30 or x > W + 30:
			continue
		var n := _hash(int(t * 12 + ph * 10), int(ph * 1000))
		var burst := _hash(int(t * 0.4 + ph), int(ph * 777)) > 0.82
		var hgt := (4 + 5 * n) * sc * (2.6 if burst else 1.0)
		var wid := 2.5 * sc * (1.8 if burst else 1.0)
		for q: QP in [p, e]:
			q.set_no_pen()
			q.set_brush(QP.rgb(DScene.AMBER))
			q.draw_polygon(PackedVector2Array([Vector2(x - wid, y), Vector2(x + (n - 0.5) * 2, y - hgt), Vector2(x + wid, y)]))
			q.set_brush(QP.rgb([255, 240, 200]))
			q.draw_rect(x - 1, y - hgt * 0.4, 2, hgt * 0.4)
		if burst:
			var g := QGrad.radial(x, y - hgt * 0.5, 26 * sc)
			g.set_color_at(0, QP.c(255, 140, 50, 90))
			g.set_color_at(1, QP.c(0, 0, 0, 0))
			p.set_mode(PLUS)
			p.fill_rect(x - 30 * sc, y - 40 * sc, 60 * sc, 60 * sc, g)
			p.set_mode(OVER)
	_blinks(p, e, cam, t, "far", far)


func _blinks(p: QP, e: QP, cam: float, t: float, which: String, lay: City.Layer) -> void:
	for bl: Array in city.blinks:
		var wh: String = bl[0]
		if wh != which:
			continue
		var L: float = bl[1]
		var y: float = bl[2]
		var col: Array = bl[3]
		var ph: float = bl[4]
		var x: float = lay.screen_x(L, cam)
		if x < -2 or x > W + 2:
			continue
		var on := sin(t * 2.2 + ph * 2.1) > 0.55
		if on:
			for q: QP in [p, e]:
				q.fill_rect(int(x) - 1, y - 1, 2, 2, QP.rgb(col))
		else:
			p.fill_rect(int(x), y, 1, 1, QP.rgb(mul(col, 0.4)))


func _searchlights(p: QP, cam: float, t: float) -> void:
	if city.searchlights.is_empty():
		return
	p.set_mode(PLUS)
	p.set_no_pen()
	var tint := mix([170, 180, 220], city.th["sky_hor"], 0.25)
	var tr_: int = tint[0]
	var tg: int = tint[1]
	var tb: int = tint[2]
	for sl: Array in city.searchlights:
		var L: float = sl[0]
		var y: float = sl[1]
		var sp: float = sl[2]
		var ph: float = sl[3]
		var x: float = city.mid.screen_x(L, cam)
		if x < -260 or x > W + 260:
			continue
		var ang := sin(t * sp + ph) * 0.62 + 0.12 * sin(t * sp * 2.7 + ph * 3)
		var ln := 330.0
		var tx := x + sin(ang) * ln
		var ty := y - cos(ang) * ln
		# weiter, weicher Kegel + enger heller Kern (volumetrisch im Dunst)
		for wa: Array in [[30, 40], [8, 70]]:
			var wdt: int = wa[0]
			var a: int = wa[1]
			var nx := cos(ang) * wdt
			var ny := sin(ang) * wdt
			var g := QGrad.linear(x, y, tx, ty)
			g.set_color_at(0, QP.c(tr_, tg, tb, a))
			g.set_color_at(0.55, QP.c(tr_, tg, tb, Py.ifloordiv(a, 3)))
			g.set_color_at(1, QP.c(0, 0, 0, 0))
			p.set_brush(g)
			p.draw_polygon(PackedVector2Array([Vector2(x - 1, y), Vector2(tx - nx, ty - ny), Vector2(tx + nx, ty + ny),
				Vector2(x + 1, y)]))
		# Lichtfleck auf den Wolken
		if ty < 70:
			var rg := QGrad.radial(tx, maxf(4, ty), 40)
			rg.set_color_at(0, QP.c(tr_, tg, tb, 40))
			rg.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(tx - 40, maxf(4, ty) - 40, 80, 80, rg)
		p.fill_rect(int(x) - 1, y - 1, 3, 2, QP.rgb(DScene.PALE))
	p.set_mode(OVER)


## Luftstraßen: Ketten aus Positionslichtern, die über die Stadt ziehen.
func _air_traffic(p: QP, e: QP, cam: float, t: float, far: bool) -> void:
	var span := W + 240
	var pale := PackedVector2Array()
	var amber := PackedVector2Array()
	var white := PackedVector2Array()
	var red := PackedVector2Array()
	var bodies: Array[Rect2] = []
	for ln: Dictionary in city.air:
		var fac: float = ln["fac"]
		if (fac < DScene.MID_F) != far:
			continue
		var d: int = ln["dir"]
		var lph: float = ln["ph"]
		var gap: float = ln["gap"]
		var speed: float = ln["speed"]
		var ly: float = ln["y"]
		var slope: float = ln["slope"]
		var size: int = ln["size"]
		for k in range(int(ln["n"])):
			var base := lph + k * gap + t * speed * d - cam * fac
			var x := int(Py.mod(base, span) - 120)
			var y := int(ly + slope * x + (k % 3) * 2)
			if size == 1:
				if k % 2:
					pale.append(Vector2(x, y))
				else:
					amber.append(Vector2(x, y))
			else:
				bodies.append(Rect2(x - 2, y, 5, 2))
				white.append(Vector2(x + 2 * d, y))
				red.append(Vector2(x - 2 * d, y))
	for r in bodies:
		p.fill_rect(r.position.x, r.position.y, r.size.x, r.size.y, QP.rgb([20, 22, 32]))
	for grp: Array in [[pale, DScene.PALE, true], [amber, DScene.AMBER, false], [white, DScene.WHITE, true],
			[red, [240, 40, 70], true]]:
		var pts: PackedVector2Array = grp[0]
		if pts.is_empty():
			continue
		var col: Array = grp[1]
		var glow: bool = grp[2]
		for q: QP in ([p, e] if glow else [p]):
			q.set_pen(QP.rgb(col))
			q.draw_points(pts)


## Kachelnde Nebelschwaden, gestreckt auf Höhe h.
func _fog(p: QP, idx: int, y: float, fh: float, scroll: float, opacity: float) -> void:
	_fog_img(p, city.fog_layers[idx], y, fh, scroll, opacity)


func _fog_img(p: QP, im: QImg, y: float, fh: float, scroll: float, opacity: float) -> void:
	if opacity <= 0.01:
		return
	var iw := im.width()
	var off := Py.mod(scroll, iw)
	p.set_opacity(minf(1.0, opacity))
	p.set_smooth(true)
	var x := -off
	while x < W:
		p.draw_image(Rect2(x, y, iw, fh), im)
		x += iw
	p.set_smooth(false)
	p.set_opacity(1.0)


func _blimp(p: QP, e: QP, dt: float, t: float) -> void:
	if blimp == null:
		return
	var b: Dictionary = blimp
	b["x"] = float(b["x"]) - 6.0 * dt
	if float(b["x"]) < -170:
		b["x"] = W + 60.0
		b["ad"] = _grand.choice(DScene.ADS)
	var x: float = b["x"]
	var y: float = b["y"]
	var bw := 120.0
	var bh := 26.0
	var g := QGrad.linear(0, y, 0, y + bh)
	g.set_color_at(0, QP.rgb([40, 44, 66]))
	g.set_color_at(1, QP.rgb([12, 14, 24]))
	p.set_no_pen()
	p.set_brush(g)
	p.draw_ellipse(x, y, bw, bh)
	p.fill_rect(x + bw - 8, y + 4, 10, 6, QP.rgb([20, 22, 34]))
	# Werbe-Laufband
	var sx := x + 18
	var sy := y + 8
	var sw := 80.0
	var sh := 10.0
	p.fill_rect(sx - 1, sy - 1, sw + 2, sh + 2, QP.rgb(DScene.VOID))
	var im: QImg = Pixfont.render(str(b["ad"]) + "   ", DScene.AMBER, 1, null)
	var off := Py.imod(int(t * 22), im.width())
	for q: QP in [p, e]:
		q.save()
		q.set_clip_rect(sx, sy, sw, sh)
		q.draw_image_at(int(sx - off), int(sy + 2), im)
		q.draw_image_at(int(sx - off + im.width()), int(sy + 2), im)
		q.restore()
	# Lichter + Strahlen nach unten
	for q: QP in [p, e]:
		if Py.imod(int(t * 2), 2) == 0:
			q.fill_rect(x + 4, y + bh / 2, 2, 2, QP.rgb(DScene.CRIMSON))
		q.fill_rect(x + bw / 2, y + bh - 1, 2, 2, QP.rgb(DScene.PALE))
	p.set_mode(PLUS)
	for kp: Array in [[0, 0.0], [1, 2.0]]:
		var k: int = kp[0]
		var ph: float = kp[1]
		var bx := x + 40 + k * 30
		var ang := sin(t * 0.6 + ph) * 0.35
		var ln := 140.0
		var tx := bx + sin(ang) * ln
		var ty := y + bh + cos(ang) * ln
		var gg := QGrad.linear(bx, y + bh, tx, ty)
		gg.set_color_at(0, QP.c(110, 110, 140, 60))
		gg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.set_brush(gg)
		p.draw_polygon(PackedVector2Array([Vector2(bx - 1, y + bh), Vector2(tx - 16, ty), Vector2(tx + 16, ty),
			Vector2(bx + 1, y + bh)]))
	p.set_mode(OVER)


func _mid_life(p: QP, e: QP, cam: float, t: float) -> void:
	var mid: City.Layer = city.mid
	_blinks(p, e, cam, t, "mid", mid)
	for i in range(city.billboards.size()):
		var bb: Array = city.billboards[i]
		var L: float = bb[0]
		var y: float = bb[1]
		var bw: int = bb[2]
		var bh: int = bb[3]
		var bseed: int = bb[4]
		var x: float = mid.screen_x(L, cam)
		if x < -bw or x > W:
			continue
		var frames: Array = bb_frames[i]
		var k := Py.imod(int(t * 0.5 + bseed), frames.size())
		if not frames.is_empty() and frames.size() == 4 and _hash(int(t * 3), bseed) < 0.15:
			k = 3
		var im: QImg = frames[k]
		var glitch := _hash(int(t * 8), bseed + 1) < 0.08
		for qo: Array in [[p, 0.92], [e, 0.6]]:
			var q: QP = qo[0]
			q.set_opacity(qo[1])
			if glitch:
				for row in range(0, bh, 4):
					var off := int((_hash(row + int(t * 30), bseed) - 0.5) * 6)
					q.draw_image(Rect2(int(x) + off, y + row, bw, 4), im, Rect2(0, row, bw, 4))
			else:
				q.draw_image_at(int(x), y, im)
			q.set_opacity(1.0)


## near: null = ferne Spinner hinter der Skyline, false = mittlere, true = nahe.
func _spinners(p: QP, e: QP, dt: float, t: float, near: Variant) -> void:
	var sel: Array = []
	for s: Dictionary in spinners:
		var sn: bool = s["near"]
		var ss: float = s["s"]
		if near == null:
			if not sn and ss < 0.6:
				sel.append(s)
		elif near:
			if sn:
				sel.append(s)
		elif not sn and ss >= 0.6:
			sel.append(s)
	if dt > 0 and typeof(near) == TYPE_BOOL and near:
		for i in range(spinners.size()):
			var s: Dictionary = spinners[i]
			s["x"] = float(s["x"]) + float(s["vx"]) * dt
			if float(s["x"]) < -80 or float(s["x"]) > W + 80:
				spinners.remove_at(i)
				_spawn_spinner(rng)
				break
	for s: Dictionary in sel:
		var sc: float = s["s"]
		var x: float = s["x"]
		var y: float = float(s["y"]) + sin(t * 1.3 + float(s["bob"])) * 1.5 * sc
		var d := 1 if float(s["vx"]) > 0 else -1
		_spinner_body(p, e, x, y, sc, d, t + float(s["ph"]), near, s["police"])


## Fliegender Spinner (gleiche Silhouette wie am Boden), Anker = Rumpfmitte.
func _spinner_body(p: QP, e: QP, x: float, y: float, sc: float, d: int, t: float, near: Variant, police: bool) -> void:
	var ppx := 22 * sc / DVehicles.SPIN_L
	var far: bool = near == null or (not near and sc < 0.9)
	_spinner_sprite(p, e, x, y + 10 * ppx, ppx, d, t, police, far, true)


func _spinner_sprite(p: QP, e: QP, x: float, gy: float, ppx: float, d: int, t: float, police: bool,
		far: bool = false, cone: bool = true) -> void:
	var r: Array = Vehicles.spinner_image(ppx, police, d, far)
	var im: QImg = r[0]
	var em: QImg = r[1]
	var ax: int = r[2]
	var ayg: int = r[4]
	var kq := maxf(0.25, Py.round(ppx * 8) / 8.0)
	var x0 := int(x) - ax
	var y0 := int(gy) - ayg
	p.draw_image_at(x0, y0, im)
	if not far:
		e.draw_image_at(x0, y0, em)
	var nx: float = DVehicles.SPIN_NOSE[0]
	var ny: float = DVehicles.SPIN_NOSE[1]
	var hx := x + nx * kq * d
	var hy := gy + ny * kq
	if cone:
		p.set_mode(PLUS)
		var ln := 60 * kq / 0.35 if not far else 30 * kq / 0.35
		var g := QGrad.linear(hx, hy, hx + ln * d, hy + ln * 0.3)
		g.set_color_at(0, QP.c(130, 130, 150, 70 if not far else 30))
		g.set_color_at(1, QP.c(0, 0, 0, 0))
		p.set_no_pen()
		p.set_brush(g)
		p.draw_polygon(PackedVector2Array([Vector2(hx, hy - 1), Vector2(hx + ln * d, hy + ln * 0.08),
			Vector2(hx + ln * 0.9 * d, hy + ln * 0.42), Vector2(hx, hy + 1)]))
		p.set_mode(OVER)
	if police:
		_spinner_lights(p, e, x, gy, kq, kq, d, t)
	elif Py.imod(int(t * 1.5), 2) == 0:
		var tx: float = DVehicles.SPIN_TAIL[0]
		var ty: float = DVehicles.SPIN_TAIL[1]
		for q: QP in [p, e]:
			q.fill_rect(x + tx * kq * d - 1, gy + ty * kq, 2, 1, QP.rgb(DScene.CRIMSON))


## Lichtbalken (rot/blau im Wechsel) + Mittelscheinwerfer + Blitzer am Unterboden.
func _spinner_lights(p: QP, e: QP, cx: float, gy: float, kx: float, ky: float, d: int, t: float) -> void:
	var bx: float = DVehicles.SPIN_BAR[0]
	var by: float = DVehicles.SPIN_BAR[1]
	var bw: float = DVehicles.SPIN_BAR[2]
	var bh: float = DVehicles.SPIN_BAR[3]
	var ph := Py.imod(int(t * 7), 4)
	var w2 := bw * kx / 2
	var x0 := cx + bx * kx * d + (0.0 if d > 0 else -bw * kx)
	var y0 := gy + by * ky
	var hh := maxf(1.0, bh * ky)
	var left: Array = DScene.MAGENTA if ph in [0, 1] else [40, 20, 30]
	var right: Array = [90, 140, 255] if ph in [2, 3] else [20, 30, 50]
	if ph == 1:
		right = DScene.WHITE
	for q: QP in [p, e]:
		q.fill_rect(x0, y0, w2, hh, QP.rgb(left))
		q.fill_rect(x0 + w2, y0, w2, hh, QP.rgb(right))
		q.fill_rect(cx + (bx + 4.2) * kx * d - kx, y0 - maxf(1.0, 1.2 * ky), maxf(1.0, 2.4 * kx),
			maxf(1.0, 1.2 * ky), QP.rgb(DScene.WHITE))
	if ph in [0, 2]:
		var c: Array = DScene.MAGENTA if ph == 0 else [90, 140, 255]
		p.set_mode(PLUS)
		var rg := QGrad.radial(x0 + w2, y0, 18 * kx)
		rg.set_color_at(0, QP.rgb(c, 90))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.fill_rect(x0 + w2 - 18 * kx, y0 - 18 * kx, 36 * kx, 36 * kx, rg)
		p.set_mode(OVER)


## Dunst über der Skyline: die Ferne versinkt stärker im Nebel als die Front.
func _fog_band(p: QP) -> void:
	var th: Dictionary = city.th
	var fy := Persp.FACADE_Y
	var fd := _fog_d
	var fc := mix(th["fog"], th["sky_hor"], 0.5)
	var g := QGrad.linear(0, fy - 150, 0, fy + 6)
	g.set_color_at(0.0, QP.rgb(fc, 0))
	g.set_color_at(0.55, QP.rgb(fc, int(255 * minf(1.0, fd * 0.3))))
	g.set_color_at(1.0, QP.rgb(fc, int(255 * minf(1.0, fd * 0.75))))
	p.fill_rect(0, fy - 150, W, 157, g)


# ====================================================================== TEIL B/C
# Platzhalter mit der Signatur des Originals (Parameter mit "_" bis zum Port,
# sonst schlagen unused_parameter-Warnungen als Fehler an).

func _ramen(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float, _dt: float) -> void:
	pass  # TEIL B/C


func _cook(_p_: QP, _e_: QP, _cx: float, _base: float, _t: float, _greet: Variant, _serving: Variant) -> void:
	pass  # TEIL B/C


func _holos(_p_: QP, _e_: QP, _cam: float, _t: float, _kind: String) -> void:
	pass  # TEIL B/C


func _shout_fx(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _new_wisp(_rng_: PyRandom, _initial: bool = false) -> void:
	pass  # TEIL B/C


func _wisps(_p_: QP, _dt: float, _cam: float) -> void:
	pass  # TEIL B/C


func _facade_life(_p_: QP, _e_: QP, _cam: float, _t: float, _dt: float) -> void:
	pass  # TEIL B/C


func _gate(_p_: QP, _e_: QP, _x: float, _g: Variant, _t: float) -> void:
	pass  # TEIL B/C


func _street(_p_: QP, _e_: QP, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _rim_for(_a: Variant, _cam: float) -> Variant:
	return null  # TEIL B/C


func _mirror(_img: QImg) -> Variant:
	return null  # TEIL B/C


func _actors(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float, _show_player: bool) -> void:
	pass  # TEIL B/C


func _draw_actor(_p_: QP, _e_: QP, _a: Variant, _cam: float, _t: float, _lit: bool = false) -> void:
	pass  # TEIL B/C


func _glints(_p_: QP, _e_: QP, _world: Variant, _cam: float, _boost: bool = false) -> void:
	pass  # TEIL B/C


func _flashlight(_p_: QP, _e_: QP, _world: Variant, _cam: float) -> void:
	pass  # TEIL B/C


func _draw_vehicle(_p_: QP, _e_: QP, _v: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _vehicle_lights(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _draw_origami(_p_: QP, _e_: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _draw_parked(_p_: QP, _e_: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _draw_steam(_p_: QP, _e_: QP, _m: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _draw_obstacle(_p_: QP, _e_: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _patrol_geom(_world: Variant, _cam: float, _t: float) -> Variant:
	return null  # TEIL B/C


func _land_pose(_P: Variant, _cam: float, _t: float) -> Variant:
	return null  # TEIL B/C


func _draw_landing(_p_: QP, _e_: QP, _P: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _patrol(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _beam_rain(_p_: QP) -> void:
	if _beam_poly == null:   # bp = getattr(self, "_beam_poly", None)
		return
	pass  # TEIL B/C


func _hand(_world: Variant) -> Variant:
	return null  # TEIL B/C


func _chest(_a: Variant, _cam: float) -> Variant:
	return null  # TEIL B/C


func _combat(_p_: QP, _e_: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass  # TEIL B/C


func _foreground(_p_: QP, _cam: float) -> void:
	pass  # TEIL B/C


func _power_on(_p_: QP, _k: float) -> void:
	pass  # TEIL B/C
