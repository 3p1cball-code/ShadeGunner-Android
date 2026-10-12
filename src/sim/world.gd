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
			if traffic_gap != 0.0 else 1.0)
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

# ------------------------------------------------------------------ Verkehr
## Wer beim Start in einem Hindernis steht (parkendes Auto ...), tritt daneben.
func _unstick(acts: Array) -> void:
	for a: Actor in acts:
		for o: Dictionary in obstacles:
			if absf(a.x - o["x"]) < o["w"] + 3 and absf(a.depth - o["d"]) < o["dd"] + 0.025:
				var up: float = o["d"] - o["dd"] - 0.03
				var dn: float = o["d"] + o["dd"] + 0.03
				a.depth = up if up > Config.NPC_DEPTH_MIN + 0.005 and (a.depth < o["d"] or dn > 0.98) else dn
				a.target_depth = a.depth
				break


func _new_vehicle(lane: float, dr: int, x: Variant = null) -> Variant:
	var kinds: Array = DSim.ZONE_TRAFFIC[Py.imod(zone_index, DSim.ZONE_TRAFFIC.size())]
	var kind: String = rng.choice(kinds)
	if kind == "bus":                                  # keine Bus-Kolonne
		for vb: Dictionary in vehicles:
			if vb["kind"] == "bus" and absf(vb["x"] - camera_x) < 900.0:
				kind = "car"
				break
	var dm: Array = DSim.VEHICLES[kind]
	var L: float = dm[0]
	var h: float = dm[1]
	var sp: float = dm[2]
	sp *= rng.uniform(0.9, 1.15) * traffic_slow
	var vx_: float
	if x == null:
		vx_ = camera_x - dr * (maxf(sp, 120.0) * 0.8 + 300.0)
	else:
		vx_ = float(x)
	for v: Dictionary in vehicles:                               # Einfahrt frei?
		if v["depth"] == lane and absf(v["x"] - vx_) < (v["L"] + L) * 0.5 + 30.0:
			return null
	_veh_uid += 1
	var vseed := rng.randint(0, 9999)
	var react := rng.uniform(0.25, 0.6) * (1.6 if zone_index <= 1 else 0.8)
	var v := {"x": vx_, "depth": lane, "dir": dr, "speed": sp, "vmax": sp, "kind": kind, "L": L, "h": h,
			"seed": vseed, "honk": false, "snd": false, "slow_t": 0.0, "honk_cd": 0.0,
			"react": react, "uid": -1000 - _veh_uid}
	vehicles.append(v)
	return v


## Dichter Verkehr ist schon da, wenn man ankommt (statt erst hereinzufahren).
func _prefill_traffic() -> void:
	if traffic_gap == 0.0 or traffic_slow > 0.6:
		return
	for ld: Array in Config.LANES:
		var lane: float = ld[0]
		var dr: int = ld[1]
		var x := camera_x - dr * 600.0
		while (x - camera_x) * dr < 600.0:
			var v: Variant = _new_vehicle(lane, dr, x)
			var L: float = v["L"] if v != null else 90.0
			if v != null:
				v["snd"] = absf(x - camera_x) < 250        # schon vorbei / zu nah: kein Anfahrtsgeräusch
			x += dr * (L + rng.uniform(1.0, 2.2) * traffic_gap * 60.0 * traffic_slow)


