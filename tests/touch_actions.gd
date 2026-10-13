extends SceneTree
## Headless-Prüfung ohne Rendern: je Spielzustand erzeugen die sichtbaren Touch-
## Elemente die richtigen InputEventActions (mitgeschnitten über tc.event_log),
## Wiederholung beim Halten, Freigabe bei Zustandswechsel, is_over_controls nur
## für sichtbare Elemente; zuletzt: eingespeiste Ereignisse kommen nach dem
## Flush im Input-Zustand an.
##
##   godot --headless --path . --script res://tests/touch_actions.gd

var fails := 0
var tc: TouchControls
var frame := 0


func _chk(what: String, ok: bool, got: Variant = null) -> void:
	if not ok:
		fails += 1
		print("FAIL ", what, "  ", got)


## Antippen (drücken + loslassen) und Mitschnitt zurückgeben.
func _tap(id: String) -> Array:
	tc.event_log.clear()
	var p := tc.button_center(id)
	tc.debug_touch(p, true)
	tc.debug_touch(p, false)
	return tc.event_log.duplicate()


func _expect_mode(mode: String, help: bool, ids: Dictionary) -> void:
	tc.set_mode(mode)
	tc.set_help(help)
	var have := tc.button_ids()
	_chk("%s: Anzahl Buttons" % mode, have.size() == ids.size(), have)
	for id: String in ids:
		var acts: Array = ids[id]
		_chk("%s: Button %s sichtbar" % [mode, id], have.has(id), have)
		var seen := _tap(id)
		var want: Array = []
		for a: String in acts:
			want.append([a, true])
		for a: String in acts:
			want.append([a, false])
		_chk("%s: %s -> %s" % [mode, id, acts], seen == want, seen)


