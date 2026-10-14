extends SceneTree
## Save/Settings: Defaults, Validierung, record() wie save.py (headless).
var fails := 0
func _chk(name: String, ok: bool, got: Variant = null) -> void:
	if not ok:
		fails += 1
		print("FAIL ", name, " ", got)
func _init() -> void:
	for f in ["user://save.json", "user://settings.json"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	_chk("leer", Save.load_().is_empty())
	var r := Save.record(800, "C", false)
	_chk("record1", r[1] == true and r[0]["runs"] == 1 and r[0]["best"] == 800 and r[0]["rank"] == "C", r)
	r = Save.record(500, "A", true)
	_chk("record2", r[1] == false and r[0]["runs"] == 2 and r[0]["wins"] == 1 and r[0]["best"] == 800 and r[0]["rank"] == "A", r)
	r = Save.record(900, "B", false)
	_chk("record3", r[1] == true and r[0]["rank"] == "A" and r[0]["best"] == 900, r)
	var d := Save.load_()
	_chk("load int", d["runs"] is int and d["runs"] == 3, d)
	var s := Settings.load_()
	var want: Dictionary = DSettings.DEFAULTS.duplicate(true)
	want.merge(Settings.PORT_DEFAULTS, true)
	_chk("defaults", s == want, s)
	s["resolution"] = [1920, 1080]
	s["lang"] = "en"
	s["sfx"] = 0.5
	Settings.save_(s)
	var s2 := Settings.load_()
	_chk("roundtrip", s2["resolution"] == [1920, 1080] and s2["resolution"][0] is int and s2["lang"] == "en" and s2["sfx"] == 0.5, s2)
	var f := FileAccess.open("user://settings.json", FileAccess.WRITE)
	f.store_string('{"resolution": [1.5, 2], "difficulty": "brutal", "lang": "fr", "foo": 1, "music": 0.2}')
	f.close()
	var s3 := Settings.load_()
	_chk("validierung", s3["resolution"] == [1280, 720] and s3["difficulty"] == "normal" and s3["lang"] == "de" and not s3.has("foo") and s3["music"] == 0.2, s3)
	_chk("wrap", HUD.wrap_("EIN ZWEI  DREI VIERUNDZWANZIG", 9) == ["EIN ZWEI", "DREI", "VIERUNDZWANZIG"], HUD.wrap_("EIN ZWEI  DREI VIERUNDZWANZIG", 9))
	_chk("rank", HUD.rank_of(2600, 0, true) == "S" and HUD.rank_of(2100, 1, false) == "A" and HUD.rank_of(2100, 2, false) == "B" and HUD.rank_of(499, 0, true) == "D")
	_chk("conf", HUD.conf_color(0.66) == DHud.CYAN and HUD.conf_color(0.33) == DHud.AMBER and HUD.conf_color(0.1) == DHud.ASH)
	_chk("tw", Pixfont.text_width("ABC", 2) == 34 and Pixfont.text_width("", 3) == 0)
	print(FileAccess.get_file_as_string("user://save.json"))
	for p in ["user://save.json", "user://settings.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	print("Save/Settings-Tests: Fehler ", fails)
	quit(1 if fails else 0)
