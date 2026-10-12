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

## Nudelbar lebt: Lichtpool auf dem nassen Asphalt, Glühbirnen, Laternen,
## Koch mit Nudelsieb, flackernde Drachenzunge, Tropfen vom Vordach, Dampf.
func _ramen(p: QP, e: QP, world: Variant, cam: float, t: float, dt: float) -> void:
	var fac: City.Layer = city.facade
	var spots: Array = world.ramen
	var pl: Variant = world.player
	var lv_dark := 1.0 - 0.55 * dark
	p.set_no_pen()
	for sp: Dictionary in city.ramen_spots:
		var x0: float = fac.screen_x(float(sp["L"]), cam)
		if x0 < -240 or x0 > W + 60:
			continue
		var base: float = sp["base"]
		var spw: float = sp["w"]
		var cxw := (float(sp["L"]) + spw / 2) / fac.factor
		var r: Variant = null
		for rr: Dictionary in spots:
			if absf(float(rr["x"]) - cxw) < 6:
				r = rr
				break
		var used := r != null and bool(r["used"])
		# Lichtpool auf der Straße (breit, warm) + Lichtkegel der Birnen
		p.set_mode(PLUS)
		var gx := Persp.screen_x(cxw, 0.16, cam)
		var gy := Persp.ground_y(0.16)
		var g := QGrad.radial(gx, gy, 110)
		g.set_color_at(0.0, QP.rgb([255, 150, 60], int(62 * lv_dark)))
		g.set_color_at(0.5, QP.rgb([255, 110, 40], int(22 * lv_dark)))
		g.set_color_at(1.0, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(gx, gy)
		p.scale(1.0, 0.28)
		p.translate(-gx, -gy)
		p.fill_rect(gx - 110, gy - 110, 220, 220, g)
		p.restore()
		for i in range((sp["bulbs"] as Array).size()):
			var bb: Array = sp["bulbs"][i]
			var bl: float = bb[0]
			var by: float = bb[1]
			var bx: float = fac.screen_x(bl, cam)
			var fl := 0.2 if (i == 2 and Scene._hash(int(t * 15), int(bl)) < 0.12) else 1.0
			var rg := QGrad.radial(bx, by + 1, 18)
			rg.set_color_at(0, QP.rgb([255, 206, 140], int(55 * fl * lv_dark)))
			rg.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(bx - 18, by - 17, 36, 36, rg)
			if fl < 1.0:        # Wackelkontakt: Birne kurz aus
				p.set_mode(OVER)
				p.fill_rect(bx - 1, by, 3, 3, QP.rgb([70, 50, 30]))
				p.set_mode(PLUS)
		for ll_: Array in sp["lanterns"]:
			var ll: float = ll_[0]
			var ly: float = ll_[1]
			var lx: float = fac.screen_x(ll, cam)
			var rg2 := QGrad.radial(lx, ly, 16)
			rg2.set_color_at(0, QP.rgb([255, 60, 60], int(50 * lv_dark)))
			rg2.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(lx - 16, ly - 16, 32, 32, rg2)
		p.set_mode(OVER)
		# Koch: grüßt, wenn der Blade Runner herankommt; reicht beim Essen die Schale
		var near: bool = r != null and absf(float(pl.x) - float(r["x"])) < 70 and float(pl.depth) < 0.7
		var serving: bool = r != null and float(r["t"]) > 0.05 and not used
		_cook(p, e, fac.screen_x(float(sp["cook"]), cam), base, t, near and not serving, serving)
		if used:   # leere Schale am freien Platz
			var cx := int(fac.screen_x(float(sp["cook"]), cam))
			p.fill_rect(cx - 2, base - 20, 5, 2, QP.rgb([200, 202, 210]))
		# Drachenzunge (rot, flackert wie im Film)
		var tng: Array = sp["tongue"]
		var tx := int(fac.screen_x(float(tng[0]), cam))
		var ty: float = tng[1]
		if Scene._hash(int(t * 11), int(float(tng[0]))) > 0.35 and dark < 0.4:
			for q: QP in [p, e]:
				q.fill_rect(tx - 3, ty, 3, 1, QP.rgb([255, 50, 70]))
				q.fill_rect(tx - 4, ty - 1, 1, 1, QP.rgb([255, 50, 70]))
				q.fill_rect(tx - 4, ty + 1, 1, 1, QP.rgb([255, 50, 70]))
		# Wok-Flamme
		var wk: Array = sp["wok"]
		var wx: float = fac.screen_x(float(wk[0]), cam)
		var wy: float = wk[1]
		var fh := 2 + 3 * Scene._hash(int(t * 20), int(float(wk[0])))
		for q: QP in [p, e]:
			q.fill_rect(wx - 6, wy + 4, 12, 1, QP.rgb([90, 140, 255]))
			q.fill_rect(wx - 4, wy + 4 - fh, 2, fh, QP.rgb(DScene.AMBER))
			q.fill_rect(wx + 2, wy + 5 - fh, 2, fh - 1, QP.rgb(DScene.AMBER))
		# Tropfen vom Vordach
		var lip: float = sp["lip"]
		var fall := base - lip - 2
		for k in range((sp["drips"] as Array).size()):
			var dl: float = sp["drips"][k]
			var ph := Py.mod(t * 0.9 + Scene._hash(k, int(float(sp["L"]))) * 7.0, 1.0)
			var dx := int(fac.screen_x(dl, cam))
			if ph < 0.7:
				var y := lip + fall * pow(ph / 0.7, 2.0)
				p.fill_rect(dx, int(y), 1, 2, QP.rgb([170, 182, 204]))
			elif ph < 0.8:
				p.fill_rect(dx - 1, base - 1, 3, 1, QP.rgb([150, 160, 186]))
		# Dampf: Suppentopf, Wok, Schalen
		if rng.random() < dt * 4.0:
			var pot: Array = sp["pot"]
			fx.puff(float(pot[0]) + rng.uniform(-6, 6), pot[1], null, null, 0.8)
		if rng.random() < dt * 1.5:
			fx.puff(wx + rng.uniform(-3, 3), wy - 2, null, null, 0.6)
		for bl_ in (sp.get("bowls", []) as Array):
			if rng.random() < dt * 0.5:
				fx.puff(bl_, base - 22, null, null, 0.4)


## Koch hinter der Theke: weiße Jacke, Stirnband, schüttelt das Nudelsieb.
func _cook(p: QP, _ea: QP, cx: float, base: float, t: float, greet: bool, serving: bool) -> void:
	var x := int(cx + sin(t * 1.3) * 2)
	var top_c := base - 18
	var jacket := [214, 196, 170]
	var shade := [150, 126, 100]
	var skin := [150, 104, 72]
	p.set_no_pen()
	p.fill_rect(x - 5, base - 31, 10, top_c - base + 31, QP.rgb(jacket))
	p.fill_rect(x - 5, base - 31, 2, top_c - base + 31, QP.rgb(shade))
	p.fill_rect(x - 1, base - 31, 2, 2, QP.rgb(skin))
	p.set_brush(QP.rgb(skin))
	p.draw_ellipse(x - 3, base - 38, 7, 8)
	p.fill_rect(x - 3, base - 38, 7, 2, QP.rgb([30, 24, 20]))
	p.fill_rect(x - 4, base - 36, 9, 1, QP.rgb([240, 240, 244]))
	p.fill_rect(x - 3, base - 38, 7, 1, QP.rgb(Scene.mix([30, 24, 20], DScene.AMBER, 0.5)))
	if greet:          # winkt: „Irasshai!“
		var a := -1.9 + 0.35 * sin(t * 9)
		var sx := x + 4.0
		var sy := base - 31
		var hx := sx + cos(a) * 7
		var hy := sy + sin(a) * 7
		p.set_pen(QP.rgb(jacket), 2)
		p.draw_line(sx, sy, hx, hy)
		p.set_no_pen()
		p.fill_rect(hx - 1, hy - 2, 3, 3, QP.rgb(skin))
	elif serving:      # reicht die Schale über den Tresen
		p.set_pen(QP.rgb(jacket), 2)
		p.draw_line(x + 4, base - 30, x + 3, top_c - 3)
		p.draw_line(x - 4, base - 30, x - 3, top_c - 3)
		p.set_no_pen()
		p.fill_rect(x - 4, top_c - 3, 9, 3, QP.rgb([226, 228, 234]))
		p.fill_rect(x - 3, top_c - 4, 7, 1, QP.rgb([214, 150, 80]))
	else:              # Nudelsieb schütteln
		var k := sin(t * 7.0) * 2.0 if Py.mod(t, 4.0) < 2.4 else 0.0
		var sx2 := x + 4.0
		var sy2 := base - 31
		var hx2 := x + 9.0
		var hy2 := top_c - 4 + k
		p.set_pen(QP.rgb(jacket), 2)
		p.draw_line(sx2, sy2, hx2, hy2)
		p.set_no_pen()
		p.fill_rect(hx2, hy2, 5, 1, QP.rgb([120, 124, 134]))
		p.set_brush(QP.rgb([150, 154, 166]))
		p.draw_chord(hx2 + 4, hy2 - 1, 5, 4, 180 * 16, 180 * 16)
		p.fill_rect(hx2 + 5, hy2 + 1, 3, 1, QP.rgb([230, 200, 120]))


# ------------------------------------------------------------------ Hologramme
func _holos(p: QP, e: QP, cam: float, t: float, kind: String) -> void:
	var hs: Array = city.holos
	if hs.is_empty():
		return
	var dim := 1.0 - 0.85 * dark          # Stromausfall: Hologramme fallen (fast) aus
	if dim <= 0.05:
		return
	for hd: Dictionary in hs:
		if hd["kind"] != kind:
			continue
		var lay: City.Layer = city.mid if kind == "giant" else city.facade
		var x: float = lay.screen_x(float(hd["L"]), cam)
		var hh: float = hd["h"]
		if x < -hh or x > W + hh:
			continue
		var col: Array = hd["col"]
		if kind == "street":
			# Projektorsockel mit Linse + schwacher Lichtsäule
			var b: float = hd["base"]
			p.fill_rect(int(x) - 6, b - 4, 12, 5, QP.rgb([26, 28, 40]))
			p.fill_rect(int(x) - 6, b - 4, 12, 1, QP.rgb(City.mul(city.th["rim"], 0.8)))
			for q: QP in [p, e]:
				q.fill_rect(int(x) - 3, b - 5, 6, 1, QP.rgb(col))
			p.set_mode(PLUS)
			var g := QGrad.linear(x, b - 5, x, b - hh)
			g.set_color_at(0, QP.rgb(col, int(40 * dim)))
			g.set_color_at(1, QP.c(0, 0, 0, 0))
			p.set_no_pen()
			p.set_brush(g)
			p.draw_polygon(PackedVector2Array([Vector2(x - 3, b - 5), Vector2(x - hh * 0.3, b - hh),
				Vector2(x + hh * 0.3, b - hh), Vector2(x + 3, b - 5)]))
			p.set_mode(OVER)
			Holo.render(p, e, x, b - 5, hh, col, t, hd["seed"], 0.4, 0.95 * dim, hd["mirror"])
		else:
			Holo.render(p, e, x, hd["base"], hh, col, t * 0.85, hd["seed"], 0.0, 0.6 * dim, hd["mirror"])


# ------------------------------------------------------------------ Ruf
## Rufwelle als Ring auf dem nassen Asphalt; beim Halten von V ein Lade-Ring.
func _shout_fx(p: QP, _ea: QP, world: Variant, cam: float, t: float) -> void:
	var pl: Variant = world.player
	var rings: Array = []
	var wave: Variant = world.wave
	if wave != null and float(wave["r"]) > 0:
		var k := float(wave["r"]) / maxf(1.0, float(wave["R"]))
		rings.append([wave["x"], wave["depth"], wave["r"], maxf(0.0, 1.0 - k) * 0.9 + 0.1, [214, 220, 226]])
	var hold: float = world.shout_hold
	if hold >= Config.SHOUT_TAP and pl.alive:
		var R: float = world.shout_radius()
		var pulse := 0.55 + 0.25 * sin(t * 14)
		rings.append([pl.x, pl.depth, R, pulse, [255, 138, 44]])
	if rings.is_empty():
		return
	p.set_mode(PLUS)
	p.set_no_brush()
	for rg: Array in rings:
		var x: float = rg[0]
		var d: float = rg[1]
		var r: float = rg[2]
		var a: float = rg[3]
		var col: Array = rg[4]
		# Kreis in Welt-Einheiten (x, Tiefe*DEPTH_UNITS) -> Ellipse auf dem Boden
		var cx := Persp.screen_x(x, d, cam)
		var cy := Persp.ground_y(d)
		var rx := r * Persp.ppu(d)
		var ry := r / Config.DEPTH_UNITS * (Persp.ground_y(1) - Persp.ground_y(0))
		for wd_a: Array in [[3, 0.35], [1, 1.0]]:
			var wd: int = wd_a[0]
			var aa: float = wd_a[1]
			p.set_pen(QP.rgb(col, int(150 * a * aa)), wd)
			p.draw_ellipse(cx - rx, cy - ry, 2 * rx, 2 * ry)
	p.set_no_pen()
	p.set_mode(OVER)


func _new_wisp(rng_: PyRandom, initial: bool = false) -> Dictionary:
	var x: float = rng_.uniform(0, W) if initial else rng_.choice([-170.0, W + 170.0])
	var vx := rng_.uniform(6, 15) * (1 if x < W * 0.5 else -1)
	return {"x": x, "y": rng_.uniform(Persp.FACADE_Y - 30, H - 16), "vx": vx,
		"vy": rng_.uniform(-1.4, 1.4), "s": rng_.uniform(320, 900), "a": rng_.uniform(0.18, 0.44),
		"t": 0.0, "life": rng_.uniform(12, 26)}


## Große, weiche Nebelschwaden ziehen durchs Vordergrundbild und lassen die Sicht
## stellenweise verschwimmen. Dichte folgt der Wetterlage (_fog_d).
func _wisps(p: QP, dt: float, _cam: float) -> void:
	if wisps.is_empty():
		for _i in range(9):
			wisps.append(_new_wisp(rng, true))
	for wi: Dictionary in wisps:
		wi["t"] = float(wi["t"]) + dt
		wi["x"] = float(wi["x"]) + float(wi["vx"]) * dt
		wi["y"] = float(wi["y"]) + float(wi["vy"]) * dt
		if float(wi["t"]) > float(wi["life"]) or float(wi["x"]) < -260 or float(wi["x"]) > W + 260:
			wi.clear()
			wi.merge(_new_wisp(rng), true)
	p.set_smooth(true)
	var tex: QImg = city.cloud
	var boost := 0.7 + 1.0 * _fog_d
	for wi: Dictionary in wisps:
		var fade := sin(minf(1.0, float(wi["t"]) / float(wi["life"])) * PI)
		var a := float(wi["a"]) * fade * boost
		if a <= 0.006:
			continue
		p.set_opacity(minf(0.5, a))
		var sw: float = wi["s"]
		var sh := sw * 0.66
		p.draw_image(Rect2(float(wi["x"]) - sw / 2, float(wi["y"]) - sh / 2, sw, sh), tex)
	p.set_opacity(1.0)
	p.set_smooth(false)


# ---- vorläufige Stubs (werden gruppenweise ersetzt)
# ------------------------------------------------------------------ Häuserfront
func _facade_life(p: QP, e: QP, cam: float, t: float, dt: float) -> void:
	var fac: City.Layer = city.facade
	# Neon-Schilder (+ Lichthof im Dunst); bei Stromausfall nur Notstrom-Schilder
	var halos: Array = []
	var L0 := cam * fac.factor - W * 0.5 - 140
	var L1 := cam * fac.factor + W * 0.5 + 40
	for s: City.Sign in city.visible(city.signs, city._sign_x, L0, L1):
		var x: float = fac.screen_x(s.L, cam)
		if x < -s.w - 30 or x > W + 30:
			continue
		var lv: float = s.lit(t)
		if dark > 0.4 and Py.imod(s.seed_, 4) != 0:
			lv = 0.0
		if lv > 0:
			p.draw_image_at(int(x), int(s.y), s.on)
			e.draw_image_at(int(x), int(s.y), s.emit)
			halos.append([x + s.w / 2.0, s.y + s.h / 2.0, maxf(s.w, s.h) * 0.9 + 10, s.color])
		else:
			p.draw_image_at(int(x), int(s.y), s.off)
	if not halos.is_empty():
		p.set_mode(PLUS)
		for ha: Array in halos:
			var hx: float = ha[0]
			var hy: float = ha[1]
			var r: float = ha[2]
			var c: Array = ha[3]
			var g := QGrad.radial(hx, hy, r)
			g.set_color_at(0, QP.rgb(c, 46))
			g.set_color_at(0.5, QP.rgb(c, 16))
			g.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(hx - r, hy - r, 2 * r, 2 * r, g)
		p.set_mode(OVER)
	# Fernseher-Fenster
	for tv: Array in city.visible(city.tvs, city._tv_x, L0 - fac.lmin, L1 - fac.lmin):
		var wx: float = tv[0]
		var wy: float = tv[1]
		var ww: float = tv[2]
		var wh: float = tv[3]
		var seed_: int = tv[4]
		var x := fac.screen_x(wx + fac.lmin, cam)
		if x < -10 or x > W + 10:
			continue
		if dark > 0.4:
			p.fill_rect(int(x), wy, ww, wh, QP.rgb([8, 10, 18]))
			continue
		var n := Scene._hash(int(t * 6), seed_)
		var c := Scene.mix([40, 60, 140], [150, 190, 255], n)
		if Py.imod(seed_, 5) == 0:
			c = Scene.mix(DScene.MAGENTA, DScene.PALE, n * 0.6)
		for q: QP in [p, e]:
			q.fill_rect(int(x), wy, ww, wh, QP.rgb(c))
	# Lampions
	for la: Array in city.visible(city.lanterns, city._lan_x, L0, L1):
		var L: float = la[0]
		var y: float = la[1]
		var c: Array = la[2]
		var ph: float = la[3]
		var x := fac.screen_x(L, cam) + sin(t * 1.7 + ph) * 0.8
		if x < -4 or x > W + 4:
			continue
		for q: QP in [p, e]:
			q.set_no_pen()
			q.set_brush(QP.rgb(c))
			q.draw_ellipse(int(x) - 2, y, 4, 5)
		p.fill_rect(int(x) - 1, y + 2, 2, 1, QP.rgb(Scene.mix(c, DScene.WHITE, 0.6)))
	_blinks(p, e, cam, t, "fac", fac)
	# Dampf aus Lüftungen
	for v: Array in city.vents:
		var L: float = v[0]
		var y: float = v[1]
		var x := fac.screen_x(L, cam)
		if -20 < x and x < W + 20 and rng.random() < dt * 1.3:
			fx.puff(L, y, null, null, 0.8)
	for mh: Array in city.manholes:
		var mx: float = mh[0]
		var md: float = mh[1]
		var sx := Persp.screen_x(mx, md, cam)
		if -20 < sx and sx < W + 20 and rng.random() < dt * 2.2:
			fx.puff(rng.uniform(-6, 6), Persp.ground_y(md) - 1, mx, md, 1.2)
	# Ausgangstor
	if city.gate != null:
		var g: Dictionary = city.gate
		var x := fac.screen_x(float(g["L"]), cam)
		if -130 < x and x < W + 10:
			_gate(p, e, x, g, t)


func _gate(p: QP, e: QP, x: float, g: Dictionary, t: float) -> void:
	var open_ := _gate_open
	var col: Array = [90, 230, 140] if open_ else DScene.CRIMSON
	var txt: String = g["label"]
	var tw := Pixfont.text_width(txt, 1)
	var bx := int(x + float(g["w"]) / 2 - tw / 2.0 - 5)
	p.fill_rect(bx, g["y"], tw + 10, 13, QP.rgb(DScene.VOID))
	for q: QP in [p, e]:
		Pixfont.draw(q, bx + 5, float(g["y"]) + 3, txt, col, 1, null)
		q.set_pen(QP.rgb(col))
		q.draw_rect(bx, g["y"], tw + 9, 12)
	var door: Array = g["door"]
	var dx: float = door[0]
	var dy: float = door[1]
	var dw: float = door[2]
	var dh: float = door[3]
	var X := int(x + (dx - float(g["L"])))
	if open_:
		var gr := QGrad.linear(0, dy, 0, dy + dh)
		gr.set_color_at(0, QP.c(40, 120, 90))
		gr.set_color_at(1, QP.c(200, 255, 220))
		for q: QP in [p, e]:
			q.fill_rect(X, dy, dw, dh, gr)
	else:
		var blink := Py.imod(int(t * 2), 2) == 0
		for q: QP in [p, e]:
			if blink:
				q.fill_rect(X, dy - 3, dw, 2, QP.rgb(DScene.CRIMSON))


# ------------------------------------------------------------------ Straße
func _street(p: QP, e: QP, cam: float, t: float) -> void:
	var th: Dictionary = city.th
	var fy := int(Persp.FACADE_Y)
	p.fill_rect(0, fy, W, H - fy, QP.rgb(th["street"]))
	city.draw_ground(p, cam)
	# Reflexionen liegen AUF dem nassen Asphalt (die Oberfläche spiegelt, nicht
	# der Untergrund): erst der Baukörper normal, dann die Neon-Leuchten additiv.
	var fac: City.Layer = city.facade
	var x0 := fac.lmin - cam * fac.factor + W * 0.5
	var band := 12
	var k := _reflk * (1.0 - 0.8 * dark)
	for rm: Array in [[city.facade_refl_body, OVER, minf(1.0, 0.8 * k)],
			[city.facade_refl, PLUS, minf(1.0, 0.95 * k)]]:
		var refl: QImg = rm[0]
		p.set_mode(rm[1])
		p.set_opacity(rm[2])
		var hlim := mini(refl.height(), H - fy)
		for kb in range(0, hlim, band):
			var off := sin(t * 2.3 + kb * 0.37) * 1.2
			p.draw_image(Rect2(0, fy + kb, W, band), refl, Rect2(-x0 - off, kb, W, band))
		p.set_opacity(1.0)
	p.set_mode(OVER)
	# In Pfützen ist die Fahrbahn noch nasser -> Reflexion dort klar verstärkt.
	var vis: Array = []
	var reg_rects: Array = []
	for pd: Array in city.puddles:
		var wx: float = pd[0]
		var pdepth: float = pd[1]
		var rw: float = pd[2]
		var rh: float = pd[3]
		var sx := Persp.screen_x(wx, pdepth, cam)
		if sx < -80 or sx > W + 80:
			continue
		var y := Persp.ground_y(pdepth)
		var rx := maxf(3.0, rw * Persp.ppu(pdepth))
		var ry := maxf(5.0, rh * 3.2)
		vis.append([sx, y, rx, ry])
		reg_rects.append(Rect2(sx - rx, y - ry, 2 * rx, 2 * ry))
	if not reg_rects.is_empty():
		p.save()
		p.set_clip_ellipses(reg_rects)
		for rm: Array in [[city.facade_refl_body, OVER, minf(1.0, 0.95 * k)],
				[city.facade_refl, PLUS, minf(1.0, 1.0 * k)]]:
			var refl: QImg = rm[0]
			p.set_mode(rm[1])
			p.set_opacity(rm[2])
			var hlim := mini(refl.height(), H - fy)
			for kb in range(0, hlim, band):
				var off := sin(t * 2.3 + kb * 0.37) * 1.2
				p.draw_image(Rect2(0, fy + kb, W, band), refl, Rect2(-x0 - off, kb, W, band))
			p.set_opacity(1.0)
		p.restore()
		p.set_mode(OVER)
	# Pfützen-Glanz: heller Schimmer, damit die nassen Stellen als Pfützen erkennbar sind
	p.set_mode(PLUS)
	p.set_no_pen()
	for v: Array in vis:
		var sx: float = v[0]
		var y: float = v[1]
		var rx: float = v[2]
		var ry: float = v[3]
		var g := QGrad.radial(sx, y, maxf(rx, 8))
		g.set_color_at(0.0, QP.rgb([120, 150, 195], int(52 * k)))
		g.set_color_at(1.0, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(sx, y)
		p.scale(1.0, maxf(0.22, ry / maxf(rx, 8)))
		p.translate(-sx, -y)
		p.fill_rect(sx - rx, y - rx, 2 * rx, 2 * rx, g)
		p.restore()
	p.set_mode(OVER)
	# Neon-Spiegelung (live, mit Flackern) - ebenfalls weich
	p.set_mode(PLUS)
	var L0 := cam * fac.factor - W * 0.5 - 140
	for s: City.Sign in city.visible(city.signs, city._sign_x, L0, L0 + W + 180):
		var x: float = fac.screen_x(s.L, cam)
		if x < -s.w or x > W or s.lit(t) <= 0 or (dark > 0.4 and Py.imod(s.seed_, 4) != 0):
			continue
		var ry := fy + (fy - s.y - s.h)
		if ry > H:
			continue
		var key := "sign%d" % s.get_instance_id()
		var r: Variant = _refl.get(key)
		if r == null:
			r = City.soft_reflection(s.emit)
			_refl[key] = r
		p.set_opacity(minf(1.0, 0.48 * k))
		p.draw_image(Rect2(int(x), ry, s.w, s.h * 1.9), r)
	p.set_opacity(1.0)
	p.set_mode(OVER)
	# Asphalt-Körnung noch einmal mit reduzierter Deckkraft darüber: die Reflexion
	# sinkt in die Textur, die Straße bleibt als Straße lesbar (kein voller Spiegel).
	p.set_opacity(0.42)
	city.draw_ground(p, cam)
	p.set_opacity(1.0)
	# Laternen: Kopf, Kegel, Lichtpfütze
	p.set_mode(PLUS)
	for lamp: City.Lamp in city.lamps:
		var x: float = fac.screen_x(lamp.L, cam)
		if x < -120 or x > W + 120:
			continue
		var lv := lamp.level(t) * (1.0 - dark)
		if lv <= 0.01:
			continue
		var arm: float = lamp.arm
		var hx := x + arm
		var hy := lamp.y + 4
		var c: Array = lamp.color
		var px := Persp.screen_x(lamp.x + arm / fac.factor, 0.25, cam)
		var gy := Persp.ground_y(0.25)
		var g := QGrad.linear(hx, hy, hx, gy)
		g.set_color_at(0, QP.rgb(c, int(34 * lv)))
		g.set_color_at(1, QP.rgb(c, 0))
		p.set_no_pen()
		p.set_brush(g)
		p.draw_polygon(PackedVector2Array([Vector2(hx - 2, hy), Vector2(hx + 2, hy), Vector2(px + 30, gy),
			Vector2(px - 30, gy)]))
		var rg := QGrad.radial(px, gy, 60)
		rg.set_color_at(0, QP.rgb(c, int(95 * lv)))
		rg.set_color_at(0.5, QP.rgb(c, int(30 * lv)))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(px, gy)
		p.scale(1.0, 0.32)
		p.translate(-px, -gy)
		p.fill_rect(px - 60, gy - 60, 120, 120, rg)
		p.restore()
	p.set_mode(OVER)
	for lamp: City.Lamp in city.lamps:
		var x: float = fac.screen_x(lamp.L, cam)
		if x < -20 or x > W + 20:
			continue
		var lv := lamp.level(t) * (1.0 - dark)
		var c: Array = lamp.color if lv > 0.5 else Scene.mul(lamp.color, 0.3)
		for q: QP in ([p, e] if lv > 0.5 else [p]):
			q.fill_rect(int(x + lamp.arm) - 2, lamp.y + 3, 5, 2, QP.rgb(c))
	# Suchscheinwerfer: die nasse Fahrbahn wirft unter jedem Leuchtkörper einen weichen
	# Lichtschleier zurück (kein harter Strahl - nur diffuser Schimmer).
	var tint := Scene.mix([170, 180, 220], th["sky_hor"], 0.25)
	p.set_mode(PLUS)
	p.set_no_pen()
	for sl: Array in city.searchlights:
		var L: float = sl[0]
		var _y: float = sl[1]
		var sp: float = sl[2]
		var ph: float = sl[3]
		var x: float = city.mid.screen_x(L, cam)
		if x < -80 or x > W + 80:
			continue
		var warm := 0.4 + 0.6 * absf(sin(t * sp + ph))
		var g := QGrad.linear(0, fy, 0, fy + 120)
		g.set_color_at(0, QP.rgb(tint, int(34 * warm * (1 - dark))))
		g.set_color_at(0.4, QP.rgb(tint, int(14 * warm * (1 - dark))))
		g.set_color_at(1, QP.c(0, 0, 0, 0))
		p.set_brush(g)
		p.draw_polygon(PackedVector2Array([Vector2(x - 2, fy), Vector2(x + 2, fy),
			Vector2(x + 10, fy + 120), Vector2(x - 10, fy + 120)]))
	p.set_mode(OVER)
	fx.draw_splashes(p, Scene.mix(city.th["fog"], DScene.PALE, 0.5))
# ------------------------------------------------------------------ Figuren
func _rim_for(a: Variant, _cam: float) -> Array:
	var best: Variant = null
	var bd := 110.0
	for lamp: City.Lamp in city.lamps:
		var d := absf(lamp.x - float(a.x))
		if d < bd:
			best = lamp
			bd = d
	if best != null:
		var bl: City.Lamp = best
		var side := 1 if bl.x + 6 >= float(a.x) else -1
		return [bl.color, side]
	return [city.th["rim"], 1]


## Wet-Street-Reflexion (progressiv scharf->weich, city.soft_reflection).
## Einmal pro Sprite gerechnet und gecacht - Rendern kostet nur ein drawImage.
func _mirror(im: QImg) -> QImg:
	var r: Variant = _refl.get(im)
	if r == null:
		if _refl.size() > 6000:
			_refl.clear()
		r = City.soft_reflection(im)
		_refl[im] = r
	return r


## Figuren, Fahrzeuge und Hindernisse gemeinsam nach Tiefe sortiert.
func _actors(p: QP, e: QP, world: Variant, cam: float, t: float, show_player: bool) -> void:
	screen = {}
	var items: Array = []
	var idx := 0
	for a: Variant in world.actors:
		if not a.escaped and (show_player or not a.player):
			items.append([float(a.depth) if a.alive else float(a.depth) - 0.002, 0, a, idx])
			idx += 1
	for v: Variant in world.vehicles:
		items.append([float(v["depth"]) - 0.001, 1, v, idx])
		idx += 1
	for o: Variant in world.obstacles:
		if not (o["kind"] in ["spinner", "stack"]):
			items.append([float(o["d"]) + float(o["dd"]) * 0.5, 2, o, idx])
			idx += 1
	for m: Variant in world.manholes:
		items.append([float(m["d"]) + 0.012, 5, m, idx])
		idx += 1
	var patrol: Variant = world.patrol
	if patrol != null and float(patrol.get("alt", 1.0)) < 1.0:
		items.append([Config.LAND_DEPTH, 3, patrol, idx])
		idx += 1
	for o: Variant in world.origami:
		if not o["taken"]:
			items.append([float(o["depth"]), 4, o, idx])
			idx += 1
	items.sort_custom(func(x: Array, y: Array) -> bool:
		if x[0] == y[0]:
			return x[3] < y[3]
		return x[0] < y[0])
	for it: Array in items:
		var kind: int = it[1]
		var obj: Variant = it[2]
		if kind == 0:
			var lit: bool = patrol != null and float(patrol["on"]) > 0.3 and world.in_beam(obj)
			_draw_actor(p, e, obj, cam, t, lit)
		elif kind == 1:
			_draw_vehicle(p, e, obj, cam, t)
		elif kind == 2:
			_draw_obstacle(p, e, obj, cam, t)
		elif kind == 3:
			_draw_landing(p, e, obj, cam, t)
		elif kind == 5:
			_draw_steam(p, e, obj, cam, t)
		else:
			_draw_origami(p, e, obj, cam, t)


func _draw_actor(p: QP, e: QP, a: Variant, cam: float, t: float, lit: bool = false) -> void:
	var th: Dictionary = city.th
	var fog_rgb: Array = th["fog"]
	var cx := Persp.screen_x(float(a.x), float(a.depth), cam)
	var hgt := Persp.figure_h(float(a.depth)) * float(a.look.get("hf", 1.0))
	if cx < -hgt * 1.4 or cx > W + hgt * 1.4:
		return
	var gy := Persp.ground_y(float(a.depth))
	var lift := int(Py.round(float(a.z) * Persp.ppu(float(a.depth))))
	var fog := float(th["fog_amt"]) * 0.85 * pow(1.0 - float(a.depth), 1.6)
	var rim_side: Array = _rim_for(a, cam)
	var rim: Array = rim_side[0]
	var side: int = rim_side[1]
	if a.player:
		rim = DScene.CYAN
		fog = 0.0
	if not a.alive:
		# Liegende Körper: kein Nebel, kühles Oberlicht -> heben sich vom nassen Asphalt ab
		rim = [200, 210, 232]
		fog = 0.0
		side = 1
	if lit:
		rim = DScene.WHITE
		fog = 0.0
	var outline := [4, 5, 10]
	if not a.alive and float(a.dead_t) > 0.5:
		# „Kreide“-Umriss: liegende Körper bleiben auf dem nassen Asphalt lesbar
		outline = [150, 40, 64] if not a.is_replicant else [120, 170, 190]
	var r: Array = Sprites.get_(a.look, a.anim, int(a.get("frame")), hgt, int(a.facing),
		rim, side * int(a.facing), fog_rgb, fog, outline)
	var im: QImg = r[0]
	var em: QImg = r[1]
	var ax: int = r[2]
	var ay: int = r[3]
	var meta: Dictionary = r[4]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay - lift
	if not a.alive:
		# Lache: Menschen dunkelrot, Replikanten milchig-weiß
		var k := minf(1.0, float(a.dead_t) / 2.5)
		if k > 0.05:
			var rw := hgt * (0.3 + 0.6 * k)
			var px_ := cx + (meta["head"] as Vector2).x * 0.55 - rw / 2
			var cc: Array
			var hl: Array
			if not a.is_replicant:
				cc = [150, 24, 50]
				hl = [220, 70, 96]
			else:
				cc = [176, 192, 206]
				hl = [240, 248, 255]
			p.set_no_pen()
			p.set_brush(QP.rgb(cc, 225))
			p.draw_ellipse(px_, gy - rw * 0.08, rw, rw * 0.2)
			p.fill_rect(int(px_ + rw * 0.3), int(gy - rw * 0.04), maxi(1, int(rw * 0.3)), 1, QP.rgb(hl))
		p.draw_image_at(x0, y0, im)
		p.set_mode(PLUS)
		p.set_opacity(0.22)
		p.draw_image_at(x0, y0, im)
		p.set_opacity(1.0)
		p.set_mode(OVER)
		if em != null:
			e.draw_image_at(x0, y0, em)
		screen[a.uid] = [cx, gy, hgt, meta]
		return
	# Schatten (bleibt am Boden, schrumpft beim Sprung)
	var sw := hgt * 0.42 * maxf(0.45, 1.0 - float(a.z) / 40.0)
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 110))
	p.draw_ellipse(cx - sw / 2, gy - sw * 0.07, sw, sw * 0.16)
	# Spiegelbild im nassen Asphalt
	p.set_opacity(minf(1.0, 0.46 * _reflk))
	p.draw_image_at(x0, int(gy) + lift - (im.height() - 1 - ay), _mirror(im))
	p.set_opacity(1.0)
	if a.player:
		var rw := hgt * 0.5
		for qa: Array in [[p, 120], [e, 90]]:
			var q: QP = qa[0]
			var al: int = qa[1]
			q.set_pen(QP.c(64, 210, 220, al), 1)
			q.set_no_brush()
			q.draw_ellipse(cx - rw / 2, gy - rw * 0.1, rw, rw * 0.2)
	p.draw_image_at(x0, y0, im)
	if em != null:
		e.draw_image_at(x0, y0, em)
	if lit:
		p.set_mode(PLUS)
		p.set_opacity(0.28)
		p.draw_image_at(x0, y0, im)
		p.set_opacity(1.0)
		p.set_mode(OVER)
	if float(a.flash_t) > 0:
		p.set_mode(PLUS)
		p.set_opacity(minf(1.0, float(a.flash_t) * 4))
		p.draw_image_at(x0, y0, im)
		p.draw_image_at(x0, y0, im)
		p.set_opacity(1.0)
		p.set_mode(OVER)
	if a.player and float(a.invuln) > 0 and Py.imod(int(t * 16), 2) == 0:
		p.set_opacity(0.5)
		p.draw_image_at(x0, y0, im)
		p.set_opacity(1.0)
	if float(a.glint_t) > 0 and dark <= 0:
		var eye: Vector2 = meta["eye"]
		var gx := int(cx + eye.x)
		var gy2 := int(gy + eye.y) - lift
		for q: QP in [p, e]:
			q.fill_rect(gx, gy2, 2, 1, QP.rgb(DScene.AMBER))
			q.fill_rect(gx, gy2, 1, 1, QP.rgb([255, 230, 180]))
	screen[a.uid] = [cx, gy - lift, hgt, meta]


