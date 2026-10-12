extends SceneTree
## Headless-Sim-Tests, portiert aus tests/test_sim.py (Original).
##   godot --headless --path . --script res://tests/test_sim.gd
## Nicht portiert (gehören nicht zur Sim): vehicle_variants (Renderer), settings_* (Settings/HUD/Game).

const DT := 1.0 / 60.0
var fails := 0
var cur := ""


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		fails += 1
		print("  FAIL ", cur, ": ", msg)


func _place_near(w: World, a: Actor, dx: float = 20.0) -> void:
	w.player.x = a.x - dx
	w.player.depth = a.depth
	w.player.facing = 1
	w.camera_x = w.player.x + 40


func _run_scan(w: World, a: Actor) -> Array:
	_place_near(w, a)
	w.target = a
	var r := w.scan()
	for _i in 200:
		if w.scan_t < 0:
			break
		w.update(DT, {})
	return r


func _quiet(w: World) -> void:
	w.traffic_cd = 1e9
	w.patrol_cd = null
	w.blackout_at = null
	w.vehicles.clear()


func _first(arr: Array, pred: Callable) -> Actor:
	for a: Actor in arr:
		if pred.call(a):
			return a
	return null


func _npc(a: Actor) -> bool:
	return not a.player


func _human(a: Actor) -> bool:
	return not a.player and not a.is_replicant


func _rep(a: Actor) -> bool:
	return a.is_replicant


func _count_ev(w: World, kind: String) -> int:
	var n := 0
	for e: Array in w.events:
		if e[0] == kind:
			n += 1
	return n


# ------------------------------------------------------------------ Tests
func test_population() -> void:
	var w := World.new(null, 1)
	_ok(w.actors.size() > 10, "zu wenige Aktoren")
	var reps := w.actors.filter(_rep)
	_ok(reps.size() == int(DSim.ZONES[0]["replicants"]), "Replikantenzahl")
	_ok(w.replicants_total == reps.size(), "replicants_total")
	_ok(0 < w.prior and w.prior < 0.5, "prior")


func test_confidence_calibration() -> void:
	var tells := {}
	var none := {}
	for k: String in Detection.ORDER:
		tells[k] = true
		none[k] = false
	var hi := Detection.confidence(Detection.ORDER, tells, 0.5, 0.1)
	_ok(hi > 0.9, "alle Tells -> hohe Konfidenz erwartet, war %f" % hi)
	var mid := Detection.confidence([], tells, 0.5, 0.1)
	_ok(absf(mid - 0.1) < 1e-6, "ohne Tells = Prior erwartet, war %f" % mid)
	var lo := Detection.confidence(Detection.ORDER, none, 0.5, 0.1)
	_ok(lo < 0.02, "keine Tells -> niedrig erwartet, war %f" % lo)


func test_camo_makes_it_harder() -> void:
	var easy := Detection.likelihoods(0.0)
	var hard := Detection.likelihoods(1.0)
	for n: String in Detection.ORDER:
		_ok(easy[n][0] > hard[n][0], n + ": Replikanten-Tells sollen mit Tarnung seltener werden")
		_ok(easy[n][1] < hard[n][1], n + ": Gegen-Tells sollen mit Tarnung häufiger werden")


func test_calibration_empirical() -> void:
	var rng := PyRandom.new(3)
	var camo := 0.5
	var prior := 0.15
	var bins := {}
	for _i in 40000:
		var rep := rng.random() < prior
		var tells := Detection.spawn_tells(rng, rep, camo)
		var c := Detection.confidence(Detection.ORDER, tells, camo, prior)
		var b := mini(4, int(c * 5))
		var nk: Array = bins.get(b, [0, 0])
		bins[b] = [nk[0] + 1, nk[1] + (1 if rep else 0)]
	for b: int in bins:
		var nk: Array = bins[b]
		if nk[0] < 400:
			continue
		var rate := float(nk[1]) / float(nk[0])
		_ok(b / 5.0 - 0.08 <= rate and rate <= (b + 1) / 5.0 + 0.08, "Bin %d: Quote %.2f passt nicht" % [b, rate])


