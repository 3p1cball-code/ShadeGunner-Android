extends Node
## Vollbild-Paritaet der Szenen-Komposition gegen tools/scene_reference.py.
##
## godot --path . --rendering-driver opengl3 res://tests/scene_test.tscn -- --out=<dir>
## Vergleich: python3 tools/imgdiff.py <dir>/py_*.png <dir>/gd_*.png
##
## Beide Seiten bauen dieselben sim.Worlds (Seed/Zone), lassen sie STEPS Schritte mit
## leerer Eingabe laufen und rendern dann dieselben Kamerapositionen ueber dieselbe
## (eine) Scene. frame() wird pro Schuss GENAU EINMAL aufgerufen (gleiche t-Phasen wie
## die Referenz); danach wird nur noch gezeichnet.
##
## Wichtig: City-Ebenen und die Laufzeit-Reflexionen (Fahrzeuge/Figuren/Schilder)
## entstehen als Ketten von UPDATE_ONCE-SubViewports und sind erst ueber echte
## Engine-Frames hinweg fertig. Deshalb wird die Zone vorab per ensure_zone() gebaut
## und SETTLE Frames gewartet; je Schuss folgen weitere SETTLE Frames, bevor das Bild
## gelesen wird. Der Szenen-Viewport leert dabei jedes Frame (CLEAR_ALWAYS), damit das
## Warten die additive Leuchtschicht nicht aufsummiert.

const DT := 1.0 / 60.0
const SEED := 12345
const STEPS := 300
const CAMS := [-1500.0, 0.0, 1500.0]
const SETTLE := 3

var out := "res://shots/scene_godot"
var baker: Baker
var sc: Scene
var zones: Array = []          # [World, zone, base_camera_x]
var zi := 0
var ci := 0
var wait := 0
var phase := 0                 # 0 Start | 1 Zone settlen | 2 Schuss settlen | 3 fertig


func _ready() -> void:
	var fixed: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--cams="):
			for c: String in a.substr(7).split(","):
				var zx := c.split(":")
				fixed.append([int(zx[0]), float(zx[1])])
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
	if not fixed.is_empty():
		_fixed = fixed
		var made := {}
		for fz: Array in fixed:
			var z: int = fz[0]
			if not made.has(z):
				var w := World.new(Run.new(SEED, "normal"), SEED, z)
				for i in STEPS:
					w.update(DT, {})
					w.events.clear()
				made[z] = w
			zones.append([made[z], z, fz[1]])
		return
	for z in 5:
		var w := World.new(Run.new(SEED, "normal"), SEED, z)
		for i in STEPS:
			w.update(DT, {})
			w.events.clear()
		zones.append([w, z, w.camera_x])


func _process(_d: float) -> void:
	if wait > 0:
		RenderingServer.force_draw()
		wait -= 1
		return
	match phase:
		0:
			sc.ensure_zone(zi, SEED, (zones[zi][0] as World).length)
			phase = 1
			wait = SETTLE
		1:
			_draw_shot()
			phase = 2
			wait = SETTLE
		2:
			_save_shot()
			_advance()
		3:
			pass


func _draw_shot() -> void:
	var w: World = zones[zi][0]
	var base: float = zones[zi][2]
	if _fixed.is_empty():
		w.camera_x = clampf(base + CAMS[ci], 0.0, w.length)
	else:
		w.camera_x = base
	sc.frame(w, DT)


func _save_shot() -> void:
	var im := sc.img.get_image()
	im.convert(Image.FORMAT_RGBA8)
	im.save_png(out.path_join(("gd_f%d.png" % zi) if not _fixed.is_empty() else ("gd_z%d_c%d.png" % [zi, ci])))


var _fixed: Array = []


func _advance() -> void:
	if not _fixed.is_empty():
		zi += 1
		if zi < zones.size():
			sc.ensure_zone(zones[zi][1], SEED, (zones[zi][0] as World).length)
			phase = 1
			wait = SETTLE
			return
		print("scene_test: ", zones.size(), " Bilder -> ", out)
		phase = 3
		get_tree().quit()
		return
	ci += 1
	if ci < CAMS.size():
		phase = 1
		wait = SETTLE
		return
	ci = 0
	zi += 1
	if zi < zones.size():
		phase = 0
		wait = 0
		return
	var names: Array = []
	for p: Array in zones:
		for c in CAMS.size():
			names.append("z%d_c%d" % [p[1], c])
	var f := FileAccess.open(out.path_join("cases.txt"), FileAccess.WRITE)
	f.store_string("\n".join(names))
	f.close()
	print("scene_test: ", names.size(), " Bilder -> ", out)
	phase = 3
	get_tree().quit()
