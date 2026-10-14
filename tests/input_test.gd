extends Node
## Eingabe-Test am echten Spiel: Menue-Navigation per D-Pad (Gamepad), per Taste nur mit
## logischem Code (wie Android), Druecken+Loslassen im selben Frame, Zurueck-Taste.
var g: Node
var step := 0
var wait := 0
var fails := 0
var _t_hold := 0

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

## Ein Druck wie auf dem Retroid Pocket: Taste (KEYCODE_DPAD_DOWN), Gamepad-Taste und
## Achse gleichzeitig, dazu Tasten-Wiederholungen (echo) - darf nur EINE Zeile weiter.
func _retroid_down() -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_DOWN
	k.pressed = true
	Input.parse_input_event(k)
	var j := InputEventJoypadButton.new()
	j.button_index = JOY_BUTTON_DPAD_DOWN
	j.pressed = true
	Input.parse_input_event(j)
	for v: float in [0.3, 0.8, 1.0, 1.0]:
		var m := InputEventJoypadMotion.new()
		m.axis = JOY_AXIS_LEFT_Y
		m.axis_value = v
		Input.parse_input_event(m)
	for _i in 3:
		var r := InputEventKey.new()
		r.keycode = KEY_DOWN
		r.pressed = true
		r.echo = true
		Input.parse_input_event(r)


func _retroid_release() -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_DOWN
	Input.parse_input_event(k)
	var j := InputEventJoypadButton.new()
	j.button_index = JOY_BUTTON_DPAD_DOWN
	Input.parse_input_event(j)
	var m := InputEventJoypadMotion.new()
	m.axis = JOY_AXIS_LEFT_Y
	m.axis_value = 0.0
	Input.parse_input_event(m)


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
			g._open_settings("pause")
			g.settings_sel = 0
			_retroid_down()
		12:
			_retroid_release()
			_chk("Retroid: ein Druck (Taste+Knopf+Achse+Echo) -> genau 1 Zeile", g.settings_sel == 1,
				str(g.settings_sel))
			_retroid_down()
			_t_hold = Time.get_ticks_msec()
			wait = -52                 # halten
		13:
			_retroid_release()
			var held := (Time.get_ticks_msec() - _t_hold) / 1000.0
			var want := 2 + (maxi(0, int((held - 0.45) / 0.16) + 1) if held >= 0.45 else 0)
			_chk("Halten %.2f s -> ruhige Wiederholung (ca. %d)" % [held, want], absi(g.settings_sel - want) <= 1,
				str(g.settings_sel))
			print("Eingabe-Test: Fehler ", fails)
			get_tree().quit(1 if fails else 0)