func test_scan_reveals_and_costs() -> void:
	var w := World.new(null, 2)
	var target := _first(w.actors, _npc)
	var before := w.scan_charges
	var r := _run_scan(w, target)
	_ok(r[0] == "ok" and r[1] == target, "Scan nicht ok")
	_ok(w.scan_charges < before, "Scan sollte Ladung kosten")
	_ok(target.scanned and target.revealed.has(Detection.STRONG_TELLS[0]), "nicht gescannt")
	_ok(target.revealed.has("serial"), "Nahscan sollte die Seriennummer zeigen")


func test_scan_far_hides_serial() -> void:
	var w := World.new(null, 2)
	var target := _first(w.actors, _npc)
	w.player.x = target.x - 110
	w.player.depth = target.depth
	w.camera_x = w.player.x + 60
	w.target = target
	w.scan()
	for _i in 200:
		if w.scan_t < 0:
			break
		w.update(DT, {})
	if target.scanned:
		_ok(not target.revealed.has("serial"), "Fernscan zeigt Seriennummer")


func test_kill_outcomes() -> void:
	var w := World.new(null, 3, 2)
	var rep := _first(w.actors, _rep)
	_place_near(w, rep)
	w.target = rep
	for a: Actor in w.actors:
		if a != rep and not a.player and absf(a.x - rep.x) < 40:
			a.depth = 0.12 if rep.depth > 0.5 else 0.97
	var r := w.fire()
	_ok(r[0] == "replicant" and not rep.alive and r[1] == rep, "Replikant nicht getroffen: %s" % str(r[0]))
	_ok(w.stats["reps"] == 1 and w.run.score > 0, "Punkte")
	var civ := _first(w.actors, func(a: Actor) -> bool: return not a.is_replicant and a.alive and not a.player)
	_place_near(w, civ)
	w.target = civ
	w.shot_cd = 0
	for a: Actor in w.actors:
		if a != civ and not a.player and a.alive and absf(a.x - civ.x) < 40:
			a.depth = 0.12 if civ.depth > 0.5 else 0.97
	var s0 := w.suspicion
	r = w.fire()
	_ok(r[0] == "civilian" and w.suspicion > s0, "Zivilist")


func test_line_of_fire_blocker() -> void:
	var w := World.new(null, 4, 2)
	var npcs := w.actors.filter(_npc).slice(0, 2)
	var t: Actor = npcs[0]
	var b: Actor = npcs[1]
	w.actors = [w.player, t, b]
	w.player.x = 100.0
	w.player.depth = 0.5
	t.x = 180.0
	t.depth = 0.5
	b.x = 140.0
	b.depth = 0.5
	w.target = t
	_ok(w.line_of_fire(t) == b, "Person dazwischen muss die Kugel fangen")
	b.depth = 0.9
	_ok(w.line_of_fire(t) == t, "nach Tiefenwechsel ist die Linie frei")


func test_failure_on_too_many_civilians() -> void:
	var w := World.new(null, 4, 2)
	for a: Actor in w.actors.duplicate():
		if a.is_replicant or a.player or not a.alive:
			continue
		w.shot_cd = 0
		_place_near(w, a)
		w.target = a
		w.fire()
		if w.state == "failed":
			break
	_ok(w.state == "failed" and w.fail_reason == "suspicion", "nicht gescheitert")


func test_exit_locked_until_quota() -> void:
	var w := World.new(null, 5)
	w.player.x = w.length + 5
	w.update(DT, {"move": [1, 0]})
	_ok(w.state == "playing", "Ausgang muss ohne Auftrag gesperrt sein")
	for a: Actor in w.actors:
		if a.is_replicant and w.stats["reps"] < w.quota:
			w._kill(a)
	w.player.x = w.length + 5
	w.update(DT, {"move": [1, 0]})
	_ok(w.state == "zone_clear", "Zone nicht geschafft")


func test_zone_progression_and_run_carry() -> void:
	var run := Run.new(7)
	var w := World.new(run, 7, 0)
	for a: Actor in w.actors:
		if a.is_replicant:
			w._kill(a)
	w._zone_clear()
	var score := run.score
	run.apply("akku")
	var nw := w.next_world()
	_ok(nw != null and nw.zone_index == 1 and nw.state == "playing", "nächste Zone")
	_ok(nw.run.score == score and nw.scan_max == Config.SCAN_CHARGES + 2, "Run-Übertrag")
	w.zone_index = DSim.ZONES.size() - 1
	_ok(w.next_world() == null, "nach Tyrell keine Zone mehr")


