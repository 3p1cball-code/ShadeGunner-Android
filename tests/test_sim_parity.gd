extends SceneTree
## Paritäts-Test der Simulation gegen die Python-Referenz (tools/sim_trace.py ->
## tests/sim_trace.json.gz). Gleicher Seed + gleiche Eingaben => gleicher Verlauf.
##   godot --headless --path . --script res://tests/test_sim_parity.gd [-- runs=z0_s1234,title]
## Meldet je Lauf den ersten abweichenden Schritt (Toleranz 1e-6 relativ).

const DT := 1.0 / 60.0
const STATES := ["walk", "idle", "loiter", "panic", "flee", "attack", "cower", "duck", "freeze", "hands", "hurt",
		"dead", "run", "aim", "shoot", "scan", "punch", "leap"]
const WSTATES := ["playing", "zone_clear", "failed", "finished"]


func make_world(rn: String) -> World:
	if rn == "title":
		return World.new(null, 4711, 2)
	var parts := rn.split("_")
	var z := int(parts[-2].substr(1))
	var s := int(parts[-1].substr(1))
	var w := World.new(Run.new(s, "normal"), s, z)
	setup(w, parts[0] if parts.size() == 3 else "")
	return w


func _near(w: World, a: Actor, dx: float) -> void:
	w.player.x = a.x - dx
	w.player.depth = a.depth
	w.camera_x = w.player.x + 40


## 1:1 wie sim_trace.setup (Sonder-Läufe)
func setup(w: World, kind: String) -> void:
	var p := w.player
	match kind:
		"ev":
			w.blackout_at = 1.0
			w.patrol_cd = 2.0
		"boss":
			w.stats["reps"] = w.quota
			p.x = w.length - 320.0 + 5
			w.camera_x = p.x + 40
		"bounty":
			_near(w, w.bounty, 30.0)
			w.set_target(w.bounty)
		"exit":
			for a: Actor in w.actors:
				if a.is_replicant:
					w._kill(a)
			p.x = w.length - 60.0
			w.camera_x = p.x + 40
		"gate":
			p.x = w.length - 60.0
			w.camera_x = p.x + 40
		"ramen":
			p.hp = w.run.max_hp - 1
			w.run.hp = p.hp
			p.x = float(w.ramen[0]["x"]) - 10
			p.depth = 0.3
			w.camera_x = p.x + 40


func input_for(rn: String, w: World, i: int) -> Dictionary:
	if rn == "title":
		return {}
	var kind := rn.split("_")[0]
	if kind == "boss" or kind == "bounty":
		return {"aim": (i % 30) < 20, "move": [0, 0]}
	if kind == "ramen" and i < 240:
		return {}
	return script_step(w, i)


## 1:1 wie sim_trace.script_step
func script_step(w: World, i: int) -> Dictionary:
	var c := i / 240
	var ph := i % 240
	var inp := {}
	var mx := 0
	var md := 0
	if ph < 60 or ph >= 220:
		mx = 1
	if ph >= 30 and ph < 60:
		inp["sprint"] = true
	if ph == 60:
		var best: Actor = null
		var bd := 1e9
		for a: Actor in w.living():
			var d := w.dist(w.player, a)
			if d < bd:
				best = a
				bd = d
		if best != null:
			w.set_target(best)
		inp["scan"] = true
	if ph == 120:
		inp["cycle"] = 1 if c % 2 == 0 else -1
	if ph >= 125 and ph < 160:
		inp["aim"] = true
	if ph == 150:
		var t := w.target
		var shoot := t != null and ((t.scanned and w.confidence_of(t) >= 0.4) or c % 3 == 0)
		if not shoot:
			inp["cancel"] = true
	if ph == 170:
		inp["jump"] = true
	if ph >= 175 and ph < 215:
		md = 1 if c % 2 == 0 else -1
		mx = -1 if ph < 190 else 1
	if c % 2 == 1 and ph >= 200 and ph < 230:
		inp["shout"] = true
	if c % 2 == 0 and (ph == 200 or ph == 201):
		inp["shout"] = true
	inp["move"] = [mx, md]
	return inp


