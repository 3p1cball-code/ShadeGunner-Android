class_name World
extends RefCounted
## Spielwelt und Kern-Loop (sim.World, reine Simulation, kein Rendering).
##
## Der Renderer konsumiert nur diesen Zustand plus die `events`-Liste (Schüsse,
## Tode, Scans ...) für Effekte und Sound. Ereignisse sind Arrays wie die Python-
## Tupel, z. B. ["shot", sx, sd, ex, ed, hit_uid_oder_null].
## Tabellen: DSim (ZONES, VEHICLES, ...), Konstanten: Config.

const DU := Config.DEPTH_UNITS
const _CELL := 64.0

# Test-Schalter: in Python patchen die Tests config.X zur Laufzeit; Konstanten
# sind hier unveränderlich, darum diese drei als überschreibbare statische Werte.
static var SPINNER_LAND_CHANCE: float = Config.SPINNER_LAND_CHANCE
static var SHOUT_SCATTER: float = Config.SHOUT_SCATTER
static var UNREST_PER_SHOUT: float = Config.UNREST_PER_SHOUT

var run: Run
var zone_index: int = 0
var rng: PyRandom
var seed: int = 0
var zone: Dictionary = {}
var length: float = 0.0
var camo: float = 0.0
var time: float = 0.0

var player: Actor
var camera_x: float = 0.0
var actors: Array = []
var _uid: int = 0
var prior: float = 0.0
var bounty: Actor = null
var bounty_desc: Variant = null

var ramen: Array = []
var obstacles: Array = []
var manholes: Array = []
var origami: Array = []
var vehicles: Array = []
var traffic_cd: float = 0.0
var car_escape: float = 0.35
var traffic_gap: float = 0.0
var traffic_slow: float = 1.0
var patrol: Variant = null              # Dictionary oder null
var patrol_cd: Variant = null           # float oder null
var watched: bool = false
# Endboss (nur Tyrell)
var boss: Actor = null
var boss_spawned: bool = false
var boss_line: int = 0
var boss_hits: int = 0
var boss_speak_t: float = 0.0
var blackout_t: float = 0.0
var blackout_at: Variant = null         # float oder null
var _veh_uid: int = 0

var scan_max: int = 0
var scan_charges: float = 0.0
var replicants_total: int = 0
var quota: int = 0
var combo: int = 1
var state: String = "playing"           # playing | zone_clear | failed | finished
var fail_reason: String = ""
var mission_failed: bool = false
var stats: Dictionary = {}

var target: Actor = null
var manual_target: bool = false
var aim_t: float = 0.0
var aim_latch: bool = false
var aiming: bool = false
var shot_cd: float = 0.0
var scan_t: float = -1.0                # >= 0: Scan läuft
var scan_target: Actor = null
var blocker: Actor = null
var events: Array = []
var floaters: Array = []
var log_: Array = []                    # Python: log (Kollision mit globalem log())
var _gate_msg_cd: float = 0.0
var _prev_aim: bool = false
var shout_cd: float = 0.0
var talk_cd: float = 0.0
var shout_hold: float = -1.0            # >= 0: V wird gehalten (Sekunden)
var reactions: Array = []               # [Restzeit, Aktor, Art] - verzögerte Reaktionen
var wave: Variant = null                # sichtbare Rufwelle (Dictionary)
var unrest: float = 0.0                 # Unruhe der Straße 0..1 (steigt mit jedem Ruf)
var shout_count: Variant = null         # Dictionary oder null
var shout_n: int = 0

# Hindernis-Raster (_obs_near)
var _grid: Dictionary = {}
var _grid_obs: Variant = null
var _grid_len: int = -1

var suspicion: float:
	get:
		return run.suspicion
	set(v):
		run.suspicion = v

var points: int:
	get:
		return int(stats["reps"])