func test_attacker_hurts_player() -> void:
	var w := World.new(null, 8, 4)
	var rep := _first(w.actors, _rep)
	rep.aggressive = true
	w._alert(rep)
	rep.x = w.player.x + 30
	rep.depth = w.player.depth
	rep.target_depth = rep.depth
	var hp0 := w.player.hp
	for _i in 300:
		w.update(DT, {})
		if w.player.hp < hp0:
			break
	_ok(w.player.hp < hp0, "angreifender Replikant muss Schaden machen")


func test_long_random_play_no_crash() -> void:
	var rng := PyRandom.new(11)
	var run := Run.new(11)
	var w := World.new(run, 11, 0)
	var steps := 0
	while steps < 60 * 400:
		var inp := {"move": [rng.choice([1, 1, 1, 0, -1]), rng.choice([0, 0, 1, -1])],
				"sprint": rng.random() < 0.3, "aim": rng.random() < 0.2,
				"scan": rng.random() < 0.01, "cycle": 1 if rng.random() < 0.01 else 0}
		w.update(DT, inp)
		w.events.clear()
		steps += 1
		if w.state == "zone_clear":
			var off: Array = run.offer(rng)
			run.apply(off[0][0])
			var nw := w.next_world()
			if nw == null:
				break
			w = nw
		elif w.state == "failed":
			break
	_ok(steps > 100, "zu kurz")


func test_projection_monotonic() -> void:
	_ok(Persp.figure_h(0.95) > Persp.figure_h(0.2), "figure_h")
	_ok(Persp.ground_y(0.95) > Persp.ground_y(0.2), "ground_y")
	_ok(Persp.FACADE_Y < Persp.ground_y(0.0) and Persp.FACADE_PPU < Persp.ppu(0.0), "Fassade")


func test_jump_clears_obstacle() -> void:
	var w := World.new(null, 4, 1)
	_quiet(w)
	var o := {"x": 500.0, "d": 0.5, "w": 8.0, "dd": 0.05, "h": 9.0, "kind": "crates", "seed": 1}
	w.obstacles = [o]
	w.actors = [w.player]
	var p := w.player
	p.x = 480.0
	p.depth = 0.5
	for _i in 60:
		w.update(DT, {"move": [1, 0]})
	_ok(p.x < o["x"] - o["w"], "ohne Sprung durchs Hindernis gelaufen (x=%.1f)" % p.x)
	w.update(DT, {"move": [1, 0], "jump": true})
	var peak := 0.0
	for _i in 90:
		w.update(DT, {"move": [1, 0]})
		peak = maxf(peak, p.z)
	_ok(peak > o["h"], "Sprung zu niedrig (%.1f)" % peak)
	_ok(p.x > o["x"] + o["w"], "nicht drübergesprungen (x=%.1f)" % p.x)
	_ok(p.z == 0.0, "nicht gelandet")


func test_jump_dodges_punch() -> void:
	var w := World.new(null, 5, 2)
	_quiet(w)
	var rep := _first(w.actors, _rep)
	w.actors = [w.player, rep]
	var p := w.player
	rep.x = p.x + 10
	rep.depth = p.depth
	rep.state = "punch"
	rep.timer = 0.25
	rep.hit_done = false
	p.vz = Config.JUMP_V
	p.z = 0.01
	for _i in 3:
		w.update(DT, {})
	var hp := p.hp
	for _i in 10:
		w.update(DT, {})
	_ok(p.hp == hp, "Schlag hätte im Sprung ins Leere gehen müssen")


func test_vehicle_brakes_for_player_in_lane() -> void:
	var w := World.new(null, 6, 2)
	_quiet(w)
	w.actors = [w.player]
	var p := w.player
	var lane: float = Config.LANES[1][0]
	var dr: int = Config.LANES[1][1]
	p.depth = lane
	w.vehicles.append({"x": p.x - dr * 220, "depth": lane, "dir": dr, "speed": 170.0, "vmax": 170.0, "kind": "car",
			"L": 87.0, "h": 25.5, "seed": 1, "honk": false, "uid": -1, "react": 0.3})
	var hp := p.hp
	var honks := 0
	for _i in int(5 / DT):
		w.update(DT, {})
		honks += _count_ev(w, "honk")
		w.events.clear()
	_ok(p.hp == hp, "gebremstes Auto darf kein Herz kosten")
	_ok(honks >= 1, "Auto hat den Spieler in der Spur nicht angehupt")
	var v: Dictionary = w.vehicles[0]
	_ok(v["speed"] < 20.0, "Auto bremst nicht (%.0f)" % v["speed"])