func _update_traffic(dt: float, spawn: bool = true) -> void:
	var p := player
	if spawn and traffic_gap != 0.0:
		traffic_cd -= dt
		if traffic_cd <= 0:
			var ld: Array = rng.choice(Config.LANES)
			if _new_vehicle(ld[0], ld[1]) == null:
				traffic_cd = 0.4                       # Einfahrt zu, gleich nochmal
			else:
				traffic_cd = rng.uniform(0.55, 1.45) * traffic_gap
	# Kolonne: wer aufläuft, bremst auf das Tempo des Vordermanns
	for ld: Array in Config.LANES:
		var lane: float = ld[0]
		var keyed := []
		for j in vehicles.size():
			var vv: Dictionary = vehicles[j]
			if vv["depth"] == lane:
				keyed.append([-vv["x"] * vv["dir"], j, vv])
		keyed.sort_custom(func(pa: Array, qa: Array) -> bool:
			return pa[0] < qa[0] or (pa[0] == qa[0] and pa[1] < qa[1]))   # stabil wie sorted()
		var q := []
		for e: Array in keyed:
			q.append(e[2])
		for i in q.size():
			var v: Dictionary = q[i]
			var vmax: float = v.get("vmax", v["speed"])
			var goal := vmax
			v["honk_cd"] = maxf(0.0, float(v.get("honk_cd", 0.0)) - dt)
			# Spieler steht in der Spur: bremsen statt umfahren (früh = wenig Zeit)
			if p.alive and absf(p.depth - lane) < Config.LANE_HALF + 0.03:
				var ahead: float = (p.x - v["x"]) * v["dir"]
				if 0.0 < ahead and ahead < vmax * 3.0 + v["L"]:
					var need: float = ahead - (v["L"] * 0.5 + 5.0) - v["speed"] * float(v.get("react", 0.35))
					goal = minf(goal, sqrt(maxf(0.0, 2.0 * Config.CAR_BRAKE * maxf(0.0, need))))
			# Stop-and-go: Taxi lädt ein, jemand sucht einen Parkplatz ...
			if float(v.get("halt", 0.0)) > 0.0:
				v["halt"] -= dt
				goal = 0.0
			elif traffic_slow < 0.6 and vmax > 0 and absf(v["x"] - camera_x) < 600 \
					and rng.random() < dt * (0.05 if v["kind"] == "taxi" else 0.012):
				v["halt"] = rng.uniform(1.5, 4.5)
			if i > 0:
				var lv: Dictionary = q[i - 1]
				var gap: float = (lv["x"] - v["x"]) * v["dir"] - (lv["L"] + v["L"]) * 0.5
				var safe := Config.TRAFFIC_GAP + vmax * 0.9
				if gap < safe:
					goal = minf(vmax, maxf(0.0, lv["speed"] + (gap - safe) * 1.6))
				if gap < 3.0:
					v["speed"] = minf(v["speed"], lv["speed"])
			var acc := 70.0 if goal > v["speed"] else 240.0
			v["speed"] += maxf(-acc * dt, minf(acc * dt, goal - v["speed"]))
			# dichter Verkehr: hier und da ein genervtes Meep (nur im Bild)
			if traffic_slow < 0.7 and v["speed"] > 18 and absf(v["x"] - camera_x) < 340 \
					and rng.random() < dt * 0.018:
				events.append(["jam_honk", v["kind"], v["x"] - camera_x])
			# Stau: wer lange steckt, hupt (nur im Bild)
			if vmax > 0 and v["speed"] < vmax * 0.4:
				v["slow_t"] = float(v.get("slow_t", 0.0)) + dt
				if v["slow_t"] > 1.5 and rng.random() < dt * 0.25 and absf(v["x"] - camera_x) < 330:
					events.append(["jam_honk", v["kind"], v["x"] - camera_x])
					v["slow_t"] = 0.0
			else:
				v["slow_t"] = 0.0
	var near_lane := {}
	if not vehicles.is_empty():
		for ld: Array in Config.LANES:
			var lane: float = ld[0]
			var lst := []
			for a: Actor in actors:
				if not a.player and a.alive and not a.escaped and absf(a.depth - lane) < Config.LANE_HALF + 0.045:
					lst.append(a)
			near_lane[lane] = lst
	var n_near := 0
	for w: Dictionary in vehicles:
		if absf(w["x"] - camera_x) < 420:
			n_near += 1
	n_near = maxi(1, n_near)
	var density_k := minf(1.0, 3.0 / n_near)             # viel Verkehr -> leiser
	var keep := []
	for v: Dictionary in vehicles:
		v["x"] += v["dir"] * v["speed"] * dt
		if (v["x"] - camera_x) * v["dir"] > 640.0:
			continue
		keep.append(v)
		var lane: float = v["depth"]
		# Anfahrtsgeräusch, wenn es die Kamera in ~2,5 s erreicht
		if not v.get("snd", true):
			var r_: float = (camera_x - v["x"]) * v["dir"]
			if 0 < r_ and r_ < maxf(v["speed"], 60.0) * 2.5:
				v["snd"] = true
				var vs := minf(1.0, maxf(0.15, v["speed"] / 170.0))          # langsam -> leise
				var vol := maxf(0.18, minf(1.0, (0.20 + 0.80 * vs) * density_k))
				events.append(["vehicle", v["kind"], v["dir"], Py.round_n(vol, 3)])
		# Spieler: Hupen, Treffer
		if p.alive:
			var in_lane := absf(p.depth - lane) < Config.LANE_HALF + 0.02
			var ahead: float = (p.x - v["x"]) * v["dir"]
			# anhupe, wenn ich in der Spur stehe (auch seitlich / halb davor)
			if (absf(p.depth - lane) < Config.LANE_HALF + 0.035 and v["speed"] > 12
					and -v["L"] < ahead and ahead < maxf(v["speed"], 45.0) * 1.5 + v["L"] and v["honk_cd"] <= 0.0):
				v["honk_cd"] = 2.8
				events.append(["honk", v["kind"]])
			if in_lane and absf(p.x - v["x"]) < v["L"] * 0.5 + 3 and p.z < v["h"] * 0.75:
				if ahead > 0.0 and v["speed"] > Config.CAR_DANGER_SPEED:
					# Chance, dass der Fahrer in letzter Sekunde noch bremst (früh seltener)
					if rng.random() < car_escape:
						v["speed"] = minf(v["speed"], 25.0)
						events.append(["honk", v["kind"]])
						_car_bump(v, lane)
					elif hurt_player(v, 60.0, "ANGEFAHREN! -1"):
						_push_out_of_lane(lane)
						events.append(["car_hit"])
				else:
					_car_bump(v, lane)
		# Passanten weichen aus
		for a: Actor in near_lane.get(lane, []):
			var rel: float = (a.x - v["x"]) * v["dir"]
			if -v["L"] < rel and rel < maxf(v["speed"], 30.0) * 2.3 and absf(a.depth - lane) < Config.LANE_HALF + 0.045:
				if a.state in ["duck", "freeze", "hands", "loiter"]:
					a.state = "panic"
					a.timer = 1.5
				if a.dodge_t <= 0.0:
					var side := 1 if a.depth >= lane else -1
					var td := lane + side * (Config.LANE_HALF + 0.07)
					if td < Config.DEPTH_MIN + 0.01 or td > 0.98:
						td = lane - side * (Config.LANE_HALF + 0.07)
					a.target_depth = minf(0.98, maxf(Config.DEPTH_MIN + 0.01, td))
				a.dodge_t = 0.8
	vehicles = keep


func _push_out_of_lane(lane: float) -> void:
	var p := player
	var side := 1 if p.depth >= lane else -1
	p.depth = minf(Config.DEPTH_MAX, maxf(Config.DEPTH_MIN, lane + side * (Config.LANE_HALF + 0.06)))