## World.new(run, seed, zone_index) - wie World(run=None, seed=0, zone_index=None).
func _init(run_: Run = null, seed_value: int = 0, zone_index_: Variant = null) -> void:
	run = run_ if run_ != null else Run.new(seed_value)
	if zone_index_ != null:
		run.zone_index = int(zone_index_)
	zone_index = run.zone_index
	rng = PyRandom.new(seed_value * 31 + zone_index * 7 + 1)
	seed = seed_value
	zone = (DSim.ZONES[zone_index] as Dictionary).duplicate()
	for k: String in ["density", "sidewalk", "groups"]:
		zone[k] = float(zone.get(k, 0.0)) * run.density
	length = float(zone["length"])
	camo = float(zone["camo"])
	time = 0.0

	player = Actor.new(40.0, 0.7, {"player": true, "look": Looks.player_look(), "uid": 0, "state": "idle"})
	player.hp = run.hp
	camera_x = player.x + 60.0

	actors = []
	var pr: Array = Procgen.populate(rng, zone, 140.0, length + 60.0, 1, zone_index)
	var acts: Array = pr[0]
	_uid = pr[1]
	actors.append_array(acts)
	actors.append(player)
	var nrep := 0
	for a: Actor in acts:
		if a.is_replicant:
			nrep += 1
	prior = float(nrep) / float(maxi(1, acts.size()))
	bounty = _make_bounty(acts)

	# Ramen-Stände (Herzen auffüllen) und Straße: Hindernisse, Verkehr, Patrouillen
	ramen = []
	for x: float in Procgen.ramen_positions(length, seed_value, zone_index):
		ramen.append({"x": x, "depth": 0.16, "used": false, "t": 0.0})
	var rxs := _ramen_xs()
	obstacles = Procgen.obstacles(rng, zone_index, length, rxs)
	# Parkende Fahrzeuge und Gullis: eigener Zufallsstrom (ändert sonst nichts)
	var rng2 := PyRandom.new(seed_value * 613 + zone_index * 17 + 9)
	var dims := {}
	for k: String in DSim.VEHICLES:
		dims[k] = DSim.VEHICLES[k]
	obstacles += Procgen.parked(rng2, zone, DSim.ZONE_PARKED[Py.imod(zone_index, DSim.ZONE_PARKED.size())],
			dims, length, rxs, obstacles)
	var mh: Array = Procgen.manholes(rng2, zone, length, rxs, obstacles)
	manholes = mh[0]
	obstacles += mh[1]
	_unstick(acts)
	origami = _place_origami()
	vehicles = []
	traffic_cd = rng.uniform(3.0, 7.0)
	car_escape = 0.35 if zone_index <= 1 else 0.6   # Chance, in letzter Sekunde nicht erwischt zu werden
	# Je dichter der Verkehr, desto langsamer fließt er (Kolonne statt Raserei)
	var tr_v: Variant = zone.get("traffic")
	traffic_gap = (float(tr_v) if tr_v else 0.0) / maxf(0.3, run.density)
	traffic_slow = (minf(1.0, maxf(0.35, pow(traffic_gap / Config.TRAFFIC_REF, 0.55)))
			if traffic_gap else 1.0)
	patrol = null
	patrol_cd = rng.uniform(16.0, 28.0) if zone.get("patrol") else null
	watched = false
	boss = null
	boss_spawned = false
	boss_line = 0
	boss_hits = 0
	boss_speak_t = 0.0
	blackout_t = 0.0
	blackout_at = rng.uniform(35.0, 85.0) if rng.random() < float(zone.get("blackout", 0)) else null
	_veh_uid = 0
	_prefill_traffic()

	var m := run.mods
	scan_max = int(m["scan_max"])
	scan_charges = float(scan_max)
	replicants_total = 0
	for a: Actor in actors:
		if a.is_replicant:
			replicants_total += 1
	quota = mini(int(zone["quota"]), replicants_total)
	combo = 1
	state = "playing"
	fail_reason = ""
	stats = {"reps": 0, "civs": 0, "escaped": 0, "scans": 0, "shots": 0, "score": 0, "time": 0.0,
			"bounty": false, "origami": false}


func _ramen_xs() -> Array:
	var out := []
	for r: Dictionary in ramen:
		out.append(r["x"])
	return out


## Python-Wahrheitswert (None/0/False/leer -> false).
static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return v != 0.0
	if v is Array or v is Dictionary:
		return not v.is_empty()
	if v is String:
		return v != ""
	return true


static func _tr(s: String, args: Array = []) -> String:
	return I18n.t(s, args)


# ------------------------------------------------------------------ Kopfgeld
## Ein benannter Nexus-6 mit Personenbeschreibung; ab Innenstadt mit Doppelgänger.
func _make_bounty(acts: Array) -> Actor:
	bounty_desc = null
	if zone_index == 4:
		return null            # In Tyrell ist ROY der Boss, kein Kopfgeld im Volk
	var reps := []
	for i in acts.size():
		var a: Actor = acts[i]
		if a.is_replicant:
			reps.append([a.x, i, a])
	if reps.is_empty():
		return null
	reps.sort_custom(func(p: Array, q: Array) -> bool:
		return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]))   # stabil wie sorted()
	var sorted_reps := []
	for e: Array in reps:
		sorted_reps.append(e[2])
	var b: Actor = rng.choice(sorted_reps.slice(Py.ifloordiv(sorted_reps.size(), 3)))
	var zi := zone_index
	b.bounty = true
	b.name = DSim.BOUNTY_NAMES[Py.imod(zi, DSim.BOUNTY_NAMES.size())]
	b.hp = 2 if zi >= 2 else 1
	b.aggressive = zi >= 1
	var lk := b.look
	if b.name == "ZHORA":
		lk.merge({"outfit": "cloak", "head": "long", "umbrella": null, "hair": [14, 14, 20]}, true)
	elif b.name == "PRIS":
		lk.merge({"outfit": "dress", "head": "short", "hair": [226, 210, 160]}, true)
	elif b.name == "ROY":
		var c7: Array = DSprites.COATS[7]
		lk.merge({"outfit": "long", "head": "short", "hair": [214, 220, 226], "coat": (c7[0] as Array).duplicate(),
				"coat_name": c7[1]}, true)
	elif b.name == "LEON":
		lk.merge({"outfit": "jacket", "head": "short"}, true)
	var humans := []
	for a: Actor in acts:
		if not a.is_replicant:
			humans.append(a)
	var desc := Looks.describe(lk)
	var same := []
	for a: Actor in humans:
		if Looks.describe(a.look) == desc:
			same.append(a)
	# Höchstens ein Doppelgänger: alle weiteren bekommen einen anderen Kopf
	for a: Actor in same.slice(1):
		a.look["head"] = "beanie" if a.look["head"] != "beanie" else "cap"
	if zi >= 2 and same.is_empty() and not humans.is_empty():
		var d: Actor = rng.choice(humans)
		for key: String in ["outfit", "head", "coat", "coat_name", "umbrella", "hair"]:
			d.look[key] = lk[key]
	bounty_desc = desc
	return b


