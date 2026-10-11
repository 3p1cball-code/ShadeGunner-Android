extends Node2D
## Prozedurale Straße (Belt-Scroller) - Nachbau von shadegunner/render/.
##
## Schichten von hinten nach vorn: Himmel, ferne Stadt (Fenster + Türme),
## Ladenzeile am Horizont mit Neonschildern, Straße mit nassen Reflexionen,
## Figuren (Sprites), Vordergrund-Masten, Regen.

const W := Config.RENDER_W
const H := Config.RENDER_H

const NEON := [Palette.CYAN, Palette.MAGENTA, Palette.AMBER, Palette.VIOLET,
	Palette.TEAL, Palette.PALE, Palette.BLUE, Palette.SODIUM]

# Grundtöne (aus dem Original gemessen: Szene liegt bei ca. 50-80 pro Kanal)
const SKY_BASE := Color8(52, 54, 74)
const TOWER := Color8(28, 32, 50)
const ROAD_BASE := Color8(44, 50, 74)
const ROAD_LANE := Color8(56, 64, 92)

# Parallax-Maßstäbe (Bildschirmpixel pro Welt-Einheit) je Schicht
const PPU_FAR := 0.20
const PPU_MID := 0.44
const PPU_SHOP := 0.90

var t := 0.0
var cam_x := 0.0
var rng := RandomNumberGenerator.new()
var length := 6000.0
var sprites := Sprites.new()

var towers: Array = []
var windows: Array = []
var shops: Array = []
var actors: Array = []
var poles: Array = []
var vehicles: Array = []
var player: Dictionary = {}


func _col(i: int) -> Color:
	return Palette.NOIR16[i]


func _layer_x(x: float, ppu: float) -> float:
	return W * 0.5 + (x - cam_x) * ppu


func _ready() -> void:
	rng.seed = 11
	_generate()


func _generate() -> void:
	# Ferne Türme: Silhouetten mit Fensterrastern
	var x := -600.0
	while x < length:
		var bw := rng.randf_range(120.0, 300.0)
		var bh := rng.randf_range(60.0, 155.0)
		var wins: Array = []
		var wy := 6.0
		while wy < bh - 8.0:
			var wxx := 5.0
			while wxx < bw - 8.0:
				if rng.randf() < 0.55:
					wins.append({"dx": wxx, "y": wy, "c": _col(NEON[rng.randi_range(0, NEON.size() - 1)])})
				wxx += rng.randf_range(7.0, 13.0)
			wy += rng.randf_range(7.0, 12.0)
		towers.append({"x": x, "w": bw, "h": bh, "win": wins})
		x += bw + rng.randf_range(4.0, 22.0)

	# lose Fensterpunkte weit hinten (dichte Wand)
	for _i in 520:
		windows.append({
			"x": rng.randf_range(0.0, 1.0), "y": rng.randf_range(0.0, 0.47),
			"w": rng.randf_range(1.8, 4.5), "h": rng.randf_range(1.8, 5.0),
			"c": _col(NEON[rng.randi_range(0, NEON.size() - 1)]),
			"p": rng.randf_range(0.03, 0.12),
		})

	# Läden am Horizont: Schaufenster + Neonschild
	x = -300.0
	while x < length:
		var sw := rng.randf_range(60.0, 130.0)
		var cols := maxi(3, int(sw / 13.0))
		var cells := []
		for _c in cols:
			cells.append(0.0 if rng.randf() < 0.16 else rng.randf_range(0.55, 1.0))
		shops.append({
			"x": x, "w": sw,
			"lit": Color8(246, 249, 253) if rng.randf() < 0.5 else Color8(255, 158, 70),
			"sign": _col([Palette.CYAN, Palette.MAGENTA, Palette.AMBER, Palette.VIOLET][rng.randi_range(0, 3)]),
			"sign_w": rng.randf_range(20.0, 44.0), "sign_off": rng.randf_range(4.0, maxf(6.0, sw - 30.0)),
			"h": rng.randf_range(15.0, 21.0), "cells": cells,
			"blink": rng.randf() < 0.25, "seed": rng.randi_range(0, 999),
		})
		x += sw + rng.randf_range(6.0, 26.0)

	player = {"x": length * 0.3, "depth": 0.62}

	# Fahrzeuge auf den Spuren
	for i in 12:
		var lane: Vector2 = Config.LANES[i % Config.LANES.size()]
		vehicles.append(_make_vehicle(float(player["x"]) + rng.randf_range(-700.0, 900.0), lane))

	# Passanten: rund um die Kamera (recyceln, wenn sie aus dem Bild laufen)
	for i in 60:
		actors.append(_make_actor(float(player["x"]) + rng.randf_range(-460.0, 900.0), i))

	# Vordergrund-Masten
	x = -100.0
	while x < length:
		poles.append({"x": x, "w": rng.randf_range(7.0, 14.0)})
		x += rng.randf_range(340.0, 640.0)