func test_vehicle_bump_costs_no_heart() -> void:
	var w := World.new(null, 6, 2)
	_quiet(w)
	w.actors = [w.player]
	var p := w.player
	var lane: float = Config.LANES[0][0]
	var dr: int = Config.LANES[0][1]
	p.depth = lane
	var hp := p.hp
	w.vehicles.append({"x": p.x, "depth": lane, "dir": dr, "speed": 0.0, "vmax": 0.0, "kind": "car",
			"L": 87.0, "h": 25.5, "seed": 1, "honk": false, "uid": -1, "react": 0.3})
	var bumps := 0
	for _i in 30:
		w.update(DT, {})
		bumps += _count_ev(w, "bump")
		w.events.clear()
	_ok(bumps >= 1, "kein Rempler")
	_ok(p.hp == hp, "Rempler darf kein Herz kosten")
	_ok(absf(p.depth - lane) > Config.LANE_HALF, "Spieler nicht aus der Spur geschoben")


func test_vehicle_frontal_hit_at_speed() -> void:
	var w := World.new(null, 6, 2)
	_quiet(w)
	w.actors = [w.player]
	w.car_escape = 0.0
	var p := w.player
	var lane: float = Config.LANES[1][0]
	var dr: int = Config.LANES[1][1]
	p.depth = lane
	var hp := p.hp
	w.vehicles.append({"x": p.x - dr * 20, "depth": lane, "dir": dr, "speed": 200.0, "vmax": 200.0, "kind": "car",
			"L": 87.0, "h": 25.5, "seed": 1, "honk": false, "uid": -1, "react": 0.6})
	for _i in 30:
		w.update(DT, {})
		w.events.clear()
	_ok(p.hp == hp - 1, "frontal mit Tempo muss ein Herz kosten")
	_ok(absf(p.depth - lane) > Config.LANE_HALF, "Spieler nicht aus der Spur geschleudert")


func _avg_vol(z: int) -> float:
	var w := World.new(null, 7, z)
	var s := 0.0
	var n := 0
	for _i in int(12 / DT):
		w.update(DT, {})
		for e: Array in w.events:
			if e[0] == "vehicle":
				s += float(e[3])
				n += 1
		w.events.clear()
	return s / maxi(1, n)


func test_engine_sound_quieter_when_dense() -> void:
	_ok(_avg_vol(0) > _avg_vol(2) + 0.3, "dichter Verkehr klingt nicht leiser")


func test_npcs_dodge_traffic() -> void:
	var w := World.new(null, 7, 2)
	_quiet(w)
	var lane: float = Config.LANES[0][0]
	var dr: int = Config.LANES[0][1]
	var civ := _first(w.actors, _human)
	civ.depth = lane
	civ.target_depth = lane
	civ.state = "idle"
	civ.vx = 0.0
	civ.timer = 99
	w.vehicles.append({"x": civ.x - dr * 300, "depth": lane, "dir": dr, "speed": 180.0, "kind": "car", "L": 87.0,
			"h": 25.5, "seed": 1, "honk": false, "uid": -1})
	for _i in int(1.4 / DT):
		w.update(DT, {})
	_ok(absf(civ.depth - lane) > Config.LANE_HALF - 0.01, "Passant blieb auf der Spur (%.2f)" % civ.depth)


func test_bounty_and_tough() -> void:
	var w := World.new(null, 8, 2)
	_quiet(w)
	var b := w.bounty
	_ok(b != null and b.is_replicant and b.hp == 2 and w.bounty_desc != null, "Kopfgeld")
	_place_near(w, b, 30)
	w.target = b
	var score := w.run.score
	w.shot_cd = 0
	_ok(w._hit(b) == "tough" and b.alive, "zäh")
	_ok(w._hit(b) == "replicant" and not b.alive, "zweiter Treffer")
	_ok(w.run.score - score >= Config.POINTS_REPLICANT + Config.POINTS_BOUNTY, "Kopfgeldpunkte")