## Seitlich/stehend gerammt: kurzer Stun, kein Herz.
func _car_bump(v: Dictionary, lane: float) -> void:
	var p := player
	if p.invuln > 0 or state != "playing":
		return
	p.invuln = Config.CAR_BUMP_INVULN
	p.flash_t = 0.2
	p.state = "hurt"
	p.timer = 0.3
	p.knock = 55.0 if p.x >= v["x"] else -55.0
	_push_out_of_lane(lane)
	scan_t = -1.0
	scan_target = null
	aiming = false
	floater(_tr("REMPLER"), p, [255, 182, 72], 1.1)
	events.append(["bump"])


# ------------------------------------------------------------------ Dampf
## 0..1: wie dicht der Dampf an dieser Stelle ist (Gullis / Schlote).
func steam_at(x: float, d: float) -> float:
	var best := 0.0
	for m: Dictionary in manholes:
		var dx: float = x - (m["x"] + m["drift"])
		if absf(dx) < 30 and absf(d - m["d"]) < 0.07:
			var k: float = (1.0 - absf(dx) / 30.0) * (1.0 - absf(d - m["d"]) / 0.07)
			best = maxf(best, m["s"] * k)
	return minf(1.0, best * 1.6)


func _update_steam(dt: float) -> void:
	for m: Dictionary in manholes:
		m["t"] += dt
		var t: float = m["t"]
		var base: float = m["base"] * (0.75 + 0.25 * sin(t * 0.7 + m["ph"]))
		if m["burst"] <= 0.0 and rng.random() < dt / m["every"]:
			m["burst"] = 3.0                                 # Schwall
		if m["burst"] > 0.0:
			m["burst"] -= dt
			base = maxf(base, minf(1.0, m["burst"] / 1.2) * 1.0)
		m["s"] = base
		m["drift"] = 10.0 * sin(t * 0.13 + m["ph"])

# ------------------------------------------------------------------ Polizei-Suchlicht
func _update_patrol(dt: float) -> void:
	var p := player
	if patrol == null:
		if patrol_cd != null and state == "playing":
			patrol_cd = float(patrol_cd) - dt
			if patrol_cd <= 0:
				var zp: Variant = zone.get("patrol")
				patrol_cd = rng.uniform(0.8, 1.2) * (float(zp) if _truthy(zp) else 60.0)
				var dr: int = rng.choice([-1, 1])
				var land := rng.random() < SPINNER_LAND_CHANCE
				var life := rng.uniform(18.0, 25.0) if not land else 90.0
				var ph := rng.random() * 6.28
				patrol = {"x": camera_x - dr * 330.0, "dir": dr, "t": 0.0, "life": life,
						"ph": ph, "on": 0.0, "bx": 0.0, "bd": 0.5, "leaving": false,
						"mode": "land" if land else "fly", "phase": "fly", "alt": 1.0, "face": dr,
						"obs": null, "land_t": 0.0}
				events.append(["patrol"])
				_say(_tr("Polizei-Spinner mit Suchlicht über der Straße."))
		watched = false
		for a: Actor in actors:
			a.lit_t = 0.0
		return
	var P: Dictionary = patrol
	P["t"] += dt
	var t: float = P["t"]
	if (t > P["life"] or state != "playing") and not P["leaving"]:
		if P["alt"] < 1.0:
			if P["phase"] != "lift":
				_spinner_liftoff(P)
		else:
			P["leaving"] = true
	if P["leaving"]:
		P["x"] += P["dir"] * 140.0 * dt
		P["on"] = maxf(0.0, P["on"] - dt * 1.5)
		if absf(P["x"] - camera_x) > 420.0:
			patrol = null
			return
	elif P["mode"] == "land" and (P["phase"] != "fly" or t > 4.0):
		_update_landing(P, dt)
	else:
		var goal := p.x + 40.0 * sin(t * 0.23)
		var sp := 150.0 if absf(goal - P["x"]) > 120 else 34.0
		P["x"] += maxf(-sp * dt, minf(sp * dt, goal - P["x"]))
		if absf(goal - P["x"]) < 160:
			P["on"] = minf(1.0, P["on"] + dt * 0.8)
	if P["phase"] == "landed":
		# Suchlicht vom Bug über die Straße vor dem Spinner
		P["bx"] = P["x"] + P["face"] * (72.0 + 40.0 * sin(t * 0.5 + P["ph"]))
		P["bd"] = 0.5 + 0.4 * sin(t * 0.37 + P["ph"] * 1.7)
	else:
		P["bx"] = P["x"] + 78.0 * sin(t * 0.52 + P["ph"])
		P["bd"] = 0.55 + 0.38 * sin(t * 0.39 + P["ph"] * 1.7)
	var lit_on: bool = P["on"] > 0.5
	watched = lit_on and in_beam(p)
	for a: Actor in actors:
		if a.player or not a.alive or a.escaped:
			continue
		if lit_on and in_beam(a):
			a.lit_t += dt
			if _truthy(a.tells.get("pupils")) and a.glint_t <= 0 and int(a.lit_t * 1.25) != int((a.lit_t - dt) * 1.25):
				a.glint_t = 0.3
				_glint_seen(a, "SUCHLICHT: AUGENREFLEX", Config.OBSERVE_RANGE * 1.3)
			elif not _truthy(a.tells.get("pupils")) and a.lit_t > 1.6 and not a.revealed.has("pupils") \
					and dist(p, a) <= Config.OBSERVE_RANGE * 1.3:
				a.revealed["pupils"] = true
				if a == target:
					floater("SUCHLICHT: AUGEN NORMAL", a, [162, 168, 180], 1.4)
		else:
			a.lit_t = maxf(0.0, a.lit_t - dt * 2.0)


