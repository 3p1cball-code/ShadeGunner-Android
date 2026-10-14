extends Node
## Leistungsprofil der Szenen-Komposition je Zone: ms/Bild und Sprite-Bakes/Bild.
##   godot --path . --rendering-driver opengl3 res://tests/prof_scene.tscn -- [--zones=0,2] [--q=niedrig]
## Die Welt läuft mit leerer Eingabe weiter (Passanten bewegen sich, Kamera steht).
var zones: Array = [0, 1, 2, 3, 4]
var quality := "hoch"
var sc: Scene
var w: World
var zi := 0
var n := 0
var ts: Array = []
var bakes0 := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--zones="):
			zones = Array(a.substr(8).split(",")).map(func(x: String) -> int: return int(x))
		elif a.begins_with("--q="):
			quality = a.substr(4)
	var baker := Baker.new()
	add_child(baker)
	City.baker = baker
	Sprites.baker = baker
	Vehicles.baker = baker
	Pixfont.baker = baker
	Holo.baker = baker
	sc = Scene.new()
	sc.setup(self, baker)
	sc.opt_quality = quality
	if quality != "hoch":
		sc.opt_reflections = false
	if quality == "niedrig":
		sc.opt_rain = "aus"
		sc.opt_fog = false
		sc.opt_fx = false
	_start()


func _start() -> void:
	w = World.new(Run.new(12345, "normal"), 12345, zones[zi])
	for i in 300:
		w.update(1.0 / 60, {})
		w.events.clear()
	n = 0
	ts = []


func _process(_d: float) -> void:
	w.update(1.0 / 60, {})
	w.events.clear()
	if n == 30:
		bakes0 = Sprites.bake_n
	var t0 := Time.get_ticks_usec()
	sc.frame(w, 1.0 / 60)
	if n >= 30:
		ts.append((Time.get_ticks_usec() - t0) / 1000.0)
	n += 1
	if n == 150:
		ts.sort()
		var mean := 0.0
		for v: float in ts:
			mean += v
		mean /= ts.size()
		print("zone %d (%s): med=%.2f mean=%.2f p90=%.2f ms | sprite-bakes/bild=%.2f" % [zones[zi], quality,
			ts[ts.size() / 2], mean, ts[int(ts.size() * 0.9)], float(Sprites.bake_n - bakes0) / ts.size()])
		zi += 1
		if zi >= zones.size():
			get_tree().quit()
		else:
			_start()
