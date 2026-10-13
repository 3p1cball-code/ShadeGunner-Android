class_name TouchControls
extends Control
## Bildschirm-Touchsteuerung für Android (und Touch-Desktops).
##
## Eigene CanvasLayer OBEN über der CRT-Kette (Layer 110 > 100), scharf über dem Bild.
## Keine eigene Spiellogik: Stick und Buttons speisen InputEventAction-Ereignisse
## über Input.parse_input_event() ein. Damit erreichen sie die Menülogik des Spiels
## (_input -> _on_action) UND den Input-Zustand (Input.is_action_pressed für aim/move/shout).
##
##   var tc := TouchControls.new()
##   tc.setup(self, settings)      # hängt die CanvasLayer in den Baum
##   tc.set_mode(mode)             # jedes Frame: Spielzustand -> Layout
##   tc.set_help(help)             # Hilfe-Overlay: nur ZURÜCK
##   tc.refresh_visibility(settings)
##
## Layouts je Zustand: play (Stick + 6 Buttons), title, pause, settings, clear,
## over/victory, intro, help. Nur sichtbar, wenn aktiv - sonst keine Auswertung.
## Sichtbarkeit settings["touch"]: "an" | "aus" | "auto" (mobil UND kein Gamepad).

const LAYER := 110                       # CRT-Kette liegt auf 100 -> darüber
const DEADZONE := 0.26                   # Stick-Mitte: kein Druck
const KNOB := 0.42                       # Knopfgröße relativ zum Stickradius
const REPEAT_DELAY := 0.4                # Halten: erste Wiederholung
const REPEAT_RATE := 0.15                # danach alle ...

const HUD_W := 1280.0                    # HUD-Koordinaten (hud.gd)
const HUD_H := 720.0

## Englische Rückfälle, falls DI18n.TR den deutschen Schlüssel nicht kennt.
const EN := {
	"ZIELEN": "AIM", "SPRUNG": "JUMP", "RUF": "SHOUT", "ABBRECHEN": "CANCEL",
	"START": "START", "EINSTELLUNGEN": "SETTINGS", "HILFE": "HELP", "TITEL": "TITLE",
	"ZURÜCK": "BACK", "NOCHMAL": "AGAIN", "OK": "OK", "SCAN": "SCAN", "PAUSE": "PAUSE",
}

const NEEDED_ACTIONS := ["move_left", "move_right", "depth_far", "depth_near",
	"aim", "scan", "jump", "shout", "cancel", "pause", "confirm", "up", "down",
	"help", "open_settings", "to_title", "restart"]

# Farben in der HUD-Anmutung (noir16, Amber/Cyan)
const C_FILL := Color(0.075, 0.098, 0.16, 0.55)
const C_FILL_ON := Color(0.18, 0.24, 0.38, 0.80)
const C_AMBER := Color(1.0, 0.541, 0.173, 0.95)
const C_CYAN := Color(0.251, 0.824, 0.863, 0.70)
const C_MARK := Color(0.44, 0.46, 0.52, 0.8)
const C_TEXT := Color(0.90, 0.925, 0.94, 1.0)

## Testhaken: mitschneiden, was eingespeist wird ([Aktion, gedrückt]).
var record := false
var event_log: Array = []

var _layer: CanvasLayer
var _host: Node                          # Spiel (für chain.aspect_mode), darf fehlen
var _enabled_mode := "auto"
var _active := false
var _mode := "play"
var _help := false

var _size := Vector2.ZERO
var _aspect := ""
var _key := ""                           # aktuelles Layout
var _has_stick := false
var _stick_c := Vector2.ZERO
var _stick_r := 120.0
var _knob := Vector2.ZERO
var _w: Array = []                       # Widgets des aktuellen Layouts (Dictionary)

var _touch_widget: Dictionary = {}       # Touch-Index -> Widget-id
var _pressed: Dictionary = {}            # Widget-id -> bool
var _hold: Dictionary = {}               # Widget-id -> [gehalten s, nächste Wiederholung s]
var _stick_actions: Array = []           # gerade gedrückte Stick-Aktionen


## Aktionen anlegen, falls das Spiel sie noch nicht erzeugt hat (idempotent).
static func ensure_actions() -> void:
	for a: String in NEEDED_ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