func test_cancel_aim_no_shot() -> void:
	var w := World.new(null, 11, 1)
	_quiet(w)
	var civ := _first(w.living(), func(a: Actor) -> bool: return not a.is_replicant)
	_place_near(w, civ, 30)
	civ.state = "idle"
	civ.timer = 99
	civ.vx = 0.0
	w.set_target(civ)
	for _i in 30:
		w.update(DT, {"aim": true})
	_ok(w.aiming, "zielt nicht")
	w.update(DT, {"aim": true, "cancel": true})
	_ok(not w.aiming and w.aim_latch, "Abbruch")
	for _i in 40:
		w.update(DT, {"aim": true})
	_ok(civ.alive and w.stats["shots"] == 0, "Schuss trotz Abbruch!")
	w.update(DT, {})
	_ok(not w.aim_latch, "Sperre nicht gelöst")
	for _i in 30:
		w.update(DT, {"aim": true})
	w.update(DT, {})
	_ok(w.stats["shots"] == 1, "kein Schuss nach erneutem Loslassen")


func test_boss_flow() -> void:
	var w := World.new(null, 3, 4)
	_quiet(w)
	w.player.x = w.length - Config.ROY_TRIGGER + 5
	w.update(DT, {})
	_ok(not w.boss_spawned, "ROY spawnt, obwohl der Auftrag nicht erfüllt ist")
	w.stats["reps"] = w.quota
	w.update(DT, {})
	var b := w.boss
	_ok(w.boss_spawned and b != null and b.alive and b.hp == Config.ROY_HP, "ROY fehlt")
	_ok(b.boss_invuln, "ROY redet nicht zu Beginn")
	_ok(not w.exit_open(), "Tor offen, obwohl ROY lebt")
	w._hit(b)
	_ok(b.hp == Config.ROY_HP, "Treffer während der Rede hat gezählt")
	for _i in Config.ROY_HP:
		b.boss_invuln = false
		w.boss_speak_t = 0.0
		w._hit(b)
	_ok(not b.alive, "ROY lebt")
	_ok(w.exit_open(), "Tor blieb nach ROY zu")


func test_manual_target_scan_too_far() -> void:
	var w := World.new(null, 9, 1)
	_quiet(w)
	var far: Actor = null
	var fd := -1.0
	for a: Actor in w.living():
		if w.on_screen(a) and w.dist(w.player, a) > fd:
			far = a
			fd = w.dist(w.player, a)
	if far == null or fd <= Config.SCAN_RANGE:
		return
	_ok(w.set_target(far), "set_target")
	var r := w.scan()
	_ok(r[0] == "too_far" and w.target == far, "gewähltes Ziel wurde stillschweigend gewechselt")
	_ok(w.scan_t < 0, "Scan läuft trotzdem")


func test_blackout_and_patrol_reveal() -> void:
	var w := World.new(null, 10, 2)
	_quiet(w)
	var rep := _first(w.actors, _rep)
	rep.tells["pupils"] = true
	rep.revealed.erase("pupils")
	_place_near(w, rep, 40)
	rep.state = "idle"
	rep.timer = 99
	w.blackout_at = w.time
	for _i in int(4 / DT):
		w.update(DT, {})
		rep.state = "idle"
		rep.vx = 0.0
	_ok(rep.revealed.has("pupils"), "Augenreflex im Stromausfall nicht aufgedeckt")


func _has_spinner(w: World) -> bool:
	for o: Dictionary in w.obstacles:
		if o["kind"] == "spinner":
			return true
	return false


func test_spinner_lands_blocks_and_lifts_off() -> void:
	var w := World.new(null, 12, 2)
	_quiet(w)
	w.obstacles.clear()
	w.ramen.clear()
	var p := w.player
	p.x = 600.0
	p.depth = 0.8
	w.camera_x = p.x + 40
	var old := World.SPINNER_LAND_CHANCE
	World.SPINNER_LAND_CHANCE = 1.0
	w.patrol_cd = 0.1
	var landed := false
	for _i in int(25 / DT):
		w.update(DT, {})
		var P: Variant = w.patrol
		if P != null and P["phase"] == "landed":
			landed = true
			_ok(_has_spinner(w), "gelandeter Spinner blockiert nicht")
			_ok(w.blocked(P["x"], Config.LAND_DEPTH, 0.0), "Landeplatz nicht gesperrt")
			_ok(w.blocked(P["x"], Config.LAND_DEPTH, 30.0), "über den Spinner springen darf nicht gehen")
		if landed and (P == null or P["phase"] in ["lift", "fly"]):
			break
	World.SPINNER_LAND_CHANCE = old
	_ok(landed, "Spinner ist nie gelandet")
	_ok(not _has_spinner(w), "Sperre nach dem Abheben nicht entfernt")


