class_name Scene
extends RefCounted

static var dbg_null := 0
static var dbg_ok := 0
static var dbg_null_v := 0
static var dbg_ok_v := 0
## Szenen-Komposition (QP): Stadt + Figuren + Licht + Effekte -> Szenen-Textur.
## 1:1 nach shadegunner/render/scene.py.
##
## Pro Frame:
##   Himmel/Wolken -> Suchscheinwerfer/Spinner -> Skyline fern/mittel (+ Fackeln,
##   Warnlichter, Holo-Billboards, Luftschiff) -> Häuserfront (+ Neon, Laternen)
##   -> nasser Boden (Spiegelungen, Perspektiv-Textur, Lichtkegel) -> Figuren
##   (Schatten, Spiegelbild, Rimlight, Augenreflex) -> Laser/Scan/Leuchtspuren
##   -> Regen, Vordergrund -> Glow-Pass (Leuchtschicht verkleinert/vergrößert,
##   additiv) -> Treffer/Blende.
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
##     SceneNear    W x H, transparent  <- Painter _nq (kameranahe Ebene: Kabel, Ampeltürme)
##     SceneNearS   W//2 x H//2 (Box-Verkleinerung -> leicht unscharf)
##     SceneFg      W x H, transparent  <- Painter _fq (Vordergrund vor der Kamera)
##     SceneFgS     W//3 x H//3 (Box-Verkleinerung -> Tiefenunschärfe)
##     SceneImg     W x H, opak, jedes Frame geleert (malt vollflaechig) <- Painter p
##
## Godot rendert Geschwister-SubViewports in Baumreihenfolge: emit -> small ->
## tiny -> Szene. Der Glow im Szenenbild nutzt also die emit-Texturen desselben
## Frames - wie im Original. CRTChain muss danach im Baum hängen.
##
## Umbenennungen gegenüber Python: self.t -> t_ (Parameter t überall),
## lokale seed -> seed_, lokale img -> im, rng-Parameter -> rng_.

## Bildbreite zur Laufzeit (View.W: 640 ohne View.setup, sonst 400..960); Höhe fest.
## Alle Verwendungen meinen die BILDSCHIRMBREITE (Mitte, Ränder, Kulling, Breitenschleifen,
## Viewport-/Kachelgrößen); der Maßstab hängt an Persp.PPU_NEAR (Basisbreite 640).
static var W: int:
	get: return View.W
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
var bikes: Array = []         # Radfahrer: reine Kulisse, nicht Teil der Simulation
var doves: Array = []         # ROYs Taube (nur wenn man ihn verschont)
var _bike_next := 12.0
var litter: Array = []        # flatternder Müll (Zeitungen, Papier) - Kulisse
var _gust := 6.0
var _near: Array = []         # kameranahe Ampeltürme dieses Frames
var _fg_e: QP = null          # Leuchtschicht während _foreground

# Leistungs-Optionen (werden von den Einstellungen/game.gd gesetzt; Default = volle Pracht)
var opt_reflections := true
var opt_rain := "viel"        # "viel" | "wenig" | "aus"
var opt_fog := true
var opt_fx := true
var opt_quality := "hoch"     # Sammelstufe (derzeit nur "hoch")
var _rain_applied := "viel"   # zuletzt auf FX angewandte Regen-Stufe

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
var _nq: QP                   # kameranahe, leicht unscharfe Ebene (Python: self._nb_img)
var _fq: QP                   # Vordergrund-Ebene (Python: self._fg_img)
var _near_vp: SubViewport
var _near_tex: Texture2D      # verkleinert (W//2)
var _fg_vp: SubViewport
var _fg_tex: Texture2D        # verkleinert (W//3)


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

	# Kameranahe Ebene + Vordergrund: eigene Bilder, verkleinert und wieder vergrößert
	# (Tiefenunschärfe). Vor dem Szenen-Viewport im Baum -> im selben Frame fertig.
	_near_vp = _make_vp("SceneNear", w, h, true, SubViewport.CLEAR_MODE_ALWAYS)
	var nh := Node2D.new()
	_near_vp.add_child(nh)
	parent.add_child(_near_vp)
	_nq = QP.new(nh.get_canvas_item())
	var nb := NEAR_BLUR
	var near_small := _make_box("SceneNearS", _near_vp.get_texture(), Vector2(w, h), Py.ifloordiv(W, nb),
		Py.ifloordiv(H, nb))
	parent.add_child(near_small)
	_near_tex = near_small.get_texture()
	_fg_vp = _make_vp("SceneFg", w, h, true, SubViewport.CLEAR_MODE_ALWAYS)
	var fh := Node2D.new()
	_fg_vp.add_child(fh)
	parent.add_child(_fg_vp)
	_fq = QP.new(fh.get_canvas_item())
	var fb := FG_BLUR
	var fg_small := _make_box("SceneFgS", _fg_vp.get_texture(), Vector2(w, h), Py.ifloordiv(W, fb),
		Py.ifloordiv(H, fb))
	parent.add_child(fg_small)
	_fg_tex = fg_small.get_texture()

	# Jedes frame() malt die Szene vollflaechig neu (Himmel + Strasse sind deckend), daher
	# darf der Viewport jedes Frame geleert werden. Das entspricht dem nicht geleerten
	# self.img des Originals und macht ein erneutes force_draw() idempotent (kein
	# Addieren der Leuchtschicht), was der Paritaetstest zum Settlen braucht.
	_scene_vp = _make_vp("SceneImg", w, h, false, SubViewport.CLEAR_MODE_ALWAYS)
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
static func _billboard_frames(bk: Baker, brng: PyRandom, bw: int, bh: int, kind: String,
		neon: Array = [DScene.RED, DScene.CYAN, DScene.AMBER, DScene.GREEN]) -> Array:
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
				var col: Array = neon[(k + brng.randint(0, 3)) % neon.size()]
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
## Regenmenge gemäß opt_rain auf FX anwenden (Ausgangsmenge der Zone bleibt sonst gleich).
func _apply_rain() -> void:
	var f := 1.0
	match opt_rain:
		"wenig":
			f = 0.6
		"aus":
			f = 0.0
	fx.set_rain(float(city.th["rain"]) * f)
	_rain_applied = opt_rain


func ensure_zone(zone_index: int, seed_: int, length: Variant = null) -> void:
	if length == null:
		length = (DSim.ZONES[zone_index] as Dictionary)["length"]
	var key := [zone_index, seed_, length]
	if _zone_key != null and key == _zone_key:
		return
	_zone_key = key
	Vehicles.set_zone(zone_index)
	city = City.new(zone_index, float(length), seed_)
	var th: Dictionary = city.th
	_apply_rain()
	var zr := PyRandom.new(seed_ + 77)
	for fr: Array in bb_frames:      # Godot: alte gebackene Bilder freigeben
		for im: QImg in fr:
			baker.release(im)
	bb_frames = []
	for bb: Array in city.billboards:
		var kind: String = zr.choice(["face", "logo", "kanji"])
		bb_frames.append(_billboard_frames(baker, zr, int(bb[2]), int(bb[3]), kind, th["neon"]))
	spinners = []
	for _i in range(int(th["spinners"])):
		_spawn_spinner(zr, true)
	blimp = null
	if th["blimp"]:
		blimp = {"x": zr.uniform(0, W), "y": zr.uniform(28, 60), "ad": zr.choice(DScene.ADS), "off": 0.0}
	_refl.clear()
	_refl_mat.clear()
	_last_cam = null
	bikes = []
	_bike_next = PyRandom.new(seed_ + 5).uniform(8.0, 25.0)
	litter = []
	_gust = PyRandom.new(seed_ + 6).uniform(4.0, 12.0)
	Palette.active = Palette.zone_look(zone_index)["name"]


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
		elif k == "dove":
			var dx: float = ev[1]
			var dd: float = ev[2]
			doves.append({"x": dx, "d": dd, "z": Persp.figure_h(dd) / Persp.ppu(dd) * 0.55, "t": 0.0,
					"vx": 6.0, "vz": 10.0})


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
	Palette.active = Palette.zone_look(city.zone)["name"]
	var seed_: int = int(_wget(world, "seed", 0))
	_reflk = 0.6 + 0.7 * float(th["rain"])     # Regen verstärkt die Spiegelung
	var cam: float = world.camera_x if cam_override == null else cam_override
	var cam_dx := 0.0 if _last_cam == null else (cam - float(_last_cam)) * Persp.PPU_NEAR * 0.6
	_last_cam = cam

	if opt_rain != _rain_applied:
		_apply_rain()
	fx.update_rain(dt, cam_dx)
	fx.update_steam(dt)
	_update_bikes(dt, cam)
	for dv: Dictionary in doves:
		dv["t"] = float(dv["t"]) + dt
		var tt: float = dv["t"]
		# erst ein paar unsichere Flügelschläge, dann steigt sie steil in den Regen
		dv["vz"] = 10.0 + 34.0 * minf(1.0, tt / 1.6)
		dv["vx"] = 6.0 + 10.0 * sin(tt * 0.7)
		dv["x"] = float(dv["x"]) + float(dv["vx"]) * dt
		dv["z"] = float(dv["z"]) + float(dv["vz"]) * dt
	doves = doves.filter(func(dv: Dictionary) -> bool: return float(dv["t"]) < 14.0)
	_update_litter(dt, cam)
	fx.update_combat(dt)

	# self.emit.fill(0): der Leucht-Viewport wird jedes Frame geleert.
	var p := _p
	var e := _e
	p.begin()
	e.begin()
	_nq.begin()
	_fq.begin()
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
	if opt_fog:
		_fog(p, 0, 24, 168, cam * DScene.MID_F * 1.4 + t * 5.0, minf(1.0, fd * 0.9))   # hinter der Skyline
	_air_traffic(p, e, cam, t, true)
	_searchlights(p, cam, t)
	_blimp(p, e, dt, t)
	city.mid.draw(p, cam)
	_mid_life(p, e, cam, t)
	_air_traffic(p, e, cam, t, false)
	_spinners(p, e, dt, t, false)
	_holos(p, e, cam, t, "giant")
	if opt_fog:
		_fog_band(p)
		_fog(p, 0, Persp.FACADE_Y - 122, 128, cam * DScene.MID_F * 1.4 + t * 5.0, minf(1.0, fd * 1.5))
	city.facade.draw(p, cam)
	city.facade.draw(e, cam, city.facade_emit, 0, 0.8 * (1.0 - dark))
	_facade_life(p, e, cam, t, dt)
	_street(p, e, cam, t)
	_holos(p, e, cam, t, "street")
	_ramen(p, e, world, cam, t, dt)
	if opt_fx:
		_shout_fx(p, e, world, cam, t)
	if opt_fog:
		_fog(p, 1, Persp.FACADE_Y - 28, 72, cam * Persp.ppu(0.0) + t * 9.0, minf(1.0, fd * 0.7))
	_spans_back(p, e, cam, t)
	_near = []
	_actors(p, e, world, cam, t, show_player)
	_near_layer(p, e, cam, t)
	_spans_front(p, e, cam, t)
	for dv: Dictionary in doves:
		_draw_dove(p, e, dv, cam)
	if dark > 0:
		p.fill_rect(0, 0, W, H, QP.c(2, 3, 10, int(165 * dark)))
		if opt_fx:
			_glints(p, e, world, cam, true)
		_flashlight(p, e, world, cam)
	_vehicle_lights(p, e, world, cam, t)
	if opt_fx:
		_combat(p, e, world, cam, t)
		fx.draw_steam(p, cam, city.facade.factor)
	_patrol(p, e, world, cam, t)
	_spinners(p, e, dt, t, true)
	if opt_rain != "aus":
		fx.draw_rain(p, mix(th["fog"], DScene.PALE, 0.55), _span_clip(cam))
		_beam_rain(p)
	if opt_fog:
		_fog(p, 1, H - 70, 78, cam * Persp.ppu(1.15) + t * 14.0, minf(1.0, fd * 0.42))
		# Ganzflächiger Nebelschleier: bei dichter Lage verschwimmt auch der Vordergrund
		# (Vordergrund liegt "näher an der Kamera", also über allem anderen).
		_fog_img(p, city.bank, -30, H + 70, cam * Persp.ppu(1.0) * 0.6 + t * 7.0, minf(0.46, fd * 0.34))
	if opt_fx:
		_wisps(p, dt, cam)
	_fg_e = e
	_foreground(p, cam)
	_fg_e = null
	e.end()
	_nq.end()
	_fq.end()

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
	for cl: Array in city.cloud_layers:
		var im: QImg = cl[0]
		var speed: float = cl[1]
		var fac: float = cl[2]
		var off := Py.mod(t * speed + cam * fac, im.width())
		var x := -off
		p.draw_image_at(int(x), 0, im)
		if x + im.width() < W:
			p.draw_image_at(int(x + im.width()), 0, im)
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
	if not opt_fog or opacity <= 0.01:
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
	if not opt_fog:
		return
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
	_fires(p, e, cam, t)
	_walk_signals(p, e, cam, t)
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
	if opt_reflections:
		for rm: Array in [[city.facade_refl_body, OVER, minf(1.0, 0.8 * k)],
				[city.facade_refl, PLUS, minf(1.0, 0.95 * k)]]:
			var refl: QImg = rm[0]
			p.set_mode(rm[1])
			p.set_opacity(rm[2])
			var hlim := mini(refl.height(), H - fy)
			var dsts: Array = []
			var srcs: Array = []
			for kb in range(0, hlim, band):
				var off := sin(t * 2.3 + kb * 0.37) * 1.2
				dsts.append(Rect2(0, fy + kb, W, band))
				srcs.append(Rect2(-x0 - off, kb, W, band))
			p.draw_image_rects(refl, dsts, srcs)
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
		if opt_reflections:
			for rm: Array in [[city.facade_refl_body, OVER, minf(1.0, 0.95 * k)],
					[city.facade_refl, PLUS, minf(1.0, 1.0 * k)]]:
				var refl: QImg = rm[0]
				p.set_mode(rm[1])
				p.set_opacity(rm[2])
				var hlim := mini(refl.height(), H - fy)
				var dsts: Array = []
				var srcs: Array = []
				for kb in range(0, hlim, band):
					var off := sin(t * 2.3 + kb * 0.37) * 1.2
					dsts.append(Rect2(0, fy + kb, W, band))
					srcs.append(Rect2(-x0 - off, kb, W, band))
				p.draw_image_rects(refl, dsts, srcs)
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
	if opt_reflections:
		p.set_mode(PLUS)
		var L0 := cam * fac.factor - W * 0.5 - 140
		for s: City.Sign in city.visible(city.signs, city._sign_x, L0, L0 + W + 180):
			var x: float = fac.screen_x(s.L, cam)
			if x < -s.w or x > W or s.lit(t) <= 0 or (dark > 0.4 and Py.imod(s.seed_, 4) != 0):
				continue
			var ry := fy + (fy - s.y - s.h)
			if ry > H:
				continue
			p.set_opacity(minf(1.0, 0.48 * k))
			_draw_refl(p, int(x), ry, s.emit, s.h * 1.9)
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
	if opt_fx:
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


