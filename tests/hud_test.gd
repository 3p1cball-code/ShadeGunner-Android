extends Node
## Gegenstück zu tools/hud_reference.py: Pixfont, alle HUD-Bildschirme (DE/EN) und FX.
## godot --path . --rendering-driver opengl3 --audio-driver Dummy res://tests/hud_test.tscn -- --out=<dir>

const BG := [40, 44, 70]

var out := "res://shots"
var baker: Baker
var hud: HUD
var hud_tex: Texture2D
var comp: SubViewport
var cq: QP
var data: Dictionary
var jobs: Array = []          # [Name, Callable(), Dateiname]
var job := -1
var wait := 0
var _last_drawn := -1


class FakeActor:
	var uid := 0
	var x := 0.0
	var depth := 0.5
	var player := false
	var alive := true
	var escaped := false
	var state := "walk"
	var revealed: Dictionary = {}
	var tells: Dictionary = {}
	var scanned := false
	var exposure := 0.0
	var boss_invuln := false
	var hp := 1
	var name := ""


class FakeRun:
	var mods: Dictionary = {}
	var max_hp := 3
	var score := 0
	var totals: Dictionary = {}
	var upgrades: Array = []
	var origami: Array = []


class FakeScene:
	var screen: Dictionary = {}


class FakeWorld:
	var actors: Array = []
	var conf: Dictionary = {}
	var camera_x := 0.0
	var target: Variant = null
	var aiming := false
	var aim_t := 0.0
	var blocker: Variant = null
	var run: FakeRun
	var zone: Dictionary = {}
	var zone_index := 0
	var quota := 0
	var stats: Dictionary = {}
	var _reps := 0
	var combo := 1
	var bounty: Variant = null
	var bounty_desc: Variant = null
	var scan_charges := 0.0
	var scan_max := 0
	var suspicion := 0.0
	var shout_cd := 0.0
	var unrest := 0.0
	var length := 1.0
	var player: Variant = null
	var _exit := false
	var log_: Array = []
	var shout_hold := -1.0
	var scan_t := -1.0
	var scan_target: Variant = null
	var floaters: Array = []
	var replicants_total := 0
	var prior := 0.0
	var mission_failed := false
	var origami: Array = []
	var fail_reason := ""
	var vehicles: Array = []
	var patrol: Variant = null
	var watched := false
	var blackout_t := 0.0
	var ramen: Array = []
	var boss: Variant = null
	var boss_speak_t := 0.0
	var boss_line := 0

	func confidence_of(a: Variant) -> float:
		return float(conf[str(a.uid)])

	func reps_remaining() -> int:
		return _reps

	func exit_open() -> bool:
		return _exit


static func _mk_world(d: Dictionary) -> FakeWorld:
	var w := FakeWorld.new()
	var by_uid := {}
	for ad: Dictionary in d["actors"]:
		var a := FakeActor.new()
		for k: String in ["uid", "x", "depth", "player", "alive", "escaped", "state", "scanned", "exposure", "boss_invuln", "hp", "name"]:
			a.set(k, ad[k])
		for r: String in ad["revealed"]:
			a.revealed[r] = true
		a.tells = ad["tells"]
		w.actors.append(a)
		by_uid[a.uid] = a
	var ref := func(v: Variant) -> Variant: return null if v == null else by_uid[int(v)]
	w.conf = d["conf"]
	var run := FakeRun.new()
	for k: String in ["mods", "max_hp", "score", "totals", "upgrades", "origami"]:
		run.set(k, d["run"][k])
	w.run = run
	for k: String in ["camera_x", "aiming", "aim_t", "zone", "zone_index", "quota", "stats", "combo", "bounty_desc",
			"scan_charges", "scan_max", "suspicion", "shout_cd", "unrest", "length", "shout_hold", "scan_t",
			"floaters", "replicants_total", "prior", "mission_failed", "origami", "fail_reason", "vehicles", "patrol",
			"watched", "blackout_t", "ramen", "boss_speak_t", "boss_line"]:
		w.set(k, d[k])
	w.log_ = d["log"]
	w._reps = d["reps_remaining"]
	w._exit = d["exit_open"]
	for k: String in ["target", "blocker", "bounty", "player", "scan_target", "boss"]:
		w.set(k, ref.call(d[k]))
	return w


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--view-w="):     # Layout-Probe bei anderer Bildbreite (kein Paritaetsfall)
			View.W = int(a.substr(9))
	DirAccess.make_dir_recursive_absolute(out)
	data = Save._ints(JSON.parse_string(FileAccess.get_file_as_string("res://tests/hud_cases.json")))
	baker = Baker.new()
	add_child(baker)
	Pixfont.baker = baker
	FX.baker = baker
	hud = HUD.new()
	hud_tex = hud.setup(self)
	comp = SubViewport.new()
	comp.size = Vector2i(HUD.HW, 720)
	comp.transparent_bg = false
	comp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(comp)
	var host := Node2D.new()
	comp.add_child(host)
	cq = QP.new(host.get_canvas_item())
	jobs.append(["pixfont", _job_pixfont, "pixfont_godot.png"])
	for lang: String in ["de", "en"]:
		for c: Dictionary in data["hud"]:
			jobs.append([c["name"], _job_hud.bind(c, lang), "hud_%s_%s_godot.png" % [c["name"], lang]])
	jobs.append(["fx", _job_fx, "fx_godot.png"])


