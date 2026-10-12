class_name FX
extends RefCounted
## Effekte (render/fx.py): Regen + Spritzer, Dampf, Funken, Leuchtspuren, Screenshake, Blitze.
##
## Alles in Bildschirm-Koordinaten der Dither-Auflösung; Partikel mit Welt-Anker
## (Dampf aus Gullys, Treffer) werden pro Frame neu projiziert.
## Zufall: PyRandom in exakt derselben Aufrufreihenfolge wie das Original.
## Partikel-Texturen (_soft) werden über FX.baker gebacken (fehlt er, z. B. in
## Headless-Tests, bleiben die Texturen leer, die Simulation läuft gleich).

const W := Config.RENDER_W
const H := Config.RENDER_H

static var baker: Baker

var rng: PyRandom
var rain: Array = []          # [x, y, layer]
var splashes: Array = []      # [x, y, t, s]
var steam: Array = []         # Dictionary wie im Original
var sparks: Array = []
var tracers: Array = []
var flashes: Array = []
var trauma := 0.0
var lightning := 0.0
var bolt: Variant = null      # Array von [x, y] oder null
var _next_bolt := 8.0
var hurt := 0.0
var intensity := 0.6
var _steam_tex: Array = []
@warning_ignore("unused_private_class_variable")
var _puff_acc := 0.0


## Weicher Kreis als Partikel-Textur.
static func _soft(radius: float, rgb: Array, alpha: int) -> QImg:
	var s := int(radius * 2) + 2
	var bk: Baker = baker if baker != null else Pixfont.baker
	if bk == null:
		return QImg.new(null, Rect2(0, 0, s, s))
	return bk.bake(s, s, func(p: QP) -> void:
		var g := QGrad.radial(s / 2.0, s / 2.0, radius)
		g.set_color_at(0.0, QP.c(rgb[0], rgb[1], rgb[2], alpha))
		g.set_color_at(0.6, QP.c(rgb[0], rgb[1], rgb[2], int(alpha * 0.45)))
		g.set_color_at(1.0, QP.c(rgb[0], rgb[1], rgb[2], 0))
		p.set_no_pen()
		p.set_brush(g)
		p.draw_ellipse(0, 0, s, s))


func _init(seed_: int = 0) -> void:
	rng = PyRandom.new(seed_)
	for r: int in [4, 6, 9, 13]:
		_steam_tex.append(_soft(r, [150, 156, 170], 60))
	set_rain(0.6)


# ------------------------------------------------------------------ Regen
func set_rain(intensity_: float) -> void:
	intensity = intensity_
	var n := int(320 * intensity_) + 40
	rain = []
	for _i in n:
		var layer := rng.random()
		var rx := rng.uniform(0, W + 60)
		var ry := rng.uniform(-H, H)
		rain.append([rx, ry, layer])


func update_rain(dt: float, cam_dx: float) -> void:
	var wind := 0.32
	for r: Array in rain:
		var layer: float = r[2]
		var sp := 260 + 260 * layer
		r[1] = float(r[1]) + sp * dt
		r[0] = float(r[0]) + (-sp * wind * dt - cam_dx * (0.2 + 0.8 * layer))
		if float(r[1]) > H:
			r[1] = rng.uniform(-40, -4)
			r[0] = rng.uniform(0, W + 80)
		if float(r[0]) < -20:
			r[0] = float(r[0]) + (W + 80)
		elif float(r[0]) > W + 60:
			r[0] = float(r[0]) - (W + 80)
	# Spritzer auf dem Boden
	var n := int(intensity * 160 * dt * 4)
	for _i in n:
		var d := pow(rng.random(), 0.7)
		var y := Persp.ground_y(d * 1.08 - 0.05)
		if y < Persp.FACADE_Y:
			continue
		splashes.append([rng.uniform(0, W), y, 0.0, 0.5 + d])
	splashes = splashes.filter(func(s: Array) -> bool: return float(s[2]) < 0.22)
	for s: Array in splashes:
		s[2] = float(s[2]) + dt


func draw_rain(p: QP, tint: Array) -> void:
	var lines_far: Array = []
	var lines_mid: Array = []
	var lines_near: Array = []
	for r: Array in rain:
		var x: float = r[0]
		var y: float = r[1]
		var layer: float = r[2]
		var ln := 4 + 12 * layer
		var dx := ln * 0.32
		var ln_ := [Vector2(x, y), Vector2(x - dx, y + ln)]
		if layer < 0.4:
			lines_far.append(ln_)
		elif layer < 0.8:
			lines_mid.append(ln_)
		else:
			lines_near.append(ln_)
	for e: Array in [[lines_far, 0.5, 90], [lines_mid, 0.75, 120], [lines_near, 1.0, 150]]:
		var f: float = e[1]
		p.set_pen(QP.c(int(tint[0] * f), int(tint[1] * f), int(tint[2] * f), e[2]), 1.0)
		p.draw_lines(e[0])


func draw_splashes(p: QP, tint: Array) -> void:
	p.set_pen(QP.c(tint[0], tint[1], tint[2], 150), 1.0)
	for sp: Array in splashes:
		var x: float = sp[0]
		var y: float = sp[1]
		var k: float = float(sp[2]) / 0.22
		var r := 1 + int(3 * float(sp[3]) * k)
		if k < 0.35:
			p.draw_point(x, y - 1)
		else:
			p.draw_point(x - r, y - 1 - int(2 * (1 - k)))
			p.draw_point(x + r, y - 1 - int(2 * (1 - k)))