## CanvasLayer (Layer 110) im Baum anlegen und self hineinhängen.
func setup(parent: Node, settings: Dictionary) -> void:
	if _layer != null:
		return
	_host = parent
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


## Spielzustand (game.mode) - jedes Frame aufrufbar, wechselt nur bei Änderung.
func set_mode(mode: String) -> void:
	if mode != _mode:
		_mode = mode
		_relayout_if_needed()


## Hilfe-Overlay aktiv: nur ZURÜCK.
func set_help(on: bool) -> void:
	if on != _help:
		_help = on
		_relayout_if_needed()


func is_active() -> bool:
	return _active


## Liegt der Punkt über einem im aktuellen Zustand sichtbaren Bedienelement?
func is_over_controls(pos: Vector2) -> bool:
	if not _active:
		return false
	_recalc_if_needed()
	return _hit(pos) != ""


## Mittelpunkt des virtuellen Sticks (Bildschirmpixel; nur im Layout "play").
func stick_center() -> Vector2:
	_recalc_if_needed()
	return _stick_c


## Mittelpunkt eines sichtbaren Buttons (Vector2.ZERO wenn nicht vorhanden).
func button_center(id: String) -> Vector2:
	_recalc_if_needed()
	var w := _find(id)
	return Vector2.ZERO if w.is_empty() else _center(w)


## Ids der im aktuellen Zustand sichtbaren Buttons (ohne Stick).
func button_ids() -> Array:
	_recalc_if_needed()
	var ids: Array = []
	for w: Dictionary in _w:
		ids.append(String(w["id"]))
	return ids


## Aktuelles Layout ("play", "title", ... "help").
func layout_key() -> String:
	_recalc_if_needed()
	return _key


## Testeingabe: einen Touch an einem Bildschirmpunkt pressen/loslassen.
func debug_touch(pos: Vector2, pressed: bool, index: int = 777) -> void:
	_recalc_if_needed()
	_touch(index, pos, pressed)


## Testeingabe: einen laufenden Touch verschieben (Stick ziehen).
func debug_drag(pos: Vector2, index: int = 777) -> void:
	_recalc_if_needed()
	_drag(index, pos)


## Testeingabe: Zeit für die Halte-Wiederholung vorspulen.
func debug_tick(dt: float) -> void:
	_repeat_step(dt)


# ------------------------------------------------------------------ Loop
func _process(dt: float) -> void:
	if not _active:
		return
	_recalc_if_needed()
	_repeat_step(dt)
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


# ------------------------------------------------------------------ Ereignisse
func _emit(action: String, pressed: bool, strength: float = 1.0) -> void:
	var ev := InputEventAction.new()
	ev.action = StringName(action)
	ev.pressed = pressed
	ev.strength = clampf(strength, 0.0, 1.0) if pressed else 0.0
	if record:
		event_log.append([action, pressed])
	Input.parse_input_event(ev)


func _repeat_step(dt: float) -> void:
	for id: String in _hold.keys():
		var w := _find(id)
		if w.is_empty() or not bool(_pressed.get(id, false)):
			_hold.erase(id)
			continue
		var h: Array = _hold[id]
		var t := float(h[0]) + dt
		var nxt := float(h[1])
		while t >= nxt:
			for a: String in (w["actions"] as Array):
				_emit(a, true)
			nxt += REPEAT_RATE
		_hold[id] = [t, nxt]


# ------------------------------------------------------------------ Layout
func _layout_key() -> String:
	if _help:
		return "help"
	match _mode:
		"play", "cleared", "failing":
			return "play"
		"over", "victory":
			return "end"
		"title", "pause", "settings", "clear", "intro":
			return _mode
	return "none"


## Bildformat der CRT-Kette (game.chain.aspect_mode); bewusst ohne Typbindung an CRTChain.
func _aspect_mode() -> String:
	if _host != null and is_instance_valid(_host):
		var ch: Variant = _host.get("chain")
		if ch is Object and is_instance_valid(ch):
			var am: Variant = (ch as Object).get("aspect_mode")
			if am is String:
				return am
	return "auto"


