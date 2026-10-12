class_name Procgen
extends RefCounted
## Prozedurale Bevölkerung und Straßenmöblierung einer Zone (procgen.py).
##
## Authored macro (Zone: Länge, Dichte, Replikantenzahl, Tarnung), procedural micro
## (wer läuft wo, wie sieht er aus). Das Aussehen korreliert bewusst NICHT mit dem
## Replikanten-Status - sonst wäre das Erkennen trivial. Tabellen: DProcgen.

const ZONE_RAIN := DProcgen.ZONE_RAIN
const OBSTACLE_KINDS := DProcgen.OBSTACLE_KINDS
const ZONE_OBSTACLES := DProcgen.ZONE_OBSTACLES


static func _zf(zone: Dictionary, key: String) -> float:
	var v: Variant = zone.get(key, 0.0)
	return 0.0 if v == null else float(v)


## Liste neuer Aktoren zwischen x_from und x_to. Gibt [actors, next_uid].
## Drei Sorten, alle gleichwertig Teil der Simulation: Passanten, Flaneure auf dem
## hinteren Gehweg und Gruppen, die herumstehen und reden.
static func populate(rng: PyRandom, zone: Dictionary, x_from: float, x_to: float, uid_start: int,
		zone_index: int = 0) -> Array:
	var span := maxf(1.0, x_to - x_from)
	var rain: float = ZONE_RAIN[Py.imod(zone_index, ZONE_RAIN.size())]
	var specs := []                                  # [x, depth, kind, gruppe, gx]
	for _i in maxi(10, int(span / 100.0 * float(zone["density"]))):
		var sx := rng.uniform(x_from, x_to)
		var sd := rng.uniform(Config.DEPTH_MIN + 0.02, 0.97)
		specs.append([sx, sd, "street", -1, 0.0])
	var lo: float = Config.SIDEWALK[0]
	var hi: float = Config.SIDEWALK[1]
	for _i in int(span / 100.0 * _zf(zone, "sidewalk")):
		var sx := rng.uniform(x_from, x_to)
		var sd := rng.uniform(lo, hi)
		specs.append([sx, sd, "sidewalk", -1, 0.0])
	var gid := 0
	for _i in int(span / 100.0 * _zf(zone, "groups")):
		var gx := rng.uniform(x_from + 40, x_to - 40)
		var back := rng.random() < 0.6
		var gd := rng.uniform(lo + 0.01, hi) if back else rng.uniform(0.22, 0.9)
		var n: int = rng.choice([2, 2, 3, 3, 4])
		for k in n:
			var ang := 2 * PI * k / n + rng.uniform(-0.3, 0.3)
			var rr := rng.uniform(6, 9)
			specs.append([gx + cos(ang) * rr, maxf(Config.NPC_DEPTH_MIN, gd + sin(ang) * 0.035), "group", gid, gx])
		gid += 1
	var count := specs.size()
	var n_rep := mini(count - 4, int(zone["replicants"]))
	var replicant_ids := {}
	for i: int in rng.sample(range(count), n_rep):
		replicant_ids[i] = true

	var actors := []
	for i in count:
		var sp: Array = specs[i]
		var x: float = sp[0]
		var depth: float = sp[1]
		var kind: String = sp[2]
		var grp: int = sp[3]
		var gx: float = sp[4]
		var is_rep := replicant_ids.has(i)
		var uid := uid_start + i
		var tells := Detection.spawn_tells(rng, is_rep, float(zone["camo"]))
		var look := Looks.random_look(rng, uid, rain)
		var facing: int = rng.choice([-1, 1])
		var speed := rng.uniform(11.0, 26.0) * (0.55 if look.get("old") else 1.0)
		var phase := rng.random()
		var a := Actor.new(x, depth, {
			"look": look, "uid": uid, "is_replicant": is_rep, "tells": tells,
			"facing": facing, "speed": speed, "phase": phase, "target_depth": depth,
		})
		a.react_t = rng.uniform(0.12, 0.5) + (0.45 if look.get("old") else 0.0)
		a.glint_next = rng.uniform(2.0, 9.0)
		if kind == "group":
			a.group = grp
			a.gx = gx
			a.state = "loiter"
			a.timer = rng.uniform(25.0, 70.0)
			a.facing = 1 if gx >= x else -1
			if look.get("umbrella") and rng.random() < 0.5:
				look["umbrella"] = null              # unterm Vordach braucht's keinen Schirm
		else:
			if kind == "sidewalk":
				a.home = [lo, hi]
				a.speed *= 0.8                       # Flaneure bummeln
			a.state = "walk" if rng.random() < 0.72 else "idle"
			a.timer = rng.uniform(2.0, 9.0)
			# Gang-Tell sichtbar machen: auffällig gleichmäßige Geher bleiben nie stehen
			if tells.get("gait"):
				a.state = "walk"
				a.speed = 19.0
		if is_rep:
			a.aggressive = rng.random() < float(zone["aggression"])
		actors.append(a)
	return [actors, uid_start + count]


