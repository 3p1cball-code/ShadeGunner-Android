extends Node
## Gegenstück zu tools/vehicles_reference.py.
## godot --path . --rendering-driver opengl3 res://tests/vehicles_test.tscn -- --dir=<outdir>

var dir := ""
var frame := 0
var results: Array = []
var _last_drawn := -1
var data: Dictionary
var hl_vp: Array = []     # [Index, SubViewport] für headlight-Fälle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
	var baker := Baker.new()
	add_child(baker)
	Vehicles.baker = baker
	Pixfont.baker = baker
	data = JSON.parse_string(FileAccess.get_file_as_string(dir + "/cases.json"))
	var cases: Array = data["cases"]
	_bake(0, cases.size() / 2)


func _bake(i0: int, i1: int) -> void:
	for i in range(i0, i1):
		var c: Dictionary = data["cases"][i]
		var t: String = c["t"]
		var r: Array = []
		if t == "v":
			r = Vehicles.vehicle_image(c["kind"], int(c["seed"]), float(c["ppu"]), c["rim"], int(c["d"]))
			r = [r[0], r[1], r[2], r[3], r[4]]
		elif t == "s":
			var s := Vehicles.spinner_image(float(c["ppx"]), bool(c["police"]), int(c["d"]), bool(c["far"]))
			r = [s[0], s[1], s[2], s[4], s[3]]
		elif t == "o":
			var o := Vehicles.obstacle_image(c["kind"], int(c["seed"]), float(c["ppu"]), c["rim"])
			r = [o[0], o[1], o[2], o[3], 0]
		else:
			var vp := SubViewport.new()
			vp.size = Vector2i(160, 60)
			vp.transparent_bg = true
			vp.disable_3d = true
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			var host := Node2D.new()
			vp.add_child(host)
			add_child(vp)
			var p := QPExact.new(host.get_canvas_item())
			p.begin()
			var x := 20.0 if int(c["d"]) > 0 else 140.0
			Vehicles.headlight(p, x + 0.3, 30.4, int(c["d"]), float(c["ppu"]), 44.6, float(c["length"]),
				[255, 240, 210], float(c["a"]))
			p.end()
			hl_vp.append([i, vp])
			r = [null, null, 0, 0, 0]
		results.append(r)


func _cut(img: QImg, imgs: Dictionary) -> Image:
	if not imgs.has(img.tex):
		imgs[img.tex] = img.tex.get_image()
	var im: Image = (imgs[img.tex] as Image).get_region(Rect2i(img.region))
	if img.mirrored:
		im.flip_x()
	return im


func _process(_d: float) -> void:
	if Engine.get_frames_drawn() == _last_drawn:
		RenderingServer.force_draw(false)
	_last_drawn = Engine.get_frames_drawn()
	frame += 1
	if frame == 3:
		_bake(results.size(), (data["cases"] as Array).size())
	if frame < 8:
		return
	var imgs := {}
	var meta: Array = []
	for i in results.size():
		var r: Array = results[i]
		var m := {"ax": r[2], "ay": r[3], "extra": r[4], "emit": r[1] != null}
		if r[0] != null:
			var im := _cut(r[0], imgs)
			im.save_png("%s/gd_%d.png" % [dir, i])
			m["w"] = im.get_width()
			m["h"] = im.get_height()
			if r[1] != null:
				_cut(r[1], imgs).save_png("%s/gd_%d_e.png" % [dir, i])
		meta.append(m)
	for hv: Array in hl_vp:
		var im: Image = (hv[1] as SubViewport).get_texture().get_image()
		im.save_png("%s/gd_%d.png" % [dir, int(hv[0])])
		meta[int(hv[0])]["w"] = im.get_width()
		meta[int(hv[0])]["h"] = im.get_height()
	var f := FileAccess.open(dir + "/gd_meta.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, " "))
	f.close()
	print("vehicles_test ok: ", results.size())
	get_tree().quit()