func _recalc_if_needed() -> void:
	var vp := Vector2(1280.0, 720.0)
	if is_inside_tree():
		vp = get_viewport_rect().size
	if vp.x < 8.0 or vp.y < 8.0:
		vp = Vector2(1280.0, 720.0)
	var asp := _aspect_mode()
	if vp != _size or asp != _aspect or _layout_key() != _key:
		_size = vp
		_aspect = asp
		_relayout()


func _relayout_if_needed() -> void:
	if _layout_key() != _key:
		_relayout()


## Neues Layout: gehaltene Elemente lösen (sonst bleiben Aktionen hängen).
func _relayout() -> void:
	_release_all()
	_key = _layout_key()
	_w = []
	_has_stick = false
	if _size == Vector2.ZERO:
		_size = Vector2(1280.0, 720.0)
	match _key:
		"play":
			_lay_play()
		"title":
			_lay_row([_btn("settings", "EINSTELLUNGEN", ["open_settings"]),
				_btn("start", "START", ["confirm"], true), _btn("help", "HILFE", ["help"])])
		"pause":
			_lay_row([_btn("settings", "EINSTELLUNGEN", ["open_settings"]),
				_btn("resume", "WEITER", ["pause"], true, "RESUME"), _btn("title", "TITEL", ["to_title"])])
		"end":
			_lay_row([_btn("title", "TITEL", ["to_title"]), _btn("again", "NOCHMAL", ["restart"], true)])
		"intro":
			_lay_corner(_btn("continue", "WEITER", ["confirm"], true, "CONTINUE"), false)
		"help":
			_lay_corner(_btn("back", "ZURÜCK", ["help"], true), true)
		"settings":
			_lay_settings()
		"clear":
			_lay_clear()
	queue_redraw()


## Widget-Grundgerüst (Rechteck; Kreis/Pfeil werden danach gesetzt).
func _btn(id: String, de: String, actions: Array, accent: bool = false, en: String = "") -> Dictionary:
	return {"id": id, "de": de, "en": en, "actions": actions, "shape": "rect", "rect": Rect2(),
		"c": Vector2.ZERO, "r": 0.0, "icon": "", "repeat": false, "accent": accent, "group": ""}


func _metrics() -> Dictionary:
	var mn := minf(_size.x, _size.y)
	return {"m": clampf(mn * 0.045, 12.0, 40.0), "bh": maxf(_size.y * 0.13, 56.0)}


## HUD-Fläche (1280x720) auf dem Bildschirm, wie CRTChain sie abbildet.
func _hud_rect() -> Rect2:
	var cell := 0.0
	if _aspect == "auto":
		cell = maxf(_size.x / 640.0, _size.y / 360.0)
	else:
		cell = minf(_size.x / 640.0, _size.y / 360.0)
	var pw := 640.0 * cell
	var ph := 360.0 * cell
	return Rect2((_size.x - pw) / 2.0, (_size.y - ph) / 2.0, pw, ph)


func _hud_x(x: float) -> float:
	var r := _hud_rect()
	return r.position.x + x / HUD_W * r.size.x


func _hud_y(y: float) -> float:
	var r := _hud_rect()
	return r.position.y + y / HUD_H * r.size.y


func _lay_play() -> void:
	var mn := minf(_size.x, _size.y)
	var br := clampf(mn * 0.085, 40.0, 80.0)
	var m := clampf(mn * 0.045, 16.0, 40.0)
	_has_stick = true
	_stick_r = clampf(mn * 0.20, 70.0, 165.0)
	_stick_c = Vector2(m + _stick_r, _size.y - m - _stick_r)
	# 2x3-Raster rechts unten (ZIELEN in der Mitte, größer)
	var x1 := _size.x - m - br
	var x2 := x1 - br * 2.35
	var y1 := _size.y - m - br
	var y2 := y1 - br * 2.35
	var y3 := y2 - br * 2.35
	var spec: Array = [
		["cancel", "ABBRECHEN", ["cancel"], Vector2(x2, y3)], ["pause", "PAUSE", ["pause"], Vector2(x1, y3)],
		["scan", "SCAN", ["scan"], Vector2(x2, y2)], ["aim", "ZIELEN", ["aim"], Vector2(x1, y2)],
		["shout", "RUF", ["shout"], Vector2(x2, y1)], ["jump", "SPRUNG", ["jump"], Vector2(x1, y1)],
	]
	for s: Array in spec:
		var id := String(s[0])
		var w := _btn(id, String(s[1]), s[2] as Array, id == "aim")
		w["shape"] = "circle"
		w["c"] = s[3]
		w["r"] = br * (1.18 if id == "aim" else 1.0)
		_w.append(w)


