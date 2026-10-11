extends Node2D
## Prozedurale Straße (Belt-Scroller) - PoC der Render-Kette.
##
## Alles wird pro Frame mit _draw() gezeichnet (wie QPainter in der
## Python-Version). Der Dither-Shader macht daraus danach 16 Farben.

const W := Config.RENDER_W
const H := Config.RENDER_H

const NEON := [Palette.CYAN, Palette.MAGENTA, Palette.AMBER, Palette.VIOLET,
	Palette.TEAL, Palette.WHITE, Palette.BLUE, Palette.SODIUM]
const SIGNS := [Palette.CYAN, Palette.MAGENTA, Palette.AMBER, Palette.VIOLET]
const BODIES := [Palette.NAVY, Palette.INDIGO, Palette.NIGHT, Palette.STEEL,
	Palette.CRIMSON, Palette.SODIUM, Palette.MAGENTA, Palette.VIOLET]

var t := 0.0
var cam_x := 0.0
var rng := RandomNumberGenerator.new()
var length := 6000.0

var far_windows: Array = []
var buildings: Array = []
var actors: Array = []
var player: Dictionary = {}


func _ready() -> void:
	rng.seed = 11
	_generate()


func _col(i: int) -> Color:
	return Palette.NOIR16[i]


func _neon() -> Color:
	return _col(NEON[rng.randi_range(0, NEON.size() - 1)])


func _generate() -> void:
	# Ferne Stadt: dichte Fensterwand oben (Parallaxe je Fenster)
	for _i in 260:
		far_windows.append({
			"x": rng.randf_range(0.0, 1.0),
			"y": rng.randf_range(0.02, 0.49),
			"w": rng.randf_range(1.5, 4.0),
			"h": rng.randf_range(1.5, 5.0),
			"c": _neon(),
			"p": rng.randf_range(0.03, 0.16),
		})

	# Fassaden: Ladenzeile am Horizont mit Schildern
	var x := 0.0
	while x < length:
		var bw := rng.randf_range(120.0, 260.0)
		var bh := rng.randf_range(22.0, 78.0)
		var b := {"x": x, "w": bw, "h": bh, "win": [], "signs": []}
		var wx := x + 6.0
		while wx < x + bw - 8.0:
			var wy := 4.0
			while wy < bh - 10.0:
				if rng.randf() < 0.5:
					b["win"].append({"dx": wx - x, "y": wy, "c": _neon()})
				wy += rng.randf_range(9.0, 15.0)
			wx += rng.randf_range(9.0, 17.0)
		var nsign := rng.randi_range(0, 2)
		for _s in nsign:
			b["signs"].append({
				"dx": rng.randf_range(6.0, maxf(8.0, bw - 46.0)),
				"y": rng.randf_range(bh * 0.25, maxf(bh * 0.3, bh - 8.0)),
				"w": rng.randf_range(22.0, 48.0),
				"c": _col(SIGNS[rng.randi_range(0, SIGNS.size() - 1)]),
			})
		buildings.append(b)
		x += bw + rng.randf_range(2.0, 14.0)

	# Passanten
	for _i in 44:
		actors.append(_make_actor(rng.randf_range(0.05, length * 0.9)))

	player = {"x": length * 0.3, "depth": 0.62}


func _make_actor(px: float) -> Dictionary:
	return {
		"x": px,
		"depth": rng.randf_range(0.06, 0.96),
		"dir": 1.0 if rng.randf() < 0.5 else -1.0,
		"speed": rng.randf_range(14.0, 30.0),
		"body": _col(BODIES[rng.randi_range(0, BODIES.size() - 1)]),
		"head": _col(Palette.ASH if rng.randf() < 0.6 else Palette.PALE),
		"walk": rng.randf_range(0.0, 10.0),
	}


func _process(delta: float) -> void:
	t += delta
	player["x"] = float(player["x"]) + Config.PLAYER_WALK_SPEED * delta
	if float(player["x"]) > length - 200.0:
		player["x"] = 200.0
	cam_x = float(player["x"]) + 40.0

	for a in actors:
		a["x"] = float(a["x"]) + float(a["dir"]) * float(a["speed"]) * delta
		a["walk"] = float(a["walk"]) + delta * 6.0
		if float(a["x"]) < cam_x - 420.0:
			a["x"] = cam_x + 900.0
			a["depth"] = rng.randf_range(0.06, 0.96)
		elif float(a["x"]) > cam_x + 900.0:
			a["x"] = cam_x - 400.0
			a["depth"] = rng.randf_range(0.06, 0.96)

	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), _col(Palette.VOID))
	_draw_far_city()
	_draw_facade()
	_draw_ground()
	_draw_rain()
	_draw_actors()


func _draw_far_city() -> void:
	for fw in far_windows:
		var sx: float = fposmod(float(fw["x"]) * W - cam_x * float(fw["p"]) * 6.0, float(W))
		var y: float = float(fw["y"]) * H
		var c: Color = fw["c"]
		c.a = 0.75
		draw_rect(Rect2(sx, y, float(fw["w"]), float(fw["h"])), c)