## Wet-Street-Reflexion (progressiv scharf->weich wie city.soft_reflection) - im Port als
## Shader beim Zeichnen (shaders/reflect.gdshader). Das Original backt je Bild eine
## Reflexion; hier kostete das ~12 SubViewports und ~10 ms je neuem Sprite-Frame (und
## die Viewports wurden nie freigegeben). Je Bild bleibt nur ein kleines Material.
const SH_REFLECT := preload("res://shaders/reflect.gdshader")
var _refl_mat := {}


func _refl_material(im: QImg) -> ShaderMaterial:
	var m: Variant = _refl_mat.get(im)
	if m != null:
		return m
	if _refl_mat.size() > 4000:
		_refl_mat.clear()
	var ts := im.tex.get_size()
	var r := im.region
	var mat := ShaderMaterial.new()
	mat.shader = SH_REFLECT
	mat.set_shader_parameter("reg", Vector4(r.position.x / ts.x, r.position.y / ts.y, r.end.x / ts.x, r.end.y / ts.y))
	mat.set_shader_parameter("flip_x", 1.0 if im.mirrored else 0.0)
	_refl_mat[im] = mat
	return mat


## Reflexion von im bei (x, y) zeichnen (Größe des Bildes oder dst_h hoch gestreckt).
func _draw_refl(p: QP, x: float, y: float, im: QImg, dst_h: float = -1.0) -> void:
	if not opt_reflections or im == null or im.tex == null:
		return
	p.draw_image_material(Rect2(x, y, im.width(), im.height() if dst_h < 0.0 else dst_h), im, _refl_material(im))


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
	for b: Dictionary in bikes:
		items.append([float(b["d"]), 6, b, idx])
		idx += 1
	for m: Dictionary in litter:
		items.append([float(m["d"]), 7, m, idx])
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
		elif kind == 6:
			_draw_bike(p, e, obj, cam, t)
		elif kind == 7:
			_draw_litter(p, obj, cam)
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
	var peaceful: bool = a.peaceful if a is Actor else false
	if not a.alive and float(a.dead_t) > 0.5 and not peaceful:
		# „Kreide“-Umriss: liegende Körper bleiben auf dem nassen Asphalt lesbar
		outline = [150, 40, 64] if not a.is_replicant else [120, 170, 190]
	var r: Array = Sprites.get_(a.look, a.anim, int(a.get("frame")), hgt, int(a.facing),
		rim, side * int(a.facing), fog_rgb, fog, outline)
	var im: QImg = r[0]
	if im == null:
		dbg_null += 1
	else:
		dbg_ok += 1
	var em: QImg = r[1]
	var ax: int = r[2]
	var ay: int = r[3]
	var meta: Dictionary = r[4]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay - lift
	if not a.alive:
		# Lache: Menschen dunkelrot, Replikanten milchig-weiß
		var k := 0.0 if peaceful else minf(1.0, float(a.dead_t) / 2.5)
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
	_draw_refl(p, x0, int(gy) + lift - (im.height() - 1 - ay), im)
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
func _draw_vehicle(p: QP, e: QP, v: Dictionary, cam: float, t: float) -> void:
	var d: float = v["depth"]
	var k := Persp.ppu(d)
	var cx := Persp.screen_x(float(v["x"]), d, cam)
	if cx < -float(v["L"]) * k or cx > W + float(v["L"]) * k:
		return
	var gy := Persp.ground_y(d)
	var r: Array = Vehicles.vehicle_image(v["kind"], v["seed"], k, city.th["rim"], v["dir"])
	var im: QImg = r[0]
	if im == null:
		dbg_null_v += 1
	else:
		dbg_ok_v += 1
	@warning_ignore("unused_variable")
	var em: QImg = r[1]
	var ax: int = r[2]
	var ay: int = r[3]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 130))
	p.draw_ellipse(cx - float(v["L"]) * k * 0.55, gy - 3 * k, float(v["L"]) * k * 1.1, 5 * k)
	p.set_opacity(minf(1.0, 0.5 * _reflk))
	_draw_refl(p, x0, int(gy) - (im.height() - 1 - ay), im)
	p.set_opacity(1.0)
	p.draw_image_at(x0, y0, im)
	e.draw_image_at(x0, y0, em)
	if v["kind"] == "police":
		var kk := k * Vehicles.VEH_SCALE
		_spinner_lights(p, e, cx, gy, kk * 60.0 / Vehicles.SPIN_L, kk, v["dir"], t + float(v["seed"]))


## Scheinwerferkegel und Lichtflecken auf der nassen Fahrbahn (additiv).
func _vehicle_lights(p: QP, _ee: QP, world: Variant, cam: float, _t: float) -> void:
	var vs: Array = world.vehicles
	if vs.is_empty():
		return
	p.set_mode(PLUS)
	for v: Dictionary in vs:
		var d: float = v["depth"]
		var k := Persp.ppu(d)
		var cx := Persp.screen_x(float(v["x"]), d, cam)
		if cx < -300 or cx > W + 300:
			continue
		var gy := Persp.ground_y(d)
		var dr: int = v["dir"]
		var fx_ := cx + dr * float(v["L"]) * 0.5 * k
		var hh: float = {"truck": 11.0, "bus": 12.0, "police": 8.4}.get(v["kind"], 9.0)
		var hy := gy - hh * k * Vehicles.VEH_SCALE
		Vehicles.headlight(p, fx_, hy, dr, k, gy, 120.0, [255, 240, 210], 80)
		var rg := QGrad.radial(fx_ + dr * 50 * k, gy, 60 * k)
		rg.set_color_at(0, QP.c(255, 240, 210, 70))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(fx_ + dr * 50 * k, gy)
		p.scale(1.0, 0.25)
		p.translate(-(fx_ + dr * 50 * k), -gy)
		p.fill_rect(fx_ + dr * 50 * k - 60 * k, gy - 60 * k, 120 * k, 120 * k, rg)
		p.restore()
		# Rücklicht-Schimmer
		var bx := cx - dr * float(v["L"]) * 0.5 * k
		var rg2 := QGrad.radial(bx, gy - 7 * k, 16 * k)
		rg2.set_color_at(0, QP.c(240, 40, 70, 70))
		rg2.set_color_at(1, QP.c(0, 0, 0, 0))
		p.fill_rect(bx - 16 * k, gy - 23 * k, 32 * k, 32 * k, rg2)
	p.set_mode(OVER)


# Gaffs Origami: Silhouetten in Welt-Einheiten (Boden y = 0, Blick nach +x)
const ORIGAMI_SHAPES := {
	"huhn": [[[-4, 0], [-1, -5], [3, -5], [4, 0]], [[-4, -2], [-6.5, -7], [-2, -4]],
		[[2, -5], [3.5, -9], [5, -8.5], [4, -5]], [[5, -8.5], [7, -8], [5, -7.6]]],
	"mann": [[[-0.6, 0], [-0.2, -6], [0.6, -6], [0.2, 0]], [[-3, 0], [-0.4, -5.6], [0.2, -5.2], [-2.2, 0]],
		[[3, 0], [0.4, -5.6], [-0.2, -5.2], [2.2, 0]], [[-3.4, -6.6], [0, -7.4], [3.4, -6.6], [0, -6.2]],
		[[-1.2, -8], [0, -9.8], [1.2, -8], [0, -7.2]], [[0.4, -4.4], [3.2, -3.4], [0.4, -3.8]]],
	"schaf": [[[-4.5, -2.5], [-3, -6.5], [3, -6.5], [4.5, -2.5]], [[-4, -2.5], [-3.4, 0], [-2.8, -2.5]],
		[[3, -2.5], [3.6, 0], [4.2, -2.5]], [[3.5, -6], [6.5, -7.5], [7, -4.5], [4.5, -4]]],
	"kranich": [[[-6, -3], [0, -1], [6, -3], [0, -3.6]], [[-1.5, -3.2], [1, -9], [2, -3.2]],
		[[-6, -3], [-8, -7], [-5, -3.4]], [[6, -3], [8, -7.5], [9, -7], [5, -3.4]]],
	"einhorn": [[[-4.5, -3], [-3.5, -7], [3.5, -7], [4.5, -3]], [[-4, -3], [-3.6, 0], [-2.8, -3]],
		[[3, -3], [3.6, 0], [4.2, -3]], [[3, -6.5], [5.5, -10.5], [7, -9.5], [5, -6]],
		[[6, -10], [9, -14], [6.8, -9.6]], [[-4.5, -6.6], [-7, -4], [-4.4, -5]]],
}


## Gefaltete Papierfigur am Straßenrand; blinkt alle paar Sekunden kurz auf.
func _draw_origami(p: QP, e: QP, o: Dictionary, cam: float, t: float) -> void:
	var d: float = o["depth"]
	var k := Persp.ppu(d) * 1.4
	var cx := Persp.screen_x(float(o["x"]), d, cam)
	if cx < -30 or cx > W + 30:
		return
	var gy := Persp.ground_y(d)
	var paper: Array = [200, 210, 230] if o["kind"] == "einhorn" else [220, 222, 228]
	var fold := Scene.mul(paper, 0.7)
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 110))
	p.draw_ellipse(cx - 6 * k, gy - 1.2 * k, 12 * k, 2.4 * k)
	var shapes: Array = ORIGAMI_SHAPES[o["kind"]]
	for i in range(shapes.size()):
		var poly: Array = shapes[i]
		var pts := PackedVector2Array()
		for pt: Array in poly:
			pts.append(Vector2(cx + float(pt[0]) * k, gy + float(pt[1]) * k))
		p.set_brush(QP.rgb(paper if Py.imod(i, 2) == 0 else fold))
		p.draw_polygon(pts)
		var pts2 := PackedVector2Array()
		for pt: Array in poly:
			pts2.append(Vector2(cx + float(pt[0]) * k, gy - float(pt[1]) * k * 0.8))
		p.set_opacity(0.35 * _reflk)
		p.draw_polygon(pts2)
		p.set_opacity(1.0)
	# Glanzpunkt: alle ~2,4 s ein kurzer Stern
	var ph := Py.mod(t + float(o["seed"]) * 0.01, 2.4)
	if ph < 0.35:
		var a := 1.0 - ph / 0.35
		var sy := gy - 9 * k
		var r := 2 + 5 * a
		for q: QP in [p, e]:
			q.fill_rect(cx - r, sy, 2 * r + 1, 1, QP.rgb(DScene.WHITE, int(255 * a)))
			q.fill_rect(cx, sy - r, 1, 2 * r + 1, QP.rgb(DScene.WHITE, int(255 * a)))