# ------------------------------------------------------------------ Hilfen
func _say(text: String) -> void:
	log_.append(text)
	if log_.size() > 5:
		log_.pop_front()


## a: Actor oder _Spot (uid, x, depth).
func floater(text: String, a: Variant, color: Array, t: float = 1.6) -> void:
	var busy := {}
	for f: Dictionary in floaters:
		if f["uid"] == a.uid and f["t"] < f["life"] * 0.8:
			busy[f["slot"]] = true
	var slot := 0
	for i in 8:
		if not busy.has(i):
			slot = i
			break
	floaters.append({"text": text, "x": a.x, "depth": a.depth, "t": 0.0, "life": t, "color": color,
			"uid": a.uid, "slot": slot})


## math.hypot in doppelter Genauigkeit (Vector2 wäre float32).
func dist(a: Variant, b: Variant) -> float:
	var dx: float = a.x - b.x
	var dy: float = (a.depth - b.depth) * DU
	return sqrt(dx * dx + dy * dy)


func confidence_of(a: Actor) -> float:
	return Detection.confidence(a.revealed, a.tells, camo, prior)


func living() -> Array:
	var out := []
	for a: Actor in actors:
		if not a.player and a.alive and not a.escaped:
			out.append(a)
	return out


func reps_remaining() -> int:
	var n := 0
	for a: Actor in actors:
		if a.is_replicant and a.alive and not a.escaped:
			n += 1
	return n


func on_screen(a: Variant, margin: float = 6) -> bool:
	var sx := Persp.screen_x(a.x, a.depth, camera_x)
	return margin < sx and sx < Persp.W - margin


# ------------------------------------------------------------------ Update
## inp: Dictionary (move=[mx, md], sprint, aim, scan, cycle, jump, cancel, shout, shout_crowd)
## oder Array [mx, md] (Kompatibilität) oder null.
func update(dt: float, inp: Variant = null) -> void:
	if not _truthy(inp):
		inp = {}
	if inp is Array:            # Kompatibilität: (mx, md)
		inp = {"move": inp}
	time += dt
	for f: Dictionary in floaters:
		f["t"] += dt
	var keep := []
	for f: Dictionary in floaters:
		if f["t"] < f["life"]:
			keep.append(f)
	floaters = keep
	_update_dead(dt)
	if state != "playing":
		_update_traffic(dt, false)
		_update_steam(dt)
		_update_patrol(dt)
		_update_npcs(dt, true)
		_physics_z(player, dt)
		_animate(player, dt)
		return
	stats["time"] += dt
	_gate_msg_cd = maxf(0.0, _gate_msg_cd - dt)
	shot_cd = maxf(0.0, shot_cd - dt)
	shout_cd = maxf(0.0, shout_cd - dt)
	talk_cd = maxf(0.0, talk_cd - dt)
	_update_reactions(dt)
	if scan_charges < scan_max:
		scan_charges = minf(scan_max, scan_charges + dt / Config.SCAN_RECHARGE_S)
	_update_blackout(dt)

	_update_player(dt, inp)
	_update_target(inp)
	_update_traffic(dt)
	_update_steam(dt)
	_update_patrol(dt)
	_update_npcs(dt)
	_observe(dt)
	_update_ramen(dt)
	_update_origami()
	_update_boss(dt)

	# Kamera: führt in Blickrichtung
	var p := player
	var lead := 46.0 * p.facing
	var cam_t := minf(maxf(p.x + lead, 20.0), length + 40.0)
	camera_x += (cam_t - camera_x) * minf(1.0, dt * 3.0)

	if suspicion >= 1.0 and state == "playing":
		_fail("suspicion")