func _make_vehicle(px: float, lane: Vector2) -> Dictionary:
	var col := _col([Palette.NAVY, Palette.INDIGO, Palette.STEEL, Palette.SODIUM][rng.randi_range(0, 3)])
	return {
		"x": px, "depth": lane.x, "dir": lane.y,
		"speed": rng.randf_range(26.0, 54.0),
		"body": col, "len": rng.randf_range(26.0, 52.0), "big": rng.randf() < 0.3,
	}


func _make_actor(px: float, i: int) -> Dictionary:
	var anim := "walk"
	var r := rng.randf()
	if r < 0.18:
		anim = "idle"
	elif r < 0.32:
		anim = "talk"
	var d := rng.randf_range(0.03, 1.0)
	if rng.randf() < 0.12:
		d = rng.randf_range(0.98, 1.12)   # ganz nah an der Kamera
	return {
		"x": px, "depth": d,
		"dir": 1.0 if rng.randf() < 0.5 else -1.0,
		"speed": rng.randf_range(12.0, 28.0),
		"look": Sprites.random_look(rng, i), "anim": anim,
		"phase": rng.randf(),
	}


func _process(delta: float) -> void:
	t += delta
	player["x"] = float(player["x"]) + Config.PLAYER_WALK_SPEED * delta
	if float(player["x"]) > length - 200.0:
		player["x"] = 200.0
	cam_x = float(player["x"]) + 40.0

	for a in actors:
		a["x"] = float(a["x"]) + float(a["dir"]) * float(a["speed"]) * delta
		a["phase"] = fmod(float(a["phase"]) + delta * (0.9 if a["anim"] == "walk" else 0.25), 1.0)
		if float(a["x"]) < cam_x - 420.0:
			a["x"] = cam_x + 900.0
			a["depth"] = rng.randf_range(0.03, 1.0)
		elif float(a["x"]) > cam_x + 900.0:
			a["x"] = cam_x - 400.0
			a["depth"] = rng.randf_range(0.03, 1.0)

	for v in vehicles:
		v["x"] = float(v["x"]) + float(v["dir"]) * float(v["speed"]) * delta
		if float(v["x"]) < cam_x - 700.0:
			v["x"] = cam_x + 900.0
		elif float(v["x"]) > cam_x + 900.0:
			v["x"] = cam_x - 700.0

	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), SKY_BASE)
	_draw_far_city()
	_draw_shops()
	_draw_ground()
	_draw_vehicles()
	_draw_actors()
	_draw_poles()
	_draw_rain()


func _draw_far_city() -> void:
	var base_y: float = Persp.ground_y(Config.FACADE_DEPTH)
	var c_night := TOWER
	for b in towers:
		var sx: float = _layer_x(float(b["x"]), PPU_FAR)
		var sw: float = float(b["w"]) * PPU_FAR
		if sx > W or sx + sw < 0.0:
			continue
		var top := base_y - float(b["h"]) * PPU_FAR * 2.4
		draw_rect(Rect2(sx, top, sw, base_y - top), c_night)
		for wn in b["win"]:
			var wx: float = sx + float(wn["dx"]) * PPU_FAR
			if wx < 0.0 or wx > W:
				continue
			draw_rect(Rect2(wx, top + float(wn["y"]) * PPU_FAR * 2.0, 1.6, 2.2), wn["c"])
	for fw in windows:
		var fx: float = fposmod(float(fw["x"]) * W - cam_x * float(fw["p"]), float(W))
		draw_rect(Rect2(fx, float(fw["y"]) * H, float(fw["w"]), float(fw["h"])), fw["c"])
	var haze := _col(Palette.INDIGO)
	haze.a = 0.12
	draw_rect(Rect2(0, base_y - 150.0, W, 150.0), haze)
	# Himmelsverlauf: nach oben dunkler
	for i in 10:
		var gf := float(i) / 9.0
		var top := base_y * (1.0 - gf)
		var cb := _col(Palette.NIGHT)
		cb.a = 0.16 * (1.0 - gf) * (1.0 - gf)
		draw_rect(Rect2(0, top - base_y * 0.1, W, base_y * 0.1 + 1.0), cb)