func test_spinner_downdraft_pushes_away() -> void:
	var w := World.new(null, 13, 2)
	_quiet(w)
	w.obstacles.clear()
	var civ := _first(w.actors, _npc)
	civ.state = "idle"
	civ.vx = 0.0
	civ.timer = 99
	civ.x = 500.0
	civ.depth = Config.LAND_DEPTH
	civ.target_depth = Config.LAND_DEPTH
	w.patrol = {"x": 490.0, "dir": 1, "t": 10.0, "life": 90.0, "ph": 0.0, "on": 0.0, "bx": 0.0, "bd": 0.5,
			"leaving": false, "mode": "land", "phase": "descend", "alt": 0.3, "face": 1, "obs": null,
			"land_t": 0.0, "lx": 490.0}
	var x0 := civ.x
	for _i in 30:
		w._update_patrol(DT)
	_ok(civ.x > x0 + 5, "Abwind hat die Figur nicht weggeschoben")


func test_origami_pickup() -> void:
	var w := World.new(null, 14, 4)
	_quiet(w)
	_ok(not w.origami.is_empty(), "keine Origami-Figur platziert")
	var o: Dictionary = w.origami[0]
	_ok(o["kind"] == "einhorn", "Tyrell-Zone sollte das Einhorn haben")
	var p := w.player
	w.scan_charges = 0.0
	var score := w.run.score
	p.x = o["x"] - 8
	p.depth = o["depth"]
	w.update(DT, {})
	_ok(o["taken"] and w.stats["origami"], "Origami nicht aufgehoben")
	_ok(w.run.score == score + Config.POINTS_ORIGAMI, "Punkte")
	_ok(w.scan_charges >= w.scan_max - 0.01, "Scanner nicht voll geladen")
	_ok(w.run.origami == ["EINHORN"], "run.origami")


func test_ramen_cook_greets() -> void:
	var w := World.new(null, 15, 1)
	_quiet(w)
	var r: Dictionary = w.ramen[0]
	var p := w.player
	p.hp = w.run.max_hp - 1
	p.x = r["x"] - 40
	p.depth = 0.3
	w.update(DT, {})
	_ok(r.get("greet", false), "Koch hat nicht gegrüßt")
	var found := false
	for f: Dictionary in w.floaters:
		if String(f["text"]).contains("IRASSHAI"):
			found = true
	_ok(found, "kein IRASSHAI")


func _crowd_around(w: World, n: int = 8, stim_every: int = 3) -> Array:
	var p := w.player
	var humans := w.actors.filter(_human).slice(0, n)
	for i in humans.size():
		var a: Actor = humans[i]
		a.x = p.x + 20 + i * 8
		a.depth = p.depth
		a.target_depth = p.depth
		a.state = "idle"
		a.vx = 0.0
		a.timer = 99
		a.tells["stimulus"] = (i % stim_every == 0)
		a.revealed.erase("stimulus")
	return humans


func test_shout_ducks_crowd_and_reveals_stimulus() -> void:
	var w := World.new(null, 21, 2)
	_quiet(w)
	w.actors = w.actors.filter(func(a: Actor) -> bool: return a.player or not a.is_replicant)
	var s0 := World.SHOUT_SCATTER
	var u0 := World.UNREST_PER_SHOUT
	World.SHOUT_SCATTER = 0.0
	World.UNREST_PER_SHOUT = 0.0
	var crowd := _crowd_around(w)
	_ok(w.shout_crowd() == "ok", "Ruf")
	for _i in int(1.5 / DT):
		w._update_reactions(DT)
	for a: Actor in crowd:
		_ok(a.revealed.has("stimulus"), "Ruf hat REIZ nicht aufgedeckt")
		var want := "freeze" if a.tells["stimulus"] else "duck"
		_ok(a.state == want, "%s statt %s" % [a.state, want])
	_ok(w.shout_crowd() == "cooldown", "Ruf ohne Abklingzeit")
	World.SHOUT_SCATTER = s0
	World.UNREST_PER_SHOUT = u0