# ------------------------------------------------------------------ Spieler
func _update_player(dt: float, inp: Dictionary) -> void:
	var p := player
	var m := run.mods
	p.invuln = maxf(0.0, p.invuln - dt)
	p.flash_t = maxf(0.0, p.flash_t - dt)
	var mv: Array = inp.get("move", [0, 0])
	var mx: float = mv[0]
	var md: float = mv[1]
	var aim := _truthy(inp.get("aim"))
	_physics_z(p, dt)

	if p.state == "hurt":
		p.timer -= dt
		p.x = minf(maxf(0.0, p.x + p.knock * dt), length + 2)
		p.knock *= 0.88
		if p.timer <= 0:
			p.state = "idle"
		_animate(p, dt)
		_prev_aim = aim
		return

	if _truthy(inp.get("jump")) and p.z <= 0.0 and p.vz <= 0.0:
		if scan_t >= 0.0:
			scan_t = -1.0
			scan_target = null
			events.append(["scan_abort"])
		p.vz = Config.JUMP_V
		p.z = 0.01
		events.append(["jump", p.uid])

	_shout_input(dt, _truthy(inp.get("shout")))
	if _truthy(inp.get("shout_crowd")):          # Skript/Bot: sofort voller Ruf
		shout_crowd()

	# Scan-Kanal
	if scan_t >= 0.0:
		var t := scan_target
		scan_t += dt
		if t == null or not t.alive or t.escaped or dist(p, t) > Config.SCAN_RANGE * 1.25:
			scan_t = -1.0
			scan_target = null
			events.append(["scan_abort"])
			_say(_tr("Scan abgebrochen."))
		else:
			p.facing = 1 if t.x >= p.x else -1
			if scan_t >= Config.SCAN_TIME * float(m["scan_time"]):
				_finish_scan(t)
		p.state = "scan"
		_animate(p, dt)
		_prev_aim = aim
		return

	# Zielen abbrechen: Waffe senken, ohne zu feuern. Bleibt gesenkt, solange die
	# Zieltaste gedrückt bleibt (aim_latch), bis man sie loslässt.
	if _truthy(inp.get("cancel")) and aiming and not aim_latch:
		aim_latch = true
		aiming = false
		aim_t = 0.0
		blocker = null
		events.append(["holster"])
		_say(_tr("Waffe gesenkt - Schuss abgebrochen."))
	if not aim:
		aim_latch = false
	aim = aim and not aim_latch

	if _truthy(inp.get("scan")):
		scan()

	if aim:
		aim_t += dt
		aiming = true
		p.state = "aim" if shot_cd <= 0.2 else "shoot"
		var t := target
		if t != null:
			p.facing = 1 if t.x >= p.x else -1
			t.aimed_t += dt * 2.0
			blocker = line_of_fire(t)
		else:
			blocker = line_of_fire(null)
	else:
		if _prev_aim and aiming:
			if aim_t >= float(m["aim_min"]):
				fire()
		aiming = false
		aim_t = 0.0
		blocker = null
		var sprint := _truthy(inp.get("sprint"))
		var speed: float = (Config.PLAYER_SPRINT_SPEED if sprint else Config.PLAYER_WALK_SPEED) * float(m["speed"])
		if shot_cd > Config.SHOT_COOLDOWN - 0.25:
			speed *= 0.2
		p.vx = mx * speed
		var nx := minf(maxf(0.0, p.x + p.vx * dt), length + 2)
		var nd := minf(Config.DEPTH_MAX, maxf(Config.DEPTH_MIN, p.depth + md * Config.PLAYER_DEPTH_SPEED * dt))
		if not blocked(p.x, p.depth, p.z) and blocked(nx, nd, p.z):
			if not blocked(nx, p.depth, p.z):
				nd = p.depth
			elif not blocked(p.x, nd, p.z):
				nx = p.x
			else:
				nx = p.x
				nd = p.depth
			p.vx = (nx - p.x) / maxf(dt, 1e-4)
		p.x = nx
		p.depth = nd
		if mx != 0.0:
			p.facing = 1 if mx > 0 else -1
		if shot_cd > Config.SHOT_COOLDOWN - 0.22:
			p.state = "shoot"
		elif mx != 0.0 or md != 0.0:
			p.state = "run" if (sprint and mx != 0.0) else "walk"
		else:
			p.state = "idle"
		if p.x >= length:
			_try_exit()
	_prev_aim = aim
	_animate(p, dt, md)


func exit_open() -> bool:
	if boss_spawned and boss != null:
		return not boss.alive      # Tor öffnet erst, wenn ROY liegt
	return (stats["reps"] >= quota or reps_remaining() == 0
			or stats["reps"] + reps_remaining() < quota)


func _try_exit() -> void:
	if exit_open():
		_zone_clear()
		return
	player.x = length - 0.5
	if _gate_msg_cd <= 0:
		_gate_msg_cd = 2.5
		events.append(["gate_locked"])
		_say(_tr("Ausgang gesperrt: Auftrag {}/{}.", [stats["reps"], quota]))


# ------------------------------------------------------------------ Zielerfassung
func _target_ok(a: Actor) -> bool:
	var rng_ := Config.TARGET_RANGE * (1.7 if manual_target else 1.0)
	return (a != null and a.alive and not a.escaped and not a.player
			and dist(player, a) <= rng_ and on_screen(a, 2))


