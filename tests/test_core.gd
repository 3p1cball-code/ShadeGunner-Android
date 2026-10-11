extends SceneTree
## Py.fmt / Py.round / Persp gegen Python-Vektoren.
var fails := 0
func _chk(name: String, ok: bool, got: Variant, want: Variant) -> void:
	if not ok:
		fails += 1
		print("FAIL ", name, " godot=", got, " python=", want)
func _init() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/py_vectors.json"))
	for c in d["fmt"]:
		var args: Array = []
		for a in c[1]:
			args.append(int(a) if (a is float and floorf(a) == a and not str(c[0]).contains("f}")) else a)
		var g := Py.fmt(c[0], args)
		_chk("fmt " + str(c[0]), g == c[2], g, c[2])
	for c in d["round"]:
		_chk("round " + str(c[0]), Py.round(c[0]) == int(c[1]), Py.round(c[0]), c[1])
	for r in d["persp"]:
		var dd: float = r[0]
		var got := [dd, Persp.scale(dd), Persp.ground_y(dd), Persp.ppu(dd), Persp.figure_h(dd), Persp.screen_x(123.4, dd, 50.0), Persp.world_x(300.0, dd, 50.0)]
		for i in got.size():
			_chk("persp %s[%d]" % [dd, i], absf(float(got[i]) - float(r[i])) < 1e-9, got[i], r[i])
	for r in d["depth_at_y"]:
		_chk("depth_at_y", absf(Persp.depth_at_y(r[0]) - float(r[1])) < 1e-9, Persp.depth_at_y(r[0]), r[1])
	var k: Array = d["consts"]
	_chk("PPU_NEAR", absf(Persp.PPU_NEAR - float(k[0])) < 1e-9, Persp.PPU_NEAR, k[0])
	_chk("FACADE_Y", absf(Persp.FACADE_Y - float(k[1])) < 1e-9, Persp.FACADE_Y, k[1])
	_chk("FACADE_PPU", absf(Persp.FACADE_PPU - float(k[2])) < 1e-9, Persp.FACADE_PPU, k[2])
	_chk("horizon", absf(Persp.horizon_px() - float(k[3])) < 1e-9, Persp.horizon_px(), k[3])
	I18n.set_lang("en")
	var t := I18n.t("BESTWERT {:06d}  RANG {}  EINSÄTZE {}", [1234, "A", 7])
	_chk("tr", t == "BEST 001234  RANK A  RUNS 7", t, "BEST 001234  RANK A  RUNS 7")
	print("Kern-Tests: Fehler ", fails)
	quit(1 if fails else 0)