func _draw_shops() -> void:
	var base_y: float = Persp.ground_y(0.0)
	var c_frame := _col(Palette.VOID)
	for s in shops:
		var sx: float = _layer_x(float(s["x"]), PPU_SHOP)
		var sw: float = float(s["w"]) * PPU_SHOP
		if sx > W or sx + sw < 0.0:
			continue
		var bh: float = float(s["h"])
		# Schaufenster mit dunklem Rahmen, zerlegt in ein Fenstergitter
		draw_rect(Rect2(sx, base_y - bh, sw, bh), c_frame)
		var cells: Array = s["cells"]
		var cwid := sw / float(cells.size())
		for j in cells.size():
			var br: float = cells[j]
			if br <= 0.0:
				continue
			var cx := sx + j * cwid + 1.5
			draw_rect(Rect2(cx, base_y - bh + 2.0, cwid - 3.0, bh - 4.0), (s["lit"] as Color) * br)
		# Neonschild darüber
		var lit: bool = (not s["blink"]) or (int(t * 6.0 + float(s["seed"])) % 7 != 0)
		if lit:
			var gx: float = sx + float(s["sign_off"]) * PPU_SHOP
			var gw: float = float(s["sign_w"]) * PPU_SHOP
			draw_rect(Rect2(gx - 2.0, base_y - bh - 11.0, gw + 4.0, 9.0), c_frame)
			draw_rect(Rect2(gx, base_y - bh - 9.0, gw, 5.0), s["sign"])
	var glow := _col(Palette.AMBER)
	glow.a = 0.30
	draw_rect(Rect2(0, base_y - 1.5, W, 3.0), glow)


func _draw_ground() -> void:
	var y0: float = Persp.ground_y(0.0)
	draw_rect(Rect2(0, y0, W, H - y0), ROAD_BASE)
	for lane in Config.LANES:
		var ld: float = lane.x
		var ty: float = Persp.ground_y(ld - Config.LANE_HALF)
		var by: float = Persp.ground_y(ld + Config.LANE_HALF)
		draw_rect(Rect2(0, ty, W, by - ty), ROAD_LANE)
	var md := 0.53
	var my: float = Persp.ground_y(md)
	var ppu: float = Persp.ppu(md)
	var dash := 30.0
	var span: float = float(W) / ppu
	var first: float = floor((cam_x - span * 0.5) / dash) * dash
	var px: float = first
	while px < cam_x + span * 0.5:
		draw_rect(Rect2(Persp.screen_x(px, md, cam_x), my - 0.8, dash * ppu * 0.5, 1.6), _col(Palette.ASH))
		px += dash
	# Pfuetzen: kurze, helle Neon-Flecken auf nasser Fahrbahn
	for i in 9:
		var px2: float = fposmod(i * 131.0 - cam_x * 0.85, float(W))
		var pd: float = 0.30 + (i % 5) * 0.14
		var py2: float = Persp.ground_y(pd)
		var c3 := _col(NEON[(i * 3) % NEON.size()])
		c3.a = 0.35
		draw_rect(Rect2(px2, py2, 14.0 + (i % 4) * 6.0, 2.0), c3)

	# nasse Reflexionen: senkrechte Neon-Schlieren, nach unten dünner
	for i in 14:
		var rx: float = fposmod(i * 97.0 - cam_x * 0.9, float(W))
		var c2 := _col(NEON[(i * 5) % NEON.size()])
		c2.a = 0.07 + (i % 3) * 0.035
		draw_rect(Rect2(rx, y0, 8.0 + (i % 4) * 3.0, H - y0), c2)