## Manuelle Zielwahl (Maus): bleibt, bis das Ziel weg/außer Sicht ist.
func set_target(a: Actor) -> bool:
	if a == null or a.player or not a.alive or a.escaped:
		return false
	if scan_t >= 0 and a != scan_target:
		return false
	if a != target:
		target = a
		events.append(["target"])
	manual_target = true
	return true


func _candidates() -> Array:
	var p := player
	var out := []
	for a: Actor in living():
		if dist(p, a) <= Config.TARGET_RANGE and on_screen(a):
			out.append(a)
	return out


func _update_target(inp: Dictionary) -> void:
	if _truthy(inp.get("cycle")):
		cycle_target(int(inp.get("cycle")))
	if _target_ok(target):
		return
	manual_target = false
	if aiming or scan_t >= 0:
		if not _target_ok(target):
			target = null
		return
	var p := player
	var best: Actor = null
	var bs := 1e9
	for a: Actor in _candidates():
		var s := dist(p, a)
		if (a.x - p.x) * p.facing < -4:
			s += 70.0
		if a.state == "attack":
			s -= 200.0
		if s < bs:
			best = a
			bs = s
	target = best


func cycle_target(direction: int = 1) -> void:
	var keyed := []
	var cl := _candidates()
	for i in cl.size():
		var a: Actor = cl[i]
		keyed.append([Persp.screen_x(a.x, a.depth, camera_x), i, a])
	keyed.sort_custom(func(p: Array, q: Array) -> bool:
		return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]))   # stabil wie sorted()
	var cands := []
	for e: Array in keyed:
		cands.append(e[2])
	if cands.is_empty():
		target = null
		return
	var i := 0
	if target != null and cands.has(target):
		i = Py.imod(cands.find(target) + (1 if direction >= 0 else -1), cands.size())
	target = cands[i]
	manual_target = true
	events.append(["target"])

# ------------------------------------------------------------------ Schusslinie
## [x, depth] der Mündung.
func muzzle() -> Array:
	var p := player
	return [p.x + p.facing * 9.0, p.depth]


## Erster Aktor auf der Linie Spieler -> Ziel (oder geradeaus). null = ins Leere.
func line_of_fire(target_: Actor) -> Actor:
	var mz := muzzle()
	var sx: float = mz[0]
	var sd: float = mz[1]
	var tx: float
	var td: float
	if target_ != null:
		tx = target_.x
		td = target_.depth
	else:
		tx = sx + player.facing * Config.SHOOT_RANGE
		td = sd
	var vx := tx - sx
	var vy := (td - sd) * DU
	var L2 := vx * vx + vy * vy
	if L2 < 1e-6:
		return target_
	var best: Actor = target_
	var best_s := 1.0
	if target_ != null and sqrt(L2) > Config.SHOOT_RANGE:
		best = null
		best_s = Config.SHOOT_RANGE / sqrt(L2)
	for a: Actor in living():
		if a == target_ or a.state == "duck":      # Geduckte: die Kugel geht drüber
			continue
		var s := ((a.x - sx) * vx + (a.depth - sd) * DU * vy) / L2
		if 0.02 < s and s < best_s:
			var dx := a.x - (sx + vx * s)
			var dy := (a.depth - sd) * DU - vy * s
			if absf(dx) < 5.5 and absf(dy) < 7.0:
				best = a
				best_s = s
	return best


# ------------------------------------------------------------------ Aktionen
func shout_ready() -> bool:
	return shout_cd <= 0.0


## V tippen = Ansprache an das Ziel; V halten = Ruf an die Menge (Radius wächst
## mit der Haltezeit), ausgelöst beim Loslassen.
func _shout_input(dt: float, held: bool) -> void:
	if held and shout_hold < 0.0:
		shout_hold = 0.0
	if held:
		shout_hold += dt
		return
	if shout_hold < 0.0:
		return
	var h := shout_hold
	shout_hold = -1.0
	if h < Config.SHOUT_TAP:
		address()
	else:
		shout_crowd(shout_radius(h))


func shout_radius(hold: Variant = null) -> float:
	var h: float = shout_hold if hold == null else float(hold)
	var k := minf(1.0, maxf(0.0, (h - Config.SHOUT_TAP) / Config.SHOUT_CHARGE))
	var r0: float = Config.SHOUT_RADIUS[0]
	var r1: float = Config.SHOUT_RADIUS[1]
	return (r0 + (r1 - r0) * k) * float(run.mods["shout_r"])


## „Sie da! Stehen bleiben!“ - spricht nur das gewählte Ziel an.
func address() -> String:
	if state != "playing":
		return "no"
	var t := target
	var p := player
	if talk_cd > 0.0:
		events.append(["no_charge"])
		return "cooldown"
	if t == null or not t.alive or dist(p, t) > Config.TALK_RANGE:
		events.append(["no_target"])
		_say("Niemand in Rufweite angesprochen.")
		return "no_target"
	talk_cd = Config.TALK_CD
	floater(_tr(rng.choice(DSim.TALK_LINES)), p, [255, 255, 255], 1.4)
	events.append(["talk", t.uid])
	reactions.append([t.react_t + 0.1, t, "talk"])
	unrest = minf(1.0, unrest + 0.03)
	return "ok"