## Geparktes Fahrzeug: Motor aus, Lichter fast dunkel, manche mit Warnblinker.
func _draw_parked(p: QP, e: QP, o: Dictionary, cam: float, t: float) -> void:
	var d: float = o["d"]
	var k := Persp.ppu(d)
	var cx := Persp.screen_x(float(o["x"]), d, cam)
	if cx < -float(o["w"]) * 2 * k or cx > W + float(o["w"]) * 2 * k:
		return
	var gy := Persp.ground_y(d)
	var r: Array = Vehicles.vehicle_image(o["veh"], o["seed"], k, city.th["rim"], o["dir"])
	var im: QImg = r[0]
	var em: QImg = r[1]
	var ax: int = r[2]
	var ay: int = r[3]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 140))
	p.draw_ellipse(cx - float(o["w"]) * k * 1.1, gy - 3 * k, float(o["w"]) * k * 2.2, 5 * k)
	p.set_opacity(minf(1.0, 0.5 * _reflk))
	_draw_refl(p, x0, int(gy) - (im.height() - 1 - ay), im)
	p.set_opacity(1.0)
	p.draw_image_at(x0, y0, im)
	e.set_opacity(0.12)
	e.draw_image_at(x0, y0, em)
	e.set_opacity(1.0)
	if o["veh"] == "police":
		var kk := k * Vehicles.VEH_SCALE
		_spinner_lights(p, e, cx, gy, kk * 60.0 / Vehicles.SPIN_L, kk, o["dir"], t + float(o["seed"]))
	elif bool(o.get("hazard", false)) and Py.imod(int(t * 1.7 + float(o["seed"]) * 0.01), 2) == 0:
		var hy := gy - 8 * k
		for sx: float in [cx - float(o["w"]) * k * 0.92, cx + float(o["w"]) * k * 0.92]:
			for q: QP in [p, e]:
				q.fill_rect(sx - 1.2 * k, hy, 2.4 * k + 1, 1.6 * k + 1, QP.rgb(DScene.AMBER))
			var rg := QGrad.radial(sx, gy, 18 * k)
			rg.set_color_at(0, QP.c(255, 150, 40, 60))
			rg.set_color_at(1, QP.c(0, 0, 0, 0))
			p.set_mode(PLUS)
			p.fill_rect(sx - 18 * k, gy - 5 * k, 36 * k, 10 * k, rg)
			p.set_mode(OVER)


## Dampfender Gulli (oder gestreifter Dampfschlot): Deckel mit Glut im Spalt,
## darüber Schwaden, die aufsteigen, wachsen, abdriften und das Neon fangen.
func _draw_steam(p: QP, e: QP, m: Dictionary, cam: float, t: float) -> void:
	var d: float = m["d"]
	var k := Persp.ppu(d)
	var cx := Persp.screen_x(float(m["x"]), d, cam)
	if cx < -90 * k or cx > W + 90 * k:
		return
	var gy := Persp.ground_y(d)
	var s: float = m.get("s", 0.5)
	p.set_no_pen()
	var src_y := 0.0
	var rise := 0.0
	if m["stack"]:
		# Con-Ed-Schlot: orange-weiß gestreift, schwarze Kappe
		var sw := 3.6 * k
		var sh := 14.0 * k
		p.set_brush(QP.c(0, 0, 0, 120))
		p.draw_ellipse(cx - sw, gy - 1.5 * k, sw * 2, 3 * k)
		var n := 6
		for i in range(n):
			var col: Array = [232, 104, 34] if Py.imod(i, 2) == 0 else [226, 222, 214]
			var y0 := gy - sh * (i + 1) / n
			p.fill_rect(cx - sw / 2, y0, sw, sh / n + 1, QP.rgb(Scene.mul(col, 0.62)))
			p.fill_rect(cx - sw / 2, y0, sw * 0.35, sh / n + 1, QP.rgb(Scene.mul(col, 0.85)))
		p.fill_rect(cx - sw / 2 - 0.6 * k, gy - sh - 1.4 * k, sw + 1.2 * k, 1.6 * k, QP.rgb([26, 26, 32]))
		src_y = gy - sh - 1.0 * k
		rise = 95.0
	else:
		p.set_brush(QP.rgb([14, 14, 20]))
		p.draw_ellipse(cx - 6.5 * k, gy - 1.3 * k, 13 * k, 2.6 * k)
		p.set_no_brush()
		p.set_pen(QP.rgb([70, 72, 86]), maxf(1.0, 0.6 * k))
		p.draw_ellipse(cx - 6.5 * k, gy - 1.3 * k, 13 * k, 2.6 * k)
		p.set_no_pen()
		var glow := int(90 + 80 * s)
		for q: QP in [p, e]:                                  # Glut in den Löchern
			for i: int in [-2, 0, 2]:
				q.fill_rect(cx + i * 1.8 * k - 0.5 * k, gy - 0.3 * k, 1.0 * k + 1, 0.6 * k + 1,
					QP.c(255, 120, 40, glow))
		src_y = gy - 0.5 * k
		rise = 75.0
	# Bodennebel um den Gulli
	var tint := Scene.mix([222, 222, 232], city.th["fog"], 0.3)
	var rg := QGrad.radial(cx, gy, 34 * k)
	rg.set_color_at(0.0, QP.rgb(tint, int(70 * s)))
	rg.set_color_at(1.0, QP.c(0, 0, 0, 0))
	p.save()
	p.translate(cx, gy)
	p.scale(1.0, 0.22)
	p.fill_rect(-34 * k, -34 * k, 68 * k, 68 * k, rg)
	p.restore()
	# Schwaden: dichter Strahl an der Quelle, darüber aufsteigende, wachsende Ballen
	var n2 := 22
	var side := 1 if Py.imod(m["seed"], 2) else -1
	var rate := 0.32
	for i in range(n2):
		var u := (t + float(m["seed"]) * 0.37) * rate + float(i) / n2
		var age := Py.mod(u, 1.0)
		var fade := minf(1.0, age / 0.05) * pow(1.0 - age, 1.6)
		var a := minf(1.0, s * 1.25) * fade
		if a < 0.04:
			continue
		var hhx := Scene._hash(i * 13 + int(u), m["seed"])
		var ox := (float(m.get("drift", 0.0)) * age + age * age * (34.0 + 26 * hhx) * side
			+ sin(age * 6.0 + i * 1.7) * 3.5 * age + (hhx - 0.5) * 4.0 * age)
		var r2 := (2.2 + 15.0 * pow(age, 0.9) + 3.5 * hhx) * k
		var px := cx + ox * k
		var py := src_y - pow(age, 0.8) * rise * k
		var col2 := Scene.mix(tint, [250, 250, 255], maxf(0.0, 0.5 - age))     # unten heller
		var rg2 := QGrad.radial(px, py, r2)
		rg2.set_color_at(0.0, QP.rgb(col2, int(235 * a)))
		rg2.set_color_at(0.55, QP.rgb(col2, int(150 * a)))
		rg2.set_color_at(1.0, QP.rgb(col2, 0))
		p.set_brush(rg2)
		p.draw_ellipse(px - r2, py - r2 * 0.85, 2 * r2, 1.7 * r2)
		if age < 0.5:                                 # unten fängt der Dampf das Licht
			rg2.set_color_at(0.0, QP.rgb(col2, int(34 * a)))
			rg2.set_color_at(0.55, QP.rgb(col2, int(10 * a)))
			e.set_brush(rg2)
			e.set_no_pen()
			e.draw_ellipse(px - r2, py - r2 * 0.85, 2 * r2, 1.7 * r2)


func _draw_obstacle(p: QP, e: QP, o: Dictionary, cam: float, t: float) -> void:
	if o["kind"] == "parked":
		_draw_parked(p, e, o, cam, t)
		return
	if o["kind"] == "tower":
		if float(o["d"]) > 1.0:
			_near.append(o)            # vor der Kamera: eigene, leicht unscharfe Ebene
		else:
			_draw_tower(p, e, o, cam, t)
		return
	var d: float = o["d"]
	var k := Persp.ppu(d)
	var cx := Persp.screen_x(float(o["x"]), d, cam)
	if cx < -60 or cx > W + 60:
		return
	var gy := Persp.ground_y(d)
	var r: Array = Vehicles.obstacle_image(o["kind"], o["seed"], k, city.th["rim"])
	var im: QImg = r[0]
	var em: QImg = r[1]
	var ax: int = r[2]
	var ay: int = r[3]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 120))
	p.draw_ellipse(cx - float(o["w"]) * k * 1.1, gy - 2 * k, float(o["w"]) * k * 2.2, 4 * k)
	p.set_opacity(minf(1.0, 0.46 * _reflk))
	_draw_refl(p, x0, int(gy) - (im.height() - 1 - ay), im)
	p.set_opacity(1.0)
	p.draw_image_at(x0, y0, im)
	e.draw_image_at(x0, y0, em)
	var kind: String = o["kind"]
	var light: Variant = null
	k = k * float(Vehicles.OB_SCALE.get(kind, 1.0))      # Zeichenmaßstab wie im Bild
	if kind == "barrier" and Py.imod(int(t * 2.5 + float(o["seed"])), 2) == 0:
		for q: QP in [p, e]:
			q.fill_rect(cx - 1 * k, gy - 12 * k, 2 * k + 1, 2 * k + 1, QP.rgb(DScene.AMBER))
		light = [DScene.AMBER, 30, 40]
	elif kind == "barrel":
		for i in range(3):
			var n := Scene._hash(int(t * 14) + i * 7, o["seed"])
			var fh := (5 + 6 * n) * k
			var bx := cx + (i - 1) * 2.2 * k
			var poly := PackedVector2Array([Vector2(bx - 1.6 * k, gy - 9 * k),
				Vector2(bx + (n - 0.5) * 2 * k, gy - 9 * k - fh), Vector2(bx + 1.6 * k, gy - 9 * k)])
			for q: QP in [p, e]:
				q.set_no_pen()
				q.set_brush(QP.rgb(DScene.AMBER if i != 1 else [255, 220, 150]))
				q.draw_polygon(poly)
		light = [DScene.AMBER, 70 + int(25 * Scene._hash(int(t * 9), o["seed"])), 70]
		if rng.random() < 0.05:
			fx.puff(0, gy - 16 * k, o["x"], d, 0.6)
	elif kind == "vending":
		light = [[150, 200, 255], 45, 50]
	if light != null:
		var la: Array = light
		var c: Array = la[0]
		var a: int = la[1]
		var rr: float = float(la[2]) * k
		p.set_mode(PLUS)
		var rg := QGrad.radial(cx, gy, rr)
		rg.set_color_at(0, QP.rgb(c, a))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(cx, gy)
		p.scale(1.0, 0.35)
		p.translate(-cx, -gy)
		p.fill_rect(cx - rr, gy - rr, 2 * rr, 2 * rr, rg)
		p.restore()
		if kind == "barrel":
			var rg2 := QGrad.radial(cx, gy - 14 * k, rr * 0.7)
			rg2.set_color_at(0, QP.rgb(c, Py.ifloordiv(a, 2)))
			rg2.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(cx - rr, gy - 14 * k - rr, 2 * rr, 2 * rr, rg2)
		p.set_mode(OVER)
# ------------------------------------------------------------------ Polizei-Suchlicht
func _patrol_geom(world: Variant, cam: float, t: float) -> Variant:
	var P: Variant = world.patrol
	if P == null:
		return null
	var bx := Persp.screen_x(float(P["bx"]), float(P["bd"]), cam)
	var by := Persp.ground_y(float(P["bd"]))
	var rx := 34 * Persp.ppu(float(P["bd"]))
	var ry := 0.13 * (Persp.ground_y(1) - Persp.ground_y(0))
	var alt: float = P.get("alt", 1.0)
	var sx := Persp.screen_x(float(P["x"]), 0.35, cam)
	var sy := 46 + sin(t * 1.4) * 2.0
	if alt >= 1.0:
		return [P, sx, sy + 4, bx, by, rx, ry]
	var k: Array = _land_pose(P, cam, t)
	var x: float = k[0]
	var yg: float = k[1]
	var ppx: float = k[2]
	var d: int = k[3]
	var nx: float = Vehicles.SPIN_NOSE[0]
	var ny: float = Vehicles.SPIN_NOSE[1]
	return [P, x + nx * ppx * d, yg + ny * ppx, bx, by, rx, ry]


