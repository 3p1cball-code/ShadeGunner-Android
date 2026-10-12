extends Node
## Vollbild-Paritaet der Szenen-Komposition: rendert Scene.frame fuer dieselben
## sim.Worlds (Seed/Zone), Schrittzahlen und Kamerapositionen wie
## tools/scene_reference.py und speichert gd_z<zone>_c<cam>.png.
##
## godot --path . --rendering-driver opengl3 res://tests/scene_test.tscn -- --out=<dir>
## Vergleich: python3 tools/imgdiff.py <dir>/py_*.png <dir>/gd_*.png

const DT := 1.0 / 60.0
const SEED := 12345
const STEPS := 300
const CAMS := [-1500.0, 0.0, 1500.0]

var out := "res://shots/scene_godot"
var baker: Baker
var sc: Scene
var frames := 0
var done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	baker = Baker.new()
	add_child(baker)
	City.baker = baker
	Sprites.baker = baker
	Vehicles.baker = baker
	Pixfont.baker = baker
	Holo.baker = baker
	sc = Scene.new()
	sc.setup(self, baker)


func _process(_d: float) -> void:
	frames += 1
	if frames < 3 or done:
		return
	done = true
	var names: Array = []
	for z in 5:
		var w := World.new(Run.new(SEED, "normal"), SEED, z)
		for i in STEPS:
			w.update(DT, {})
			w.events.clear()
		var base: float = w.camera_x
		for ci in CAMS.size():
			w.camera_x = clampf(base + CAMS[ci], 0.0, w.length)
			sc.frame(w, DT)
			# Zweimal zeichnen: die beim Zonenaufbau frisch gebackenen City-Ebenen
			# hängen als UPDATE_ONCE-Viewports am Baker und sind erst einen Draw
			# spaeter sichtbar (sonst waere genau das erste Bild je Zone zu dunkel).
			RenderingServer.force_draw()
			RenderingServer.force_draw()
			var im := sc.img.get_image()
			im.convert(Image.FORMAT_RGBA8)
			var nm := "z%d_c%d" % [z, ci]
			im.save_png(out.path_join("gd_" + nm + ".png"))
			names.append(nm)
	var f := FileAccess.open(out.path_join("cases.txt"), FileAccess.WRITE)
	f.store_string("\n".join(names))
	f.close()
	print("scene_test: ", names.size(), " Bilder -> ", out)
	get_tree().quit()