## Breite Buttons nebeneinander am unteren Rand (Titel/Pause/Ende).
func _lay_row(items: Array) -> void:
	var mt := _metrics()
	var m := float(mt["m"])
	var h := float(mt["bh"])
	var gap := m * 0.8
	var n := items.size()
	var bw := minf(_size.x * 0.28, (_size.x - 2.0 * m - (n - 1) * gap) / n)
	var total := n * bw + (n - 1) * gap
	var x := (_size.x - total) / 2.0
	var y := _size.y - m - h
	for w: Dictionary in items:
		w["rect"] = Rect2(x, y, bw, h)
		w["group"] = "row"
		_w.append(w)
		x += bw + gap


## Ein Button in der Ecke: unten rechts, oder oben rechts (top=true).
func _lay_corner(w: Dictionary, top: bool) -> void:
	var mt := _metrics()
	var m := float(mt["m"])
	var h := float(mt["bh"])
	var bw := clampf(_size.x * 0.22, h * 1.8, _size.x * 0.4)
	w["rect"] = Rect2(_size.x - m - bw, m if top else _size.y - m - h, bw, h)
	_w.append(w)


## Einstellungen: Liste in der Mitte bleibt frei. Links ZURÜCK (oben) und ◀ (unten),
## rechts ▲ ▼ und ▶ übereinander - jeweils in den Spalten neben der Liste.
func _lay_settings() -> void:
	var mt := _metrics()
	var h := float(mt["bh"])
	var left := maxf(0.0, _hud_x(280.0) - 6.0)            # linker Rand der Liste
	var right := minf(_size.x, _hud_x(1000.0) + 6.0)      # rechter Rand der Liste
	var colw := minf(left, _size.x - right)
	var ms := clampf(colw * 0.08, 6.0, 32.0)
	var r := clampf((colw - 2.0 * ms) / 2.0, _size.y * 0.055, h * 0.62)
	# Spaltenmitte; ist die Spalte schmaler als ein Button, an den Rand rücken
	var lx := maxf(ms + r, left / 2.0)
	var rx := _size.x - maxf(ms + r, (_size.x - right) / 2.0)
	var yb := _size.y - ms - r
	var step := r * 2.3

	var back := _btn("back", "ZURÜCK", ["cancel"], true)
	var bw := maxf(minf(colw - 2.0 * ms, h * 2.6), 2.0 * r)
	back["rect"] = Rect2(lx - bw / 2.0, ms, bw, minf(h, r * 2.0))
	_w.append(back)
	for s: Array in [["up", "up", Vector2(rx, yb - 2.0 * step), true],
			["down", "down", Vector2(rx, yb - step), true],
			["right", "move_right", Vector2(rx, yb), false],
			["left", "move_left", Vector2(lx, yb), false]]:
		var w := _btn(String(s[0]), "", [String(s[1])])
		w["shape"] = "circle"
		w["icon"] = s[0]
		w["c"] = s[2]
		w["r"] = r
		w["repeat"] = s[3]
		_w.append(w)


## Upgrade-Wahl: ◀ links, OK Mitte, ▶ rechts im Streifen unter den Karten.
func _lay_clear() -> void:
	var mt := _metrics()
	var m := float(mt["m"])
	var band := _size.y - _hud_y(578.0)
	var h := clampf(band - 2.0 * m * 0.5, _size.y * 0.11, float(mt["bh"]))
	var y := _size.y - m * 0.5 - h
	var aw := h * 1.4
	var ok := _btn("ok", "OK", ["confirm"], true)
	var ow := minf(_size.x * 0.28, _size.x - 2.0 * (m + aw + m))
	ok["rect"] = Rect2((_size.x - ow) / 2.0, y, ow, h)
	var lft := _btn("left", "", ["move_left"])
	lft["icon"] = "left"
	lft["rect"] = Rect2(m, y, aw, h)
	var rgt := _btn("right", "", ["move_right"])
	rgt["icon"] = "right"
	rgt["rect"] = Rect2(_size.x - m - aw, y, aw, h)
	_w.append_array([lft, ok, rgt])