# ------------------------------------------------------------------ Spinner-Landung
## Freier Platz auf dem Mittelstreifen vor dem Spieler (keine Hindernisse,
## kein Nudelstand, nicht am Tor). null = keiner.
func _land_spot() -> Variant:
	var p := player
	var base := p.x + p.facing * 95.0
	for off: float in [0.0, 60.0, -60.0, 130.0, -130.0, 210.0]:
		var x := minf(length - 130.0, maxf(130.0, base + off))
		var bad := false
		for r: Dictionary in ramen:
			if absf(x - r["x"]) < 120:
				bad = true
				break
		if bad:
			continue
		for o: Dictionary in obstacles:
			if absf(x - o["x"]) < o["w"] + 60 and absf(o["d"] - Config.LAND_DEPTH) < 0.12:
				bad = true
				break
		if bad:
			continue
		return x
	return null


func _spinner_liftoff(P: Dictionary) -> void:
	P["phase"] = "lift"
	if P["obs"] != null and obstacles.has(P["obs"]):
		obstacles.erase(P["obs"])
	P["obs"] = null
	events.append(["spinner_lift", P["face"]])


## Polizei-Spinner landet auf dem Mittelstreifen: Abwind schiebt alles weg,
## dann leuchtet er die Straße vom Boden aus ab und hebt wieder ab.
func _update_landing(P: Dictionary, dt: float) -> void:
	var p := player
	var ph: String = P["phase"]
	if ph == "fly":
		var lx: Variant = _land_spot()
		if lx == null:
			P["mode"] = "fly"
			return
		P["phase"] = "descend"
		P["lx"] = lx
		P["face"] = 1 if p.x >= float(lx) else -1
		events.append(["spinner_land", P["face"]])
		_say(_tr("Polizei-Spinner setzt zur Landung an - Kontrolle!"))
	elif ph == "descend":
		var dx: float = P["lx"] - P["x"]
		P["x"] += maxf(-90.0 * dt, minf(90.0 * dt, dx))
		P["on"] = maxf(0.0, P["on"] - dt * 1.5)
		if absf(dx) < 30.0:
			P["alt"] = maxf(0.0, P["alt"] - dt / Config.LAND_DESCENT_S)
		if P["alt"] <= 0.0:
			P["phase"] = "landed"
			P["land_t"] = rng.uniform(Config.LAND_TIME[0], Config.LAND_TIME[1])
			P["obs"] = {"x": P["x"], "d": Config.LAND_DEPTH, "w": 40.0, "dd": 0.07, "h": 60.0, "kind": "spinner", "seed": 0}
			obstacles.append(P["obs"])
			P["tt"] = 0.0
			events.append(["spinner_touch"])
	elif ph == "landed":
		P["land_t"] -= dt
		P["tt"] = float(P.get("tt", 0.0)) + dt
		P["on"] = minf(1.0, P["on"] + dt * 1.2)
		if P["land_t"] <= 0.0:
			_spinner_liftoff(P)
	elif ph == "lift":
		P["on"] = maxf(0.0, P["on"] - dt * 2.0)
		P["alt"] = minf(1.0, P["alt"] + dt / Config.LAND_ASCENT_S)
		if P["alt"] >= 1.0:
			P["mode"] = "fly"
			P["phase"] = "fly"
			P["leaving"] = true
	# Abwind der Turbinen beim Landen/Abheben: schiebt Figuren vom Landeplatz weg
	if P["phase"] in ["descend", "lift", "landed"] and P["alt"] < 0.7:
		var k: float = 1.0 - P["alt"] / 0.7
		if P["phase"] == "landed":
			k = maxf(0.0, 1.0 - float(P.get("tt", 0.0)) * 0.8)
		if k > 0.0:
			for a: Actor in actors:
				if not a.alive or a.escaped:
					continue
				var dxa: float = a.x - P["x"]
				if absf(dxa) < 75.0 and absf(a.depth - Config.LAND_DEPTH) < 0.3:
					var s := 1.0 if dxa >= 0 else -1.0
					var nx := a.x + s * Config.LAND_PUSH * k * dt
					if not blocked(nx, a.depth, a.z) or blocked(a.x, a.depth, a.z):
						a.x = nx
		P["wash"] = k
	else:
		P["wash"] = 0.0


func in_beam(a: Actor) -> bool:
	if patrol == null:
		return false
	var P: Dictionary = patrol
	var u: float = (a.x - P["bx"]) / 34.0
	var w: float = (a.depth - P["bd"]) / 0.13
	return u * u + w * w < 1.0


func _glint_seen(a: Actor, text: String, rng_: float) -> void:
	if a.revealed.has("pupils") or dist(player, a) > rng_:
		return
	a.revealed["pupils"] = true
	floater(_tr(text), a, [255, 138, 44], 1.6)
	events.append(["tell", a.uid, "pupils"])


