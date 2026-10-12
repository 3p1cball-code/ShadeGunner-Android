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

# --- TEIL2 ---