# ------------------------------------------------------------------ Dampf
func puff(x: float, y: float, wx: Variant = null, depth: Variant = null, scale: float = 1.0) -> void:
	var life := rng.uniform(2.0, 3.6)
	var vx := rng.uniform(-6, 6)
	var vy := rng.uniform(-14, -8)
	var tex := rng.randrange(2)
	steam.append({"x": x, "y": y, "wx": wx, "d": depth, "t": 0.0, "life": life,
		"vx": vx, "vy": vy, "s": scale, "tex": tex})


func update_steam(dt: float) -> void:
	for s: Dictionary in steam:
		s["t"] = float(s["t"]) + dt
		s["x"] = float(s["x"]) + float(s["vx"]) * dt
		s["y"] = float(s["y"]) + float(s["vy"]) * dt
		s["vx"] = float(s["vx"]) + -10 * dt
	steam = steam.filter(func(s: Dictionary) -> bool: return float(s["t"]) < float(s["life"]))


func draw_steam(p: QP, cam_x: float, cam_fac: Variant = null) -> void:
	for s: Dictionary in steam:
		var k: float = float(s["t"]) / float(s["life"])
		var tex: QImg = _steam_tex[mini(3, int(s["tex"]) + int(k * 2.5))]
		var sc: float = float(s["s"]) * (0.6 + 1.6 * k)
		var bx: float
		var by: float
		if s["wx"] != null:
			bx = Persp.screen_x(float(s["wx"]), float(s["d"]), cam_x) + float(s["x"])
			by = s["y"]
		else:
			var fac: float = float(cam_fac) if cam_fac != null else 0.0
			bx = float(s["x"]) - cam_x * fac + W * 0.5
			by = s["y"]
		var w := tex.width() * sc
		p.set_opacity(maxf(0.0, minf(1.0, (1 - k) * 1.4 * minf(1.0, k * 6))))
		p.draw_image(Rect2(bx - w / 2, by - w / 2, w, w), tex)
	p.set_opacity(1.0)


# ------------------------------------------------------------------ Kampf
func tracer(sx: float, sd: float, ex: float, ed: float, hit: Variant) -> void:
	tracers.append({"sx": sx, "sd": sd, "ex": ex, "ed": ed, "t": 0.0, "hit": hit})
	trauma = minf(1.0, trauma + 0.35)


func impact(wx: float, depth: float, y_off: float, color: Array, n: int = 14, blood: bool = false) -> void:
	for _i in n:
		var a := rng.uniform(-PI, 0.2)
		var v := rng.uniform(20, 90)
		var life := rng.uniform(0.2, 0.55)
		var c: Array = color if (not blood or rng.random() < 0.3) else [138, 32, 56]
		sparks.append({"wx": wx, "d": depth, "ox": 0.0, "oy": y_off, "vx": cos(a) * v, "vy": sin(a) * v,
			"t": 0.0, "life": life, "c": c, "g": 200 if blood else 120})
	flashes.append({"wx": wx, "d": depth, "oy": y_off, "t": 0.0})


func update_combat(dt: float) -> void:
	for t: Dictionary in tracers:
		t["t"] = float(t["t"]) + dt
	tracers = tracers.filter(func(t: Dictionary) -> bool: return float(t["t"]) < 0.16)
	for s: Dictionary in sparks:
		s["t"] = float(s["t"]) + dt
		s["ox"] = float(s["ox"]) + float(s["vx"]) * dt
		s["oy"] = float(s["oy"]) + float(s["vy"]) * dt
		s["vy"] = float(s["vy"]) + float(s["g"]) * dt
	sparks = sparks.filter(func(s: Dictionary) -> bool: return float(s["t"]) < float(s["life"]))
	for f: Dictionary in flashes:
		f["t"] = float(f["t"]) + dt
	flashes = flashes.filter(func(f: Dictionary) -> bool: return float(f["t"]) < 0.12)
	trauma = maxf(0.0, trauma - dt * 1.6)
	hurt = maxf(0.0, hurt - dt * 1.8)


## Bildversatz [dx, dy] (Tupel im Original).
func shake() -> Array:
	var t := trauma * trauma
	if t <= 0.001:
		return [0, 0]
	var sx := Py.round(rng.uniform(-1, 1) * 5 * t)
	var sy := Py.round(rng.uniform(-1, 1) * 4 * t)
	return [sx, sy]


# ------------------------------------------------------------------ Blitz
func update_weather(dt: float, rain_level: float) -> bool:
	lightning = maxf(0.0, lightning - dt * 3.0)
	_next_bolt -= dt
	if _next_bolt <= 0 and rain_level > 0.3:
		_next_bolt = rng.uniform(9.0, 22.0)
		lightning = 1.0
		var x := rng.uniform(40, W - 40)
		var pts: Array = [[x, 0.0]]
		var y := 0.0
		while y < Persp.FACADE_Y * 0.55:
			y += rng.uniform(6, 14)
			x += rng.uniform(-9, 9)
			pts.append([x, y])
		bolt = pts
		return true
	if lightning < 0.5:
		bolt = null
	return false