## Bildposition eines landenden Spinners: (x, y_boden, px pro Zeichen-Einheit, d).
func _land_pose(P: Variant, cam: float, t: float) -> Array:
	var alt: float = P.get("alt", 1.0)
	var u := alt * alt * (3 - 2 * alt)
	var ppx_s := 22 * 2.4 / Vehicles.SPIN_L
	var sx := Persp.screen_x(float(P["x"]), 0.35, cam)
	var sy := 46 + sin(t * 1.4) * 2.0 + 10 * ppx_s
	var D: float = Config.LAND_DEPTH
	var ppx_g := Persp.ppu(D) * Vehicles.VEH_SCALE
	var gx := Persp.screen_x(float(P["x"]), D, cam)
	var gy := Persp.ground_y(D) - (0.0 if P.get("phase") == "landed" else 2.0 * sin(t * 3.0) * (1 - u))
	return [gx + (sx - gx) * u, gy + (sy - gy) * u, ppx_g + (ppx_s - ppx_g) * u, int(P.get("face", 1))]


## Landender/gelandeter Spinner, nach Tiefe einsortiert (mit Schatten, Spiegelung,
## Turbinenglühen, Abwind und rot-blauem Lichtschein auf dem nassen Asphalt).
func _draw_landing(p: QP, e: QP, P: Variant, cam: float, t: float) -> void:
	var k: Array = _land_pose(P, cam, t)
	var x: float = k[0]
	var yg: float = k[1]
	var ppx: float = k[2]
	var d: int = k[3]
	var D: float = Config.LAND_DEPTH
	var gx := Persp.screen_x(float(P["x"]), D, cam)
	var gy := Persp.ground_y(D)
	var alt: float = P.get("alt", 1.0)
	var L := Vehicles.SPIN_L * ppx
	# Schatten wächst, je tiefer er kommt
	var sh := maxf(0.0, 1.0 - alt)
	if sh > 0.02:
		p.set_no_pen()
		p.set_brush(QP.c(0, 0, 0, int(140 * sh)))
		var ww := Persp.ppu(D) * 90 * (0.6 + 0.5 * sh)
		p.draw_ellipse(gx - ww / 2, gy - 4, ww, 8)
	var r: Array = Vehicles.spinner_image(ppx, true, d, false)
	var im: QImg = r[0]
	@warning_ignore("unused_variable")
	var em: QImg = r[1]
	var ax: int = r[2]
	var ayg: int = r[4]
	if alt < 0.25:
		p.set_opacity(minf(1.0, 0.5 * _reflk) * (1 - alt * 4))
		_draw_refl(p, int(x) - ax, int(gy) - (im.height() - 1 - ayg) + int(gy - yg), im)
		p.set_opacity(1.0)
	# Abwind: heller Luftschleier unter dem Rumpf + Gischt am Boden
	var wash: float = P.get("wash", 0.0)
	p.set_mode(PLUS)
	if alt > 0.0 or wash > 0:
		var g := QGrad.linear(x, yg - 6 * ppx, x, gy)
		var a := int(60 * maxf(wash, 0.4 if alt < 1 else 0.0))
		g.set_color_at(0, QP.c(200, 210, 230, a))
		g.set_color_at(1, QP.c(200, 210, 230, 0))
		p.set_no_pen()
		p.set_brush(g)
		p.draw_polygon(PackedVector2Array([Vector2(x - L * 0.3, yg - 4 * ppx), Vector2(x + L * 0.3, yg - 4 * ppx),
			Vector2(x + L * 0.75, gy + 3), Vector2(x - L * 0.75, gy + 3)]))
	if wash > 0.05:
		for kk in range(3):     # Druckwellen-Ringe auf dem Wasserfilm
			var ph := Py.mod(t * 1.6 + float(kk) / 3.0, 1.0)
			var rw := L * (0.4 + 1.2 * ph)
			p.set_pen(QP.c(190, 200, 230, int(90 * wash * (1 - ph))), 1)
			p.set_no_brush()
			p.draw_ellipse(gx - rw / 2, gy - rw * 0.06, rw, rw * 0.12)
		p.set_no_pen()
		if rng.random() < wash * 0.9:
			fx.puff(rng.uniform(-40, 40), gy - 4, P["x"], D, 1.4)
	# Rot-blauer Schein auf der nassen Straße, wenn er steht
	if P.get("phase") == "landed":
		var on := Py.imod(int(t * 7), 4) < 2
		var c: Array = [224, 72, 150] if on else [90, 140, 255]
		var rg := QGrad.radial(gx, gy, L * 0.9)
		rg.set_color_at(0, QP.rgb(c, 55))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(gx, gy)
		p.scale(1.0, 0.3)
		p.translate(-gx, -gy)
		p.fill_rect(gx - L, gy - L, 2 * L, 2 * L, rg)
		p.restore()
	p.set_mode(OVER)
	_spinner_sprite(p, e, x, yg, ppx, d, t, true, false, alt > 0.05)
	if alt > 0.0:       # Turbinen glühen nach unten
		for q: QP in [p, e]:
			q.fill_rect(x - L * 0.32, yg - 3.6 * ppx, L * 0.5, maxf(1.0, ppx * 0.9), QP.rgb([255, 200, 140]))


func _patrol(p: QP, e: QP, world: Variant, cam: float, t: float) -> void:
	var g: Variant = _patrol_geom(world, cam, t)
	_beam_poly = null
	if g == null:
		return
	var arr: Array = g
	var P: Variant = arr[0]
	var sx: float = arr[1]
	var sy: float = arr[2]
	var bx: float = arr[3]
	var by: float = arr[4]
	var rx: float = arr[5]
	var ry: float = arr[6]
	var on: float = P["on"]
	if on > 0.02:
		var pts := PackedVector2Array([Vector2(sx - 2, sy), Vector2(bx - rx, by), Vector2(bx + rx, by),
			Vector2(sx + 2, sy)])
		_beam_poly = [pts, on]
		p.set_mode(PLUS)
		p.set_no_pen()
		for wa: Array in [[1.0, 34], [0.55, 40]]:
			var wf: float = wa[0]
			var a: int = wa[1]
			var pl := PackedVector2Array([Vector2(sx - 2, sy), Vector2(bx - rx * wf, by), Vector2(bx + rx * wf, by),
				Vector2(sx + 2, sy)])
			var gr := QGrad.linear(sx, sy, bx, by)
			gr.set_color_at(0, QP.c(210, 225, 255, int(a * 2.2 * on)))
			gr.set_color_at(1, QP.c(210, 225, 255, int(a * on)))
			p.set_brush(gr)
			p.draw_polygon(pl)
		var rg := QGrad.radial(bx, by, rx)
		rg.set_color_at(0, QP.c(230, 240, 255, int(120 * on)))
		rg.set_color_at(0.7, QP.c(200, 220, 255, int(50 * on)))
		rg.set_color_at(1, QP.c(0, 0, 0, 0))
		p.save()
		p.translate(bx, by)
		p.scale(1.0, ry / rx)
		p.translate(-bx, -by)
		p.fill_rect(bx - rx, by - rx, 2 * rx, 2 * rx, rg)
		p.restore()
		p.set_mode(OVER)
	if float(P.get("alt", 1.0)) < 1.0:
		return          # steht/landet: wird nach Tiefe sortiert in _actors gezeichnet
	# Der Spinner selbst
	var d: int = int(P["dir"]) if P.get("leaving") else (1 if (float(P["bx"]) - float(P["x"])) >= 0 else -1)
	_spinner_body(p, e, sx, sy - 4, 2.4, d, t, true, true)
	# Scheinwerfer-Gondel unter dem Rumpf
	for q: QP in [p, e]:
		q.fill_rect(sx - 2, sy - 1, 4, 2, QP.rgb(DScene.WHITE))


## Regentropfen im Suchlicht hell nachzeichnen (wie im Film).
func _beam_rain(p: QP) -> void:
	if _beam_poly == null:
		return
	var bp: Array = _beam_poly
	var poly: PackedVector2Array = bp[0]
	var on: float = bp[1]
	p.save()
	p.set_clip_polygon(poly)
	p.set_mode(PLUS)
	fx.draw_rain(p, [int(200 * on), int(210 * on), int(240 * on)])
	p.restore()
# ------------------------------------------------------------------ Kampf-Overlays
func _hand(world: Variant) -> Array:
	var pl: Variant = world.player
	var sc: Variant = screen.get(pl.uid)
	if sc == null:
		var cx := Persp.screen_x(float(pl.x), float(pl.depth), float(world.camera_x))
		var gy := Persp.ground_y(float(pl.depth))
		return [cx, gy - Persp.figure_h(float(pl.depth)) * 0.62]
	var arr: Array = sc
	var cx2: float = arr[0]
	var gy2: float = arr[1]
	var meta: Dictionary = arr[3]
	var hand: Vector2 = meta["hand"]
	return [cx2 + hand.x + int(pl.facing) * 2, gy2 + hand.y]


func _chest(a: Variant, cam: float) -> Array:
	var sc: Variant = screen.get(a.uid)
	if sc != null:
		var arr: Array = sc
		return [arr[0], arr[1] - float(arr[2]) * 0.62, arr[2]]
	var cx := Persp.screen_x(float(a.x), float(a.depth), cam)
	var hgt := Persp.figure_h(float(a.depth))
	return [cx, Persp.ground_y(float(a.depth)) - hgt * 0.62, hgt]


func _combat(p: QP, e: QP, world: Variant, cam: float, _t: float) -> void:
	# Scan-Strahl
	if float(world.scan_t) >= 0 and world.scan_target != null and screen.has(world.player.uid):
		var tg: Variant = world.scan_target
		var hand: Array = _hand(world)
		var hx: float = hand[0]
		var hy: float = hand[1]
		var chest: Array = _chest(tg, cam)
		var tx: float = chest[0]
		var ty: float = chest[1]
		var thg: float = chest[2]
		var k := float(world.scan_t) / maxf(0.01, Config.SCAN_TIME * float(world.run.mods["scan_time"]))
		var sweep := ty - thg * 0.38 + thg * 0.9 * (0.5 + 0.5 * sin(k * PI * 3))
		p.set_mode(PLUS)
		var g := QGrad.linear(hx, hy, tx, ty)
		g.set_color_at(0, QP.c(64, 210, 220, 140))
		g.set_color_at(1, QP.c(64, 210, 220, 40))
		p.set_no_pen()
		p.set_brush(g)
		p.draw_polygon(PackedVector2Array([Vector2(hx, hy - 0.5), Vector2(tx, sweep - thg * 0.12),
			Vector2(tx, sweep + thg * 0.12), Vector2(hx, hy + 0.5)]))
		p.set_mode(OVER)
		for q: QP in [p, e]:
			q.fill_rect(tx - thg * 0.22, sweep, thg * 0.44, 1, QP.rgb(DScene.CYAN))
	# Laservisier
	if world.aiming:
		var hand2: Array = _hand(world)
		var hx2: float = hand2[0]
		var hy2: float = hand2[1]
		var b: Variant = world.blocker
		var tgt: Variant = world.target
		var ex := 0.0
		var ey := 0.0
		if b != null:
			var ch: Array = _chest(b, cam)
			ex = ch[0]
			ey = ch[1]
		elif tgt != null:
			var ch2: Array = _chest(tgt, cam)
			ex = ch2[0]
			ey = ch2[1]
		else:
			ex = hx2 + int(world.player.facing) * Config.SHOOT_RANGE * Persp.ppu(float(world.player.depth))
			ey = hy2
		var blocked: bool = b != null and b != tgt
		var col: Array = [255, 60, 80] if not blocked else DScene.AMBER
		var steady := minf(1.0, float(world.aim_t) / maxf(0.05, float(world.run.mods["aim_min"]) + 0.01))
		for qa: Array in [[p, 200], [e, 160]]:
			var q: QP = qa[0]
			var a_: int = qa[1]
			q.set_pen(QP.rgb(col, int(a_ * (0.4 + 0.6 * steady))), 1)
			q.draw_line(hx2, hy2, ex, ey)
			q.fill_rect(int(ex) - 1, int(ey) - 1, 3, 3, QP.rgb(col))
	# Leuchtspuren
	for trk: Dictionary in fx.tracers:
		var k2 := float(trk["t"]) / 0.16
		var hand3: Array = _hand(world)
		var hx3: float = hand3[0]
		var hy3: float = hand3[1]
		var ex := Persp.screen_x(float(trk["ex"]), float(trk["ed"]), cam)
		var ey := Persp.ground_y(float(trk["ed"])) - Persp.figure_h(float(trk["ed"])) * 0.62
		var sx := hx3
		var sy := hy3
		var a_ := int(255 * (1 - k2))
		for q: QP in [p, e]:
			q.set_pen(QP.c(255, 250, 230, a_), 2)
			q.draw_line(sx + (ex - sx) * k2 * 0.6, sy + (ey - sy) * k2 * 0.6, ex, ey)
			q.set_pen(QP.c(64, 210, 220, a_), 1)
			q.draw_line(sx, sy - 1, ex, ey - 1)
	for f: Dictionary in fx.flashes:
		var x := Persp.screen_x(float(f["wx"]), float(f["d"]), cam)
		var y := Persp.ground_y(float(f["d"])) + float(f["oy"])
		var r := 3 + 10 * (1 - float(f["t"]) / 0.12)
		var g := QGrad.radial(x, y, r)
		g.set_color_at(0, QP.c(255, 240, 210, 255))
		g.set_color_at(1, QP.c(255, 140, 60, 0))
		for q: QP in [p, e]:
			q.set_mode(PLUS)
			q.fill_rect(x - r, y - r, 2 * r, 2 * r, g)
			q.set_mode(OVER)
	for s: Dictionary in fx.sparks:
		var sc := Persp.scale(float(s["d"]))
		var x := Persp.screen_x(float(s["wx"]), float(s["d"]), cam) + float(s["ox"]) * sc
		var y := Persp.ground_y(float(s["d"])) + float(s["oy"])
		if y > Persp.ground_y(float(s["d"])):
			continue
		var c: Array = s["c"]
		p.fill_rect(int(x), int(y), 1, 1, QP.rgb(c))
		if c[0] > 200:
			e.fill_rect(int(x), int(y), 1, 1, QP.rgb(c))


