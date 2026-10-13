extends Node
## Integrationsprobe Touch <-> echtes Spiel (res://main.tscn):
##   Titel: EINSTELLUNGEN antippen -> mode == "settings"; ▼ -> settings_sel == 1;
##   ZURÜCK -> mode == "title"; dann START -> intro, WEITER -> play, PAUSE -> pause.
## Screenshots je Zustand nach shots/touch_<mode>.png.
##
##   godot --path . --rendering-driver opengl3 --audio-driver Dummy res://tests/touch_game_test.tscn
##
## set_mode/set_help ruft der Test selbst jedes Frame auf (falls die Verdrahtung in
## game.gd noch fehlt). Die Benutzereinstellungen werden am Ende wiederhergestellt.

const OUT := "res://shots"

var game: Node                # Game, bewusst untypisiert
var touch: TouchControls
var orig: Dictionary
var fails := 0
var step := 0
var wait := 0
var frames := 0
var timeout := 0
var release_id := ""          # im nächsten Frame loslassen


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	orig = Settings.load_()
	game = (load("res://main.tscn") as PackedScene).instantiate()
	if game == null or not ("mode" in game):
		print("touch_game_test: main.tscn nicht ladbar")
		set_process(false)
		get_tree().quit(2)
		return
	add_child(game)
	touch = game.get("touch") as TouchControls
	(game.get("settings") as Dictionary)["touch"] = "an"
	game.call("_apply_settings")


func _mode() -> String:
	return String(game.get("mode"))


func _sel() -> int:
	return int(game.get("settings_sel"))


func _chk(what: String, ok: bool, got: Variant = null) -> void:
	print("  ", "ok  " if ok else "FAIL", " ", what, "" if ok else "  (%s)" % [got])
	if not ok:
		fails += 1


func _tap(id: String) -> void:
	var p := touch.button_center(id)
	_chk("Button %s sichtbar (%s)" % [id, touch.layout_key()], p != Vector2.ZERO, touch.button_ids())
	touch.debug_touch(p, true)
	release_id = id


func _shot(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT.path_join("touch_%s.png" % tag))
	print("  shot touch_%s.png" % tag)


## Auf einen Zustand warten; false = Zeit abgelaufen (Fehler wird gemeldet).
func _until(ok: bool, what: String, limit: int = 600) -> bool:
	if ok:
		timeout = 0
		return true
	timeout += 1
	if timeout > limit:
		_chk("Zeitlimit: " + what, false, _mode())
		_finish()
	return false


func _process(_dt: float) -> void:
	frames += 1
	touch.set_mode(_mode())
	touch.set_help(bool(game.get("help")))
	if release_id != "":
		touch.debug_touch(touch.button_center(release_id), false)
		release_id = ""
		return
	if wait > 0:
		wait -= 1
		return
	match step:
		0:                                   # Titel steht
			if _until(_mode() == "title" and frames > 30, "title"):
				_shot("title")
				_tap("settings")
				step = 1
		1:
			if _until(_mode() == "settings", "settings", 60):
				_chk("EINSTELLUNGEN -> mode settings", true)
				_chk("settings_sel startet bei 0", _sel() == 0, _sel())
				wait = 8
				step = 2
		2:
			_shot("settings")
			_tap("down")
			wait = 4
			step = 3
		3:
			_chk("▼ -> settings_sel == 1", _sel() == 1, _sel())
			_tap("back")
			step = 4
		4:
			if _until(_mode() == "title", "zurück zum Titel", 60):
				_chk("ZURÜCK -> mode title", true)
				_tap("start")
				step = 5
		5:
			if _until(_mode() == "intro", "intro", 900):
				_chk("START -> intro", true)
				step = 6
		6:
			if _until(float(game.get("mode_t")) > 0.8, "intro mode_t"):
				_tap("continue")
				step = 7
		7:
			if _until(_mode() == "play", "play", 60):
				_chk("WEITER -> play", true)
				wait = 40
				step = 8
		8:
			_shot("play")
			_tap("pause")
			step = 9
		9:
			if _until(_mode() == "pause", "pause", 60):
				_chk("PAUSE -> pause", true)
				wait = 8
				step = 10
		10:
			_shot("pause")
			_finish()


func _finish() -> void:
	Settings.save_(orig)
	print("touch_game_test: ", "OK" if fails == 0 else "%d FEHLER" % fails)
	get_tree().quit(0 if fails == 0 else 1)
	set_process(false)