# ------------------------------------------------------------------ Treffer
func _find(id: String) -> Dictionary:
	for w: Dictionary in _w:
		if String(w["id"]) == id:
			return w
	return {}


func _center(w: Dictionary) -> Vector2:
	if String(w["shape"]) == "circle":
		return w["c"] as Vector2
	return (w["rect"] as Rect2).get_center()


func _hit(pos: Vector2) -> String:
	for w: Dictionary in _w:
		if String(w["shape"]) == "circle":
			if pos.distance_to(w["c"] as Vector2) <= float(w["r"]) * 1.12:
				return String(w["id"])
		elif (w["rect"] as Rect2).grow(6.0).has_point(pos):
			return String(w["id"])
	if _has_stick and pos.distance_to(_stick_c) <= _stick_r * 1.35:
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
	if bool(_pressed.get(id, false)):
		return
	_pressed[id] = true
	if id == "stick":
		_update_stick(pos)
		return
	var w := _find(id)
	for a: String in (w.get("actions", []) as Array):
		_emit(a, true)
	if bool(w.get("repeat", false)):
		_hold[id] = [0.0, REPEAT_DELAY]


func _release_id(id: String) -> void:
	if not bool(_pressed.get(id, false)):
		return
	_pressed[id] = false
	_hold.erase(id)
	if id == "stick":
		for a: String in _stick_actions:
			_emit(a, false)
		_stick_actions.clear()
		_knob = Vector2.ZERO
		return
	var w := _find(id)
	for a: String in (w.get("actions", []) as Array):
		_emit(a, false)


# ------------------------------------------------------------------ Stick
## Drücken/Loslassen nur beim Über-/Unterschreiten der Schwelle.
func _update_stick(pos: Vector2) -> void:
	var n := (pos - _stick_c) / _stick_r
	if n.length() > 1.0:
		n = n.normalized()
	_knob = n * _stick_r
	var want: Dictionary = {}
	if absf(n.x) > DEADZONE:
		want["move_right" if n.x > 0.0 else "move_left"] = absf(n.x)
	if absf(n.y) > DEADZONE:
		want["depth_near" if n.y > 0.0 else "depth_far"] = absf(n.y)
	for a: String in _stick_actions.duplicate():
		if not want.has(a):
			_emit(a, false)
			_stick_actions.erase(a)
	for a: String in want:
		if not _stick_actions.has(a):
			_emit(a, true, float(want[a]))
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
	_hold.clear()
	_touch_widget.clear()


func _on_joy_changed(_device: int, _connected: bool) -> void:
	set_enabled(_enabled_mode)


func _is_mobile() -> bool:
	return OS.has_feature("mobile") or DisplayServer.is_touchscreen_available()


# ------------------------------------------------------------------ Zeichnen
func _txt(w: Dictionary) -> String:
	var de := String(w["de"])
	if de == "" or I18n.get_lang() == "de":
		return de
	if DI18n.TR.has(de):
		return I18n.t(de)
	var en := String(w["en"])
	return en if en != "" else String(EN.get(de, de))


## Pixfont-Skala, die in das Element passt.
func _fit(w: Dictionary, text: String) -> int:
	var n := float(maxi(1, text.length()) * Pixfont.ADV)
	if String(w["shape"]) == "circle":
		var r := float(w["r"])
		return clampi(mini(int(r / 14.0), int(r * 2.0 / n)), 1, 6)
	var rc := w["rect"] as Rect2
	return clampi(mini(int(rc.size.y * 0.34 / 7.0), int(rc.size.x * 0.84 / n)), 1, 7)