# ------------------------------------------------------------------ Vordergrund
## Vordergrund je Zone: [Art, Gewicht]. Nur DÜNNE Dinge direkt vor der Kamera - Kabel,
## Masten, Rohre, Lampionschnüre. Die dicken Säulen stehen auf der anderen Straßenseite.
const FG_KINDS := [
	[["cable", 4], ["cables", 4], ["pole", 2], ["pipe", 2], ["none", 1]],
	[["cable", 3], ["cables", 3], ["pole", 3], ["lanterns", 1], ["none", 1]],
	[["cables", 4], ["lanterns", 4], ["pole", 2], ["cable", 2], ["none", 1]],
	[["cable", 3], ["pipe", 3], ["pole", 2], ["cables", 3], ["none", 1]],
	[["pole", 2], ["cable", 2], ["none", 4]],
]
const FG_DEPTH := 1.9           # sehr nah an der Kamera -> zieht schnell vorbei
const FG_SPACING := 190.0
const FG_BLUR := 3              # Unschärfe: Faktor des Herunterskalierens
const NEAR_BLUR := 2            # Unschärfe der kameranahen Ebene
const WIRE_SHARP := 1.15        # Kabelstücke ab dieser Tiefe kommen in die unscharfe Ebene


## Dünne Requisiten direkt vor der Kamera, außerhalb der Schärfeebene: Kabel mit losen,
## pendelnden Enden, Masten mit Ampel/Schild, Rohre, Lampionschnüre. Eigene Ebene, die
## vor dem Einsetzen weichgezeichnet wird (Tiefenunschärfe).
func _foreground(p: QP, cam: float) -> void:
	if not _fg_draw(_fq, cam):
		return
	p.save()
	p.reset_transform()
	p.set_mode(OVER)
	p.set_opacity(1.0)
	p.set_smooth(true)
	p.draw_texture(Rect2(0, 0, W, H), _fg_tex)
	p.restore()


func _fg_draw(p: QP, cam: float) -> bool:
	var d := FG_DEPTH
	var k := Persp.ppu(d)
	var spacing := FG_SPACING
	var t := t_
	var th: Dictionary = city.th
	var z := Py.imod(city.zone, FG_KINDS.size())
	var kinds: Array = FG_KINDS[z]
	var tot := 0.0
	for kw: Array in kinds:
		tot += float(kw[1])
	var dk := [5, 7, 9]
	var rim := mul(th["rim"], 0.3)
	var e := _fg_e
	var drawn := false
	var first := int(floor((cam - W / k) / spacing)) - 1
	for i in range(first, first + 7):
		var wx := i * spacing + 120 * Scene._hash(i, 3)
		var x := Persp.screen_x(wx, d, cam)
		if x < -300 or x > W + 300:
			continue
		var r := Scene._hash(i, 9 + z) * tot
		var kind: String = kinds[-1][0]
		for kw: Array in kinds:
			if r < float(kw[1]):
				kind = kw[0]
				break
			r -= float(kw[1])
		if kind == "none":
			continue
		drawn = true
		var sway := sin(t * 0.9 + i * 1.7) * 3.0
		if kind in ["cable", "cables", "lanterns"]:
			var n := 1 if kind == "cable" else (2 + int(Scene._hash(i, 4) * 2))
			for j in n:
				var y0 := -4 + 40 * Scene._hash(i, 5 + j)
				var y1 := -4 + 40 * Scene._hash(i, 15 + j)
				var span := 320 + 200 * Scene._hash(i, 25 + j)
				var sag := 18 + 34 * Scene._hash(i, 35 + j)
				var xa := x - span / 2
				var xb := x + span / 2
				var pts := PackedVector2Array()
				var wds := PackedFloat32Array()
				var wpen := 5.0 if j == 0 else 3.0
				for s_ in 17:
					var u := s_ / 16.0
					pts.append(Vector2(xa + (xb - xa) * u, y0 + (y1 - y0) * u + (sag + sway) * 4 * u * (1 - u)))
					wds.append(wpen)
				p.draw_strip(pts, wds, QP.rgb(dk))
				if kind == "lanterns" and j == 0:
					p.set_no_pen()
					var neon: Array = th["neon"]
					for s_ in range(2, 15, 2):
						var q_ := pts[s_]
						var c: Array = neon[int(Scene._hash(i * 31 + s_, 2) * neon.size())]
						var lit := dark < 0.4 and Scene._hash(int(t * 3) + s_, i) > 0.04
						var qs: Array = [e, p] if lit and e != null else [p]
						for q: QP in qs:
							q.set_no_pen()
							q.set_brush(QP.rgb(c if lit else mul(c, 0.3)))
							q.draw_ellipse(q_.x - 6, q_.y + 2, 12, 15)
				# loses Ende, pendelt im Wind
				if j == 0 and Scene._hash(i, 45) < 0.7:
					var q0 := pts[int(4 + 8 * Scene._hash(i, 46))]
					var ln := 40 + 90 * Scene._hash(i, 47)
					var ang := sin(t * 1.3 + i) * 0.14
					p.set_pen(QP.rgb(dk), 3)
					p.draw_line(q0.x, q0.y, q0.x + sin(ang) * ln, q0.y + cos(ang) * ln)
			p.set_no_pen()
		elif kind == "pole":
			var pw := 10
			p.fill_rect(int(x), 0, pw, H, QP.rgb(dk))
			p.fill_rect(int(x) + pw - 2, 0, 2, H, QP.rgb(rim))
			var hy := int(H * (0.14 + 0.14 * Scene._hash(i, 6)))
			if Scene._hash(i, 7) < 0.5:       # Ampelkopf
				p.fill_rect(int(x) - 8, hy, 26, 50, QP.rgb([12, 12, 14]))
				var st := Py.imod(int((t + Scene._hash(i, 8) * 9) / 3.0), 3)
				var pal: Array = Palette.zone_look(city.zone)["pal"]
				var lc: Array = [pal[6], th["neon"][0], th["neon"][-1]]
				for kk_ in 3:
					var c: Array = lc[kk_]
					var on := kk_ == st and dark < 0.4
					var qs: Array = [p, e] if on and e != null else [p]
					for q: QP in qs:
						q.fill_rect(int(x) - 3, hy + 4 + kk_ * 15, 14, 11, QP.rgb(c if on else mul(c, 0.2)))
			else:                       # Straßenschild
				var word: String = ["NO STOPPING", "SECTOR 4", "DANGER", "ONE WAY", "CROSS NOW"][int(Scene._hash(i, 10) * 5)]
				var tw := Pixfont.text_width(word, 2)
				p.fill_rect(int(x) - Py.ifloordiv(tw, 2) - 6, hy, tw + 12, 22, QP.rgb([14, 20, 24]))
				Pixfont.draw(p, int(x) - Py.ifloordiv(tw, 2), hy + 4, word, mul(th["neon"][0], 0.5), 2, null)
			p.set_pen(QP.rgb(dk), 3)
			p.draw_line(x + 4, hy - 14, x + 240, 10 + sway)
			p.set_no_pen()
		elif kind == "pipe":
			var pw := 12
			var bot := int(H * (0.22 + 0.18 * Scene._hash(i, 11)))
			p.fill_rect(int(x), 0, pw, bot, QP.rgb([10, 12, 14]))
			p.fill_rect(int(x) + 2, 0, 2, bot, QP.rgb(rim))
			for yy in range(20, bot, 46):
				p.fill_rect(int(x) - 4, yy, pw + 8, 6, QP.rgb([18, 20, 22]))
			p.fill_rect(int(x) - 5, bot, pw + 10, 8, QP.rgb([12, 14, 16]))
			var ph := Py.mod(t * 1.4 + Scene._hash(i, 12), 1.0)
			p.fill_rect(int(x) + 5, bot + 8 + ph * (H - bot), 2, 6, QP.rgb(mix(th["fog"], DScene.PALE, 0.6), 160))
	return drawn


# ------------------------------------------------------------------ Feuer / Ampeln (Fassade)
## Feuertonnen an der gegenüberliegenden Häuserfront: Flammenzungen + Lichthof.
func _fires(p: QP, e: QP, cam: float, t: float) -> void:
	var fac: City.Layer = city.facade
	var halos: Array = []
	for f: Array in city.fires:
		var L: float = f[0]
		var y: float = f[1]
		var s: float = f[2]
		var sd: int = f[3]
		var x := fac.screen_x(L, cam)
		if x < -30 or x > W + 30:
			continue
		for q: QP in [p, e]:
			for i in 5:
				var n := Scene._hash(int(t * 11) + i * 7, sd + i)
				var hx := x + (i - 2) * 1.3 + sin(t * 9 + i * 2.1 + sd) * 0.8
				var hh := s * (4 + 9 * n) * (1.0 if i in [1, 2, 3] else 0.6)
				var col: Array = [255, 236, 170] if i == 2 else ([255, 150, 40] if i % 2 else [230, 70, 30])
				q.set_no_pen()
				q.set_brush(QP.rgb(col))
				q.draw_polygon(PackedVector2Array([Vector2(hx - 1.6, y + 1), Vector2(hx + 1.6, y + 1),
					Vector2(hx + sin(t * 13 + i) * 1.2, y - hh)]))
		if Scene._hash(int(t * 7), sd) < 0.18:      # Funke
			var fy_ := y - 6 - 18 * Scene._hash(int(t * 7) + 1, sd)
			for q: QP in [p, e]:
				q.fill_rect(int(x + 6 * (Scene._hash(int(t * 7) + 2, sd) - 0.5)), int(fy_), 1, 1, QP.rgb([255, 200, 120]))
		halos.append([x, y - 4, 26 + 4 * sin(t * 7 + sd)])
	if not halos.is_empty():
		p.set_mode(PLUS)
		for ha: Array in halos:
			var hx: float = ha[0]
			var hy: float = ha[1]
			var r: float = ha[2]
			var g := QGrad.radial(hx, hy, r)
			g.set_color_at(0, QP.c(255, 140, 50, 70))
			g.set_color_at(0.5, QP.c(255, 110, 40, 22))
			g.set_color_at(1, QP.c(0, 0, 0, 0))
			p.fill_rect(hx - r, hy - r, 2 * r, 2 * r, g)
		p.set_mode(OVER)


# 7x7-Piktogramme wie im Film: Pfeil nach oben (grün) und die rote Hand
const _ARROW := ["...#...", "..###..", ".#####.", "#######", "..###..", "..#.#..", "..###.."]
const _HAND := ["#.#.#..", "#.#.#.#", "#.#.#.#", "#######", "######.", ".#####.", "..###.."]