func _code(s: String, table: Array) -> int:
	var k := table.find(s)
	return k if k >= 0 else 99


func snapshot(w: World) -> Array:
	var p := w.player
	var alive := 0
	var esc := 0
	var dead := 0
	var sx := 0.0
	var sd := 0.0
	var sph := 0.0
	var sexp := 0.0
	var sst := 0
	var sfr := 0
	for i in w.actors.size():
		var a: Actor = w.actors[i]
		if a.escaped:
			esc += 1
		elif not a.alive:
			dead += 1
		elif not a.player:
			alive += 1
		sx += a.x
		sd += a.depth
		sph += a.phase
		sexp += a.exposure
		sst += (i + 1) * _code(a.state, STATES)
		sfr += (i + 1) * a.frame
	var svx := 0.0
	var svs := 0.0
	for v: Dictionary in w.vehicles:
		svx += float(v["x"])
		svs += float(v["speed"])
	var kinds := PackedStringArray()
	var evn := 0.0
	for e: Array in w.events:
		kinds.append(e[0])
		for k in range(1, e.size()):
			var x: Variant = e[k]
			if x is int or x is float:
				evn += float(x)
	var pat: float = float(w.patrol["x"]) if w.patrol != null else -1.0
	return [p.x, p.depth, p.z, p.hp, _code(p.state, STATES), w.run.score, w.suspicion, w.unrest, w.scan_charges,
			w.target.uid if w.target != null else -1, alive, esc, dead, sx, sd, sst, sph, sfr, sexp,
			w.vehicles.size(), svx, svs, ",".join(kinds), evn, w.floaters.size(), w.log_.size(), w.rng.mti,
			w.rng.mt[0], w.camera_x, _code(w.state, WSTATES), w.shout_cd, pat, w.obstacles.size(),
			w.stats["reps"], w.time]


func _same(a: Variant, b: Variant) -> bool:
	if b is String or a is String:
		return str(a) == str(b)
	var fa := float(a)
	var fb := float(b)
	return absf(fa - fb) <= 1e-6 * maxf(1.0, absf(fb))


func _init() -> void:
	var raw := FileAccess.get_file_as_bytes("res://tests/sim_trace.json.gz")
	var txt := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var data: Dictionary = JSON.parse_string(txt)
	var fields: Array = data["fields"]
	var steps := int(data["steps"])
	var runs: Dictionary = data["runs"]
	var want := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("runs="):
			want = arg.substr(5).split(",", false)
	var total_bad := 0
	var total_steps := 0
	for rn: String in runs:
		if not want.is_empty() and not want.has(rn):
			continue
		var ref: Array = runs[rn]
		var w := make_world(rn)
		var first := -1
		var nbad := 0
		var t0 := Time.get_ticks_msec()
		for i in steps + 1:
			if i > 0:
				w.update(DT, input_for(rn, w, i - 1))
			var got := snapshot(w)
			w.events.clear()
			var row: Array = ref[i]
			var diffs := []
			for k in fields.size():
				if not _same(got[k], row[k]):
					diffs.append("%s: godot=%s python=%s" % [fields[k], str(got[k]), str(row[k])])
			if not diffs.is_empty():
				nbad += 1
				if first < 0:
					first = i
					print("  %s erste Abweichung Schritt %d: %s" % [rn, i, "; ".join(diffs)])
		total_bad += nbad
		total_steps += steps + 1
		print("%s: %d Schritte, %d abweichend%s (%d ms)" % [rn, steps + 1, nbad,
				"" if first < 0 else ", erste bei %d" % first, Time.get_ticks_msec() - t0])
	print("Parität Sim: %d/%d Schritte abweichend" % [total_bad, total_steps])
	quit(1 if total_bad else 0)