func _draw() -> void:
	if _size == Vector2.ZERO:
		return
	if _has_stick:
		_draw_stick()
	# einheitliche Schriftgröße je Gruppe (Button-Reihe)
	var group_fs: Dictionary = {}
	for w: Dictionary in _w:
		var g := String(w["group"])
		if g != "":
			var f := _fit(w, _txt(w))
			group_fs[g] = mini(int(group_fs.get(g, 99)), f)
	for w: Dictionary in _w:
		var g := String(w["group"])
		var t := _txt(w)
		var fs := int(group_fs[g]) if g != "" else _fit(w, t)
		_draw_button(w, t, fs)


func _draw_stick() -> void:
	draw_arc(_stick_c, _stick_r, 0.0, TAU, 48, C_CYAN, 2.0, false)
	var d := _stick_r * 0.20
	draw_line(_stick_c - Vector2(d, 0.0), _stick_c + Vector2(d, 0.0), C_MARK, 1.0, false)
	draw_line(_stick_c - Vector2(0.0, d), _stick_c + Vector2(0.0, d), C_MARK, 1.0, false)
	var kc := _stick_c + _knob
	draw_circle(kc, _stick_r * KNOB, C_FILL_ON)
	draw_arc(kc, _stick_r * KNOB, 0.0, TAU, 32, C_AMBER, 2.0, false)


func _draw_button(w: Dictionary, text: String, fs: int) -> void:
	var id := String(w["id"])
	var on := bool(_pressed.get(id, false))
	var line := C_AMBER if (on or bool(w["accent"])) else C_CYAN
	var c := _center(w)
	var sz := 0.0
	if String(w["shape"]) == "circle":
		var r := float(w["r"])
		draw_circle(c, r, C_FILL_ON if on else C_FILL)
		draw_arc(c, r, 0.0, TAU, 40, line, 2.0, false)
		sz = r
	else:
		var rc := (w["rect"] as Rect2)
		rc = Rect2(rc.position.round(), rc.size.round())
		draw_rect(rc, C_FILL_ON if on else C_FILL)
		draw_rect(rc, line, false, 2.0)
		# HUD-Akzent: kurze Eckmarken oben links / unten rechts
		var k := minf(rc.size.x, rc.size.y) * 0.18
		draw_rect(Rect2(rc.position, Vector2(k, 3.0)), line)
		draw_rect(Rect2(rc.end - Vector2(k, 3.0), Vector2(k, 3.0)), line)
		sz = minf(rc.size.x, rc.size.y) * 0.5
	var icon := String(w["icon"])
	if icon != "":
		_draw_arrow(c, sz * 0.5, icon, C_AMBER if on else C_TEXT)
	elif text != "":
		_label(c, text, fs, on)


## Gefülltes Dreieck (pixelgenau gerundet).
func _draw_arrow(c: Vector2, s: float, dir: String, col: Color) -> void:
	var pts := PackedVector2Array()
	match dir:
		"up":
			pts = [c + Vector2(0, -s), c + Vector2(s, s * 0.7), c + Vector2(-s, s * 0.7)]
		"down":
			pts = [c + Vector2(0, s), c + Vector2(-s, -s * 0.7), c + Vector2(s, -s * 0.7)]
		"left":
			pts = [c + Vector2(-s, 0), c + Vector2(s * 0.7, -s), c + Vector2(s * 0.7, s)]
		_:
			pts = [c + Vector2(s, 0), c + Vector2(-s * 0.7, s), c + Vector2(-s * 0.7, -s)]
	for i in pts.size():
		pts[i] = pts[i].round()
	draw_colored_polygon(pts, col)


## Beschriftung mit der HUD-Pixelschrift (Pixfont.baker muss gesetzt sein).
func _label(c: Vector2, text: String, fs: int, on: bool) -> void:
	if Pixfont.baker == null or text == "":
		return
	var rgb: Array = [255, 138, 44] if on else [230, 236, 240]
	var img: QImg = Pixfont.render(text, rgb, fs, null)
	if img == null or img.tex == null:
		return
	var w := float(Pixfont.text_width(text, fs))
	var h := float(Pixfont.GH * fs)
	var dst := Rect2((c - Vector2(w * 0.5, h * 0.5)).round(), Vector2(img.width(), img.height()))
	draw_texture_rect_region(img.tex, dst, img.region, Color.WHITE)