func _draw_vehicles() -> void:
	for v in vehicles:
		var sx: float = Persp.screen_x(float(v["x"]), float(v["depth"]), cam_x)
		var ppu: float = Persp.ppu(float(v["depth"]))
		var ln: float = float(v["len"]) * ppu
		if sx < -ln or sx > W + ln:
			continue
		var gy: float = Persp.ground_y(float(v["depth"]))
		var hgt: float = (5.2 if v["big"] else 3.6) * ppu
		var w2: float = ln * 0.5
		var body: Color = v["body"]
		var xd: float = 1.0 if float(v["dir"]) > 0.0 else -1.0
		# Schatten
		var sh := _col(Palette.VOID)
		sh.a = 0.45
		draw_rect(Rect2(sx - w2, gy - 1.0, 2.0 * w2, 2.0), sh)
		# Kabine (Windschutzscheibe in Fahrtrichtung) + Karosserie
		draw_rect(Rect2(sx - w2 * 0.5, gy - hgt * 2.0, w2, hgt * 0.9), body.darkened(0.25))
		draw_rect(Rect2(sx - w2 * 0.35, gy - hgt * 1.9, w2 * 0.7, hgt * 0.6), _col(Palette.INDIGO))
		draw_rect(Rect2(sx - w2, gy - hgt * 1.35, 2.0 * w2, hgt * 1.35), body)
		# Raeder
		draw_rect(Rect2(sx - w2 * 0.75, gy - hgt * 0.35, w2 * 0.35, hgt * 0.35), _col(Palette.VOID))
		draw_rect(Rect2(sx + w2 * 0.4, gy - hgt * 0.35, w2 * 0.35, hgt * 0.35), _col(Palette.VOID))
		# Leuchten hinten, Suchlicht vorn
		draw_rect(Rect2(sx - xd * w2 - 1.0, gy - hgt * 0.9, 2.0, 2.0), _col(Palette.MAGENTA))
		draw_rect(Rect2(sx + xd * w2 - 1.0, gy - hgt * 0.9, 2.0, 2.0), _col(Palette.AMBER))


func _draw_actors() -> void:
	var list := actors.duplicate()
	list.append({"x": player["x"], "depth": player["depth"], "dir": 1.0, "speed": 0.0,
		"look": Sprites.player_look(), "anim": "walk", "phase": fmod(t * 0.9, 1.0)})
	list.sort_custom(func(a, b): return float(a["depth"]) < float(b["depth"]))
	for a in list:
		_draw_figure(a)


func _draw_figure(a: Dictionary) -> void:
	var depth: float = a["depth"]
	var sx: float = Persp.screen_x(float(a["x"]), depth, cam_x)
	if sx < -60.0 or sx > W + 60.0:
		return
	var gy: float = Persp.ground_y(depth)
	var look: Dictionary = a["look"]
	var hpx: float = Persp.figure_h(depth) * float(look["hf"])
	var sh := _col(Palette.VOID)
	sh.a = 0.5
	var sw := hpx * 0.28
	draw_rect(Rect2(sx - sw, gy - 1.2, sw * 2.0, 2.2), sh)
	var fog := clampf((0.55 - depth) * 1.1, 0.0, 0.5)
	sprites.draw_figure(self, Vector2(sx, gy), look, a["anim"], float(a["phase"]),
		hpx, int(a["dir"]), _col(Palette.NAVY), fog)


func _draw_poles() -> void:
	var c := Color(5.0 / 255.0, 6.0 / 255.0, 10.0 / 255.0)
	for p in poles:
		var sx: float = _layer_x(float(p["x"]), 1.30)
		if sx < -20.0 or sx > W + 20.0:
			continue
		draw_rect(Rect2(sx, 0, float(p["w"]), H), c)


func _draw_rain() -> void:
	var c := _col(Palette.STEEL)
	c.a = 0.4
	var scroll: float = fposmod(cam_x * 0.4, 200.0)
	for i in 70:
		var x: float = fposmod(i * 71.0 - scroll, float(W))
		var y: float = fposmod(i * 137.0 + t * 260.0, float(H))
		draw_line(Vector2(x, y), Vector2(x - 2.5, y + 9.0), c, 1.0)