## Ein Ampelpaar (grüner Pfeil / rote Hand) bei bx,y; sz = Feldgröße in Pixeln.
func _walk_icon(p: QP, e: QP, bx: float, y: float, sz: float, t: float, ph: float) -> void:
	var ph_t := Py.mod(t + ph, 9.0)
	var go := ph_t < 4.0
	var blink := not go and ph_t > 7.6 and Py.imod(int(t * 4), 2) == 0
	var cell := sz / 8.0
	var icons := [[_ARROW, [40, 200, 150], go], [_HAND, [236, 70, 52], not go and not blink]]
	for k in 2:
		var icon: Array = icons[k][0]
		var col: Array = icons[k][1]
		var lit: bool = icons[k][2]
		var x0 := bx + k * (sz + cell)
		if dark > 0.4:
			lit = false
		var fill: Array = col if lit else mul(col, 0.3)
		var qs: Array = [p, e] if lit else [p]
		for q: QP in qs:
			q.fill_rect(x0, y, sz, sz + cell, QP.rgb(fill))
		var ink := QP.rgb([10, 12, 12] if lit else mul(col, 0.12))
		var cw := maxf(1.0, cell)
		for r in 7:
			var row: String = icon[r]
			for c_ in 7:
				if row.unicode_at(c_) == 35:       # "#"
					p.fill_rect(x0 + (c_ + 0.5) * cell, y + (r + 1) * cell, cw, cw, ink)


## Ampelturm als freistehendes Objekt (Schatten, Spiegelung, Umriss, Ampel live).
func _draw_tower(p: QP, e: QP, o: Dictionary, cam: float, t: float) -> void:
	var d: float = o["d"]
	var k := Persp.ppu(d)
	var cx := Persp.screen_x(float(o["x"]), d, cam)
	var sc := k / Persp.FACADE_PPU * float(o.get("size", 1.0))
	if cx < -45 * sc or cx > W + 45 * sc:
		return
	var gy := Persp.ground_y(d)
	var s := Py.round(sc * 8) / 8.0
	var hit := Props.tower_sprite(int(o["seed"]), s, city.th)
	if hit.is_empty():
		return
	var im: QImg = hit[0]
	var em: QImg = hit[1]
	var ax: int = hit[2]
	var ay: int = hit[3]
	var walks_: Array = hit[4]
	var blinks_: Array = hit[5]
	var x0 := int(cx) - ax
	var y0 := int(gy) - ay
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 120))
	p.draw_ellipse(cx - 16 * s, gy - 2 * s, 32 * s, 4 * s)
	if gy < H:
		p.set_opacity(minf(1.0, 0.4 * _reflk))
		_draw_refl(p, x0, int(gy) - (im.height() - 1 - ay), im)
		p.set_opacity(1.0)
	p.draw_image_at(x0, y0, im)
	e.draw_image_at(x0, y0, em)
	for wk: Array in walks_:
		_walk_icon(p, e, cx + float(wk[0]) * s, gy + float(wk[1]) * s, float(wk[3]) * s, t, float(wk[2]))
	for bl: Array in blinks_:
		if sin(t * 2.2 + float(bl[4]) * 2.1) > 0.55 and dark < 0.4:
			var bx := cx + float(bl[1]) * s
			var by := gy + float(bl[2]) * s
			for q: QP in [p, e]:
				q.fill_rect(bx - s, by - s, 2 * s, 2 * s, QP.rgb(bl[3]))


## Kabel quer über die Straße (hinten scharf, vorn leicht unscharf) und die kameranahen
## Ampeltürme - beide in einer eigenen, weichgezeichneten Ebene.
func _near_layer(p: QP, e: QP, cam: float, t: float) -> void:
	var wires := _wire_segments(cam, t)
	if wires.is_empty() and _near.is_empty():
		return
	var q := _nq
	q.reset_transform()
	q.translate(p.transform().origin.x, p.transform().origin.y)
	for o: Dictionary in _near:
		_draw_tower(q, e, o, cam, t)
	var rim: Array = city.th["rim"]
	var hl := QP.c(rim[0], rim[1], rim[2], 60)
	for wseg: Array in wires:
		var pts: PackedVector2Array = wseg[0]
		var wd: PackedFloat32Array = wseg[1]
		var col := QP.rgb(wseg[2])
		var near: Array = wseg[3]
		# Läufe gleicher Ebene (scharf/unscharf) als ein Band bzw. eine Linie
		var a := 0
		var nseg := pts.size() - 1
		while a < nseg:
			var b := a
			while b + 1 < nseg and near[b + 1] == near[a]:
				b += 1
			var tgt: QP = q if near[a] else p
			var run := pts.slice(a, b + 2)
			var rw := PackedFloat32Array()
			var thick := false
			for i in range(a, b + 2):
				var wi := maxf(1.0, wd[mini(i, nseg - 1)])
				rw.append(wi)
				thick = thick or wi > 1.0
			if thick:
				tgt.draw_strip(run, rw, col)
			else:
				tgt.set_pen(col, 1.0)
				tgt.draw_polyline(run)
			# Streiflicht oben: liest sich gegen den Himmel
			var hl_pts := PackedVector2Array()
			for i in range(a, b + 1):
				if wd[i] > 1.6:
					var off := Vector2(0, -wd[i] * 0.45)
					if hl_pts.is_empty():
						hl_pts.append(pts[i] + off)
					hl_pts.append(pts[i + 1] + off)
				elif not hl_pts.is_empty():
					tgt.set_pen(hl, 1.0)
					tgt.draw_polyline(hl_pts)
					hl_pts = PackedVector2Array()
			if hl_pts.size() > 1:
				tgt.set_pen(hl, 1.0)
				tgt.draw_polyline(hl_pts)
			a = b + 1
	p.set_no_pen()
	q.set_no_pen()
	p.save()
	p.reset_transform()
	p.set_mode(OVER)
	p.set_opacity(1.0)
	p.set_smooth(true)
	p.draw_texture(Rect2(0, 0, W, H), _near_tex)
	p.restore()


## Bildschirm-Polylinien der Querkabel: [punkte, breiten, farbe, nah-flags].
func _wire_segments(cam: float, t: float) -> Array:
	var out: Array = []
	var ws: Array = city.wires
	if ws.is_empty():
		return out
	var half := W / Persp.ppu(-0.075) * 0.5
	var lo := cam - half - 120
	var hi := cam + half + 120
	var xs: Array = []
	for wi: Dictionary in ws:
		xs.append(float(wi["x"]))
	var i0 := City.bisect_left(xs, lo)
	var n := 28 if opt_quality == "hoch" else (20 if opt_quality == "mittel" else 14)
	var d_end := 2.4
	for wi in range(i0, ws.size()):
		var w_: Dictionary = ws[wi]
		if float(w_["x"]) > hi:
			break
		var sway := sin(t * 0.6 + float(w_["seed"])) * 3.0
		var h0: float = w_["h0"]
		var h1: float = w_["h1"]
		var sag: float = w_["sag"]
		for st: Dictionary in w_["strands"]:
			var pts := PackedVector2Array()
			var wd := PackedFloat32Array()
			var near: Array = []
			for j in n + 1:
				var u := float(j) / n
				var d := -0.075 + (d_end + 0.075) * u
				var hgt := h0 + (h1 - h0) * u - (sag + float(st["dsag"]) + sway) * 4 * u * (1 - u) + float(st["dh"])
				var k := Persp.ppu(d)
				var x := Persp.screen_x(float(w_["x"]) + float(w_["dx"]) * u + float(st["dx"]), d, cam)
				var y := Persp.ground_y(d) - hgt * k
				pts.append(Vector2(x, y))
				wd.append(float(st["w"]) * k)
				near.append(d > WIRE_SHARP)
				if y < -30 and u > 0.5:
					break
			if pts.size() > 1:
				out.append([pts, wd, w_["col"], near])
	return out


## Fußgängerampeln der Ampeltürme: grünes Feld mit Pfeil / rotes Feld mit Hand, im
## Wechsel; das jeweils andere Feld glimmt nur.
func _walk_signals(p: QP, e: QP, cam: float, t: float) -> void:
	var fac: City.Layer = city.facade
	for wk: Array in city.walks:
		var x := int(fac.screen_x(float(wk[0]), cam))
		if -24 <= x and x <= W + 24:
			_walk_icon(p, e, x, float(wk[1]), float(wk[3]), t, float(wk[2]))


# ------------------------------------------------------------------ Überbauten
const D_FAR := Config.FACADE_DEPTH
const D_NEAR := 1.7


static func _pt(x: float, d: float, hh: float, cam: float) -> Vector2:
	return Vector2(Persp.screen_x(x, d, cam), Persp.ground_y(d) - hh * Persp.ppu(d))


static func _hull(pts: Array) -> PackedVector2Array:
	var pa := PackedVector2Array()
	for q: Vector2 in pts:
		pa.append(Vector2(snappedf(q.x, 0.01), snappedf(q.y, 0.01)))
	var hull := Geometry2D.convex_hull(pa)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)
	return hull


func _spans_on(cam: float) -> Array:
	var out: Array = []
	for s: Dictionary in city.spans:
		var a := minf(Persp.screen_x(float(s["x0"]), D_NEAR, cam), Persp.screen_x(float(s["x0"]), D_FAR, cam))
		var b := maxf(Persp.screen_x(float(s["x1"]), D_NEAR, cam), Persp.screen_x(float(s["x1"]), D_FAR, cam))
		if b > -30 and a < W + 30:
			out.append(s)
	return out


## Bildschirm-Polygon des Raums unter dem Überbau (trocken, dunkler).
func _span_volume(s: Dictionary, cam: float) -> PackedVector2Array:
	var pts: Array = []
	for x: float in [float(s["x0"]), float(s["x1"])]:
		for d: float in [D_FAR, D_NEAR]:
			for hh: float in [0.0, float(s["hu"])]:
				pts.append(_pt(x, d, hh, cam))
	return _hull(pts)


## Trockene Bereiche (Raum unter dem Überbau + Baukörper) als Polygone - dort kein Regen.
func _span_clip(cam: float) -> Array:
	var out: Array = []
	for s: Dictionary in _spans_on(cam):
		out.append(_span_volume(s, cam))
		var pts: Array = []
		for x: float in [float(s["x0"]), float(s["x1"])]:
			for d: float in [D_FAR, D_NEAR]:
				for hh: float in [float(s["hu"]), float(s["hu"]) + float(s["t"])]:
					pts.append(_pt(x, d, hh, cam))
		out.append(_hull(pts))
	return out