func test_shot_passes_over_ducking() -> void:
	var w := World.new(null, 22, 2)
	_quiet(w)
	var p := w.player
	var rep := _first(w.actors, _rep)
	var civ := _first(w.actors, _human)
	rep.x = p.x + 80
	rep.depth = p.depth
	rep.state = "idle"
	rep.timer = 99
	civ.x = p.x + 40
	civ.depth = p.depth
	civ.state = "idle"
	civ.timer = 99
	w.actors = [p, rep, civ]
	w.target = rep
	_ok(w.line_of_fire(rep) == civ, "Passant sollte die Schusslinie blockieren")
	civ.state = "duck"
	civ.timer = 3.0
	_ok(w.line_of_fire(rep) == rep, "Kugel geht nicht über den Geduckten")
	w._panic_area(p.x, 200.0)
	_ok(civ.state == "duck", "Geduckter steht bei Schüssen wieder auf")


func test_shout_wave_reaches_far_later() -> void:
	var w := World.new(null, 23, 2)
	_quiet(w)
	w.actors = w.actors.filter(func(a: Actor) -> bool: return a.player or not a.is_replicant)
	var p := w.player
	var two := w.actors.filter(_npc).slice(0, 2)
	var near: Actor = two[0]
	var far: Actor = two[1]
	for pair: Array in [[near, 15.0], [far, 140.0]]:
		var a: Actor = pair[0]
		a.x = p.x + float(pair[1])
		a.depth = p.depth
		a.target_depth = p.depth
		a.state = "idle"
		a.timer = 99
		a.tells["stimulus"] = false
		a.react_t = 0.2
	w.shout_crowd(160.0)
	for _i in int(0.35 / DT):
		w._update_reactions(DT)
	_ok(near.state in ["duck", "panic"] and far.state == "idle", "Welle wirkt nicht verzögert")
	for _i in int(0.8 / DT):
		w._update_reactions(DT)
	_ok(far.state in ["duck", "panic"], "Ferner Passant hat nicht reagiert")


func test_hold_v_vs_tap() -> void:
	var w := World.new(null, 24, 2)
	_quiet(w)
	var p := w.player
	var civ := _first(w.actors, _human)
	civ.x = p.x + 30
	civ.depth = p.depth
	civ.state = "idle"
	civ.timer = 99
	civ.tells["stimulus"] = false
	w.target = civ
	w._shout_input(DT, true)
	w._shout_input(DT, false)
	_ok(w.talk_cd > 0 and w.shout_cd == 0, "Tippen sollte ansprechen, nicht rufen")
	for _i in int(1.0 / DT):
		w._update_reactions(DT)
	_ok(civ.state == "hands", "Angesprochener hebt nicht die Hände (%s)" % civ.state)
	for _i in int(0.8 / DT):
		w._shout_input(DT, true)
	var r := w.shout_radius()
	w._shout_input(DT, false)
	_ok(w.shout_cd > 0 and w.wave != null and w.wave["R"] == r, "Ruf an die Menge")
	_ok(w.unrest > 0.3, "Ruf erhöht die Unruhe nicht")


func test_groups_loiter_and_are_scannable() -> void:
	var w := World.new(null, 25, 2)
	_quiet(w)
	var grp := w.actors.filter(func(a: Actor) -> bool: return a.group >= 0)
	var side := w.actors.filter(func(a: Actor) -> bool: return a.home != null)
	_ok(grp.size() >= 6 and not side.is_empty(), "keine Gruppen / Gehweg-Passanten")
	_ok(grp.all(func(a: Actor) -> bool: return a.state == "loiter"), "Gruppe nicht loiter")
	for _i in int(3 / DT):
		w.update(DT, {})
	var still := grp.filter(func(a: Actor) -> bool: return a.alive and a.state == "loiter")
	_ok(not still.is_empty() and still.all(func(a: Actor) -> bool: return absf(a.vx) < 1e-6), "Gruppe steht nicht")
	var a: Actor = still[0]
	var p := w.player
	p.x = a.x - 30
	p.depth = maxf(Config.DEPTH_MIN, a.depth)
	w.target = a
	w.scan_charges = 3.0
	_ok(w.scan()[0] == "ok", "Gruppenmitglied nicht scanbar")
	var mn := 9.0
	for x: Actor in side:
		mn = minf(mn, x.depth)
	_ok(mn < Config.DEPTH_MIN, "Gehweg-Band nicht hinter der Spielertiefe")


func test_difficulty_scales_density() -> void:
	var n := {}
	for d: String in ["leicht", "normal", "schwer"]:
		n[d] = World.new(Run.new(5, d), 5, 2).actors.size()
	_ok(n["leicht"] < n["normal"] and n["normal"] < n["schwer"], str(n))