## Augenreflexe über dem Stromausfall-Schleier: die Replikantenaugen glühen.
func _glints(p: QP, e: QP, world: Variant, _cam: float, _boost: bool = false) -> void:
	for a: Variant in world.actors:
		if a.player or not a.alive or a.escaped or float(a.glint_t) <= 0:
			continue
		var sc: Variant = screen.get(a.uid)
		if sc == null:
			continue
		var arr: Array = sc
		var cx: float = arr[0]
		var gy: float = arr[1]
		var meta: Dictionary = arr[3]
		var eye: Vector2 = meta["eye"]
		var gx := int(cx + eye.x)
		var gy2 := int(gy + eye.y)
		p.fill_rect(gx - 1, gy2, 3, 1, QP.rgb(DScene.AMBER))
		p.fill_rect(gx, gy2, 1, 1, QP.rgb(DScene.WHITE))
		e.fill_rect(gx - 2, gy2 - 1, 5, 3, QP.rgb(DScene.AMBER))


## Taschenlampe des Blade Runners im Stromausfall.
func _flashlight(p: QP, _ee: QP, world: Variant, _cam: float) -> void:
	var pl: Variant = world.player
	var sc: Variant = screen.get(pl.uid)
	if sc == null or not pl.alive:
		return
	var arr: Array = sc
	var cx: float = arr[0]
	var gy: float = arr[1]
	var hgt: float = arr[2]
	var d: int = pl.facing
	var hx := cx + d * hgt * 0.12
	var hy := gy - hgt * 0.55
	var ln := 170.0 * dark
	var tx := hx + d * ln
	p.set_mode(PLUS)
	var g := QGrad.linear(hx, hy, tx, hy)
	g.set_color_at(0, QP.c(150, 200, 210, 120))
	g.set_color_at(1, QP.c(0, 0, 0, 0))
	p.set_no_pen()
	p.set_brush(g)
	p.draw_polygon(PackedVector2Array([Vector2(hx, hy - 1), Vector2(tx, hy - hgt * 0.7),
		Vector2(tx, gy + hgt * 0.15), Vector2(hx, hy + 1)]))
	p.set_mode(OVER)
