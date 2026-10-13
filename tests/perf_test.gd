extends Node
## A/B-Leistungsmessung der Szenen-Komposition.
##
##   godot --path . --rendering-driver opengl3 res://tests/perf_test.tscn \
##       -- --zones=0,2,4 --a=basis --b=reflexion_aus
##
## Zwei Scenes zeichnen dieselbe Welt im Gleichschritt (gleiche dt-Folge).
## Dadurch ist der Szenenzustand beim Vergleich identisch und die sonst
## dominierende Frame-zu-Frame-Schwankung fällt heraus.

const DT := 1.0 / 60.0
const SEED := 12345
const STEPS := 300
const WARM := 20
const MEAS := 80

var zones: Array = [0, 2, 4]
var steps := STEPS
var name_a := "basis"
var name_b := "reflexion_aus"
var baker: Baker
var sa: Scene
var sb: Scene
var worlds: Dictionary = {}
var zi := 0
var wait := 0
var phase := 0
var n := 0
var ta: Array = []
var tb: Array = []

var configs: Dictionary = {
	"basis": [true, "viel", true, true],
	"reflexion_aus": [false, "viel", true, true],
	"fx_aus": [true, "viel", true, false],
	"nebel_aus": [true, "viel", false, true],
	"regen_wenig": [true, "wenig", true, true],
	"regen_aus": [true, "aus", true, true],
	"alles_aus": [false, "aus", false, false],
}


func _apply(sc: Scene, name: String) -> void:
	var c: Array = configs[name]
	sc.opt_reflections = c[0]
	sc.opt_rain = c[1]
	sc.opt_fog = c[2]
	sc.opt_fx = c[3]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--zones="):
			zones = []
			for z in a.substr(8).split(","):
				zones.append(int(z))
		elif a.begins_with("--steps="):
			steps = int(a.substr(8))
		elif a.begins_with("--a="):
			name_a = a.substr(4)
		elif a.begins_with("--b="):
			name_b = a.substr(4)
	baker = Baker.new()
	add_child(baker)
	City.baker = baker
	Sprites.baker = baker
	Vehicles.baker = baker
	Pixfont.baker = baker
	Holo.baker = baker
	sa = Scene.new()
	sa.setup(self, baker)
	sb = Scene.new()
	sb.setup(self, baker)
	_apply(sa, name_a)
	_apply(sb, name_b)
	for z: int in zones:
		var w := World.new(Run.new(SEED, "normal"), SEED, z)
		for i in steps:
			w.update(DT, {})
			w.events.clear()
		w.camera_x = clampf(w.length * 0.5, 0.0, w.length)
		worlds[z] = w


func _process(_d: float) -> void:
	match phase:
		0:
			var z: int = zones[zi]
			var w: World = worlds[z]
			sa.ensure_zone(z, SEED, w.length)
			sb.ensure_zone(z, SEED, w.length)
			wait = 3
			phase = 1
		1:
			if wait > 0:
				wait -= 1
				return
			ta.clear()
			tb.clear()
			n = 0
			phase = 2
		2:
			if n < WARM + MEAS:
				_tick()
				n += 1
				return
			_report()
			zi += 1
			phase = 0 if zi < zones.size() else 3
		3:
			get_tree().quit()


func _tick() -> void:
	var w: World = worlds[zones[zi]]
	var cam := w.camera_x
	# Reihenfolge je Frame wechseln (Cache-/Thermikeffekte ausmitteln)
	if n % 2 == 0:
		var x0 := Time.get_ticks_usec()
		sa.frame(w, DT, true, 0.0, 1.0, cam)
		var x1 := Time.get_ticks_usec()
		sb.frame(w, DT, true, 0.0, 1.0, cam)
		var x2 := Time.get_ticks_usec()
		_save(float(x1 - x0) / 1000.0, float(x2 - x1) / 1000.0)
	else:
		var y0 := Time.get_ticks_usec()
		sb.frame(w, DT, true, 0.0, 1.0, cam)
		var y1 := Time.get_ticks_usec()
		sa.frame(w, DT, true, 0.0, 1.0, cam)
		var y2 := Time.get_ticks_usec()
		_save(float(y2 - y1) / 1000.0, float(y1 - y0) / 1000.0)


func _save(ms_a: float, ms_b: float) -> void:
	if n < WARM:
		return
	ta.append(ms_a)
	tb.append(ms_b)


func _stat(s: Array) -> Array:
	var c := s.duplicate()
	c.sort()
	var med: float = c[c.size() / 2]
	var mean := 0.0
	for v: float in c:
		mean += v
	mean /= c.size()
	return [med, mean, c[0]]


func _report() -> void:
	var z: int = zones[zi]
	var a := _stat(ta)
	var b := _stat(tb)
	print("%s vs %s zone=%d | %s med=%.2f mean=%.2f min=%.2f | %s med=%.2f mean=%.2f min=%.2f | Delta(med)=%+.2f (%.0f%%)"
		% [name_a, name_b, z, name_a, a[0], a[1], a[2], name_b, b[0], b[1], b[2], b[0] - a[0],
			(b[0] - a[0]) / a[0] * 100.0])