# ------------------------------------------------------------------ Ramen
## Kurz am Nudelstand stehen bleiben füllt ein Herz auf (einmal pro Stand).
## Der Koch ruft wie im White Dragon: „Akimashita! Irasshai!“ - ein Platz ist frei.
func _update_ramen(dt: float) -> void:
	var p := player
	for i in ramen.size():
		var r: Dictionary = ramen[i]
		if not _truthy(r.get("greet")) and absf(p.x - r["x"]) < Config.RAMEN_RANGE + 44 and p.depth < 0.7:
			r["greet"] = true
			var cook := _Spot.new(-300 - i, r["x"], r["depth"])
			if r["used"]:
				continue
			if p.hp >= run.max_hp:
				floater(_tr("FUTATSU DE JUBUN!"), cook, [214, 220, 226], 2.4)
				_say(_tr("Koch: Zwei reichen. (Integrität ist voll.)"))
			else:
				floater(_tr("IRASSHAI! PLATZ FREI!"), cook, [255, 138, 44], 2.4)
				_say(_tr("Koch: Akimashita! Ein Platz an der Theke ist frei."))
			events.append(["greet"])
	if p.hp >= run.max_hp:
		for r: Dictionary in ramen:
			r["t"] = 0.0
		return
	for r: Dictionary in ramen:
		if r["used"]:
			r["t"] = 0.0
			continue
		if absf(p.x - r["x"]) < Config.RAMEN_RANGE and p.depth < 0.6 and p.z <= 0.0:
			r["t"] += dt
			if r["t"] >= Config.RAMEN_TIME:
				r["used"] = true
				p.hp = mini(run.max_hp, p.hp + 1)
				run.hp = p.hp
				events.append(["ramen"])
				floater(_tr("RAMEN  +1 ♥"), p, [255, 138, 44], 2.2)
				_say(_tr("Am Nudelstand gestärkt: +1 Integrität."))
		else:
			r["t"] = maxf(0.0, r["t"] - dt)


# ------------------------------------------------------------------ Origami
## Eine gefaltete Figur pro Zone (eigener Zufallsstrom - ändert sonst nichts).
func _place_origami() -> Array:
	var orng := PyRandom.new(seed * 977 + zone_index * 31 + 5)
	var kn: Array = DSim.ORIGAMI[Py.imod(zone_index, DSim.ORIGAMI.size())]
	for _i in 40:
		var x := orng.uniform(0.15, 0.92) * length
		var band: Array = orng.choice(Config.OBSTACLE_BANDS)
		var d := orng.uniform(band[0], band[1])
		var bad := false
		for o: Dictionary in obstacles:
			if absf(x - o["x"]) < o["w"] + 20 and absf(d - o["d"]) < o["dd"] + 0.05:
				bad = true
				break
		if bad:
			continue
		for r: Dictionary in ramen:
			if absf(x - r["x"]) < 70:
				bad = true
				break
		if bad:
			continue
		return [{"x": x, "depth": d, "kind": kn[0], "name": kn[1], "taken": false, "seed": orng.randint(0, 999)}]
	return []


func _update_origami() -> void:
	var p := player
	for o: Dictionary in origami:
		if o["taken"] or absf(p.x - o["x"]) > 11.0 or absf(p.depth - o["depth"]) > 0.065:
			continue
		o["taken"] = true
		stats["origami"] = true
		run.origami.append(o["name"])
		run.score += Config.POINTS_ORIGAMI
		stats["score"] += Config.POINTS_ORIGAMI
		scan_charges = float(scan_max)
		floater(_tr("ORIGAMI: {}  +{}", [_tr(o["name"]), Config.POINTS_ORIGAMI]), p, [214, 220, 226], 2.6)
		_say(_tr("Gaff war hier. Scanner wieder voll geladen."))
		events.append(["origami"])


# ------------------------------------------------------------------ Endboss ROY
func _spawn_boss() -> void:
	var look := Looks.random_look(rng, 900)
	look.merge({"outfit": "long", "head": "short", "umbrella": null, "hair": [214, 220, 226],
			"coat": [22, 22, 28], "coat_name": "schwarz", "collar": true, "bag": null,
			"wf": 1.12, "hf": 1.07, "cig": false, "led": false, "mask": false, "old": false}, true)
	var b := Actor.new(minf(length - 70.0, player.x + 120.0), player.depth, {
		"look": look, "uid": 900, "is_replicant": true, "facing": -1, "speed": 24.0,
		"phase": 0.0, "target_depth": player.depth})
	b.hp = Config.ROY_HP
	b.aggressive = true
	b.boss = true
	b.name = "ROY"
	b.state = "idle"
	b.timer = 99.0
	b.boss_invuln = true
	actors.append(b)
	boss = b
	boss_spawned = true
	boss_line = 0
	boss_hits = 0
	boss_speak_t = Config.ROY_SPEAK_S + 0.8
	events.append(["boss"])
	target = b
	manual_target = true


func _update_boss(dt: float) -> void:
	if zone_index != 4 or state != "playing":
		return
	if not boss_spawned:
		# ROY tritt erst auf, wenn der Auftrag in Tyrell erledigt ist (Quote erfüllt)
		if stats["reps"] >= quota and player.x > length - Config.ROY_TRIGGER:
			_spawn_boss()
		return
	var b := boss
	if b == null or not b.alive:
		return
	if boss_speak_t > 0.0:            # während der Rede: stehen, unverwundbar
		boss_speak_t -= dt
		b.boss_invuln = true
		b.state = "idle"
		b.vx = 0.0
		b.timer = 99.0
		b.facing = 1 if player.x >= b.x else -1
		if boss_speak_t <= 0.0:
			boss_speak_t = 0.0
	else:
		b.boss_invuln = false
		if not (b.state in ["attack", "punch", "leap"]):   # nach der Rede angreifen
			b.alert = true
			b.aggressive = true
			b.state = "attack"
			b.timer = 99.0