func _initialize() -> void:
	tc = TouchControls.new()
	tc.setup(root, {"touch": "an"})
	tc.set_enabled("an")
	tc.record = true

	# --- Layouts je Zustand
	_expect_mode("play", false, {"aim": ["aim"], "scan": ["scan"], "jump": ["jump"], "shout": ["shout"],
		"cancel": ["cancel"], "pause": ["pause"]})
	_expect_mode("title", false, {"start": ["confirm"], "settings": ["open_settings"], "help": ["help"]})
	_expect_mode("pause", false, {"resume": ["pause"], "settings": ["open_settings"], "title": ["to_title"]})
	_expect_mode("settings", false, {"up": ["up"], "down": ["down"], "left": ["move_left"],
		"right": ["move_right"], "back": ["cancel"]})
	_expect_mode("clear", false, {"left": ["move_left"], "right": ["move_right"], "ok": ["confirm"]})
	_expect_mode("over", false, {"again": ["restart"], "title": ["to_title"]})
	_expect_mode("victory", false, {"again": ["restart"], "title": ["to_title"]})
	_expect_mode("intro", false, {"continue": ["confirm"]})
	_expect_mode("title", true, {"back": ["help"]})
	tc.set_help(false)

	# --- Beschriftung DE/EN (I18n.t, sonst lokaler Rückfall)
	var want_en := {"title": {"start": "START", "settings": "SETTINGS", "help": "HELP"},
		"pause": {"resume": "RESUME", "title": "TITLE"}, "settings": {"back": "BACK"},
		"over": {"again": "AGAIN", "title": "TITLE"}, "intro": {"continue": "CONTINUE"}}
	for lang: String in ["en", "de"]:
		I18n.set_lang(lang)
		for mode: String in want_en:
			tc.set_mode(mode)
			for id: String in (want_en[mode] as Dictionary):
				var got := tc._txt(tc._find(id))
				var de_ok := got == String(tc._find(id)["de"])
				_chk("%s/%s/%s Label" % [lang, mode, id],
					(got == String((want_en[mode] as Dictionary)[id])) if lang == "en" else de_ok, got)
	I18n.set_lang("de")

	# --- Stick (nur play): Schwelle über-/unterschreiten
	tc.set_mode("play")
	tc.event_log.clear()
	var c := tc.stick_center()
	tc.debug_touch(c, true)
	_chk("stick neutral: nichts", tc.event_log.is_empty(), tc.event_log)
	tc.debug_drag(c + Vector2(400.0, 0.0))
	tc.debug_drag(c + Vector2(500.0, 10.0))          # weiter außen: kein neues Ereignis
	tc.debug_drag(c + Vector2(0.0, 400.0))
	tc.debug_drag(c)
	tc.debug_touch(c, false)
	_chk("stick Ereignisse", tc.event_log == [["move_right", true], ["move_right", false],
		["depth_near", true], ["depth_near", false]], tc.event_log)
	tc.set_mode("title")
	_chk("stick nur in play", not tc.is_over_controls(c))

	# --- Wiederholung ▲ in den Einstellungen: 0,4 s, dann alle 0,15 s
	tc.set_mode("settings")
	tc.event_log.clear()
	var up := tc.button_center("up")
	tc.debug_touch(up, true)
	tc.debug_tick(0.39)
	_chk("repeat: vor 0,4 s nur 1x", tc.event_log == [["up", true]], tc.event_log)
	tc.debug_tick(0.02)
	_chk("repeat: bei 0,4 s", tc.event_log.size() == 2, tc.event_log)
	tc.debug_tick(0.15)
	tc.debug_tick(0.15)
	_chk("repeat: +2 nach 0,3 s", tc.event_log.size() == 4, tc.event_log)
	tc.debug_touch(up, false)
	_chk("repeat: Loslassen", tc.event_log.back() == ["up", false], tc.event_log)
	tc.event_log.clear()
	tc.debug_tick(1.0)
	_chk("repeat: danach Ruhe", tc.event_log.is_empty(), tc.event_log)
	# ◀ wiederholt nicht
	tc.debug_touch(tc.button_center("left"), true)
	tc.debug_tick(1.0)
	_chk("◀ ohne Wiederholung", tc.event_log == [["move_left", true]], tc.event_log)
	tc.debug_touch(tc.button_center("left"), false)

	# --- Einstellungs-Liste in der Mitte bleibt frei
	var vp := Vector2(1280.0, 720.0)
	for y in [180.0, 360.0, 600.0]:
		for x in [300.0, 640.0, 980.0]:
			_chk("settings frei bei %s,%s" % [x, y], not tc.is_over_controls(Vector2(x, y)))
	_chk("settings: ▲ trifft", tc.is_over_controls(tc.button_center("up")))
	# im Titel ist die Stelle von ▲ leer
	var up_pos := tc.button_center("up")
	tc.set_mode("title")
	_chk("is_over_controls nur sichtbare", not tc.is_over_controls(up_pos))
	_chk("Titelmitte frei", not tc.is_over_controls(vp * 0.5))

	# --- Zustandswechsel löst gehaltene Aktionen
	tc.set_mode("play")
	tc.event_log.clear()
	tc.debug_touch(tc.button_center("aim"), true)
	tc.set_mode("pause")
	_chk("Wechsel löst aim", tc.event_log == [["aim", true], ["aim", false]], tc.event_log)

	# --- "aus" deaktiviert
	tc.set_mode("play")
	tc.debug_touch(tc.button_center("scan"), true)
	tc.event_log.clear()
	tc.set_enabled("aus")
	_chk("aus: scan gelöst", tc.event_log == [["scan", false]], tc.event_log)
	_chk("aus: inaktiv", not tc.is_active())
	_chk("aus: nichts trifft", not tc.is_over_controls(tc.button_center("jump")))

	# --- Flush: aim gedrückt halten, Input-Zustand nach ein paar Frames prüfen (_process)
	tc.set_enabled("an")


func _process(_delta: float) -> bool:
	frame += 1
	# Der Headless-DisplayServer leert den Ereignispuffer nicht selbst (Desktop/
	# Android tun das in process_events) - hier von Hand.
	Input.flush_buffered_events()
	if frame == 2:
		# erst jetzt: das Fenster hat seine echte Größe (Größenwechsel = neues Layout,
		# das gehaltene Elemente bewusst löst)
		tc.debug_touch(tc.button_center("aim"), true)
	elif frame == 4:
		_chk("flush: aim gehalten", Input.is_action_pressed("aim"))
		tc.debug_touch(tc.button_center("aim"), false)
	elif frame == 6:
		_chk("flush: aim gelöst", not Input.is_action_pressed("aim"))
		print("touch_actions: ", "OK" if fails == 0 else "%d FEHLER" % fails)
		quit(0 if fails == 0 else 1)
	return false
