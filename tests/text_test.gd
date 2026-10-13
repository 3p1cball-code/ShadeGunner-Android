extends Node
## Textmodus-Test: rendert die echte Szene (City + Sprites, wie scene_test.gd)
## durch TextMode und legt PNGs unter shots/text ab.
##
##   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##     res://tests/text_test.tscn -- --out=<dir>
##
## Geprueft werden alle 5 Zonen (2 Kameras) im Modus "blocks" sowie eine
## Vergleichsaufnahme im Modus "ascii". Ausgabe je Aufnahme: 1:1 (640x360)
## und 2x nearest (fuer die Lesbarkeitskontrolle).

const DT := 1.0 / 60.0
const SEED := 12345
const STEPS := 300
const CAMS := [0.0, 1500.0]
const SETTLE := 3
const CELL := 8

var out := "res://shots/text"
var baker: Baker
var sc: Scene
var tm: TextMode
var crt: CRTChain
var zones: Array = []          # [World, zone, base_camera_x]
var jobs: Array = []           # [{zi, cam, charset}]
var ji := 0
var wait := 0
var phase := 0                 # 0 Zone/Charset | 1 Schuss settlen | 2 speichern | 3 CRT | 4 fertig


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
	# TextMode NACH der Szene (liest sc.img) und vor einer CRT-Kette.
	tm = TextMode.new()
	tm.set_cell_size(CELL)
	tm.set_charset("blocks")
	tm.setup(self, sc.img)
	for z in 5:
		var w := World.new(Run.new(SEED, "normal"), SEED, z)
		for i in STEPS:
			w.update(DT, {})
			w.events.clear()
		zones.append([w, z, w.camera_x])
	for z in 5:
		for c in CAMS.size():
			jobs.append({"zi": z, "cam": c, "charset": "blocks", "cell": CELL})
	jobs.append({"zi": 2, "cam": 0, "charset": "ascii", "cell": CELL})
	jobs.append({"zi": 2, "cam": 0, "charset": "ascii", "cell": 12})
	jobs.append({"zi": 2, "cam": 0, "charset": "blocks", "cell": 6})


func _process(_d: float) -> void:
	if wait > 0:
		RenderingServer.force_draw()
		wait -= 1
		return
	match phase:
		0:
			var zi: int = jobs[ji]["zi"]
			sc.ensure_zone(zi, SEED, (zones[zi][0] as World).length)
			tm.set_charset(str(jobs[ji]["charset"]))
			tm.set_cell_size(int(jobs[ji]["cell"]))
			phase = 1
			wait = SETTLE
		1:
			_draw_shot()
			phase = 2
			wait = SETTLE
		2:
			_save_shot()
			ji += 1
			if ji < jobs.size():
				phase = 0
				wait = 0
			else:
				phase = 3
				wait = 0
		3:
			_setup_crt()
			phase = 4
			wait = SETTLE
		4:
			_save_crt()
			print("text_test: ", jobs.size(), " Textbilder + 1 CRT-Bild -> ", out)
			get_tree().quit()


func _draw_shot() -> void:
	var j: Dictionary = jobs[ji]
	var zi: int = j["zi"]
	var w: World = zones[zi][0]
	var base: float = zones[zi][2]
	w.camera_x = clampf(base + CAMS[j["cam"]], 0.0, w.length)
	sc.frame(w, DT)


func _save_shot() -> void:
	var j: Dictionary = jobs[ji]
	var zi: int = j["zi"]
	var ci: int = j["cam"]
	var cs: String = j["charset"]
	var cp: int = j["cell"]
	var fname := "text_z%d_c%d_%s_c%d" % [zi, ci, cs, cp]
	var im := tm.tex.get_image()
	im.convert(Image.FORMAT_RGBA8)
	im.save_png(out.path_join(fname + ".png"))
	var up := im.duplicate()
	up.resize(im.get_width() * 2, im.get_height() * 2, Image.INTERPOLATE_NEAREST)
	up.save_png(out.path_join(fname + "_2x.png"))


## Verdrahtung wie im Spiel: CRT-Kette bekommt die TextMode-Textur als scene_tex.
func _setup_crt() -> void:
	tm.set_charset("ascii")
	tm.set_cell_size(CELL)
	tm.set_enabled(true)
	crt = CRTChain.new()
	crt.scene_tex = tm.tex
	crt.scan_on = true
	add_child(crt)


## Endgueltiges Bild (Fenster): Textmodus -> CRT.
func _save_crt() -> void:
	var im := get_viewport().get_texture().get_image()
	im.convert(Image.FORMAT_RGBA8)
	im.save_png(out.path_join("text_crt.png"))
