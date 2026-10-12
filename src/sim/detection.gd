class_name Detection
extends RefCounted
## Tell- und Konfidenz-System (detection.py).
##
## Ein Replikant ist ein *Sampling* aus Tells - kein einzelner Tell beweist etwas.
## Die Konfidenz ist ein Naive-Bayes-Log-Odds-Score über die aufgedeckten Tells.
## TELLS[name] = [p_replikant, p_mensch, braucht_scan, kurzname] (Tabellen: DDetection)

const TELLS := DDetection.TELLS
const ORDER := DDetection.ORDER
const WEAK_TELLS := DDetection.WEAK_TELLS
const STRONG_TELLS := DDetection.STRONG_TELLS
const PRIOR := DDetection.PRIOR


## {name: [r, h]} je Tell für eine Tarntiefe camo in [0, 1].
static func likelihoods(camo: float) -> Dictionary:
	var out := {}
	for tname: String in TELLS:
		var row: Array = TELLS[tname]
		var rp: float = row[0]
		var hp: float = row[1]
		var r := minf(0.95, rp * (1.25 - 0.6 * camo))
		var h := minf(0.6, hp * (0.8 + 2.2 * camo))
		out[tname] = [r, h]
	return out


static func spawn_tells(rng: PyRandom, is_replicant: bool, camo: float) -> Dictionary:
	var lk := likelihoods(camo)
	var tells := {}
	for tname: String in ORDER:
		var rh: Array = lk[tname]
		tells[tname] = rng.random() < (float(rh[0]) if is_replicant else float(rh[1]))
	return tells


## P(Replikant | aufgedeckte Tells) als 0..1 (Naive Bayes, Log-Odds).
## revealed: Dictionary-Set oder Array von Tell-Namen. Summiert in ORDER-Reihenfolge
## (Python iteriert das Set in Hash-Reihenfolge - Unterschied nur im letzten Bit).
static func confidence(revealed: Variant, tells: Dictionary, camo: float = 0.5, prior: float = PRIOR) -> float:
	var lk := likelihoods(camo)
	var pr := minf(maxf(prior, 0.01), 0.99)
	var lo := log(pr / (1.0 - pr))
	for tname: String in ORDER:
		if not (tname in revealed):
			continue
		var rh: Array = lk[tname]
		var rp: float = rh[0]
		var hp: float = rh[1]
		var present := bool(tells.get(tname, false))
		var r := rp if present else (1.0 - rp)
		var h := hp if present else (1.0 - hp)
		r = minf(maxf(r, 1e-3), 1.0 - 1e-3)
		h = minf(maxf(h, 1e-3), 1.0 - 1e-3)
		lo += log(r / h)
	return 1.0 / (1.0 + exp(-lo))


static func tell_present_count(revealed: Variant, tells: Dictionary) -> int:
	var n := 0
	for tname: Variant in revealed:
		if tells.get(tname, false):
			n += 1
	return n
