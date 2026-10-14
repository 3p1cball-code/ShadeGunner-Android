extends SceneTree
## Variable Bildbreite (View): Breitenwahl, Persp bei 640 unverändert, HUD-Trefferflächen
## (settings_row_at / option_at) gegen die Zeichengeometrie.
##   godot --headless --path . --script res://tests/test_view.gd

var bad := 0


func _chk(name: String, ok: bool, info: Variant = "") -> void:
	if not ok:
		bad += 1
		print("  FEHLER ", name, "  ", info)


func _init() -> void:
	# --- Breitenwahl
	var cases := [[Vector2(1280, 720), 640], [Vector2(1920, 1080), 640], [Vector2(1280, 592), 778],
		[Vector2(1280, 548), 840], [Vector2(1280, 520), 886], [Vector2(2520, 1080), 840],
		[Vector2(960, 720), 480], [Vector2(800, 600), 480], [Vector2(1280, 800), 576],
		[Vector2(1000, 1000), 400], [Vector2(1240, 1080), 414], [Vector2(3840, 1080), 960], [Vector2(2400, 1080), 800]]
	for c: Array in cases:
		var win: Vector2 = c[0]
		View.setup("auto", win)
		_chk("auto %s" % c[0], View.W == int(c[1]), View.W)
		_chk("gerade %s" % c[0], View.W % 2 == 0, View.W)
		_chk("hud %s" % c[0], View.hud_w() == View.W * 2 and HUD.HW == View.W * 2, HUD.HW)
		# Szene passt vollständig ins Fenster; Rest (Balken) <= 1 Zelle nur außerhalb 4:3..24:9
		var cell := minf(win.x / View.W, win.y / View.H)
		var rest := win.x - View.W * cell + win.y - View.H * cell
		var inside := win.x / win.y >= 4.0 / 3.0 - 1e-6 and win.x / win.y <= 24.0 / 9.0 + 1e-6
		if inside:
			_chk("kein Balken %s" % c[0], rest <= cell + 0.5, rest)
	for a: String in ["letterbox", "16:9"]:
		View.setup(a, Vector2(1280, 520))
		_chk("16:9 erzwingt 640 (%s)" % a, View.W == 640, View.W)

	# --- Persp: Maßstab fest, Bildmitte folgt der Breite
	View.W = 640
	_chk("ppu 640", Persp.ppu(1.0) == 640.0 / Config.VIEW_SPAN_NEAR)
	_chk("screen_x 640", Persp.screen_x(100.0, 0.5, 40.0) == 320.0 + 60.0 * Persp.ppu(0.5))
	View.W = 886
	_chk("ppu fest", Persp.ppu(1.0) == 640.0 / Config.VIEW_SPAN_NEAR)
	_chk("Mitte 886", Persp.screen_x(40.0, 0.5, 40.0) == 443.0)
	_chk("world_x invers", absf(Persp.world_x(Persp.screen_x(123.0, 0.3, 7.0), 0.3, 7.0) - 123.0) < 1e-9)

	# --- HUD-Trefferflächen bei mehreren Breiten
	var hud := HUD.new()
	for w: int in [400, 414, 480, 640, 886, 960]:
		View.W = w
		var n := HUD.SETTING_ROWS.size()
		for sel in n:
			var g := HUD._settings_geom(sel)
			_chk("sel sichtbar w%d s%d" % [w, sel], sel >= int(g["first"]) and sel < int(g["last"]))
			for i in range(int(g["first"]), int(g["last"])):
				var y0 := HUD.SET_Y + (i - int(g["first"])) * (HUD.SET_ROWH + HUD.SET_GAP)
				var x0: int = Py.ifloordiv(HUD.HW - HUD.SET_W, 2)
				_chk("zeile w%d s%d i%d" % [w, sel, i], hud.settings_row_at(Vector2(x0 + 5, y0 + 21), sel) == i)
				_chk("kante w%d s%d i%d" % [w, sel, i], hud.settings_row_at(Vector2(x0 + HUD.SET_W - 1, y0 + HUD.SET_ROWH - 1), sel) == i)
				_chk("lücke w%d s%d i%d" % [w, sel, i], hud.settings_row_at(Vector2(x0 + 5, y0 + HUD.SET_ROWH + 4), sel) == -1)
				_chk("links w%d s%d i%d" % [w, sel, i], hud.settings_row_at(Vector2(x0 - 1, y0 + 21), sel) == -1)
		var cg := HUD._clear_geom()
		_chk("karten im bild w%d" % w, int(cg["x0"]) >= 16 and int(cg["x0"]) + 3 * int(cg["cw"]) + 2 * int(cg["gap"]) <= HUD.HW - 16, cg)
		for sel in 3:
			for i in 3:
				var x := int(cg["x0"]) + i * (int(cg["cw"]) + int(cg["gap"]))
				var top := HUD.CLEAR_Y + (-8 if i == sel else 0)
				_chk("karte w%d s%d i%d" % [w, sel, i], hud.option_at(Vector2(x + 10, top + 1), 3, sel) == i)
				_chk("karte unten w%d s%d i%d" % [w, sel, i], hud.option_at(Vector2(x + 10, top + HUD.CLEAR_H - 1), 3, sel) == i)
				_chk("karte drunter w%d s%d i%d" % [w, sel, i], hud.option_at(Vector2(x + 10, top + HUD.CLEAR_H), 3, sel) == -1)
				_chk("karte lose w%d i%d" % [w, i], hud.option_at(Vector2(x + 10, HUD.CLEAR_Y + 50), 3) == i)
			_chk("zwischen w%d" % w, hud.option_at(Vector2(int(cg["x0"]) + int(cg["cw"]) + 1, HUD.CLEAR_Y + 50), 3, sel) == -1)
		_chk("n=2 w%d" % w, hud.option_at(Vector2(int(cg["x0"]) + 2 * (int(cg["cw"]) + int(cg["gap"])) + 5, HUD.CLEAR_Y + 50), 2) == -1)
	View.W = 640
	print("View-Tests: Fehler ", bad)
	quit(bad)
