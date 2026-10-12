extends Node
## Gegenstück zu tools/holo_reference.py: Fälle nacheinander (eigene Textur je Hologramm
## wird pro Tick neu gezeichnet), je Fall Szene p, Leuchtschicht e und interne Textur.

var dir := ""
var frame := 0
var cases: Array = []
var cur := -1
var wait := 0
var vps: Array = []
var _last_drawn := -1
var meta: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--ss="):
			Holo.ss = int(a.substr(5))
	var baker := Baker.new()
	add_child(baker)
	Holo.baker = baker
	cases = (JSON.parse_string(FileAccess.get_file_as_string(dir + "/cases.json")) as Dictionary)["cases"]
	# pose_at-Zahlenvergleich
	var poses: Array = JSON.parse_string(FileAccess.get_file_as_string(dir + "/py_poses.json"))
	var maxd := 0.0
	for ps: Dictionary in poses:
		var r := Holo.pose_at(float(ps["t"]))
		maxd = maxf(maxd, absf(float(r[1]) - float(ps["th"])))
		var pts: Dictionary = r[0]
		for k: String in ps["pts"]:
			for j in 3:
				maxd = maxf(maxd, absf(float(pts[k][j]) - float(ps["pts"][k][j])))
	print("pose_at: ", poses.size(), " Zeitpunkte, max. Abweichung ", maxd)


func _vp() -> Array:
	var vp := SubViewport.new()
	vp.size = Vector2i(240, 260)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var host := Node2D.new()
	vp.add_child(host)
	add_child(vp)
	var p := QP.new(host.get_canvas_item())
	p.begin()
	p.fill_rect(0, 0, 240, 260, Color(0, 0, 0, 1))     # deckender Grund wie in der Szene
	return [vp, p]


func _process(_d: float) -> void:
	if Engine.get_frames_drawn() == _last_drawn:
		RenderingServer.force_draw(false)
	_last_drawn = Engine.get_frames_drawn()
	frame += 1
	if wait > 0:
		wait -= 1
		if wait == 0:
			(vps[0][0] as SubViewport).get_texture().get_image().save_png("%s/gd_%d.png" % [dir, cur])
			(vps[1][0] as SubViewport).get_texture().get_image().save_png("%s/gd_%d_e.png" % [dir, cur])
			var ent: Array = Holo._TMP.values()[0]
			ent[1].vpb.get_texture().get_image().save_png("%s/gd_%d_tex.png" % [dir, cur])
			meta.append({"ax": 0, "ay": 0, "extra": 0, "w": 240, "h": 260, "emit": true})
			for v: Array in vps:
				(v[1] as QP).free_all()
				(v[0] as SubViewport).queue_free()
		return
	cur += 1
	if cur >= cases.size():
		var f := FileAccess.open(dir + "/gd_meta.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(meta))
		f.close()
		print("holo_test ok: ", cases.size())
		get_tree().quit()
		return
	var c: Dictionary = cases[cur]
	for old: Array in Holo._TMP.values():
		Holo._free_tex(old[1])
	Holo._TMP.clear()
	vps = [_vp(), _vp()]
	Holo.render(vps[0][1], vps[1][1], float(c["x"]), float(c["base"]), float(c["h"]), c["col"], float(c["t"]),
		int(c["seed"]), float(c["reflect"]), 0.62, bool(c["mirror"]))
	(vps[0][1] as QP).end()
	(vps[1][1] as QP).end()
	wait = 3