## Brücken / überhängende Gebäude: Schatten am Boden, Pfeiler, Baukörper, Lichter.
func _spans_back(p: QP, e: QP, cam: float, t: float) -> void:
	var th: Dictionary = city.th
	var rim: Array = th["rim"]
	for s: Dictionary in _spans_on(cam):
		var x0: float = s["x0"]
		var x1: float = s["x1"]
		var hu: float = s["hu"]
		var T: float = s["t"]
		var col: Array = s["col"]
		var bridge: bool = s["kind"] == "bridge"
		p.set_no_pen()
		# Schatten auf Gehweg/Fahrbahn und an der Hauswand darunter
		var sh := 150 if bridge else 120
		p.set_brush(QP.c(0, 0, 0, sh))
		p.draw_polygon(PackedVector2Array([_pt(x0, D_FAR, 0, cam), _pt(x1, D_FAR, 0, cam), _pt(x1, 1.3, 0, cam),
			_pt(x0, 1.3, 0, cam)]))
		p.draw_polygon(PackedVector2Array([_pt(x0, D_FAR, hu, cam), _pt(x1, D_FAR, hu, cam),
			_pt(x1, D_FAR, 0, cam), _pt(x0, D_FAR, 0, cam)]))
		# Pfeiler (Brücke) auf der anderen Straßenseite
		for pier: float in s["piers"]:
			var d := -0.035
			var k := Persp.ppu(d)
			var xp := Persp.screen_x(pier, d, cam)
			var pw := 20 * k
			var gy := Persp.ground_y(d)
			var top := gy - hu * k
			var g := QGrad.linear(0, top, 0, gy)
			g.set_color_at(0, QP.rgb(mul(col, 0.6)))
			g.set_color_at(1, QP.rgb(mul(col, 1.5)))
			p.fill_rect(xp - pw / 2, top, pw, gy - top, g)
			e.fill_rect(xp - pw / 2, top, pw, gy - top, QP.c(0, 0, 0))
			p.fill_rect(xp - pw / 2, top, 1, gy - top, QP.rgb(mul(rim, 0.45)))
			p.fill_rect(xp + pw / 2 - 3, top, 3, gy - top, QP.rgb(mul(col, 0.5)))
			p.fill_rect(xp - pw / 2 - 2, gy - 6, pw + 4, 6, QP.rgb(mul(col, 1.2)))
			for yy in range(int(top) + 8, int(gy) - 8, 14):
				p.fill_rect(xp - pw / 2 + 1, yy, pw - 4, 1, QP.rgb(mul(col, 0.8)))
		# Baukörper
		var corners: Array = []
		for x: float in [x0, x1]:
			for d: float in [D_FAR, D_NEAR]:
				for hh: float in [hu, hu + T]:
					corners.append(_pt(x, d, hh, cam))
		var hull := _hull(corners)
		var yb := _pt(x0, D_FAR, hu, cam).y
		var lit := mix(col, rim, 0.22)
		var g2 := QGrad.linear(0, yb - 70, 0, yb)
		g2.set_color_at(0, QP.rgb(mul(col, 0.45)))
		g2.set_color_at(0.75, QP.rgb(col))
		g2.set_color_at(1, QP.rgb(lit))
		p.set_brush(g2)
		p.draw_polygon(hull)
		e.set_no_pen()
		e.set_brush(QP.c(0, 0, 0))                 # verdeckt das Leuchten dahinter
		e.draw_polygon(hull)
		# sichtbare Stirnseite
		for xv: Array in [[x0, cam < x0], [x1, cam > x1]]:
			if not xv[1]:
				continue
			var x: float = xv[0]
			var fpts: Array = []
			for d: float in [D_FAR, D_NEAR]:
				for hh: float in [hu, hu + T]:
					fpts.append(_pt(x, d, hh, cam))
			var face := _hull(fpts)
			p.set_brush(QP.rgb(mul(col, 0.8)))
			p.draw_polygon(face)
			if bridge:
				# Fachwerkträger zwischen Unter- und Obergurt
				p.set_pen(QP.rgb(mul(lit, 0.8)), 1.0)
				var dd := D_FAR
				var up := true
				while dd < D_NEAR:
					var d2 := dd + 0.09
					p.draw_line_v(_pt(x, dd, hu if up else hu + T, cam), _pt(x, d2, hu + T if up else hu, cam))
					p.draw_line_v(_pt(x, d2, hu, cam), _pt(x, d2, hu + T, cam))
					dd = d2
					up = not up
				p.set_pen(QP.rgb(mul(rim, 0.7)), 1.0)
				p.draw_line_v(_pt(x, D_FAR, hu + T, cam), _pt(x, D_NEAR, hu + T, cam))
				p.set_no_pen()
				for k in 6:            # Geländerleuchten
					var q_ := _pt(x, D_FAR + 0.15 + k * 0.22, hu + T + 2, cam)
					for q: QP in [p, e]:
						q.fill_rect(q_.x - 1, q_.y - 1, 2, 2, QP.rgb(DScene.AMBER))
			else:
				# Stirnwand des Überhangs: Fensterreihen in die Tiefe
				var wins: Array = city.th["win"]
				var rr := PyRandom.new(int(s["seed"]))
				for row in 6:
					var hh := hu + 14 + row * 16
					var dd := D_FAR + 0.04
					while dd < D_NEAR - 0.1:
						var a := _pt(x, dd, hh, cam)
						var b := _pt(x, dd + 0.05, hh + 7, cam)
						var on := rr.random() < 0.35
						var c: Array = mul(wins[rr.randrange(wins.size())][0], 0.6) if on else mul(col, 0.45)
						var poly := PackedVector2Array([a, _pt(x, dd + 0.05, hh, cam), b, _pt(x, dd, hh + 7, cam)])
						p.set_brush(QP.rgb(c))
						p.draw_polygon(poly)
						if on:
							e.set_brush(QP.rgb(mul(c, 0.5)))
							e.draw_polygon(poly)
						dd += 0.09
			p.set_pen(QP.rgb(mul(rim, 0.8)), 1.0)
			p.draw_line_v(_pt(x, D_FAR, hu, cam), _pt(x, D_NEAR, hu, cam))
			p.set_no_pen()
		# Unterkante zur Straße hin
		p.set_pen(QP.rgb(mul(rim, 0.5)), 1.0)
		p.draw_line_v(_pt(x0, D_FAR, hu, cam), _pt(x1, D_FAR, hu, cam))
		p.set_no_pen()
		_span_lights(p, e, s, cam, t)


func _span_lights(p: QP, e: QP, s: Dictionary, cam: float, t: float) -> void:
	var x0: float = s["x0"]
	var x1: float = s["x1"]
	var hu: float = s["hu"]
	var w_ := x1 - x0
	var dk := dark > 0.4
	var pools: Array = []
	if s["kind"] == "bridge":
		# Natriumlampen an kurzen Abhängern unter dem Deck
		for f: float in [0.3, 0.7]:
			var d := 0.12
			var x := x0 + w_ * f
			var top := _pt(x, d, hu, cam)
			var lamp := _pt(x, d, hu - 16, cam)
			p.set_pen(QP.rgb([14, 14, 16]), 1.0)
			p.draw_line_v(top, lamp)
			p.set_no_pen()
			var c := [255, 160, 70]
			if not dk:
				for q: QP in [p, e]:
					q.fill_rect(lamp.x - 2, lamp.y, 5, 2, QP.rgb(c))
				pools.append([x, d, c, 0.9])
		# rote Positionslichter an der Kante
		for k in 4:
			if Py.imod(int(t * 1.5) + k, 4) == 0 and not dk:
				var q_ := _pt(x0 + w_ * (k + 0.5) / 4, D_FAR, hu, cam)
				for q: QP in [p, e]:
					q.fill_rect(q_.x, q_.y - 1, 2, 2, QP.rgb(DScene.RED))
	else:
		# Neonröhren unter der Vorderkante (wie die Lichtschläuche im Film)
		var tubes: Array = s["tubes"]
		for i in tubes.size():
			var c: Array = tubes[i]
			var a := _pt(x0 + 6, D_FAR, hu, cam)
			var b := _pt(x1 - 6, D_FAR, hu, cam)
			var y := a.y + 3 + i * 4
			var n := 6
			for j in n:
				if Scene._hash(j + i * 11, int(s["seed"])) < 0.18:
					continue                       # kaputtes Segment
				var flick := Scene._hash(int(t * 14) + j, int(s["seed"]) + i) < 0.03
				var xa := a.x + (b.x - a.x) * j / n + 1
				var xb := a.x + (b.x - a.x) * (j + 1) / n - 1
				var cc: Array = mul(c, 0.25) if (dk or flick) else c
				var qs: Array = [p] if dk or flick else [p, e]
				for q: QP in qs:
					q.fill_rect(xa, y, xb - xa, 2, QP.rgb(cc))
				p.fill_rect(xa, y + 2, xb - xa, 1, QP.rgb(mul(cc, 0.35)))
			if not dk:
				pools.append([x0 + w_ * 0.5, 0.05 + 0.1 * i, c, 0.55])
		# hängende Schilder
		for sg: Array in s["signs"]:
			var f: float = sg[0]
			var c: Array = sg[1]
			var word: String = sg[2]
			var drop: float = sg[3]
			var sd: int = sg[4]
			var x := x0 + w_ * f
			var top := _pt(x, D_FAR + 0.03, hu, cam)
			var tw := Pixfont.text_width(word)
			var bx := int(top.x)
			var by := int(top.y + drop)
			p.set_pen(QP.rgb([16, 16, 18]), 1.0)
			p.draw_line(bx + 2, top.y, bx + 2, by)
			p.draw_line(bx + tw + 4, top.y, bx + tw + 4, by)
			p.set_no_pen()
			p.fill_rect(bx, by, tw + 7, 10, QP.rgb([10, 12, 14]))
			var lit := not dk and Scene._hash(int(t * 9), sd) > 0.02
			var qs: Array = [p, e] if lit else [p]
			for q: QP in qs:
				Pixfont.draw(q, bx + 4, by + 2, word, c if lit else mul(c, 0.3), 1, null)
	# Lichtpfützen am Boden unter den Lampen
	if not pools.is_empty():
		p.set_mode(PLUS)
		for pl: Array in pools:
			var x: float = pl[0]
			var d: float = pl[1]
			var c: Array = pl[2]
			var k: float = pl[3]
			var gx := Persp.screen_x(x, d, cam)
			var gy := Persp.ground_y(d)
			var r := 46 * Persp.scale(d)
			var rg := QGrad.radial(gx, gy, r)
			rg.set_color_at(0, QP.rgb(c, int(90 * k)))
			rg.set_color_at(1, QP.c(0, 0, 0, 0))
			p.save()
			p.translate(gx, gy)
			p.scale(1.0, 0.35)
			p.translate(-gx, -gy)
			p.fill_rect(gx - r, gy - r, 2 * r, 2 * r, rg)
			p.restore()
		p.set_mode(OVER)


## Unter dem Überbau ist es dunkler; von den Kanten tropft das Regenwasser.
func _spans_front(p: QP, _e: QP, cam: float, t: float) -> void:
	var th: Dictionary = city.th
	var drip := mix(th["fog"], DScene.PALE, 0.6)
	for s: Dictionary in _spans_on(cam):
		# unter dem Überbau ist es dunkler - auch auf den Leuten (Leuchtendes glüht weiter)
		p.set_no_pen()
		p.set_brush(QP.c(0, 0, 0, 70 if s["kind"] == "bridge" else 45))
		p.draw_polygon(_span_volume(s, cam))
		# Wasservorhang an den Stirnkanten
		var sd: int = s["seed"]
		for x: float in [float(s["x0"]), float(s["x1"])]:
			for k in 14:
				var d := D_FAR + (k + Scene._hash(k, sd)) * 0.09
				if d > 1.2:
					break
				var q_ := _pt(x, d, float(s["hu"]), cam)
				var gy := Persp.ground_y(d)
				var ph := Py.mod(t * (1.6 + Scene._hash(k, 7)) + Scene._hash(k, sd + 3), 1.0)
				var y := q_.y + (gy - q_.y) * ph
				var ln := 3 + 8 * Persp.scale(d)
				p.fill_rect(q_.x, y, 1, ln, QP.rgb(drip, 120))


# ------------------------------------------------------------------ Taube
## Weiße Taube: Körper, zwei Flügel im Schlag, leicht leuchtend im Gegenlicht.
func _draw_dove(p: QP, e: QP, dv: Dictionary, cam: float) -> void:
	var d: float = dv["d"]
	var k := Persp.ppu(d) * 2.2
	var x := Persp.screen_x(float(dv["x"]), d, cam)
	var y := Persp.ground_y(d) - float(dv["z"]) * Persp.ppu(d)
	if y < -20:
		return
	var flap := sin(float(dv["t"]) * 15.0)
	var body := [236, 240, 240]
	p.set_no_pen()
	p.set_mode(PLUS)                # weicher Schein, damit sie im Regen lesbar bleibt
	var g := QGrad.radial(x, y, 10 * k)
	g.set_color_at(0, QP.c(200, 210, 220, 60))
	g.set_color_at(1, QP.c(0, 0, 0, 0))
	p.fill_rect(x - 10 * k, y - 10 * k, 20 * k, 20 * k, g)
	p.set_mode(OVER)
	for qa: Array in [[p, 255], [e, 120]]:
		var q: QP = qa[0]
		q.set_no_pen()
		q.set_brush(QP.rgb(body, qa[1]))
		q.draw_ellipse(x - 2.2 * k, y - 1.0 * k, 4.4 * k, 2.0 * k)
		q.draw_ellipse(x + 1.6 * k, y - 1.6 * k, 1.6 * k, 1.4 * k)          # Kopf
		for s_: int in [-1, 1]:
			var tip_y := y - flap * 3.4 * k * s_ * s_
			q.draw_polygon(PackedVector2Array([Vector2(x - 1.2 * k, y), Vector2(x + 1.0 * k, y),
				Vector2(x - 0.4 * k + s_ * 0.6 * k, tip_y - 0.6 * k)]))
		q.draw_polygon(PackedVector2Array([Vector2(x - 2.0 * k, y - 0.3 * k), Vector2(x - 3.6 * k, y - 0.9 * k),
			Vector2(x - 3.6 * k, y + 0.5 * k)]))                    # Schwanz
	p.fill_rect(x + 2.8 * k, y - 1.1 * k, maxf(1.0, 0.6 * k), maxf(1.0, 0.4 * k), QP.rgb([200, 150, 90]))


