extends SceneTree
## Smoke-Test der Sim: World je Zone bauen, 600 Schritte mit leeren Eingaben und
## einigen Aktionen; dazu Titel-World (ohne Run). Prüft nur: keine Fehler, plausible Zustände.

const DT := 1.0 / 60.0
var fails := 0


func _chk(name: String, ok: bool, info: Variant = "") -> void:
	if not ok:
		fails += 1
		print("FAIL ", name, " ", info)


func _inp(i: int) -> Dictionary:
	# Skript: laufen, Tiefe, Sprint, Ziel wechseln, scannen, zielen/schießen, springen, rufen
	var ph := i % 300
	var d := {"move": [1 if ph < 200 else -1, 1 if (ph / 40) % 2 == 0 else -1]}
	d["sprint"] = ph > 150 and ph < 190
	d["cycle"] = 1 if ph == 20 else 0
	d["scan"] = ph == 30
	d["aim"] = ph >= 100 and ph < 130
	d["jump"] = ph == 140
	d["shout"] = ph >= 220 and ph < 260
	d["cancel"] = false
	return d


func _init() -> void:
	for z in 5:
		var run := Run.new(1234 + z, "normal")
		var w := World.new(run, 1234 + z, z)
		_chk("actors z%d" % z, w.actors.size() > 10, w.actors.size())
		_chk("quota z%d" % z, w.quota > 0 and w.quota <= w.replicants_total)
		var nev := 0
		var kinds := {}
		for i in 600:
			w.update(DT, {} if i < 60 else _inp(i))
			for e: Array in w.events:
				kinds[e[0]] = true
			nev += w.events.size()
			w.events.clear()
		var alive := w.living().size()
		print("Zone %d: actors=%d lebend=%d x=%.1f d=%.3f hp=%d score=%d verdacht=%.2f state=%s fahrzeuge=%d events=%d %s" % [
			z, w.actors.size(), alive, w.player.x, w.player.depth, w.player.hp, w.run.score,
			w.suspicion, w.state, w.vehicles.size(), nev, str(kinds.keys())])
		_chk("x>40 z%d" % z, w.player.x > 40.0, w.player.x)
	# Titelbildschirm: World ohne Run
	var tw := World.new(null, 4711, 2)
	for i in 600:
		tw.update(DT, {})
		tw.events.clear()
	print("Titel: actors=%d bounty=%s desc=%s" % [tw.actors.size(), tw.bounty.name if tw.bounty else "-", str(tw.bounty_desc)])
	# Direktaufrufe
	var w2 := World.new(null, 3, 2)
	var rep: Actor = null
	for a: Actor in w2.actors:
		if a.is_replicant:
			rep = a
			break
	w2.player.x = rep.x - 20
	w2.player.depth = rep.depth
	w2.camera_x = w2.player.x + 40
	w2.target = rep
	for a: Actor in w2.actors:
		if a != rep and not a.player and absf(a.x - rep.x) < 40:
			a.depth = 0.12 if rep.depth > 0.5 else 0.97
	var res := w2.fire()
	_chk("fire replicant", res[0] == "replicant" and not rep.alive, res)
	var r2 := Run.new(7)
	var w3 := World.new(r2, 7, 0)
	for a: Actor in w3.actors:
		if a.is_replicant:
			w3._kill(a)
	w3._zone_clear()
	r2.apply("akku")
	var nw := w3.next_world()
	_chk("next_world", nw != null and nw.zone_index == 1 and nw.scan_max == Config.SCAN_CHARGES + 2)
	_chk("advance", w3.advance_zone() and w3.zone_index == 1 and w3.state == "playing")
	print("Smoke-Test Sim: Fehler ", fails)
	quit(1 if fails else 0)