## „LAPD! Alle runter!“ - Ruf als Welle: jeder reagiert, wenn sie ihn erreicht.
func shout_crowd(R: Variant = null) -> String:
	if state != "playing":
		return "no"
	if shout_cd > 0.0:
		events.append(["no_charge"])
		return "cooldown"
	var p := player
	var rr: float = float(R) if R != null else shout_radius(Config.SHOUT_TAP + Config.SHOUT_CHARGE)
	shout_cd = Config.SHOUT_CD * float(run.mods["shout_cd"])
	wave = {"x": p.x, "depth": p.depth, "r": 0.0, "R": rr, "t": 0.0}
	events.append(["shout", p.x, rr])
	floater(_tr(rng.choice(DSim.SHOUT_LINES)), p, [255, 255, 255], 1.5)
	for a: Actor in living():
		if a.boss or a.state in ["flee", "attack", "punch", "leap"]:
			continue
		var d := dist(p, a)
		if d <= rr:
			reactions.append([d / Config.SHOUT_SPEED + a.react_t, a, "crowd"])
	shout_n = 0
	shout_count = {"duck": 0, "freeze": 0, "run": 0}
	unrest = minf(1.0, unrest + UNREST_PER_SHOUT)
	return "ok"


func _update_reactions(dt: float) -> void:
	if wave != null:
		var w: Dictionary = wave
		w["t"] += dt
		w["r"] = w["t"] * Config.SHOUT_SPEED
		if w["r"] > w["R"] * 1.15:
			wave = null
	unrest = maxf(0.0, unrest - dt * Config.UNREST_DECAY)
	if reactions.is_empty():
		return
	var due := []
	var keep := []
	for r: Array in reactions:
		r[0] -= dt
		if r[0] <= 0.0:
			due.append(r)
		else:
			keep.append(r)
	reactions = keep
	for r: Array in due:
		var a: Actor = r[1]
		if a.alive and not a.escaped:
			_react(a, r[2])
	if reactions.is_empty() and _truthy(shout_count):
		var c: Dictionary = shout_count
		_say(_tr("Ruf: {} in Deckung, {} reglos, {} rennen.", [c["duck"], c["freeze"], c["run"]]))
		shout_count = null


func _react(a: Actor, kind: String) -> void:
	var p := player
	var u := unrest
	var c: Dictionary = shout_count if (kind == "crowd" and _truthy(shout_count)) else {"duck": 0, "freeze": 0, "run": 0}
	if a.state in ["flee", "attack", "punch", "leap"] or a.z > 0.0:
		return
	# Ertappt? Gescannte/anvisierte Replikanten und ein Teil der übrigen hauen ab -
	# je unruhiger die Straße, desto eher.
	if a.is_replicant and not a.alert:
		var p_alert: float = float(zone["flee"]) * (Config.SHOUT_ALERT if kind == "crowd" else Config.TALK_ALERT) * (1 + 1.5 * u)
		if a.scanned or a.aimed_t > 0.5 or rng.random() < p_alert:
			_alert(a)
			c["run"] += 1
			return
	var new := not a.revealed.has("stimulus")
	a.revealed["stimulus"] = true
	var dur := rng.uniform(Config.SHOUT_DUCK[0], Config.SHOUT_DUCK[1]) * (1.0 - 0.35 * u)
	a.facing = 1 if p.x >= a.x else -1
	if _truthy(a.tells.get("stimulus")):
		a.state = "freeze"                         # starrt den Rufer an
		a.timer = dur
		a.vx = 0.0
		if new and (kind == "talk" or a == target or dist(p, a) < Config.OBSERVE_RANGE):
			floater(_tr("REGLOS"), a, [255, 138, 44], 1.8)
			if a == target:
				events.append(["tell", a.uid, "stimulus"])
		c["freeze"] += 1
	elif kind == "talk":
		a.state = "hands"
		a.timer = rng.uniform(2.2, 3.2)
		a.vx = 0.0
		if not a.is_replicant or rng.random() < 0.8:
			floater(_tr(rng.choice(DSim.TALK_ANSWERS)), a, [162, 168, 180], 1.6)
		if new and a == target:
			floater(_tr("REIZ: NORMAL"), a, [162, 168, 180], 1.4)
	elif not a.is_replicant and rng.random() < SHOUT_SCATTER + 0.5 * u:
		_panic_one(a, p.x)                         # rennt lieber weg
		c["run"] += 1
	else:
		a.state = "duck"
		a.timer = dur
		a.vx = 0.0
		c["duck"] += 1