## Deterministische x-Positionen der Nudelstände (Sim und Renderer nutzen dieselben).
static func ramen_positions(length: float, seed_: int, zone_index: int) -> Array:
	var rng := PyRandom.new(seed_ * 131 + zone_index * 17 + 9)
	var out := []
	for k in 2:
		var x := length * (0.28 + 0.44 * k) + rng.uniform(-120, 120)
		out.append(minf(length - 160, maxf(180, x)))
	return out


## Hindernisse neben den Fahrspuren: man springt drüber oder geht außen herum.
static func obstacles(rng: PyRandom, zone_index: int, length: float, ramen: Array = []) -> Array:
	var kinds: Array = ZONE_OBSTACLES[Py.imod(zone_index, ZONE_OBSTACLES.size())]
	var out := []
	var x := 220.0 + rng.uniform(0, 120)
	while x < length - 140:
		var band: Array = rng.choice(Config.OBSTACLE_BANDS)
		var kind: String = rng.choice(kinds)
		var wdh: Array = OBSTACLE_KINDS[kind]
		var w: float = wdh[0]
		var dd: float = wdh[1]
		var h: float = wdh[2]
		var b0: float = band[0]
		var b1: float = band[1]
		var d := rng.uniform(b0 + dd, b1 - dd) if b1 - b0 > 2 * dd else (b0 + b1) / 2
		# Nudelstände frei halten (sonst kommt man nicht heran)
		var free := true
		for rx: float in ramen:
			if absf(x - rx) < 80:
				free = false
				break
		if free:
			out.append({"x": x, "d": d, "w": w, "dd": dd, "h": h, "kind": kind, "seed": rng.randint(0, 9999)})
		x += rng.uniform(170, 330)
	return out


## Parkende Fahrzeuge am Fahrbahnrand (feste Hindernisse - nicht springbar).
static func parked(rng: PyRandom, zone: Dictionary, kinds: Array, dims: Dictionary, length: float,
		ramen: Array = [], existing: Array = []) -> Array:
	var out := []
	var n := int(length / 1000.0 * _zf(zone, "parked") + rng.random())
	for _i in n * 6:
		if out.size() >= n:
			break
		var kind: String = rng.choice(kinds)
		var dm: Array = dims[kind]
		var L: float = dm[0]
		var h: float = dm[1]
		var pb0: Array = Config.PARK_BANDS[0]
		var pb1: Array = Config.PARK_BANDS[1]
		var d: float = float(pb0[0]) if rng.random() < float(pb0[1]) else float(pb1[0])
		d += rng.uniform(-0.008, 0.008)
		var x := rng.uniform(260.0, length - 220.0)
		var bad := false
		for rx: float in ramen:
			if absf(x - rx) < 110:
				bad = true
				break
		if bad:
			continue
		for o: Dictionary in existing + out:
			if absf(x - float(o["x"])) < float(o["w"]) + L * 0.5 + 14 and absf(d - float(o["d"])) < float(o["dd"]) + 0.06:
				bad = true
				break
		if bad:
			continue
		var vdir: int = rng.choice([-1, 1])
		var vseed := rng.randint(0, 9999)
		var hazard := rng.random() < 0.25
		out.append({"x": x, "d": d, "w": L * 0.5, "dd": 0.035, "h": h, "kind": "parked", "veh": kind, "dir": vdir,
				"seed": vseed, "hazard": hazard})
	return out


## Dampfende Gullis (New York). Gibt [gullis, schlot-hindernisse].
static func manholes(rng: PyRandom, zone: Dictionary, length: float, ramen: Array = [], existing: Array = []) -> Array:
	var holes := []
	var stacks := []
	var n := int(length / 1000.0 * _zf(zone, "steam") + rng.random())
	for _i in n * 6:
		if holes.size() >= n:
			break
		var x := rng.uniform(240.0, length - 200.0)
		var stack := rng.random() < 0.3
		var d: float = rng.choice([0.17, 0.53, 0.94]) if stack else rng.choice([0.3, 0.34, 0.53, 0.72, 0.77, 0.9])
		var bad := false
		for hh: Dictionary in holes:
			if absf(x - float(hh["x"])) < 90:
				bad = true
				break
		if not bad:
			for rx: float in ramen:
				if absf(x - rx) < 90:
					bad = true
					break
		if bad:
			continue
		for o: Dictionary in existing:
			if absf(x - float(o["x"])) < float(o["w"]) + 14 and absf(d - float(o["d"])) < float(o["dd"]) + 0.04:
				bad = true
				break
		if bad:
			continue
		var base := rng.uniform(0.35, 0.8) if not stack else rng.uniform(0.7, 1.0)
		var every := rng.uniform(9.0, 22.0)
		var ph := rng.uniform(0, 6.28)
		var mseed := rng.randint(0, 9999)
		var m := {"x": x, "d": d, "stack": stack, "base": base, "every": every, "burst": 0.0, "ph": ph, "t": 0.0,
				"s": 0.5, "drift": 0.0, "seed": mseed}
		holes.append(m)
		if stack:
			stacks.append({"x": x, "d": d, "w": 3.0, "dd": 0.02, "h": 14.0, "kind": "stack", "seed": mseed})
	return [holes, stacks]
