extends Node
## Gegenstück zu tools/sprites_reference.py: dieselben Fälle mit Sprites.get_.
## godot --path . --rendering-driver opengl3 res://tests/sprites_test.tscn -- --dir=<outdir>

var dir := ""
var frame := 0
var results: Array = []
var _last_drawn := -1
var data: Dictionary
var looks: Array


func _bake(i0: int, i1: int) -> void:
	for i in range(i0, i1):
		var c: Dictionary = data["cases"][i]
		var lk: Dictionary = looks[int(c["look"])]
		var r: Array = Sprites.get_(lk, c["anim"], int(c["frame"]), float(c["h"]), int(c["facing"]), c["rim"],
			int(c["rim_side"]), c["fog_rgb"], float(c["fog"]))
		results.append(r)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
	var baker := Baker.new()
	add_child(baker)
	Sprites.baker = baker
	data = JSON.parse_string(FileAccess.get_file_as_string(dir + "/cases.json"))
	looks = data["looks"]
	# erste Hälfte jetzt, zweite in einem späteren Frame (prüft Freigabe + Weiterzeichnen)
	_bake(0, (data["cases"] as Array).size() / 2)
	# Cache-Treffer muss dasselbe Array liefern
	var c0: Dictionary = data["cases"][0]
	var again: Array = Sprites.get_(looks[int(c0["look"])], c0["anim"], int(c0["frame"]), float(c0["h"]),
		int(c0["facing"]), c0["rim"], int(c0["rim_side"]), c0["fog_rgb"], float(c0["fog"]))
	assert(again == results[0])


func _cut(img: QImg, atlas_img: Image) -> Image:
	var im := atlas_img.get_region(Rect2i(img.region))
	if img.mirrored:
		im.flip_x()
	return im


func _process(_d: float) -> void:
	# Fenster unsichtbar (Monitor aus) -> Godot zeichnet nicht; dann selbst rendern
	if Engine.get_frames_drawn() == _last_drawn:
		RenderingServer.force_draw(false)
	_last_drawn = Engine.get_frames_drawn()
	frame += 1
	if OS.get_cmdline_user_args().has("--trace"):
		print("f", frame, " post_draw=", Sprites._drawn, " drawn=", Engine.get_frames_drawn())
	if frame == 3:
		_bake(results.size(), (data["cases"] as Array).size())
	if frame < 8:
		return
	var gen: Variant = Sprites._gens[Sprites._cur]
	var raw_img: Image = (gen.raw as Baker.Atlas).texture().get_image()
	var fin_img: Image = (gen.fin as Baker.Atlas).texture().get_image()
	if OS.get_cmdline_user_args().has("--atlas"):
		raw_img.save_png(dir + "/atlas_raw.png")
		fin_img.save_png(dir + "/atlas_fin.png")
	var meta: Array = []
	for i in results.size():
		var r: Array = results[i]
		_cut(r[0], fin_img).save_png("%s/gd_%d.png" % [dir, i])
		if r[1] != null:
			_cut(r[1], raw_img).save_png("%s/gd_%d_e.png" % [dir, i])
		var m: Dictionary = r[4]
		var e: Vector2 = m["eye"]
		var h: Vector2 = m["hand"]
		var hd: Vector2 = m["head"]
		meta.append({"w": (r[0] as QImg).width(), "h": (r[0] as QImg).height(), "ax": r[2], "ay": r[3],
			"emit": r[1] != null, "eye": [e.x, e.y], "hand": [h.x, h.y], "head": [hd.x, hd.y],
			"head_top": m["head_top"]})
	var f := FileAccess.open(dir + "/gd_meta.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, " "))
	f.close()
	print("sprites_test ok: ", results.size())
	get_tree().quit()
