class_name TouchControls
extends Control
## Bildschirm-Touchsteuerung für Android (und Touch-Desktops).
##
## Liegt auf einer eigenen CanvasLayer OBEN über der CRT-Kette (Layer 110 > 100),
## damit die Bedienelemente scharf über dem Bild liegen. Sie erzeugt keine neue
## Eingabelogik: der virtuelle Stick und die Buttons drücken die vorhandenen
## InputMap-Aktionen (Input.action_press/action_release), das Spiel bleibt
## unverändert.
##
##   var tc := TouchControls.new()
##   tc.setup(self, settings)      # hängt die CanvasLayer in den Baum
##   tc.refresh_visibility(settings)
##   tc.set_enabled("auto")
##
## Nur sichtbar, wenn aktiv - sonst werden keine Touch-Events ausgewertet.
## Sichtbarkeit laut settings["touch"]: "an" | "aus" | "auto" (mobil UND kein
## Gamepad). Reagiert auf Joypad-Verbindung/-Trennung.

const LAYER := 110                       # CRT-Kette liegt auf 100 -> darüber
const DEADZONE := 0.26                   # Stick-Mitte: kein Druck
const KNOB := 0.42                       # Knopfgröße relativ zum Stickradius

# id -> [deutsch, englisch, Aktionen]
const BUTTONS := [
	["aim", "ZIELEN", "AIM", ["aim", "confirm"]],
	["scan", "SCAN", "SCAN", ["scan"]],
	["jump", "SPRUNG", "JUMP", ["jump"]],
	["shout", "RUF", "SHOUT", ["shout"]],
	["cancel", "ABBRECHEN", "CANCEL", ["cancel"]],
	["pause", "PAUSE", "PAUSE", ["pause"]],
]

const NEEDED_ACTIONS := ["move_left", "move_right", "depth_far", "depth_near",
	"aim", "scan", "jump", "shout", "cancel", "pause", "confirm", "up", "down"]

# Farben in der HUD-Anmutung (noir16, Amber/Cyan)
const C_FILL := Color(0.075, 0.098, 0.16, 0.42)
const C_FILL_ON := Color(0.18, 0.24, 0.38, 0.72)
const C_AMBER := Color(1.0, 0.541, 0.173, 0.95)
const C_CYAN := Color(0.251, 0.824, 0.863, 0.55)
const C_MARK := Color(0.44, 0.46, 0.52, 0.8)

var _layer: CanvasLayer
var _enabled_mode := "auto"
var _active := false

var _size := Vector2.ZERO
var _stick_c := Vector2.ZERO
var _stick_r := 120.0
var _knob := Vector2.ZERO
var _btns: Array = []                    # [{id, de, en, actions, c, r}]
var _actions_map: Dictionary = {}        # id -> Array[String]

var _touch_widget: Dictionary = {}       # Touch-Index -> Widget-id
var _pressed: Dictionary = {}            # Widget-id -> bool
var _stick_actions: Array = []           # aktuell gedrückte Stick-Aktionen


## Aktionen anlegen, falls das Spiel sie noch nicht erzeugt hat (idempotent).
static func ensure_actions() -> void:
	for a: String in NEEDED_ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


