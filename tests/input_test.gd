extends Node
## Eingabe-Test am echten Spiel: Menue-Navigation per D-Pad (Gamepad), per Taste nur mit
## logischem Code (wie Android), Druecken+Loslassen im selben Frame, Zurueck-Taste.
var g: Node
var step := 0
var wait := 0
var fails := 0

func _ready() -> void:
	g = (load("res://main.tscn") as PackedScene).instantiate()
	add_child(g)

func _btn(idx: int) -> void:
	var a := InputEventJoypadButton.new()
	a.button_index = idx
	a.pressed = true
	Input.parse_input_event(a)
	var b := InputEventJoypadButton.new()
	b.button_index = idx
	b.pressed = false
	Input.parse_input_event(b)        # im selben Frame wieder los

func _key(kc: int) -> void:
	var a := InputEventKey.new()
	a.keycode = kc                      # nur logisch, physical_keycode = 0 (Android)
	a.pressed = true
	Input.parse_input_event(a)
	var b := InputEventKey.new()
	b.keycode = kc
	b.pressed = false
	Input.parse_input_event(b)

func _chk(name: String, ok: bool, info: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + name + "  " + info)
	if not ok:
		fails += 1

func _process(_d: float) -> void:
	wait += 1
	if wait < 8:
		return
	wait = 0
	step += 1
	match step:
		1:
			_chk("Start im Titel", g.mode == "title", g.mode)
			_btn(JOY_BUTTON_DPAD_DOWN)
		2:
			_chk("D-Pad runter oeffnet Einstellungen", g.mode == "settings", g.mode)
			_btn(JOY_BUTTON_DPAD_DOWN)
		3:
			_chk("D-Pad runter -> Zeile 1", g.settings_sel == 1, str(g.settings_sel))
			_btn(JOY_BUTTON_DPAD_DOWN)
		4:
			_chk("D-Pad runter -> Zeile 2", g.settings_sel == 2, str(g.settings_sel))
			_key(KEY_DOWN)
		5:
			_chk("Taste runter (nur keycode) -> Zeile 3", g.settings_sel == 3, str(g.settings_sel))
			_btn(JOY_BUTTON_DPAD_UP)
		6:
			_chk("D-Pad hoch -> Zeile 2", g.settings_sel == 2, str(g.settings_sel))
			_btn(JOY_BUTTON_B)
		7:
			_chk("B -> zurueck zum Titel", g.mode == "title", g.mode)
			_btn(JOY_BUTTON_A)
		8:
			pass
		9:
			wait = -60
		10:
			_chk("A startet den Einsatz", g.mode in ["intro", "play"], g.mode)
			g._set_mode("play")
			g.get_tree().root.propagate_notification(NOTIFICATION_WM_GO_BACK_REQUEST)
		11:
			_chk("Android-Zurueck -> Pause", g.mode == "pause", g.mode)
			print("Eingabe-Test: Fehler ", fails)
			get_tree().quit(1 if fails else 0)