func _job_pixfont() -> void:
	comp.size = Vector2i(1280, 720)
	cq.begin()
	cq.fill_rect(0, 0, 1280, 720, QP.rgb(BG))
	var wbad := 0
	var i := 0
	for c: Array in data["pixfont"]:
		var w := Pixfont.draw(cq, c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])
		if w != int(data["pix_widths"][i]):
			wbad += 1
		i += 1
	cq.end()
	print("pixfont: Breiten falsch ", wbad)


func _job_hud(c: Dictionary, lang: String) -> void:
	I18n.set_lang(lang)
	var h2 := HUD.new()          # frischer Zustand wie im Python (eigenes t, Log, Emblem-Gedächtnis)
	h2.img = hud.img
	h2.host = hud.host
	h2.p = hud.p
	var w: Variant = null
	if c["world"] != null:
		w = _mk_world((c["world"] as Dictionary).duplicate(true))
	var sc := FakeScene.new()
	for st: Array in c["steps"]:
		if st[0] is String and st[0] == "reveal":
			for a: FakeActor in (w as FakeWorld).actors:
				if a.uid == int(st[1]):
					a.revealed["pupils"] = true
					a.tells["pupils"] = true
					(w as FakeWorld).conf[str(a.uid)] = float(st[2])
			continue
		h2.render(w, sc, float(st[0]), st[1])
	comp.size = Vector2i(HUD.HW, 720)
	cq.begin()
	cq.fill_rect(0, 0, HUD.HW, 720, QP.rgb(BG))
	cq.draw_texture(Rect2(0, 0, HUD.HW, 720), hud_tex)
	cq.end()


func _job_fx() -> void:
	var f := FX.new(42)
	f.set_rain(0.8)
	var dt := 1.0 / 60.0
	var log_: Array = []
	for i in 150:
		f.update_rain(dt, 0.7 if i % 30 < 20 else -1.3)
		if i % 7 == 0:
			f.puff(100 + i, 250, null, null, 0.8)
		if i % 11 == 0:
			f.puff(-3 + i * 0.1, 280, 200.0 + i, 0.4, 1.2)
		if i == 20:
			f.impact(220.0, 0.5, -30.0, [255, 220, 160], 10, true)
			f.tracer(100.0, 0.5, 220.0, 0.5, 3)
		if i == 140:
			f.impact(240.0, 0.6, -20.0, [255, 220, 160], 6, false)
		f.update_steam(dt)
		f.update_combat(dt)
		var bolt := f.update_weather(dt * 9, 0.8)
		var sh := f.shake()
		log_.append([bolt, sh, f.trauma, f.lightning])
	var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fx_ref.json"))
	var got := {"rain": f.rain, "splashes": f.splashes, "steam": f.steam, "sparks": f.sparks, "flashes": f.flashes,
		"tracers": f.tracers, "bolt": f.bolt, "log": log_, "next_bolt": f._next_bolt, "rnd": f.rng.random()}
	var res := [0.0, 0, 0]       # max. Abweichung, verglichene Zahlen, Strukturfehler
	for k: String in got:
		_cmp(got[k], ref[k], res, k)
	print("fx: Zahlen %d  max. Abw. %s  Strukturfehler %d  (Regen %d, Spritzer %d, Dampf %d, Funken %d)" % [
		res[1], str(res[0]), res[2], f.rain.size(), f.splashes.size(), f.steam.size(), f.sparks.size()])
	comp.size = Vector2i(640, 360)
	cq.begin()
	cq.fill_rect(0, 0, 640, 360, QP.c(18, 22, 38))
	f.draw_steam(cq, 150.0, 0.3)
	f.draw_rain(cq, [190, 196, 214])
	f.draw_splashes(cq, [190, 196, 214])
	cq.end()


func _cmp(a: Variant, b: Variant, res: Array, path: String) -> void:
	if (a is Array) and (b is Array):
		if (a as Array).size() != (b as Array).size():
			res[2] += 1
			print("  Länge ", path, " ", (a as Array).size(), " != ", (b as Array).size())
			return
		for i in (a as Array).size():
			_cmp(a[i], b[i], res, path + "[%d]" % i)
	elif a is Dictionary and b is Dictionary:
		for k: Variant in b:
			_cmp((a as Dictionary).get(k), b[k], res, path + "." + str(k))
	elif (a is float or a is int) and (b is float or b is int) and not (a is bool) and not (b is bool):
		res[0] = maxf(res[0], absf(float(a) - float(b)))
		res[1] += 1
	elif a != b:
		if not (a == null and b == null):
			res[2] += 1
			print("  ungleich ", path, " ", a, " != ", b)


func _process(_d: float) -> void:
	# Fenster unsichtbar (Monitor aus/verdeckt) -> Godot zeichnet nicht; dann selbst rendern
	if Engine.get_frames_drawn() == _last_drawn:
		RenderingServer.force_draw(false)
	_last_drawn = Engine.get_frames_drawn()
	if wait > 0:
		wait -= 1
		if wait == 0:
			var j: Array = jobs[job]
			comp.get_texture().get_image().save_png(out.path_join(j[2]))
		return
	job += 1
	if job >= jobs.size():
		print("hud_test ok")
		get_tree().quit()
		return
	(jobs[job][1] as Callable).call()
	wait = 4