# ------------------------------------------------------------------ Stromausfall
func _update_blackout(dt: float) -> void:
	if blackout_at != null and time >= float(blackout_at):
		blackout_at = null
		blackout_t = 9.0
		events.append(["blackout"])
		_say(_tr("Stromausfall! Im Dunkeln leuchten Replikantenaugen."))
	if blackout_t > 0.0:
		blackout_t -= dt
		if blackout_t <= 0.0:
			blackout_t = 0.0
			events.append(["blackout_end"])


func _fail(reason: String) -> void:
	if state != "playing":
		return
	state = "failed"
	fail_reason = reason
	if reason == "hp":
		player.alive = false
		player.state = "dead"
		player.dead_t = 0.0
	events.append(["fail", reason])

# ------------------------------------------------------------------ NPC-Verhalten
func _alert(a: Actor) -> void:
	if a.alert or not a.alive:
		return
	a.alert = true
	if a.aggressive:
		a.state = "attack"
		a.timer = 99.0
		events.append(["attack", a.uid])
	else:
		a.state = "flee"
		a.timer = 99.0
		events.append(["flee", a.uid])
	a.target_depth = rng.uniform(Config.DEPTH_MIN, 0.95)


func _panic_one(a: Actor, src_x: float) -> void:
	if not a.alive or a.state in ["flee", "attack"]:
		return
	if a.state == "duck":            # wer am Boden liegt, bleibt unten
		a.timer = maxf(a.timer, 2.0)
		return
	a.state = "panic"
	a.timer = rng.uniform(2.5, 4.5)
	a.facing = 1 if a.x >= src_x else -1
	a.target_depth = rng.uniform(Config.DEPTH_MIN, 0.95)


func _panic_area(x: float, radius: float, exclude: Actor = null) -> void:
	for a: Actor in living():
		if a == exclude:
			continue
		if absf(a.x - x) < radius:
			if a.is_replicant and not a.alert and rng.random() < 0.35 and (a.scanned or a.aimed_t > 0.5):
				_alert(a)
			else:
				_panic_one(a, x)