func test_traffic_denser_and_slower_by_zone() -> void:
	var w0 := World.new(null, 7, 0)
	var w2 := World.new(null, 7, 2)
	_ok(w2.traffic_gap < w0.traffic_gap and w2.traffic_slow < w0.traffic_slow, "Zonenverkehr")
	for w: World in [w0, w2]:
		for _i in int(20 / DT):
			w.update(DT, {})
	var near := w2.vehicles.filter(func(v: Dictionary) -> bool: return absf(v["x"] - w2.camera_x) < 330)
	_ok(near.size() >= 3, "Innenstadt-Verkehr zu dünn")
	var vmax := 0.0
	for v: Dictionary in w2.vehicles:
		vmax = maxf(vmax, v["speed"])
	_ok(vmax < 0.8 * 230.0, "dichter Verkehr fährt zu schnell")
	for ld: Array in Config.LANES:
		var q := w2.vehicles.filter(func(v: Dictionary) -> bool: return v["depth"] == ld[0])
		q.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["x"] < b["x"])
		for i in range(q.size() - 1):
			var a: Dictionary = q[i]
			var b: Dictionary = q[i + 1]
			_ok(b["x"] - a["x"] > (a["L"] + b["L"]) * 0.5 - 2.0, "Fahrzeuge überlappen")


func test_parked_cars_block_and_cannot_be_jumped() -> void:
	var w := World.new(null, 7, 2)
	var pk := w.obstacles.filter(func(o: Dictionary) -> bool: return o["kind"] == "parked")
	_ok(pk.size() >= 5, "zu wenig parkende Fahrzeuge")
	var o: Dictionary = pk[0]
	_ok(w.blocked(o["x"], o["d"], 0.0) and w.blocked(o["x"], o["d"], Config.JUMP_V ** 2 / (2 * Config.GRAVITY)),
			"parkendes Auto blockiert nicht")
	for a: Actor in w.actors:
		if a.player:
			continue
		for q: Dictionary in pk:
			_ok(not (absf(a.x - q["x"]) < q["w"] and absf(a.depth - q["d"]) < q["dd"]), "Passant steht im parkenden Auto")


func test_steam_slows_observation() -> void:
	var w := World.new(null, 7, 2)
	_quiet(w)
	var m: Dictionary = w.manholes[0]
	m["base"] = 1.0
	m["every"] = 1e9
	w._update_steam(DT)
	_ok(w.steam_at(m["x"] + m["drift"], m["d"]) > 0.8 and w.steam_at(m["x"] + 200, m["d"]) == 0.0, "steam_at")
	var a := _first(w.actors, _npc)
	w.player.x = m["x"] - 40
	w.player.depth = maxf(Config.DEPTH_MIN, m["d"])
	var gain := {}
	for where: String in ["frei", "dampf"]:
		if where == "dampf":
			a.x = m["x"] + m["drift"]
		else:
			a.x = m["x"] - 80
		a.depth = m["d"]
		a.exposure = 0.0
		w.target = a
		w._observe(0.1)
		gain[where] = a.exposure
	_ok(gain["dampf"] < gain["frei"] * 0.5, str(gain))


func test_i18n_switches_between_german_and_english() -> void:
	I18n.set_lang("de")
	_ok(I18n.t("SEKTOR {}/5", [3]) == "SEKTOR 3/5", "de")
	_ok(I18n.t("Nicht uebersetzt") == "Nicht uebersetzt", "de unbekannt")
	I18n.set_lang("en")
	_ok(I18n.t("SEKTOR {}/5", [3]) == "SECTOR 3/5", "en")
	_ok(I18n.t("Nicht uebersetzt") == "Nicht uebersetzt", "en unbekannt")
	I18n.set_lang("de")


func _init() -> void:
	var names := []
	for m: Dictionary in get_method_list():
		var mn: String = m["name"]
		if mn.begins_with("test_") and not names.has(mn):
			names.append(mn)
	names.sort()                         # wie sorted(globals()) im Original
	var bad := 0
	for mn: String in names:
		cur = mn
		var f0 := fails
		call(mn)
		if fails > f0:
			bad += 1
		else:
			print("  ok   ", mn)
	print("\n%d/%d bestanden" % [names.size() - bad, names.size()])
	quit(1 if bad else 0)