## Startet einen Scan auf das aktuelle Ziel. Rückgabe [status, aktor].
func scan() -> Array:
	if state != "playing":
		return ["no_target", null]
	if player.z > 0.0:
		return ["airborne", null]
	if scan_charges < 1.0:
		events.append(["no_charge"])
		_say(_tr("Keine Scan-Ladung."))
		return ["no_charge", null]
	var t := target
	if t != null and dist(player, t) > Config.SCAN_RANGE:
		# Gewähltes Ziel bleibt gewählt - kein stilles Umschwenken auf jemand anderen
		events.append(["no_target"])
		_say(_tr("Ziel zu weit für den Scan - näher ran."))
		floater(_tr("ZU WEIT"), t, [162, 168, 180], 1.0)
		return ["too_far", t]
	if t == null:
		var bd := 0.0
		for a: Actor in living():
			if not a.scanned:
				var d := dist(player, a)
				if d <= Config.SCAN_RANGE and (t == null or d < bd):
					t = a
					bd = d
		if t == null:
			events.append(["no_target"])
			return ["no_target", null]
		target = t
	scan_charges -= 1.0
	scan_t = 0.0
	scan_target = t
	stats["scans"] += 1
	events.append(["scan_start", t.uid])
	return ["ok", t]


func _finish_scan(t: Actor) -> void:
	scan_t = -1.0
	scan_target = null
	var deep := bool(run.mods["deep"])
	var close := dist(player, t) <= 70.0
	for n: String in Detection.STRONG_TELLS:
		if n == "serial" and not (close or deep):
			continue
		t.revealed[n] = true
	if deep:
		for n: String in Detection.WEAK_TELLS:
			t.revealed[n] = true
	t.scanned = true
	t.flash_t = 0.35
	var conf := confidence_of(t)
	events.append(["scan_done", t.uid, conf])
	var col: Array = [64, 210, 220] if conf >= 0.66 else ([255, 138, 44] if conf >= 0.33 else [162, 168, 180])
	floater("P %d%%" % Py.round(conf * 100), t, col, 1.4)
	# Reaktion
	if t.is_replicant:
		if rng.random() < float(zone["flee"]):
			_alert(t)
	elif rng.random() < 0.12:
		_panic_one(t, player.x)


## Rückgabe [ergebnis, getroffener Aktor oder null].
func fire() -> Array:
	if shot_cd > 0 or state != "playing":
		return ["cooldown", null]
	shot_cd = Config.SHOT_COOLDOWN
	stats["shots"] += 1
	var t := target
	var hit := line_of_fire(t)
	var mz := muzzle()
	var sx: float = mz[0]
	var sd: float = mz[1]
	var ex: float
	var ed: float
	if hit != null:
		ex = hit.x
		ed = hit.depth
	elif t != null:
		ex = t.x
		ed = t.depth
		var k := Config.SHOOT_RANGE / maxf(1.0, dist(player, t))
		ex = sx + (ex - sx) * k
		ed = sd + (ed - sd) * k
	else:
		ex = sx + player.facing * Config.SHOOT_RANGE
		ed = sd
	events.append(["shot", sx, sd, ex, ed, hit.uid if hit != null else null])
	player.state = "shoot"
	_panic_area(sx, Config.PANIC_RADIUS, hit)
	if hit == null:
		return ["miss", null]
	return [_hit(hit), hit]


func _hit(a: Actor) -> String:
	if a.boss:
		if a.boss_invuln:               # während seiner Rede abgewehrt
			events.append(["boss_blocked"])
			floater(_tr("ABGEWEHRT"), a, [162, 168, 180], 0.9)
			return "blocked"
		a.hp -= 1
		a.flash_t = 0.3
		a.knock = 44.0 * (1 if a.x >= player.x else -1)
		events.append(["boss_hit", a.hp])
		if a.hp <= 0:
			_kill(a)
			events.append(["boss_dead"])
			_say(_tr("ROY deaktiviert."))
			return "boss_dead"
		boss_hits += 1
		if boss_hits >= Config.ROY_PER_LINE and boss_line < Config.ROY_LINES.size() - 1:
			boss_hits = 0
			boss_line += 1
			boss_speak_t = Config.ROY_SPEAK_S
			a.boss_invuln = true
			events.append(["boss_line", boss_line])
		return "boss"
	if a.is_replicant and a.hp > 1:
		a.hp -= 1
		a.flash_t = 0.3
		a.knock = 60.0 * (1 if a.x >= player.x else -1)
		floater(_tr("ZÄH! NOCH EINMAL"), a, [255, 138, 44], 1.4)
		events.append(["tough", a.uid])
		a.alert = false
		a.aggressive = true
		_alert(a)
		return "tough"
	return _kill(a)


## Sofortschuss auf das aktuelle Ziel (Kompatibilität/Tests).
func neutralize() -> Array:
	if target == null or not _target_ok(target):
		_update_target({})
	var a := target
	if a == null or dist(player, a) > Config.SHOOT_RANGE:
		return ["no_target", null]
	shot_cd = 0.0
	return fire()