# ------------------------------------------------------------------ Müll im Wind
## je Zone: [mittlerer Abstand der Böen s, Stücke je Böe min, max]. Tyrell ist sauber.
const LITTER := [[9.0, 3, 7], [16.0, 2, 4], [14.0, 2, 5], [10.0, 3, 6], [0.0, 0, 0]]
const PAPER := [[170, 166, 150], [140, 146, 140], [120, 108, 88], [190, 150, 110], [90, 96, 92]]


func _update_litter(dt: float, cam: float) -> void:
	var lr: Array = LITTER[Py.imod(city.zone, 5)]
	var rate: float = lr[0]
	for m: Dictionary in litter:
		m["x"] = float(m["x"]) + float(m["vx"]) * dt
		m["ph"] = float(m["ph"]) + float(m["spin"]) * dt
		m["t"] = float(m["t"]) + dt
		# Auftrieb in Böen, dann taumelnd wieder runter
		var vz: float = float(m["vz"]) + (-9.0 + 22.0 * maxf(0.0, sin(float(m["t"]) * 1.7 + float(m["seed"])))) * dt
		vz = maxf(-14.0, minf(16.0, vz))
		m["vz"] = vz
		m["z"] = maxf(0.0, float(m["z"]) + vz * dt)
		if float(m["z"]) <= 0.0:
			m["vx"] = float(m["vx"]) * maxf(0.0, 1.0 - 1.6 * dt)        # liegt: Reibung
			m["vz"] = maxf(0.0, float(m["vz"]))
	var half := W / 2.0 / Persp.ppu(0.3) + 80
	var kept: Array = litter.filter(func(m: Dictionary) -> bool: return absf(float(m["x"]) - cam) < half + 60)
	litter = kept.slice(maxi(0, kept.size() - 40))
	if rate <= 0:
		return
	_gust -= dt
	if _gust > 0:
		return
	_gust = rng.uniform(0.5, 1.5) * rate
	var side: int = rng.choice([-1, 1])
	var v := -side * rng.uniform(55, 95)
	for _i in rng.randint(lr[1], lr[2]):
		var d := rng.uniform(0.05, 1.0)
		var x := cam + side * (W / 2.0 / Persp.ppu(d) + rng.uniform(5, 60))
		var z := rng.uniform(2, 26)
		var vz := rng.uniform(-2, 8)
		var vx := v * rng.uniform(0.7, 1.2)
		var ph := rng.uniform(0, 6.28)
		var spin := rng.uniform(5, 12) * float(rng.choice([-1, 1]))
		var sd := rng.uniform(0, 6.28)
		var col: Array = rng.choice(PAPER)
		var ww := rng.uniform(3.0, 6.0)
		litter.append({"x": x, "d": d, "z": z, "vz": vz, "vx": vx, "ph": ph, "spin": spin, "t": 0.0, "seed": sd,
				"col": col, "w": ww})


## Ein Blatt Papier, das sich im Wind dreht (Breite pulsiert mit der Drehung).
func _draw_litter(p: QP, m: Dictionary, cam: float) -> void:
	var d: float = m["d"]
	var k := Persp.ppu(d)
	var x := Persp.screen_x(float(m["x"]), d, cam)
	if x < -10 or x > W + 10:
		return
	var gy := Persp.ground_y(d)
	var y := gy - float(m["z"]) * k
	var ph: float = m["ph"]
	var ww := maxf(1.0, float(m["w"]) * k * absf(cos(ph)))
	var hh := maxf(1.0, float(m["w"]) * k * 0.6 * absf(sin(ph * 0.7)) + 0.6)
	var col := mix(m["col"], city.th["fog"], 0.3 * (1 - d))
	var lit := 0.75 + 0.35 * cos(ph)           # Vorder-/Rückseite fangen das Licht verschieden
	p.set_no_pen()
	if float(m["z"]) > 0.5:
		p.fill_rect(x - ww / 2, gy - 0.5, ww, 1, QP.c(0, 0, 0, 60))
	p.fill_rect(x - ww / 2, y - hh / 2, ww, hh, QP.rgb(mul(col, lit)))


# ------------------------------------------------------------------ Radfahrer (Kulisse)
## je Zone: [mittlerer Abstand s, Gruppengröße min, max]. Nur ab und zu ein Pulk wie im
## Film - nie ein Dauerstrom.
const BIKE_RATE := [[55.0, 3, 4], [45.0, 3, 4], [30.0, 3, 6], [60.0, 3, 4], [0.0, 0, 0]]
const CADENCE := 6.5                    # rad/s Kurbel (~1 Umdrehung pro Sekunde, gemütlich)
const BIKE_BANDS := [[0.10, 0.14], [0.42, 0.46]]
const PONCHO := [[40, 44, 40], [62, 52, 42], [30, 40, 50], [70, 40, 36], [52, 56, 60], [36, 30, 28]]


func _update_bikes(dt: float, cam: float) -> void:
	var br: Array = BIKE_RATE[Py.imod(city.zone, 5)]
	var rate: float = br[0]
	for b: Dictionary in bikes:
		b["x"] = float(b["x"]) + float(b["v"]) * dt
		b["ph"] = float(b["ph"]) + CADENCE * dt * absf(float(b["v"])) / 50.0
	var k := Persp.ppu(0.1)
	var half := W / 2.0 / k + 60
	bikes = bikes.filter(func(b: Dictionary) -> bool: return absf(float(b["x"]) - cam) < half + 160)
	if rate <= 0:
		return
	_bike_next -= dt
	if _bike_next > 0:
		return
	_bike_next = rng.uniform(0.6, 1.4) * rate
	var side: int = rng.choice([-1, 1])
	var v := -side * rng.uniform(40, 58)
	var band: Array = rng.choice(BIKE_BANDS)
	var d0 := rng.uniform(band[0], band[1])
	var x0 := cam + side * half
	for j in rng.randint(br[1], br[2]):
		var x := x0 + side * (j * rng.uniform(14, 26))
		var d := d0 + rng.uniform(-0.02, 0.02)
		var vv := v * rng.uniform(0.92, 1.06)
		var ph := rng.uniform(0, 6.28)
		var poncho: Array = rng.choice(PONCHO)
		var hat := rng.random() < 0.7
		var umb := rng.random() < 0.3
		var glow := rng.random() < 0.4
		var sd := rng.randint(0, 999)
		bikes.append({"x": x, "d": d, "v": vv, "ph": ph, "poncho": poncho, "hat": hat, "umb": umb, "glow": glow,
				"seed": sd})


## Radfahrer im Poncho mit Kegelhut (Chinatown-Sequenz): Lampe am Lenker, manchmal ein
## Schirm. Gezeichnet in Welt-Einheiten, skaliert mit der Tiefe.
func _draw_bike(p: QP, e: QP, b: Dictionary, cam: float, _t: float) -> void:
	var d: float = b["d"]
	var k := Persp.ppu(d)
	var gx := Persp.screen_x(float(b["x"]), d, cam)
	var gy := Persp.ground_y(d)
	if gx < -40 or gx > W + 40:
		return
	var sd := 1 if float(b["v"]) > 0 else -1
	var fog: Array = city.th["fog"]
	var fk := 0.25 * (1 - d)            # hinten mehr im Dunst
	var U := func(u: float, v: float) -> Vector2: return Vector2(gx + u * k * sd, gy - v * k)
	var c_ := func(col: Array) -> Color: return QP.rgb(mix(col, fog, fk))
	var frame_c := [22, 24, 26]
	# Schatten
	p.set_no_pen()
	p.set_brush(QP.c(0, 0, 0, 90))
	p.draw_ellipse(gx - 10 * k, gy - 1.2 * k, 20 * k, 2.4 * k)
	p.set_pen(c_.call(frame_c), maxf(1.0, 0.7 * k))
	p.set_no_brush()
	for wx: float in [-7.0, 7.0]:
		var c: Vector2 = U.call(wx, 4.5)
		p.draw_ellipse_c(c.x, c.y, 4.5 * k, 4.5 * k)
	p.draw_polyline(PackedVector2Array([U.call(-7, 4.5), U.call(0, 5), U.call(-2, 12), U.call(-7, 4.5)]))
	p.draw_polyline(PackedVector2Array([U.call(0, 5), U.call(6, 12), U.call(7, 4.5)]))
	p.draw_line_v(U.call(6, 12), U.call(7, 14.5))
	# Beine (Kurbel)
	var a: float = b["ph"]
	var hip: Vector2 = U.call(-2, 14)
	for s_: float in [0.0, PI]:
		var pd: Vector2 = U.call(3 * cos(a + s_), 5 - 3 * sin(a + s_))   # oben vorwärts
		var kn := Vector2((hip.x + pd.x) / 2 + 3 * k * sd, (hip.y + pd.y) / 2 - 1.5 * k)
		p.set_pen(c_.call([20, 20, 24] if s_ == 0.0 else [14, 14, 16]), maxf(1.0, 1.6 * k))
		p.draw_polyline(PackedVector2Array([hip, kn, pd]))
	# Poncho + Arm
	p.set_no_pen()
	p.set_brush(c_.call(b["poncho"]))
	p.draw_polygon(PackedVector2Array([U.call(-6, 13), U.call(5, 15), U.call(2, 27), U.call(-1, 27.5)]))
	p.set_pen(c_.call(mul(b["poncho"], 0.7)), maxf(1.0, 1.4 * k))
	p.draw_line_v(U.call(1, 25), U.call(6.5, 14.5))
	p.set_no_pen()
	# Kopf + Kegelhut / Kapuze
	p.set_brush(c_.call([120, 96, 80]))
	var hc: Vector2 = U.call(1, 30)
	p.draw_ellipse_c(hc.x, hc.y, 2.4 * k, 2.6 * k)
	if b["hat"]:
		p.set_brush(c_.call([128, 108, 76]))
		p.draw_polygon(PackedVector2Array([U.call(-5, 30.6), U.call(7, 30.6), U.call(1, 35.5)]))
		p.set_brush(c_.call([90, 74, 52]))
		p.draw_polygon(PackedVector2Array([U.call(-5, 30.6), U.call(7, 30.6), U.call(1, 31.6)]))
	else:
		p.set_brush(c_.call(mul(b["poncho"], 0.8)))
		var hk: Vector2 = U.call(0.6, 31)
		p.draw_ellipse_c(hk.x, hk.y, 3.0 * k, 3.0 * k)
	# Schirm (Papierschirm, manchmal mit leuchtendem Schaft)
	if b["umb"]:
		var shaft: Array = DScene.CYAN if b["glow"] else [50, 46, 40]
		var qs: Array = [p, e] if b["glow"] else [p]
		for q: QP in qs:
			q.set_pen(QP.rgb(shaft), maxf(1.0, 0.6 * k))
			q.draw_line_v(U.call(3, 22), U.call(1, 41))
		p.set_no_pen()
		p.set_brush(c_.call([176, 146, 100]))
		p.draw_polygon(PackedVector2Array([U.call(-10, 37), U.call(1, 43), U.call(12, 37), U.call(1, 39)]))
	# Lampe am Lenker + Lichtkegel auf dem Boden
	var hl: Vector2 = U.call(7.4, 13)
	for q: QP in [p, e]:
		q.fill_rect(hl.x - 1, hl.y - 1, 2, 2, QP.rgb([255, 246, 210]))
	p.set_mode(PLUS)
	var cx := gx + 20 * k * sd
	var g := QGrad.radial(cx, gy, 16 * k)
	g.set_color_at(0, QP.c(255, 240, 200, 60))
	g.set_color_at(1, QP.c(0, 0, 0, 0))
	p.save()
	p.translate(cx, gy)
	p.scale(1.0, 0.3)
	p.translate(-cx, -gy)
	p.fill_rect(gx + 4 * k * sd - 16 * k if sd > 0 else gx - 36 * k, gy - 16 * k, 32 * k, 32 * k, g)
	p.restore()
	p.set_mode(OVER)


# ------------------------------------------------------------------ CRT-Einschalten
## k 0..1: Bild öffnet sich vom Leuchtstrich zur vollen Höhe.
func _power_on(p: QP, k: float) -> void:
	if k <= 0:
		p.fill_rect(0, 0, W, H, QP.rgb(DScene.VOID))
		return
	var open_h := H * pow(maxf(0.0, (k - 0.25) / 0.75), 1.5)
	var band := maxf(1.0, open_h)
	var top := (H - band) / 2
	p.fill_rect(0, 0, W, top, QP.rgb(DScene.VOID))
	p.fill_rect(0, top + band, W, H - top - band, QP.rgb(DScene.VOID))
	if k < 0.4:
		var wv := W * minf(1.0, k / 0.25)
		p.fill_rect((W - wv) / 2, H / 2.0 - 1, wv, 2, QP.rgb(DScene.WHITE))
