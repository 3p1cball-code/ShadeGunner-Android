extends Node
## Smoke-/Pixeltest City Teil 1+2/3: baut City für Zone 0..4 und speichert ALLE Ebenen
## plus zusammengesetzte Straßenbilder bei mehreren Kamerapositionen.
## godot --path . --rendering-driver opengl3 res://tests/city_test.tscn -- --out=<dir>
## Gegenstück: tools/city_reference.py (gleiche Dateinamen, gleiche Daten-JSON).

const LENGTH := 3000.0
const SEED := 12345
const CAMS := [0.0, 800.0, 1600.0, 2400.0, 2900.0]

var out := "res://shots/city_godot"
var baker: Baker
var shots: Array = []     # [name, QImg]
var data := {}
var frames := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	baker = Baker.new()
	add_child(baker)
	City.baker = baker
	Pixfont.baker = baker
	var t0 := Time.get_ticks_msec()
	for z in 5:
		var c := City.new(z, LENGTH, SEED)
		shots.append(["z%d_sky" % z, c.sky])
		for i in c.cloud_layers.size():
			shots.append(["z%d_clouds%d" % [z, i], (c.cloud_layers[i] as Array)[0]])
		shots.append(["z%d_far" % z, c.far.img])
		shots.append(["z%d_mid" % z, c.mid.img])
		shots.append(["z%d_facade" % z, c.facade.img])
		shots.append(["z%d_emit" % z, c.facade_emit])
		shots.append(["z%d_ground" % z, c.ground])
		for i in c.fog_layers.size():
			shots.append(["z%d_fog%d" % [z, i], c.fog_layers[i]])
		shots.append(["z%d_bank" % z, c.bank])
		shots.append(["z%d_cloud" % z, c.cloud])
		for ci in CAMS.size():
			var cam: float = CAMS[ci]
			var img := City._bake(City.W, City.H, func(p: QP) -> void:
				p.draw_image_at(0, 0, c.sky)
				c.far.draw(p, cam)
				c.mid.draw(p, cam)
				c.facade.draw(p, cam)
				c.draw_ground(p, cam))
			shots.append(["z%d_street%d" % [z, ci], img])
		var kinds: Array = []
		for h: Dictionary in c.holos:
			kinds.append(String(h["kind"]))
		kinds.sort()
		data["z%d" % z] = {
			"counts": {"blinks": c.blinks.size(), "flames": c.flames.size(), "billboards": c.billboards.size(),
				"searchlights": c.searchlights.size(), "air": c.air.size(), "signs": c.signs.size(),
				"lamps": c.lamps.size(), "lanterns": c.lanterns.size(), "tvs": c.tvs.size(), "vents": c.vents.size(),
				"holos": c.holos.size(), "ramen_spots": c.ramen_spots.size(), "manholes": c.manholes.size(),
				"puddles": c.puddles.size()},
			"far": [c.far.lmin, c.far.width], "mid": [c.mid.lmin, c.mid.width],
			"gate": c.gate, "exit_L": c.exit_L, "g_wmin": c.g_wmin, "ground_y0": c.ground_y0,
			"holo_kinds": kinds, "rng": c.rng.random()}
	print("City x5: %d ms" % (Time.get_ticks_msec() - t0))
	var r := PyRandom.new(5)
	var s1 := City._make_sign(r, City.CYAN, "vertical")
	var s2 := City._make_sign(r, City.MAGENTA, "text", "SNAKE PIT")
	var s3 := City._make_sign(r, City.AMBER, "arrow")
	var s4 := City._dragon_sign(r)
	var names := ["on", "off", "emit"]
	for k in 3:
		shots.append(["sign_v_" + names[k], s1[k]])
		shots.append(["sign_t_" + names[k], s2[k]])
		shots.append(["sign_a_" + names[k], s3[k]])
		shots.append(["dragon_" + names[k], s4[k]])
	shots.append(["refl_mid", City.soft_reflection((shots[3] as Array)[1])])
	var sg := City.Sign.new(0, 0, s1[0], s1[1], s1[2], "buzz", 77, City.CYAN)
	var lp := City.Lamp.new(0, 0, 0, 0, City.AMBER, 33, true)
	var lits: Array = []
	for i in 200:
		var t := i * 0.137
		lits.append([sg.lit(t), lp.level(t)])
	data["lits"] = lits


func _process(_d: float) -> void:
	frames += 1
	if Engine.get_frames_drawn() < 3:
		RenderingServer.force_draw()
	if frames < 4:
		return
	for s: Array in shots:
		var q: QImg = s[1]
		var img := q.tex.get_image().get_region(Rect2i(q.region))
		img.convert(Image.FORMAT_RGBA8)
		var k := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		var a := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				k.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))     # premultipliziert = über Schwarz
				a.set_pixel(x, y, Color(c.a, c.a, c.a, 1.0))
		k.save_png(out.path_join(String(s[0]) + ".png"))
		a.save_png(out.path_join(String(s[0]) + "_a.png"))
	var f := FileAccess.open(out.path_join("data.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	print("fertig: ", shots.size(), " Bilder")
	get_tree().quit()