func _draw_vehicle(_pa: QP, _ea: QP, _v: Variant, _cam: float, _t: float) -> void:
	pass
func _vehicle_lights(_pa: QP, _ea: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass
func _draw_origami(_pa: QP, _ea: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass
func _draw_parked(_pa: QP, _ea: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass
func _draw_steam(_pa: QP, _ea: QP, _m: Variant, _cam: float, _t: float) -> void:
	pass
func _draw_obstacle(_pa: QP, _ea: QP, _o: Variant, _cam: float, _t: float) -> void:
	pass
func _patrol_geom(_world: Variant, _cam: float, _t: float) -> Variant:
	return null
func _land_pose(_P: Variant, _cam: float, _t: float) -> Variant:
	return null
func _draw_landing(_pa: QP, _ea: QP, _P: Variant, _cam: float, _t: float) -> void:
	pass
func _patrol(_pa: QP, _ea: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass
func _beam_rain(_pa: QP) -> void:
	if _beam_poly == null:
		return
func _hand(_world: Variant) -> Variant:
	return null
func _chest(_a: Variant, _cam: float) -> Variant:
	return null
func _combat(_pa: QP, _ea: QP, _world: Variant, _cam: float, _t: float) -> void:
	pass
func _foreground(_pa: QP, _cam: float) -> void:
	pass
func _power_on(_pa: QP, _k: float) -> void:
	pass
