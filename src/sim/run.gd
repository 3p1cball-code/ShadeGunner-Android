class_name Run
extends RefCounted
## Zustand, der über Zonen hinweg erhalten bleibt (sim.Run).

var seed: int = 0
var difficulty: String = "normal"
var density: float = 1.0
var score: int = 0
var max_hp: int = Config.PLAYER_HP
var hp: int = Config.PLAYER_HP
var suspicion: float = 0.0
var upgrades: Array = []
var zone_index: int = 0
var totals: Dictionary = {}
var origami: Array = []                # gefundene Origami-Figuren (Gaff war hier)
var roy_spared: bool = false           # ROY hat dich verschont und du ihn
var cheat: bool = false                # "giveall": unsterblich, Ausgang immer offen
var mods: Dictionary = {}


func _init(seed_value: int = 0, difficulty_: String = "normal") -> void:
	seed = seed_value
	difficulty = difficulty_ if Config.DIFFICULTY.has(difficulty_) else "normal"
	density = float(Config.DIFFICULTY[difficulty]["density"])
	score = 0
	max_hp = Config.PLAYER_HP
	hp = max_hp
	suspicion = 0.0
	upgrades = []
	zone_index = 0
	totals = {"reps": 0, "civs": 0, "escaped": 0, "scans": 0, "shots": 0, "time": 0.0}
	origami = []
	roy_spared = false
	cheat = false
	mods = {"scan_max": Config.SCAN_CHARGES, "scan_time": 1.0, "deep": false, "observe": 1.0,
			"speed": 1.0, "aim_min": Config.AIM_MIN, "susp": 1.0, "flee": 1.0, "glint": 1.0,
			"shout_cd": 1.0, "shout_r": 1.0}


func apply(key: String) -> void:
	var m := mods
	upgrades.append(key)
	match key:
		"akku":
			m["scan_max"] += 2
		"schnell":
			m["scan_time"] *= 0.55
		"tief":
			m["deep"] = true
		"auge":
			m["observe"] *= 2.0
		"weste":
			max_hp += 1
			hp = max_hp
		"sprint":
			m["speed"] *= 1.2
		"hand":
			m["aim_min"] = 0.0
		"kalt":
			m["susp"] *= 0.65
		"peil":
			m["flee"] *= 0.7
		"instinkt":
			m["glint"] *= 2.0
		"megafon":
			m["shout_cd"] *= 0.5
			m["shout_r"] *= 1.35


## n Upgrades zur Auswahl (Einträge wie DSim.UPGRADES: [key, name, text]).
func offer(rng: PyRandom, n: int = 3) -> Array:
	var pool := []
	for u: Array in DSim.UPGRADES:
		if not (u[0] in upgrades and u[0] in ["tief", "hand", "megafon"]):
			pool.append(u)
	return rng.sample(pool, mini(n, pool.size()))