func _update_npcs(dt: float, frozen: bool = false) -> void:
	var p := player
	var m := run.mods
	var L := length
	for a: Actor in actors:
		if a.player or not a.alive or a.escaped:
			continue
		a.flash_t = maxf(0.0, a.flash_t - dt)
		a.attack_cd = maxf(0.0, a.attack_cd - dt)
		if not (aiming and target == a):
			a.aimed_t = maxf(0.0, a.aimed_t - dt)
		# Augenreflex
		if a.glint_t > 0:
			a.glint_t -= dt
		var dark := blackout_t > 0.0
		if _truthy(a.tells.get("pupils")):
			a.glint_next -= dt * float(m["glint"]) * (4.0 if dark else 1.0)
			if a.glint_next <= 0:
				a.glint_t = 0.45 if dark else 0.24
				a.glint_next = rng.uniform(5.0, 10.0)
				if dark:
					_glint_seen(a, "AUGENREFLEX IM DUNKELN", Config.TARGET_RANGE)
				elif a == target:
					_glint_seen(a, "AUGENREFLEX!", Config.OBSERVE_RANGE)
		a.dodge_t = maxf(0.0, a.dodge_t - dt)
		_physics_z(a, dt)
		if frozen and a.state in ["attack", "punch", "leap"]:
			a.state = "walk"
			a.timer = 4.0
		var st := a.state
		a.timer -= dt
		if st == "walk":
			a.vx = a.facing * a.speed
			if a.timer <= 0:
				if not _truthy(a.tells.get("gait")) and rng.random() < 0.35:
					a.state = "idle"
					a.timer = rng.uniform(1.5, 5.0)
				else:
					a.timer = rng.uniform(3.0, 9.0)
					if rng.random() < 0.3:
						var lo := Config.DEPTH_MIN + 0.02
						var hi := 0.97
						if a.home != null:
							lo = a.home[0]
							hi = a.home[1]
						a.target_depth = rng.uniform(lo, hi)
			if a.x < 30 and a.facing < 0 or a.x > L + 80 and a.facing > 0:
				a.facing = -a.facing
		elif st == "idle":
			a.vx = 0.0
			if a.timer <= 0:
				a.state = "walk"
				a.facing = rng.choice([-1, 1])
				a.timer = rng.uniform(3.0, 9.0)
		elif st == "panic":
			a.vx = a.facing * 52.0
			if a.timer <= 0:
				a.state = "walk"
				a.timer = rng.uniform(3.0, 6.0)
		elif st in ["duck", "freeze", "hands"]:
			a.vx = 0.0
			if a.timer <= 0:
				if a.group >= 0 and absf(a.x - a.gx) < 30:
					a.state = "loiter"
					a.timer = rng.uniform(8.0, 30.0)
					a.facing = 1 if a.gx >= a.x else -1
				else:
					a.state = "idle"                   # erst umsehen, dann weiter
					a.timer = rng.uniform(0.8, 2.0)
					a.facing = rng.choice([-1, 1])
		elif st == "loiter":
			# Gruppe: stehen, zur Mitte schauen, ab und zu gestikulieren
			a.vx = 0.0
			a.facing = 1 if a.gx >= a.x else -1
			if a.timer <= 0:
				a.state = "walk"
				a.timer = rng.uniform(4.0, 9.0)
				a.facing = rng.choice([-1, 1])
				a.group = -1
		elif st == "cower":
			a.vx = 0.0
			if a.timer <= 0 and a.aimed_t <= 0.1:
				a.state = "walk"
				a.facing = 1 if a.x >= p.x else -1
				a.timer = 3.0
		elif st == "flee":
			a.facing = 1 if a.x >= p.x else -1
			a.vx = a.facing * 76.0 * float(m["flee"])
			var gone := absf(a.x - p.x) > 360.0 or a.x < -60 or a.x > L + 200
			if gone and not frozen and not on_screen(a, -30):
				_escape(a)
				continue
		elif st == "attack":
			a.facing = 1 if p.x >= a.x else -1
			var dx := absf(p.x - a.x)
			var dd := absf(p.depth - a.depth)
			a.target_depth = p.depth
			var agile := zone_index >= 2 or a.bounty
			if dx < 15.0 and dd < 0.08 and a.attack_cd <= 0 and p.alive:
				a.state = "punch"
				a.timer = 0.42
				a.attack_cd = 1.7
				a.vx = 0.0
				a.phase = 0.0
				a.hit_done = false
				events.append(["punch", a.uid])
			elif (agile and 36.0 < dx and dx < 85.0 and dd < 0.12 and a.attack_cd <= 0 and a.z <= 0
					and p.alive and rng.random() < dt * 1.4):
				# Nexus-Sprungangriff: ausweichen per Sprung oder Tiefenschritt
				a.state = "leap"
				a.vz = 150.0
				a.z = 0.01
				a.vx = a.facing * minf(220.0, dx * 3.4)
				a.timer = 1.2
				a.attack_cd = 2.4
				a.hit_done = false
				events.append(["leap", a.uid])
			else:
				a.vx = a.facing * (88.0 if dx > 15 else 0.0)
		elif st == "leap":
			if not a.hit_done and absf(p.x - a.x) < 14.0 and absf(p.depth - a.depth) < 0.09 \
					and p.z < Config.JUMP_SAFE_Z:
				a.hit_done = true
				hurt_player(a, 120.0)
			if a.z <= 0.0 and a.vz <= 0.0 and a.timer < 1.1:
				a.state = "attack"
				a.vx = 0.0
		elif st == "punch":
			a.vx = 0.0
			if a.timer < 0.22 and not a.hit_done:
				a.hit_done = true
				if absf(p.x - a.x) < 22.0 and absf(p.depth - a.depth) < 0.1:
					if p.z < Config.JUMP_SAFE_Z:
						hurt_player(a)
					else:
						floater(_tr("AUSGEWICHEN"), p, [64, 210, 220], 0.9)
			if a.timer <= 0:
				a.state = "attack"
		# Auf Zielen reagieren
		if a.aimed_t > 0.9 and a.state in ["walk", "idle", "panic", "loiter"]:
			if a.is_replicant and rng.random() < dt * 0.9:
				_alert(a)
			elif not a.is_replicant:
				a.state = "cower"
				a.timer = 1.2
		# Hindernisse: Replikanten auf der Flucht springen drüber, alle anderen gehen außen herum
		if a.z <= 0.0 and not (a.state in ["punch", "cower", "idle", "duck", "freeze", "hands", "loiter"]):
			var o: Variant = _obstacle_ahead(a)
			if o != null:
				if a.is_replicant and a.state in ["flee", "attack"] and zone_index >= 1 and o["h"] < 13:
					a.vz = 135.0
					a.z = 0.01
				elif a.dodge_t <= 0.0:
					var up: float = o["d"] - o["dd"] - 0.05
					var dn: float = o["d"] + o["dd"] + 0.05
					var td := up if (absf(a.depth - up) < absf(a.depth - dn) and up > Config.DEPTH_MIN) else dn
					if td > 0.99:
						td = up
					a.target_depth = td
					a.dodge_t = 0.5
		# Bewegung
		var nx := a.x + (a.vx + a.knock) * dt
		if not blocked(a.x, a.depth, a.z, 2.0) and blocked(nx, a.depth, a.z, 2.0):
			nx = a.x
			if a.state == "walk" and a.dodge_t <= 0.0:
				a.facing = -a.facing
				a.timer = rng.uniform(2.0, 5.0)
		a.x = nx
		a.knock *= 0.85
		var ddp := a.target_depth - a.depth
		var sp := 0.45 if a.dodge_t > 0 else (0.35 if a.state in ["flee", "panic", "attack", "leap"] else 0.08)
		a.depth += maxf(-sp * dt, minf(sp * dt, ddp))
		a.depth = minf(Config.DEPTH_MAX, maxf(Config.NPC_DEPTH_MIN, a.depth))
		_animate(a, dt)


func _escape(a: Actor) -> void:
	a.escaped = true
	a.alive = false
	if target == a:
		target = null
	if a.is_replicant:
		stats["escaped"] += 1
		run.totals["escaped"] += 1
		run.score += Config.POINTS_ESCAPE
		stats["score"] += Config.POINTS_ESCAPE
		suspicion = minf(1.0, suspicion + Config.SUSPICION_PER_ESCAPE)
		combo = 1
		events.append(["escape", a.uid])
		_say(_tr("Ein Replikant ist entkommen."))


func _update_dead(dt: float) -> void:
	for a: Actor in actors:
		if not a.alive and not a.escaped:
			a.dead_t += dt
			a.x += a.knock * dt
			a.knock *= 0.82
			if a.z > 0.0 or a.vz != 0.0:
				a.vz = minf(a.vz, 0.0)
				_physics_z(a, dt)
			_animate(a, dt)


