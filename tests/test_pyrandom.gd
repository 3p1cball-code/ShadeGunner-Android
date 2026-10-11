extends SceneTree
## godot --headless --path . --script res://tests/test_pyrandom.gd
## Vergleicht PyRandom mit Testvektoren aus echtem CPython.

const PyR := preload("res://src/core/pyrandom.gd")

var fails := 0


func _eq(name: String, a: Variant, b: Variant) -> void:
	var ok := true
	if a is float or b is float:
		ok = absf(float(a) - float(b)) <= 1e-12 * maxf(1.0, absf(float(b)))
	else:
		ok = str(a) == str(b)
	if not ok:
		fails += 1
		print("FAIL ", name, ": godot=", a, " python=", b)


func _cmp_list(name: String, got: Array, want: Array) -> void:
	if got.size() != want.size():
		fails += 1
		print("FAIL ", name, " Laenge ", got.size(), " vs ", want.size())
		return
	for i in got.size():
		var w: Variant = want[i]
		var g: Variant = got[i]
		if w is float and not (g is float):
			g = float(g)
		if g is int and w is float and floorf(w) == w:
			w = int(w)
		_eq("%s[%d]" % [name, i], g, w)


func _init() -> void:
	var data: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/pyrandom_vectors.json"))
	for rec in data:
		var s := int(rec["seed"])
		var tag := "seed %d " % s
		var r = PyR.new(s)
		var u := []
		for i in 5:
			u.append(r.getrandbits(32))
		_cmp_list(tag + "u32", u, rec["u32"])
		r = PyR.new(s)
		var a := []
		for i in 5:
			a.append(r.random())
		_cmp_list(tag + "random", a, rec["random"])
		a = []
		for i in 6:
			a.append(r.randint(0, 10))
		for i in 3:
			a.append(r.randint(-50, 50))
		_cmp_list(tag + "randint", a, rec["randint"])
		a = []
		for i in 4:
			a.append(r.uniform(-2.0, 3.0))
		_cmp_list(tag + "uniform", a, rec["uniform"])
		a = []
		for i in 6:
			a.append(r.choice([0, 1, 2, 3, 4, 5, 6]))
		_cmp_list(tag + "choice", a, rec["choice"])
		a = []
		for i in 3:
			a.append(r.randrange(1 << 16))
		for i in 3:
			a.append(r.randrange(3, 40))
		_cmp_list(tag + "randrange", a, rec["randrange"])
		a = []
		for i in 6:
			a.append(r.choices1(["a", "b", "c", "d"], [5, 1, 3, 1]))
		_cmp_list(tag + "choices", a, rec["choices"])
		a = []
		for i in 3:
			a.append(r.choices1([10, 20, 30]))
		_cmp_list(tag + "choices_nw", a, rec["choices_nw"])
		_cmp_list(tag + "sample_small", r.sample(range(20), 5), rec["sample_small"])
		_cmp_list(tag + "sample_big", r.sample(range(400), 12), rec["sample_big"])
		var xs := range(10)
		r.shuffle(xs)
		_cmp_list(tag + "shuffle", xs, rec["shuffle"])
		a = []
		for i in 4:
			a.append(r.gauss(0.0, 1.0))
		_cmp_list(tag + "gauss", a, rec["gauss"])
		_cmp_list(tag + "bits40", [r.getrandbits(40), r.getrandbits(40)], rec["bits40"])
		_eq(tag + "tail", r.random(), rec["tail"])
	print("PyRandom: ", data.size(), " Seeds, Fehler: ", fails)
	quit(1 if fails else 0)