func _kill(a: Actor) -> String:
	a.alive = false
	a.state = "dead"
	a.dead_t = 0.0
	a.flash_t = 0.25
	a.knock = 26.0 * (1 if a.x >= player.x else -1)
	a.facing = -1 if a.knock > 0 else 1
	if target == a:
		target = null
	if a.is_replicant:
		var pts := Config.POINTS_REPLICANT * combo
		if not a.scanned:
			pts += Config.POINTS_INSTINCT
		run.score += pts
		stats["score"] += pts
		stats["reps"] += 1
		run.totals["reps"] += 1
		floater(_tr("REPLIKANT +{}", [pts]), a, [64, 210, 220], 2.0)
		if combo > 1:
			floater(_tr("KETTE X{}", [combo]), a, [255, 138, 44], 1.6)
		if a.bounty:
			run.score += Config.POINTS_BOUNTY
			stats["score"] += Config.POINTS_BOUNTY
			stats["bounty"] = true
			floater(_tr("KOPFGELD {} +{}", [a.name, Config.POINTS_BOUNTY]), a, [255, 138, 44], 2.6)
			events.append(["bounty", a.uid])
		combo = mini(Config.COMBO_MAX, combo + 1)
		_say(_tr("Kopfgeld kassiert: {}.", [a.name]) if a.bounty else _tr("Replikant deaktiviert."))
		events.append(["kill", a.uid, true])
		if stats["reps"] == quota:
			events.append(["quota"])
			_say(_tr("Auftrag erfüllt - Ausgang offen."))
		return "replicant"
	var w := Config.SUSPICION_WATCHED if watched else 1.0
	suspicion = minf(1.0, suspicion + Config.SUSPICION_PER_CIVILIAN * float(run.mods["susp"]) * w)
	if watched:
		floater(_tr("VOR DEN AUGEN DER POLIZEI"), a, [224, 72, 90], 2.2)
	run.score += Config.POINTS_CIVILIAN
	stats["score"] += Config.POINTS_CIVILIAN
	stats["civs"] += 1
	run.totals["civs"] += 1
	combo = 1
	floater(_tr("MENSCH  {}", [Config.POINTS_CIVILIAN]), a, [224, 72, 90], 2.2)
	_say(_tr("MENSCH getötet! Verdacht steigt."))
	events.append(["kill", a.uid, false])
	if suspicion >= 1.0:
		_fail("suspicion")
	return "civilian"


# ------------------------------------------------------------------ Schaden
## src: Actor oder Fahrzeug-Dictionary.
func hurt_player(src: Variant, knock: float = 90.0, text: String = "-1 INTEGRITÄT") -> bool:
	var p := player
	if p.invuln > 0 or state != "playing":
		return false
	var src_x: float = src["x"] if src is Dictionary else src.x
	p.hp -= 1
	run.hp = p.hp
	p.invuln = 1.3
	p.flash_t = 0.3
	p.state = "hurt"
	p.timer = 0.45
	p.knock = knock * (1 if p.x >= src_x else -1)
	scan_t = -1.0
	scan_target = null
	aiming = false
	events.append(["hurt", p.hp])
	floater(_tr(text), p, [224, 72, 90], 1.4)
	if p.hp <= 0:
		_fail("hp")
	return true


# ------------------------------------------------------------------ Höhe / Hindernisse
func _physics_z(a: Actor, dt: float) -> void:
	if a.z > 0.0 or a.vz > 0.0:
		a.vz -= Config.GRAVITY * dt
		a.z += a.vz * dt
		if a.z <= 0.0:
			a.z = 0.0
			a.vz = 0.0
			events.append(["land", a.uid])


## Hindernisse in der Nähe von x (Raster nach x; neu gebaut, wenn sich die Liste ändert).
func _obs_near(x: float) -> Array:
	var obs := obstacles
	if not is_same(_grid_obs, obs) or _grid_len != obs.size():
		var g := {}
		for o: Dictionary in obs:
			var pad: float = o["w"] + 40.0                      # Reichweite r/look der Abfragen
			var c0 := int(Py.floordiv(o["x"] - pad, _CELL))
			var c1 := int(Py.floordiv(o["x"] + pad, _CELL))
			for c in range(c0, c1 + 1):
				if not g.has(c):
					g[c] = []
				(g[c] as Array).append(o)
		_grid = g
		_grid_obs = obs
		_grid_len = obs.size()
	return _grid.get(int(Py.floordiv(x, _CELL)), [])


func blocked(x: float, d: float, z: float, r: float = 4.0) -> bool:
	for o: Dictionary in _obs_near(x):
		if absf(x - o["x"]) < o["w"] + r and absf(d - o["d"]) < o["dd"] + 0.02 and z < o["h"]:
			return true
	return false


func _obstacle_ahead(a: Actor, look: float = 26.0) -> Variant:
	if a.vx == 0.0:
		return null
	var s := 1 if a.vx > 0 else -1
	for o: Dictionary in _obs_near(a.x):
		var ahead: float = (o["x"] - a.x) * s
		if -o["w"] < ahead and ahead < o["w"] + look and absf(a.depth - o["d"]) < o["dd"] + 0.035:
			return o
	return null

# --- TEIL3 ---