# ------------------------------------------------------------------ Beobachtung
func _observe(dt: float) -> void:
	var p := player
	var rate := float(run.mods["observe"])
	for a: Actor in living():
		var d := dist(p, a)
		if d > Config.OBSERVE_RANGE:
			a.exposure = maxf(0.0, a.exposure - dt)
			continue
		var focus := a == target
		var fog := steam_at(a.x, a.depth)               # im Dampf sieht man fast nichts
		a.exposure += dt * rate * (1.0 if focus else 0.2) * (1.0 - 0.75 * fog)
		if a.exposure >= Config.OBSERVE_SECONDS:
			a.exposure = 0.0
			var remaining := []
			for tn: String in Detection.WEAK_TELLS:
				if not a.revealed.has(tn):
					remaining.append(tn)
			if not remaining.is_empty():
				var t: String = remaining[0]
				a.revealed[t] = true
				if focus:
					var lbl := _tr(Detection.TELLS[t][3])
					var present := _truthy(a.tells.get(t))
					floater(_tr("{}: AUFFÄLLIG", [lbl]) if present else _tr("{}: NORMAL", [lbl]), a,
							[255, 138, 44] if present else [162, 168, 180], 1.6)
					events.append(["tell", a.uid, t])


# ------------------------------------------------------------------ Animation
func _animate(a: Actor, dt: float, depth_move: float = 0) -> void:
	if not a.alive and not a.escaped:
		a.anim = "die"
		var nd := Looks.frame_count("die")
		a.phase = minf(1.0, a.dead_t / 0.9)
		a.frame = mini(nd - 1, int(a.phase * (nd - 1) + 0.0001))
		return
	var st := a.state
	var speed := absf(a.vx)
	if (a.z > 0.0 or st == "leap") and not (st in ["aim", "shoot", "hurt"]):
		a.anim = "jump"
		a.frame = 0
		return
	var anim := "idle"
	if st in ["walk", "panic", "flee", "attack", "run"] or (a.player and st in ["walk", "run"]):
		var moving := speed > 1.0 or (a.player and depth_move != 0.0)
		if a.player:
			anim = "run" if st == "run" else ("walk" if moving else "idle")
		elif st == "panic":
			anim = "panic" if moving else "idle"
		elif st in ["flee", "attack"]:
			anim = "run" if moving else "idle"
		else:
			anim = "walk" if moving else "idle"
		if anim in ["walk", "run", "panic"]:
			var adv := maxf(speed, 26.0 if (a.player and depth_move != 0.0) else 0.0)
			a.phase = Py.mod(a.phase + adv * dt / (Config.STRIDE_UNITS * (1.6 if anim != "walk" else 1.0)), 1.0)
		else:
			a.phase = Py.mod(a.phase + dt * 0.4, 1.0)
	elif st == "idle":
		anim = "idle"
		a.phase = Py.mod(a.phase + dt * 0.4, 1.0)
	elif st == "cower":
		anim = "cower"
		a.phase = Py.mod(a.phase + dt * 2.0, 1.0)
	elif st == "duck":
		anim = "duck"
		a.phase = Py.mod(a.phase + dt * 1.5, 1.0)
	elif st == "hands":
		anim = "hands"
		a.phase = Py.mod(a.phase + dt * 1.2, 1.0)
	elif st == "loiter":
		anim = "talk"
		a.phase = Py.mod(a.phase + dt * (0.35 + 0.1 * Py.imod(a.uid, 3)), 1.0)
	elif st == "punch":
		anim = "punch"
		a.phase = minf(0.99, 1.0 - maxf(0.0, a.timer) / 0.42)
	elif st in ["aim", "shoot", "scan", "hurt"]:
		anim = st
		if st == "shoot":
			a.phase = minf(0.99, (Config.SHOT_COOLDOWN - shot_cd) / 0.25)
		else:
			a.phase = Py.mod(a.phase + dt * 2.0, 1.0)
	else:
		anim = "idle"
	a.anim = anim
	var n := Looks.frame_count(anim)
	a.frame = Py.imod(int(a.phase * n), n)


# ------------------------------------------------------------------ Zonen
func _zone_clear() -> void:
	if state != "playing":
		return
	var missed: bool = stats["reps"] < quota
	state = "zone_clear"
	mission_failed = missed
	if missed:
		suspicion = minf(1.0, suspicion + 0.15)
	else:
		var bonus: int = 250 + 50 * (int(stats["reps"]) - quota)
		run.score += bonus
		stats["score"] += bonus
	run.hp = player.hp
	for k: String in ["scans", "shots"]:
		run.totals[k] += stats[k]
	run.totals["time"] += stats["time"]
	events.append(["zone_clear", missed])
	_say(_tr("Zone '{}' geschafft.", [_tr(zone["name"])]))


## Neue World für die nächste Zone (oder null, wenn Tyrell geschafft).
func next_world(seed_value: Variant = null) -> World:
	if zone_index + 1 >= DSim.ZONES.size():
		return null
	run.zone_index = zone_index + 1
	run.suspicion = maxf(0.0, run.suspicion - 0.1)
	return World.new(run, seed if seed_value == null else int(seed_value))


## Kompatibilität: wechselt in-place in die nächste Zone.
func advance_zone() -> bool:
	if state != "zone_clear":
		return false
	var nw := next_world()
	if nw == null:
		state = "finished"
		return false
	for prop: Dictionary in get_property_list():
		if not (prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var pn: String = prop["name"]
		if pn in ["suspicion", "points"]:       # Durchreicher auf run
			continue
		set(pn, nw.get(pn))
	return true


# ------------------------------------------------------------------ Projektion
## Welt -> Bildschirm: [cx, ground_y, height_px].
func project(actor: Variant, _w: Variant = null, _h: Variant = null) -> Array:
	return [Persp.screen_x(actor.x, actor.depth, camera_x), Persp.ground_y(actor.depth),
			Persp.figure_h(actor.depth)]