## CanvasLayer (Layer 110) im Baum anlegen und self hineinhängen.
func setup(parent: Node, settings: Dictionary) -> void:
	if _layer != null:
		return
	ensure_actions()
	_layer = CanvasLayer.new()
	_layer.name = "TouchControls"
	_layer.layer = LAYER
	parent.add_child(_layer)
	if get_parent() != null:
		get_parent().remove_child(self)
	_layer.add_child(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # wir lesen Input in _input
	visible = false
	if not Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.connect(_on_joy_changed)
	refresh_visibility(settings)


## Sichtbarkeit aus den Einstellungen neu bestimmen ("touch").
func refresh_visibility(settings: Dictionary) -> void:
	set_enabled(str(settings.get("touch", "auto")))


## Modus setzen: "an" = immer, "aus" = nie, sonst auto (mobil ohne Gamepad).
func set_enabled(mode: String) -> void:
	_enabled_mode = mode
	var vis := false
	match mode:
		"an":
			vis = true
		"aus":
			vis = false
		_:
			vis = _is_mobile() and Input.get_connected_joypads().is_empty()
	_apply_visibility(vis)


func is_active() -> bool:
	return _active


## Liegt der Punkt über einem Bedienelement? (Für die Verdrahtung durch das Spiel.)
func is_over_controls(pos: Vector2) -> bool:
	if not _active:
		return false
	_recalc_if_needed()
	return _hit(pos) != ""


## Mittelpunkt des virtuellen Sticks (Bildschirmpixel).
func stick_center() -> Vector2:
	_recalc_if_needed()
	return _stick_c


## Mittelpunkt eines Buttons, "" wenn unbekannt (Bildschirmpixel).
func button_center(id: String) -> Vector2:
	_recalc_if_needed()
	for b: Dictionary in _btns:
		if String(b["id"]) == id:
			return b["c"] as Vector2
	return Vector2.ZERO


## Testeingabe: einen Touch an einem Bildschirmpunkt pressen/loslassen.
func debug_touch(pos: Vector2, pressed: bool, index: int = 777) -> void:
	_recalc_if_needed()
	_touch(index, pos, pressed)


## Testeingabe: einen laufenden Touch verschieben (Stick ziehen).
func debug_drag(pos: Vector2, index: int = 777) -> void:
	_recalc_if_needed()
	_drag(index, pos)


# ------------------------------------------------------------------ Loop
func _process(_dt: float) -> void:
	if not _active:
		return
	_recalc_if_needed()
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		_recalc_if_needed()
		_touch(t.index, t.position, t.pressed)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_drag(d.index, d.position)


# ------------------------------------------------------------------ Layout
func _recalc_if_needed() -> void:
	var vp := Vector2(1280.0, 720.0)
	if is_inside_tree():
		vp = get_viewport_rect().size
	if vp.x < 8.0 or vp.y < 8.0:
		vp = Vector2(1280.0, 720.0)
	if vp != _size:
		_recalc(vp)


func _recalc(vp: Vector2) -> void:
	_size = vp
	var mn := minf(vp.x, vp.y)
	var br := clampf(mn * 0.085, 40.0, 80.0)
	var m := clampf(mn * 0.045, 16.0, 40.0)
	_stick_r = clampf(mn * 0.20, 70.0, 165.0)
	_stick_c = Vector2(m + _stick_r, vp.y - m - _stick_r)

	# 2x3-Raster rechts unten (ZIELEN in der Mitte, größer)
	var x1 := vp.x - m - br
	var x2 := vp.x - m - br - br * 2.35
	var y1 := vp.y - m - br
	var y2 := y1 - br * 2.35
	var y3 := y2 - br * 2.35
	var pos := {
		"pause": Vector2(x1, y3), "aim": Vector2(x1, y2), "jump": Vector2(x1, y1),
		"scan": Vector2(x2, y2), "shout": Vector2(x2, y1), "cancel": Vector2(x2, y3),
	}
	_btns = []
	_actions_map = {}
	for b: Array in BUTTONS:
		var id := String(b[0])
		_btns.append({
			"id": id, "de": String(b[1]), "en": String(b[2]), "actions": b[3],
			"c": pos.get(id, Vector2.ZERO), "r": br * (1.18 if id == "aim" else 1.0),
		})
		_actions_map[id] = b[3]


# ------------------------------------------------------------------ Treffer
func _hit(pos: Vector2) -> String:
	for b: Dictionary in _btns:
		if pos.distance_to(b["c"] as Vector2) <= float(b["r"]) * 1.12:
			return String(b["id"])
	if pos.distance_to(_stick_c) <= _stick_r * 1.35:
		return "stick"
	return ""


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		if _touch_widget.has(index):
			return
		var id := _hit(pos)
		if id == "":
			return
		_touch_widget[index] = id
		_press_id(id, pos)
	else:
		if not _touch_widget.has(index):
			return
		var id := String(_touch_widget[index])
		_touch_widget.erase(index)
		_release_id(id)


func _drag(index: int, pos: Vector2) -> void:
	if not _touch_widget.has(index):
		return
	if String(_touch_widget[index]) == "stick":
		_update_stick(pos)


func _press_id(id: String, pos: Vector2) -> void:
	_pressed[id] = true
	if id == "stick":
		_update_stick(pos)
	else:
		for a: String in _actions_of(id):
			Input.action_press(a)


func _release_id(id: String) -> void:
	_pressed[id] = false
	if id == "stick":
		for a: String in _stick_actions:
			Input.action_release(a)
		_stick_actions.clear()
		_knob = Vector2.ZERO
	else:
		for a: String in _actions_of(id):
			Input.action_release(a)


func _actions_of(id: String) -> Array:
	return _actions_map.get(id, []) as Array


# ------------------------------------------------------------------ Stick
func _update_stick(pos: Vector2) -> void:
	var v := pos - _stick_c
	var n := v / _stick_r
	if n.length() > 1.0:
		n = n.normalized()
	_knob = n * _stick_r
	var want: Dictionary = {}
	if absf(n.x) > DEADZONE:
		want["move_right" if n.x > 0.0 else "move_left"] = clampf(absf(n.x), 0.0, 1.0)
	if absf(n.y) > DEADZONE:
		var s := clampf(absf(n.y), 0.0, 1.0)
		want["depth_near" if n.y > 0.0 else "depth_far"] = s
		want["down" if n.y > 0.0 else "up"] = s
	# Alte lösen, neue drücken (nur die Differenz)
	for a: String in _stick_actions.duplicate():
		if not want.has(a):
			Input.action_release(a)
			_stick_actions.erase(a)
	for a: String in want:
		Input.action_press(a, float(want[a]))
		if not _stick_actions.has(a):
			_stick_actions.append(a)


# ------------------------------------------------------------------ Sichtbarkeit
func _apply_visibility(vis: bool) -> void:
	_active = vis
	visible = vis
	if not vis:
		_release_all()


func _release_all() -> void:
	for id: String in _pressed.keys():
		_release_id(id)
	_pressed.clear()
	_touch_widget.clear()


func _on_joy_changed(_device: int, _connected: bool) -> void:
	set_enabled(_enabled_mode)


func _is_mobile() -> bool:
	return OS.has_feature("mobile") or DisplayServer.is_touchscreen_available()


# ------------------------------------------------------------------ Zeichnen
func _draw() -> void:
	if _size == Vector2.ZERO:
		return
	_draw_stick()
	for b: Dictionary in _btns:
		_draw_button(b)


func _draw_stick() -> void:
	draw_arc(_stick_c, _stick_r, 0.0, TAU, 48, C_CYAN, 2.0, false)
	var d := _stick_r * 0.20
	draw_line(_stick_c - Vector2(d, 0.0), _stick_c + Vector2(d, 0.0), C_MARK, 1.0, false)
	draw_line(_stick_c - Vector2(0.0, d), _stick_c + Vector2(0.0, d), C_MARK, 1.0, false)
	var kc := _stick_c + _knob
	draw_circle(kc, _stick_r * KNOB, C_FILL_ON)
	draw_arc(kc, _stick_r * KNOB, 0.0, TAU, 32, C_AMBER, 2.0, false)


func _draw_button(b: Dictionary) -> void:
	var c := b["c"] as Vector2
	var r := float(b["r"])
	var id := String(b["id"])
	var on := bool(_pressed.get(id, false))
	draw_circle(c, r, C_FILL_ON if on else C_FILL)
	var line := C_AMBER if (on or id == "aim") else C_CYAN
	draw_arc(c, r, 0.0, TAU, 40, line, 2.0, false)
	_label(c, _txt(b), r, on)


func _txt(b: Dictionary) -> String:
	return String(b["de"]) if I18n.get_lang() == "de" else String(b["en"])


## Beschriftung mit der HUD-Pixelschrift (Pixfont.baker muss gesetzt sein).
func _label(c: Vector2, text: String, r: float, on: bool) -> void:
	if Pixfont.baker == null or text == "":
		return
	var fit := int((r * 2.0) / float(maxi(1, text.length()) * Pixfont.ADV))
	var fs := clampi(mini(int(r / 14.0), fit), 1, 6)
	var rgb: Array = [255, 138, 44] if on else [230, 236, 240]
	var img: QImg = Pixfont.render(text, rgb, fs, null)
	if img == null or img.tex == null:
		return
	var w := float(Pixfont.text_width(text, fs))
	var h := float(Pixfont.GH * fs)
	var dst := Rect2(c - Vector2(w * 0.5, h * 0.5), Vector2(img.width(), img.height()))
	draw_texture_rect_region(img.tex, dst, img.region, Color.WHITE)