func _draw_facade() -> void:
	var base_y: float = Persp.ground_y(Config.FACADE_DEPTH)
	var ppu: float = Persp.ppu(Config.FACADE_DEPTH)
	var c_night := _col(Palette.NIGHT)
	var c_ind := _col(Palette.INDIGO)
	var c_void := _col(Palette.VOID)
	for b in buildings:
		var sx: float = Persp.screen_x(float(b["x"]), Config.FACADE_DEPTH, cam_x)
		var sw: float = float(b["w"]) * ppu
		if sx > W or sx + sw < 0.0:
			continue
		var top: float = base_y - float(b["h"])
		draw_rect(Rect2(sx, top, sw, float(b["h"])), c_night)
		draw_rect(Rect2(sx, top, sw, 1.5), c_ind)
		for wnode in b["win"]:
			var wx: float = sx + float(wnode["dx"]) * ppu
			if wx < -4.0 or wx > W + 4.0:
				continue
			draw_rect(Rect2(wx, top + float(wnode["y"]), 2.0, 2.6), wnode["c"])
		for sg in b["signs"]:
			var gx: float = sx + float(sg["dx"]) * ppu
			if gx < -60.0 or gx > W + 60.0:
				continue
			var gw: float = float(sg["w"]) * ppu
			var gy: float = top + float(sg["y"])
			draw_rect(Rect2(gx - 1.5, gy - 1.5, gw + 3.0, 8.0), c_void)
			draw_rect(Rect2(gx, gy, gw, 5.0), sg["c"])


func _draw_ground() -> void:
	var y0: float = Persp.ground_y(0.0)
	draw_rect(Rect2(0, y0, W, H - y0), _col(Palette.NAVY))
	draw_rect(Rect2(0, y0 - 10.0, W, 10.0), _col(Palette.INDIGO))

	# Fahrspuren (horizontal, Belt-Scroller)
	for lane in Config.LANES:
		var ld: float = lane.x
		var ty: float = Persp.ground_y(ld - Config.LANE_HALF)
		var by: float = Persp.ground_y(ld + Config.LANE_HALF)
		var c := _col(Palette.INDIGO)
		c.a = 0.55
		draw_rect(Rect2(0, ty, W, by - ty), c)

	# Mittelstreifen: gestrichelt, scrollt mit
	var md := 0.53
	var my: float = Persp.ground_y(md)
	var ppu: float = Persp.ppu(md)
	var dash := 30.0
	var span: float = float(W) / ppu
	var first: float = floor((cam_x - span * 0.5) / dash) * dash
	var px: float = first
	while px < cam_x + span * 0.5:
		var sx: float = Persp.screen_x(px, md, cam_x)
		draw_rect(Rect2(sx, my - 0.8, dash * ppu * 0.5, 1.6), _col(Palette.ASH))
		px += dash

	# Nasse Reflexionen: senkrechte Neon-Schlieren
	for i in 7:
		var rx: float = fposmod(i * 97.0 - cam_x * 0.12, float(W))
		var c2 := _col(NEON[(i * 3) % NEON.size()])
		c2.a = 0.12
		draw_rect(Rect2(rx, y0, 6.0, H - y0), c2)


func _draw_rain() -> void:
	var c := _col(Palette.STEEL)
	c.a = 0.5
	var scroll: float = fposmod(cam_x * 0.4, 200.0)
	for i in 90:
		var x: float = fposmod(i * 71.0 - scroll, float(W))
		var y: float = fposmod(i * 137.0 + t * 260.0, float(H))
		draw_line(Vector2(x, y), Vector2(x - 2.5, y + 9.0), c, 1.0)


func _draw_actors() -> void:
	var list := actors.duplicate()
	list.append({"x": player["x"], "depth": player["depth"], "dir": 1.0, "speed": 0.0,
		"body": _col(Palette.CYAN), "head": _col(Palette.PALE), "walk": t * 8.0, "player": true})
	list.sort_custom(func(a, b): return float(a["depth"]) < float(b["depth"]))
	for a in list:
		_draw_figure(a)


func _draw_figure(a: Dictionary) -> void:
	var sx: float = Persp.screen_x(float(a["x"]), float(a["depth"]), cam_x)
	if sx < -40.0 or sx > W + 40.0:
		return
	var gy: float = Persp.ground_y(float(a["depth"]))
	var h: float = Persp.figure_h(float(a["depth"]))
	var w := h * 0.34
	var is_player: bool = a.get("player", false)
	var walk: float = float(a["walk"])
	var leg: float = abs(sin(walk)) * h * 0.08

	# Schatten
	var sh := _col(Palette.VOID)
	sh.a = 0.5
	draw_rect(Rect2(sx - w * 0.6, gy - 1.5, w * 1.2, 2.5), sh)

	var body: Color = a["body"]
	draw_rect(Rect2(sx - w * 0.34, gy - h * 0.42, w * 0.28, h * 0.42), body.darkened(0.25))
	draw_rect(Rect2(sx + w * 0.06, gy - h * 0.42 - leg, w * 0.28, h * 0.42 + leg), body.darkened(0.25))
	draw_rect(Rect2(sx - w * 0.5, gy - h * 0.82, w, h * 0.42), body)
	draw_circle(Vector2(sx, gy - h * 0.9), h * 0.12, a["head"])

	var rim := _col(Palette.CYAN if is_player else Palette.BLUE)
	rim.a = 0.9
	draw_rect(Rect2(sx + w * 0.45, gy - h * 0.82, 1.0, h * 0.42), rim)
	if is_player:
		draw_rect(Rect2(sx - w * 0.5, gy - h * 0.9, w, 1.5), _col(Palette.WHITE))
