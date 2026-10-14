class_name HUD
extends RefCounted
## HUD und Bildschirm-Overlays (hud.py) in einem eigenen Ziel (HUD_SCALE x Dither-Auflösung).
##
## Original: QImage 1280x720, premultipliziert, im Bayer-Shader nach dem Dithern
## über das Bild gelegt. Hier: transparenter SubViewport 1280x720 mit einem Node2D,
## in das jeden Frame per QP gezeichnet wird. Die Textur geht an CRTChain.hud_tex.
##
##   var hud := HUD.new()
##   chain.hud_tex = hud.setup(self)          # Baker + SubViewport VOR der CRT-Kette
##   hud.render(world, scene, dt, ui)         # jeden Frame
##
## world/scene sind die Godot-Gegenstücke mit den Python-Namen (sim.py / scene.py).

const S := Config.HUD_SCALE
## HUD-Breite zur Laufzeit (View.W x HUD_SCALE, 1280 bei 16:9); Höhe fest 720.
## Rechts ausgerichtetes hängt an HW, Mittiges an HW/2. Bei HW = 1280 ist das HUD
## pixelgleich zum Original; schmaler (bis 960 = 4:3) wird umgebrochen bzw. umgestellt.
static var HW: int:
	get: return View.hud_w()
const HH := DHud.HH
const BASE_HW := DHud.HW
const C := DHud.C
const VOID := DHud.VOID
const NIGHT := DHud.NIGHT
const NAVY := DHud.NAVY
const INDIGO := DHud.INDIGO
const BLUE := DHud.BLUE
const STEEL := DHud.STEEL
const CRIMSON := DHud.CRIMSON
const SLATE := DHud.SLATE        # HUD-Grau (Palette 7 ist jetzt Natrium-Orange)
const ASH := DHud.ASH
const PALE := DHud.PALE
const WHITE := DHud.WHITE
const TEAL := DHud.TEAL
const CYAN := DHud.CYAN
const MAGENTA := DHud.MAGENTA
const AMBER := DHud.AMBER
const VIOLET := DHud.VIOLET
const RED := DHud.RED
const GREEN := DHud.GREEN

# Augenreflex-Emblem über dem Kopf: 32er Icon, nearest x HUD_SCALE (= Spielpixelraster)
const EYE_ICON := DHud.EYE_ICON
const EYE_PX := DHud.EYE_PX
const EYE_LIFE := DHud.EYE_LIFE
const ORDER := DDetection.ORDER
const TELLS := DDetection.TELLS

# Ziel-Panel links unten (_target_panel): rechte Kante + Abstand, Oberkante
const TARGET_X1 := 34 + 306 + 16
const TARGET_Y0 := DHud.HH - 188
# Einstellungsmenü (_settings / settings_row_at)
const SET_W := 720
const SET_ROWH := 42
const SET_GAP := 10
const SET_Y := 176
const SET_MAXROWS := 8          # war 9: dann lagen die Hinweise auf der letzten Zeile
# Upgrade-Wahl (_clear / option_at)
const CLEAR_Y := 380
const CLEAR_H := 190

# Zeilen des Einstellungsmenüs: [Schlüssel, Label, Wert-Funktion, Art]
static var SETTING_ROWS: Array = _make_setting_rows()

var img: SubViewport            # Ziel (statt QImage)
var host: Node2D
var p: QP
var t := 0.0
var _msg := ""
var _msg_t := 0.0
var _log_len := 0
var _log_ref: Variant = null
var _dt := 1.0 / 60.0
var _eye_seen: Dictionary = {}  # uid -> HUD-Zeit, als der Augenreflex erkannt wurde
var _eye_world: Variant = null


static func conf_color(c: float) -> Array:
	return CYAN if c >= 0.66 else (AMBER if c >= 0.33 else ASH)


static func rank_of(score: int, civs: int, won: bool) -> String:
	if won and civs == 0 and score >= 2600:
		return "S"
	if score >= 2000 and civs <= 1:
		return "A"
	if score >= 1200:
		return "B"
	if score >= 500:
		return "C"
	return "D"


## hud.wrap (Name kollidiert mit dem globalen wrap()).
static func wrap_(text: String, width_chars: int) -> Array:
	var lines: Array = []
	var cur := ""
	for w: String in text.split(" ", false):
		if w.strip_edges() == "":
			continue
		if cur.length() + w.length() + (1 if cur != "" else 0) > width_chars:
			lines.append(cur)
			cur = w
		else:
			cur = (cur + " " + w) if cur != "" else w
	if cur != "":
		lines.append(cur)
	return lines


static func _make_setting_rows() -> Array:
	return [
		["music", "MUSIK", func(s: Dictionary) -> String: return Py.fmt("{:3d}%", [Py.round(float(s["music"]) * 100)]), "range"],
		["sfx", "EFFEKTE", func(s: Dictionary) -> String: return Py.fmt("{:3d}%", [Py.round(float(s["sfx"]) * 100)]), "range"],
		["quality", "QUALITÄT", func(s: Dictionary) -> String:
			return String({"hoch": "HOCH", "mittel": "MITTEL", "niedrig": "NIEDRIG"}.get(s.get("quality", "mittel"), "MITTEL")), "cycle"],
		["reflections", "REFLEXIONEN", func(s: Dictionary) -> String: return "AN" if s.get("reflections", true) else "AUS", "toggle"],
		["rain", "REGEN", func(s: Dictionary) -> String: return String({"viel": "VIEL", "wenig": "WENIG", "aus": "AUS"}.get(s.get("rain", "viel"), "VIEL")), "cycle"],
		["fog", "NEBEL", func(s: Dictionary) -> String: return "AN" if s.get("fog", true) else "AUS", "toggle"],
		["fx", "FX", func(s: Dictionary) -> String: return "AN" if s.get("fx", true) else "AUS", "toggle"],
		["aspect", "BILDFORMAT", func(s: Dictionary) -> String:
			return "AUTO (BILDSCHIRM)" if s.get("aspect", "auto") == "auto" else "16:9", "toggle"],
		["render_mode", "DARSTELLUNG", func(s: Dictionary) -> String: return "TEXT" if s.get("render_mode", "crt") == "text" else "CRT", "toggle"],
		["touch", "TOUCH-STEUERUNG", func(s: Dictionary) -> String: return String({"auto": "AUTO", "an": "AN", "aus": "AUS"}.get(s.get("touch", "auto"), "AUTO")), "cycle"],
		["resolution", "AUFLÖSUNG", func(s: Dictionary) -> String: return "%s x %s" % [_istr(s["resolution"][0]), _istr(s["resolution"][1])], "cycle"],
		["fullscreen", "VOLLBILD", func(s: Dictionary) -> String: return "AN" if s["fullscreen"] else "AUS", "toggle"],
		["scanlines", "SCANLINES", func(s: Dictionary) -> String: return "AN" if s["scanlines"] else "AUS", "toggle"],
		["difficulty", "SCHWIERIGKEIT", func(s: Dictionary) -> String:
			return String((Config.DIFFICULTY.get(s.get("difficulty", "normal"), Config.DIFFICULTY["normal"]) as Dictionary)["label"]), "cycle"],
		["lang", "SPRACHE", func(s: Dictionary) -> String: return I18n.lang_name(String(s.get("lang", "de"))), "cycle"],
		["renderer", "RENDERER", func(s: Dictionary) -> String: return "GPU" if s.get("renderer") != "software" else "SOFTWARE", "toggle"],
	]


## Zahl wie Pythons str(int) (JSON-floats ohne ".0").
static func _istr(v: Variant) -> String:
	if v is float and floorf(v) == v:
		return str(int(v))
	return str(v)


## getattr(obj, name, default) für Objekte/Dictionaries.
static func _ga(o: Variant, key: String, default: Variant = null) -> Variant:
	if o == null:
		return default
	if o is Dictionary:
		return (o as Dictionary).get(key, default)
	var v: Variant = (o as Object).get(key)
	return default if v == null else v


static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		return v != ""
	if v is Array:
		return not (v as Array).is_empty()
	if v is Dictionary:
		return not (v as Dictionary).is_empty()
	return true


## str.upper() wie Python (ß -> SS).
static func _upper(s: String) -> String:
	return s.replace("ß", "SS").to_upper()


# ------------------------------------------------------------------ Einrichtung
## Legt (falls nötig) einen Baker für die Schrift und den transparenten HUD-SubViewport
## unter `parent` an und gibt dessen Textur zurück (für CRTChain.hud_tex).
## Reihenfolge im Baum: Baker, HUD-Viewport, danach erst die CRT-Kette einhängen.
func setup(parent: Node) -> Texture2D:
	if Pixfont.baker == null:
		var b := Baker.new()
		b.name = "HudBaker"
		parent.add_child(b)
		Pixfont.baker = b
	img = SubViewport.new()
	img.name = "HUD"
	img.size = Vector2i(HW, HH)
	img.transparent_bg = true
	img.disable_3d = true
	img.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	img.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	host = Node2D.new()
	img.add_child(host)
	parent.add_child(img)
	p = QP.new(host.get_canvas_item())
	return img.get_texture()


func texture() -> Texture2D:
	return img.get_texture() if img != null else null


# ------------------------------------------------------------------ Grundformen
func _box(q: QP, x: float, y: float, w: float, h: float, border: Array = STEEL,
		fill: Array = [6, 8, 14], alpha: int = 215) -> void:
	q.fill_rect(x, y, w, h, QP.c(fill[0], fill[1], fill[2], alpha))
	q.set_pen(QP.rgb(border), 2.0)
	q.set_no_brush()
	q.draw_rect(x + 1, y + 1, w - 2, h - 2)
	# Ecken-Akzente
	for e: Array in [[x, y, 1, 1], [x + w, y, -1, 1], [x, y + h, 1, -1], [x + w, y + h, -1, -1]]:
		var cx: float = e[0]
		var cy: float = e[1]
		q.fill_rect(cx if int(e[2]) > 0 else cx - 8, cy if int(e[3]) > 0 else cy - 3, 8, 3, QP.rgb(CYAN))


func _bar(q: QP, x: float, y: float, w: float, h: float, frac: float, col: Array,
		back: Array = [30, 34, 50]) -> void:
	q.fill_rect(x, y, w, h, QP.rgb(back))
	q.fill_rect(x, y, w * maxf(0.0, minf(1.0, frac)), h, QP.rgb(col))
	for k in range(1, 10):
		q.fill_rect(x + w * k / 10.0, y, 2, h, QP.c(6, 8, 14, 160))


func _t(q: QP, x: float, y: float, s: String, col: Array, scale: int = 2,
		align: String = "left", opacity: float = 1.0) -> int:
	return Pixfont.draw(q, x, y, I18n.t(s), col, scale, VOID, align, opacity)


# ------------------------------------------------------------------ variable Breite
## Schmaler als 16:9 (HW < 1280)? Nur dann greift das umgestellte Layout - bei 16:9
## und breiter bleibt alles exakt wie im Original (HUD-Paritaet).
static func narrow() -> bool:
	return HW < BASE_HW


## Zeilen, die in max_w Pixel (Schrift scale) passen; Wörter werden nicht getrennt,
## ein zu langes Einzelwort bekommt eine eigene Zeile.
static func wrap_px(text: String, max_w: int, scale: int = 2) -> Array:
	return wrap_(text, maxi(1, Py.ifloordiv(max_w + scale, Pixfont.ADV * scale)))


## Zentrierter Meldungstext (Original: HW/2). Schmal: unten neben dem Ziel-Panel
## (das links unten bis x = TARGET_X1 reicht), notfalls umbrochen - nach unten oder
## (up) nach oben. reveal >= 0 zeigt nur so viele Zeichen (Schreibmaschine), der
## Umbruch richtet sich dabei nach dem ganzen Text, damit nichts springt.
func _ct(q: QP, y: float, s: String, col: Array, scale: int = 2, opacity: float = 1.0,
		up: bool = false, translated: bool = false, reveal: int = -1) -> void:
	var txt := s if translated else I18n.t(s)
	if not narrow():
		Pixfont.draw(q, Py.ifloordiv(HW, 2), y, txt if reveal < 0 else txt.substr(0, reveal), col, scale, VOID, "center", opacity)
		return
	var lo := 16
	if y + 7 * scale > TARGET_Y0:
		lo = TARGET_X1
	var hi := HW - 16
	var tw := Pixfont.text_width(txt, scale)
	var cx := Py.ifloordiv(lo + hi, 2)       # unten: Mitte der freien Fläche rechts vom Ziel-Panel
	var lines: Array = [txt]
	if tw > hi - lo:
		lines = wrap_px(txt, hi - lo, scale)
	var lh := 11 * scale
	var y0 := y - (lh * (lines.size() - 1) if up else 0)
	var left := reveal if reveal >= 0 else txt.length()
	for i in lines.size():
		var ln: String = lines[i]
		if left <= 0:
			break
		Pixfont.draw(q, cx, y0 + i * lh, ln.substr(0, left), col, scale, VOID, "center", opacity)
		left -= ln.length() + 1


## Einstellungszeile unter einer HUD-Position (für Touch), -1 = keine. Gleiche Geometrie
## und gleiches Scrollen wie _settings().
func settings_row_at(hud_pos: Vector2, sel: int) -> int:
	var g := _settings_geom(sel)
	for i in range(int(g["first"]), int(g["last"])):
		var r := Rect2(g["x"], int(g["y"]) + (i - int(g["first"])) * (SET_ROWH + SET_GAP), SET_W, SET_ROWH)
		if r.has_point(hud_pos):
			return i
	return -1


## Upgrade-Karte unter einer HUD-Position (für Touch), -1 = keine. Gleiche Geometrie
## wie _clear(): mit sel exakt (die gewählte Karte ist 8 px angehoben), ohne sel
## zählt bei jeder Karte der ganze Bereich von angehoben bis abgesenkt.
func option_at(hud_pos: Vector2, n: int, sel: int = -1) -> int:
	var g := _clear_geom()
	for i in n:
		var x := int(g["x0"]) + i * (int(g["cw"]) + int(g["gap"]))
		var r := Rect2(x, CLEAR_Y - 8, int(g["cw"]), CLEAR_H + 8)
		if sel >= 0:
			r = Rect2(x, CLEAR_Y + (-8 if i == sel else 0), int(g["cw"]), CLEAR_H)
		if r.has_point(hud_pos):
			return i
	return -1


# ------------------------------------------------------------------ Haupt
func render(world: Variant, scene: Variant, dt: float, ui: Variant = null) -> Texture2D:
	var u: Dictionary = ui if ui is Dictionary and not (ui as Dictionary).is_empty() else {"mode": "play"}
	t += dt
	_dt = dt
	p.begin()
	var mode: String = u.get("mode", "play")
	if world != null and mode in ["play", "intro", "pause"]:
		_world_marks(p, world, scene)
		_panels(p, world, u)
		if mode == "play":
			_events(p, world)
			_reticle(p, u.get("mouse"), world)
			_boss(p, world)
	if world != null and _truthy(_ga(_ga(world, "run"), "cheat", false)) and mode in ["play", "pause", "intro"]:
		_t(p, HW - 16, HH - 56, "GIVEALL", MAGENTA, 2, "right")
	if mode == "title":
		_title(p, u)
	elif mode == "intro":
		_intro(p, world, u)
	elif mode == "pause":
		_pause(p)
	elif mode == "settings":
		_settings(p, u)
	elif mode == "clear":
		_clear(p, world, u)
	elif mode in ["over", "victory"]:
		_end(p, world, u, mode == "victory")
	if _truthy(u.get("help")):
		_help(p)
	p.end()
	return texture()


# ------------------------------------------------------------------ Welt-Markierungen
func _scr(scene: Variant, a: Variant, world: Variant) -> Array:
	var screen: Variant = _ga(scene, "screen", {})
	var sc: Variant = (screen as Dictionary).get(a.uid) if screen is Dictionary else null
	var cx: float
	var gy: float
	var h: float
	if sc == null:
		cx = Persp.screen_x(a.x, a.depth, world.camera_x)
		gy = Persp.ground_y(a.depth)
		h = Persp.figure_h(a.depth)
	else:
		cx = sc[0]
		gy = sc[1]
		h = sc[2]
	return [cx * S, gy * S, h * S]


func _world_marks(q: QP, world: Variant, scene: Variant) -> void:
	var t_ := t
	# Gescannte NPCs behalten einen kleinen Konfidenz-Strich überm Kopf
	for a: Variant in world.actors:
		if a.player or not a.alive or a.escaped or is_same(a, world.target):
			continue
		if not _truthy(a.revealed):
			continue
		var sc := _scr(scene, a, world)
		var cx: float = sc[0]
		var gy: float = sc[1]
		var h: float = sc[2]
		if cx < -20 or cx > HW + 20:
			continue
		var c: float = world.confidence_of(a)
		var col := conf_color(c)
		var y := gy - h * 1.08
		var w := maxf(10, h * 0.28)
		q.fill_rect(cx - w / 2, y, w, 4, QP.c(10, 12, 20, 200))
		q.fill_rect(cx - w / 2, y, w * c, 4, QP.rgb(col))
		if a.state == "flee":
			_t(q, cx, y - 18, "FLÜCHTET", AMBER, 2, "center")
		elif a.state in ["attack", "punch"]:
			_t(q, cx, y - 18, "ANGRIFF!", RED, 2, "center")
	# Ziel-Klammern
	var tg: Variant = world.target
	if tg != null and tg.alive:
		var sc := _scr(scene, tg, world)
		var cx: float = sc[0]
		var gy: float = sc[1]
		var h: float = sc[2]
		var c: float = world.confidence_of(tg)
		var col: Array = conf_color(c) if _truthy(tg.revealed) else PALE
		if tg.state in ["attack", "punch"]:
			col = RED
		var bw := h * 0.5 + 10
		var top := gy - h * 1.02 - 6
		var bot := gy + 6
		var pulse := 3 + 2 * sin(t_ * 6)
		if world.aiming:
			pulse = 1 + 6 * maxf(0.0, 1 - float(world.aim_t) / maxf(0.05, float(world.run.mods["aim_min"]) + 0.05))
		var L := 12
		q.set_no_pen()
		for e: Array in [[-1, -1], [1, -1], [-1, 1], [1, 1]]:
			var sx: int = e[0]
			var sy: int = e[1]
			var x := cx + sx * (bw / 2 + pulse)
			var y := (top - pulse) if sy < 0 else (bot + pulse)
			q.fill_rect(x - (L if sx > 0 else 0), y - (3 if sy > 0 else 0), L, 3, QP.rgb(col))
			q.fill_rect(x - (3 if sx > 0 else 0), y - (L if sy > 0 else 0), 3, L, QP.rgb(col))
		if not is_same(tg, _ga(world, "boss")):          # ROY trägt sein eigenes Label
			var label := Py.fmt("#{:04d}", [tg.uid])
			if _truthy(tg.revealed):
				label += "  %d%%" % Py.round(c * 100)
			_t(q, cx, top - pulse - 22, label, col, 2, "center")
		if tg.state == "flee":
			_t(q, cx, top - pulse - 40, "FLÜCHTET", AMBER, 2, "center")
		elif tg.state in ["attack", "punch"]:
			_t(q, cx, top - pulse - 40, "ANGRIFF!", RED, 2, "center")
		elif tg.state == "cower":
			_t(q, cx, top - pulse - 40, "ERGIBT SICH", ASH, 2, "center")
	# Endboss-Label über dem Kopf
	var bo: Variant = _ga(world, "boss")
	if bo != null and bo.alive:
		var sc := _scr(scene, bo, world)
		var bx: float = sc[0]
		var bgy: float = sc[1]
		var bh: float = sc[2]
		var col: Array = AMBER if bo.boss_invuln else WHITE
		var mercy := _truthy(_ga(world, "roy_mercy", false))
		if mercy:
			col = PALE
		_t(q, bx, bgy - bh * 1.12 - 22, "ROY", col, 3, "center")
		if bo.boss_invuln and not mercy:
			_t(q, bx, bgy - bh * 1.12 - 48, "(REDET)", ASH, 2, "center")
	# Blocker in der Schusslinie
	var b: Variant = world.blocker if world.aiming else null
	if b != null and not is_same(b, tg):
		var sc := _scr(scene, b, world)
		_t(q, sc[0], float(sc[1]) - float(sc[2]) * 1.05 - 26, "IN DER LINIE!", AMBER, 2, "center")
	# Augenreflex erkannt -> Emblem taucht über dem Kopf auf
	var eyes := _eye_marks(q, world, scene)
	# Schwebende Texte (über einem aktiven Emblem nach oben ausweichen)
	for f: Dictionary in world.floaters:
		var k: float = float(f["t"]) / float(f["life"])
		var fd: float = f["depth"]
		var cx := Persp.screen_x(float(f["x"]), fd, world.camera_x) * S
		var gy := Persp.ground_y(fd) * S
		var h := Persp.figure_h(fd) * S
		var y := gy - h * 1.15 - 40 - 36 * k - 20 * float(f.get("slot", 0))
		if eyes.has(f["uid"]):
			y -= EYE_PX + 8
		var op := 1.0 if k < 0.7 else maxf(0.0, 1 - (k - 0.7) / 0.3)
		_t(q, cx, y, String(f["text"]), f["color"], 2, "center", op)


## Spiel-Emblem (Auge im Fadenkreuz) über Personen, bei denen gerade ein Augenreflex
## erkannt wurde - egal auf welchem Weg. Es zeigt den *Tell*, nicht die Wahrheit.
## Ablauf: einblitzen (CRT-Flackern), stehen, ausflackern. Gibt die uids (Set) zurück.
func _eye_marks(q: QP, world: Variant, scene: Variant) -> Dictionary:
	if not is_same(_eye_world, world):          # neue Zone / neuer Run
		_eye_world = world
		_eye_seen = {}
		for a: Variant in world.actors:
			if a.revealed.has("pupils") and _truthy(a.tells.get("pupils")):
				_eye_seen[a.uid] = -EYE_LIFE
	var em := Assets.emblem(EYE_ICON, S)
	var shown: Dictionary = {}
	for a: Variant in world.actors:
		if a.player or not a.alive or a.escaped:
			continue
		if not a.revealed.has("pupils") or not _truthy(a.tells.get("pupils")):
			continue
		if not _eye_seen.has(a.uid):
			_eye_seen[a.uid] = t
		var t0: float = _eye_seen[a.uid]
		var age := t - t0
		if age >= EYE_LIFE or em == null:
			continue
		var sc := _scr(scene, a, world)
		var cx: float = sc[0]
		var gy: float = sc[1]
		var h: float = sc[2]
		if cx < -EYE_PX or cx > HW + EYE_PX:
			continue
		shown[a.uid] = true
		# einblitzen / ausflackern wie eine Röhre, die zündet bzw. verlischt
		if age < 0.16 and int(age * 40) % 2:
			continue
		var out := age - (EYE_LIFE - 0.45)
		if out > 0 and int(out * 24) % 3 == 0:
			continue
		var x := int(cx - EYE_PX / 2.0)
		var y := int(gy - h * 1.02 - 38 - EYE_PX)
		if age < 0.05:                        # Zündblitz: kurz weiß hinterlegt
			q.fill_rect(x + 6, y + 6, EYE_PX - 12, EYE_PX - 12, QP.rgb(WHITE))
		q.draw_image_at(x, y, em)
	return shown


# ------------------------------------------------------------------ Ereignisse / Warnungen
func _events(q: QP, world: Variant) -> void:
	var t_ := t
	var pl: Variant = world.player
	# Fahrzeuge, die noch außerhalb des Bildes heranrasen
	for v: Dictionary in _ga(world, "vehicles", []):
		var vd: float = v["depth"]
		var vdir: float = v["dir"]
		var sx := Persp.screen_x(float(v["x"]), vd, world.camera_x)
		var ahead: float = (float(pl.x) - float(v["x"])) * vdir
		if (sx < 0 and vdir > 0) or (sx > Persp.W and vdir < 0):
			if ahead > 0 and ahead < float(v["speed"]) * 3.0:
				var in_lane := absf(float(pl.depth) - vd) < 0.11
				var col: Array = RED if in_lane else AMBER
				if in_lane and int(t_ * 8) % 2:
					col = WHITE
				var y := Persp.ground_y(vd) * S - 30
				if vdir > 0:
					_t(q, 16, y, "→ FAHRZEUG", col, 2)
				else:
					_t(q, HW - 16, y, "FAHRZEUG ←", col, 2, "right")
	var P: Variant = _ga(world, "patrol")
	if P != null and (P as Dictionary).get("phase") in ["descend", "landed"]:
		var txt := "SPINNER LANDET - ABSTAND HALTEN" if P["phase"] == "descend" else "POLIZEIKONTROLLE AM BODEN"
		_ct(q, HH - 176, txt, [90, 140, 255] if int(t_ * 4) % 2 else MAGENTA, 2, 1.0, true)
	if _truthy(_ga(world, "watched", false)):
		var col: Array = RED if int(t_ * 3) % 2 else AMBER
		_ct(q, HH - 150, "IM SUCHLICHT - DIE POLIZEI SIEHT ZU", col)
	elif P != null and float(P["on"]) > 0.5:
		_ct(q, HH - 150, "SUCHLICHT: AUGENREFLEXE WERDEN SICHTBAR", PALE)
	if float(_ga(world, "blackout_t", 0)) > 0:
		if int(t_ * 2.5) % 2 == 0:
			_t(q, Py.ifloordiv(HW, 2), 196, "STROMAUSFALL", AMBER, 4, "center")
		_t(q, Py.ifloordiv(HW, 2), 236, "IM DUNKELN LEUCHTEN REPLIKANTENAUGEN", ASH, 2, "center")
	# Nudelstand: Herz auffüllen
	if int(pl.hp) < int(world.run.max_hp):
		for r: Dictionary in _ga(world, "ramen", []):
			if r["used"] or absf(float(pl.x) - float(r["x"])) >= Config.RAMEN_RANGE + 8 or float(pl.depth) >= 0.6:
				continue
			var cx := Persp.screen_x(float(r["x"]), 0.16, world.camera_x) * S
			var cy := Persp.ground_y(0.16) * S
			_t(q, cx, cy - 168, "RAMEN", AMBER, 3, "center")
			var k := minf(1.0, float(r["t"]) / Config.RAMEN_TIME)
			var bw := 170
			q.fill_rect(cx - bw / 2.0, cy - 132, bw, 9, QP.c(10, 12, 20, 210))
			q.fill_rect(cx - bw / 2.0, cy - 132, bw * k, 9, QP.rgb(AMBER))
			if k <= 0.02:
				_t(q, cx, cy - 108, "STEHEN BLEIBEN", PALE, 2, "center")
			break


func _boss(q: QP, world: Variant) -> void:
	var b: Variant = _ga(world, "boss")
	if b == null or not b.alive:
		return
	var text: Variant = _ga(world, "boss_text")
	if _truthy(_ga(world, "roy_waiting", false)):
		return                                    # er steht nur da - noch kein Kampf
	if _truthy(_ga(world, "roy_mercy", false)):
		# Kein Lebensbalken mehr - nur er, der Regen und was er sagt
		if _truthy(text):
			var k := 1.0 - float(world.boss_speak_t) / maxf(0.1, float(world.boss_text_dur))
			var line := I18n.t(text)
			var n := int(line.length() * minf(1.0, k * 1.8))
			var parts := wrap_(line.substr(0, maxi(0, n)), 56)
			for i in parts.size():
				_t(q, Py.ifloordiv(HW, 2), HH - 190 + i * 24, parts[i], PALE, 2, "center")
		return
	var w2 := 384
	var h2 := 30
	var x2 := Py.ifloordiv(HW - w2, 2)
	var y2 := 64
	if x2 < 34 + 410 + 8:          # schmal: oben ist kein Platz zwischen den Panels
		y2 = 24 + 136 + 64
	q.fill_rect(x2, y2, w2, h2, QP.c(6, 8, 14, 225))
	q.set_pen(QP.rgb(CRIMSON), 2.0)
	q.set_no_brush()
	q.draw_rect(x2, y2, w2, h2)
	q.set_no_pen()
	_t(q, x2 + 12, y2 + 6, "ROY", WHITE, 2)
	var segs := Config.ROY_HP
	var bx := x2 + 80
	var bw := w2 - 94
	var segw := float(bw) / segs
	for i in segs:
		var on := i < int(b.hp)
		q.fill_rect(bx + i * segw, y2 + 10, segw - 2, 11, QP.rgb(RED if on else [42, 22, 28]))
	if float(_ga(world, "boss_speak_t", 0.0)) > 0.0 and _truthy(text):
		var line := I18n.t(text)
		var k := 1.0 - float(world.boss_speak_t) / maxf(0.1, float(world.boss_text_dur))
		var n := int(line.length() * minf(1.0, k * 1.35))
		if narrow():
			_ct(q, HH - 172, "ROY: " + line, PALE, 2, 1.0, true, true, 5 + maxi(0, n))
		else:
			_t(q, Py.ifloordiv(HW, 2), HH - 172, "ROY: " + line.substr(0, maxi(0, n)), PALE, 2, "center")


func _reticle(q: QP, mouse: Variant, world: Variant) -> void:
	if mouse == null:
		return
	var x: float = float(mouse[0]) * S
	var y: float = float(mouse[1]) * S
	var col: Array = RED if world.aiming else PALE
	for e: Array in [[-14, -1, 9, 2], [5, -1, 9, 2], [-1, -14, 2, 9], [-1, 5, 2, 9]]:
		q.fill_rect(x + e[0], y + e[1], e[2], e[3], QP.c(4, 5, 10, 200))
		q.fill_rect(x + e[0], y + e[1] - 1, e[2], e[3], QP.rgb(col))


# ------------------------------------------------------------------ Panels
func _panels(q: QP, world: Variant, _ui: Dictionary) -> void:
	var t_ := t
	var run: Variant = world.run
	var z: Dictionary = world.zone
	var stats: Dictionary = world.stats
	var reps: int = stats["reps"]
	var quota: int = world.quota
	# oben links
	var ox := 34
	var oy := 24
	_box(q, ox, oy, 410, 88)
	_t(q, ox + 14, oy + 12, I18n.t("SEKTOR {}/5", [int(world.zone_index) + 1]), ASH)
	_t(q, ox + 146, oy + 12, _upper(I18n.t(String(z["name"]))), WHITE)
	_t(q, ox + 14, oy + 34, "AUFTRAG", ASH)
	var x := ox + 116
	for i in maxi(quota, reps):
		var done := i < reps
		var col: Array = ((CYAN if i < quota else AMBER) if done else SLATE)
		Pixfont.draw(q, x, oy + 34, "▮" if done else "▯", col, 2, VOID)
		x += 16
	_t(q, x + 8, oy + 34, "%d/%d" % [reps, quota], PALE)
	_t(q, ox + 300, oy + 34, I18n.t("REST {}", [world.reps_remaining()]), SLATE)
	_t(q, ox + 14, oy + 58, "PUNKTE", ASH)
	_t(q, ox + 116, oy + 58, Py.fmt("{:06d}", [maxi(0, int(run.score))]), WHITE)
	if int(world.combo) > 1:
		_t(q, ox + 236, oy + 58, I18n.t("KETTE X{}", [world.combo]), AMBER if int(t_ * 4) % 2 else WHITE, 2)
	# Kopfgeld-Akte
	var b: Variant = _ga(world, "bounty")
	if b != null and _truthy(_ga(world, "bounty_desc")):
		var done := _truthy(stats.get("bounty"))
		var gone: bool = not done and (not b.alive or b.escaped)
		var line1 := I18n.t("KOPFGELD  {}", [b.name])
		var line2 := ", ".join(PackedStringArray(world.bounty_desc))
		var status := "KASSIERT ✓" if done else ("ENTKOMMEN ✗" if b.escaped else ("" if not gone else "✗"))
		var bw := maxi(Pixfont.text_width(line2, 2), Pixfont.text_width(line1 + "  " + status, 2)) + 28
		var lines2: Array = [line2]
		var maxbw := HW - 34 - 410 - 16 - ox      # bis vor das rechte Panel
		if bw > maxbw:
			# Beschreibung umbrechen (Merkmale bleiben ganz, solange sie passen)
			lines2 = []
			var cur := ""
			for part: String in world.bounty_desc:
				var cand := part if cur == "" else cur + ", " + part
				if cur != "" and Pixfont.text_width(cand + ",", 2) + 28 > maxbw:
					lines2.append(cur + ",")
					cur = part
				else:
					cur = cand
			lines2.append(cur)
			var fixed: Array = []
			for ln: String in lines2:
				fixed.append_array(wrap_px(ln, maxbw - 28) if Pixfont.text_width(ln, 2) + 28 > maxbw else [ln])
			lines2 = fixed
			bw = Pixfont.text_width(line1 + "  " + status, 2) + 28
			for ln: String in lines2:
				bw = maxi(bw, Pixfont.text_width(ln, 2) + 28)
		_box(q, ox, oy + 96, bw, 58 + 22 * (lines2.size() - 1), AMBER if not done else TEAL, [6, 8, 14], 190)
		_t(q, ox + 14, oy + 106, line1, AMBER if not done else TEAL)
		if status != "":
			_t(q, ox + bw - 14, oy + 106, status, GREEN if done else RED, 2, "right")
		for i in lines2.size():
			_t(q, ox + 14, oy + 128 + 22 * i, lines2[i], PALE if not done else SLATE)
	# oben rechts
	var rx := HW - 34 - 410
	_box(q, rx, oy, 410, 136)
	_t(q, rx + 14, oy + 12, "INTEGRITÄT", ASH)
	var hx := rx + 160
	for i in int(run.max_hp):
		var full_hp := i < int(world.player.hp)
		Pixfont.draw(q, hx + i * 18, oy + 12, "♥" if full_hp else "♡", RED if full_hp else SLATE, 2, VOID)
	_t(q, rx + 14, oy + 34, "SCAN", ASH)
	var cx_ := rx + 160
	var charges: float = world.scan_charges
	var full := int(charges)
	for i in int(world.scan_max):
		if i < full:
			Pixfont.draw(q, cx_ + i * 16, oy + 34, "▮", CYAN, 2, VOID)
		else:
			Pixfont.draw(q, cx_ + i * 16, oy + 34, "▯", SLATE, 2, VOID)
			if i == full:
				var frac := charges - full
				q.fill_rect(cx_ + i * 16 + 2, oy + 34 + 12 - 10 * frac, 6, 10 * frac, QP.rgb(TEAL))
	_t(q, rx + 14, oy + 58, "VERDACHT", ASH)
	var sus: float = world.suspicion
	var scol: Array = AMBER if sus < 0.66 else (RED if int(t_ * 4) % 2 == 0 else CRIMSON)
	_bar(q, rx + 160, oy + 60, 230, 10, sus, scol)
	# Ruf (V): bereit / lädt
	var cd: float = float(_ga(world, "shout_cd", 0.0))
	var full_cd: float = Config.SHOUT_CD * float((world.run.mods as Dictionary).get("shout_cd", 1.0))
	_t(q, rx + 14, oy + 82, "RUF  V", ASH)
	if cd <= 0:
		_t(q, rx + 160, oy + 82, "BEREIT", CYAN)
		_t(q, rx + 390, oy + 82, "HALTEN", SLATE, 2, "right")
	else:
		_bar(q, rx + 160, oy + 84, 230, 10, 1.0 - cd / maxf(0.1, full_cd), TEAL)
	var un: float = float(_ga(world, "unrest", 0.0))
	_t(q, rx + 14, oy + 106, "UNRUHE", ASH)
	_bar(q, rx + 160, oy + 108, 230, 10, un, AMBER if un < 0.6 else RED)
	# Fortschritt (Mitte oben)
	var px0 := Py.ifloordiv(HW, 2) - 160
	var pw := 320
	var py := oy + 22
	if px0 < ox + 410 + 16:        # schmal: zwischen den Panels ist kein Platz -> unter das rechte
		px0 = rx + Py.ifloordiv(410 - pw, 2)
		py = oy + 136 + 26
	q.fill_rect(px0, py, pw, 2, QP.rgb(SLATE))
	var f := maxf(0.0, minf(1.0, float(world.player.x) / float(world.length)))
	var open_: bool = world.exit_open()
	q.fill_rect(px0, py, pw * f, 2, QP.rgb(CYAN))
	Pixfont.draw(q, px0 + pw * f - 4, py - 14, "▼", CYAN, 2, VOID)
	var ecol: Array = GREEN if open_ else RED
	q.fill_rect(px0 + pw - 2, py - 6, 4, 14, QP.rgb(ecol))
	_t(q, px0 + Py.ifloordiv(pw, 2), py + 12, "AUSGANG OFFEN" if open_ else "AUSGANG GESPERRT", ecol, 2, "center")
	# Ziel-Panel
	_target_panel(q, world)
	# Status / Meldungen
	var log_: Array = _ga(world, "log_", _ga(world, "log", []))   # sim.World.log heißt im Port log_
	if not is_same(log_, _log_ref) or log_.size() != _log_len:
		if not log_.is_empty() and log_.size() != _log_len:
			_msg = log_[-1]
			_msg_t = 3.0
		_log_ref = log_
		_log_len = log_.size()
	_msg_t = maxf(0.0, _msg_t - _dt)
	if _msg_t > 0 and _msg != "":
		var col: Array = RED if (_msg.contains("MENSCH") or _msg.contains("entkommen")) else PALE
		_ct(q, HH - 120, _upper(_msg), col, 2, minf(1.0, _msg_t), true)
	var hold: float = float(_ga(world, "shout_hold", -1.0))
	if hold >= Config.SHOUT_TAP:
		if float(world.shout_cd) > 0:
			_ct(q, HH - 92, "RUF LÄDT NOCH - LOSLASSEN BRICHT AB", SLATE)
		else:
			var k := minf(1.0, (hold - Config.SHOUT_TAP) / Config.SHOUT_CHARGE)
			_ct(q, HH - 92, I18n.t("LOSLASSEN: ALLE RUNTER!   RADIUS {:3d}%", [int(k * 100)]), AMBER)
	elif hold >= 0.0:
		_ct(q, HH - 92, "TIPPEN = ZIEL ANSPRECHEN   HALTEN = MENGE", SLATE)
	if world.aiming:
		var bl: Variant = world.blocker
		var tg: Variant = world.target
		var hint := "      C / RMT = ABBRECHEN"
		var main := ""
		var mcol: Array = ASH
		if bl != null and not is_same(bl, tg):
			main = "SCHUSSLINIE BLOCKIERT"
			mcol = AMBER
		elif tg != null:
			var ready: bool = float(world.aim_t) >= float(world.run.mods["aim_min"])
			main = "ZIEL ERFASST - LOSLASSEN = FEUER" if ready else "ZIELEN..."
			mcol = RED if ready else ASH
		else:
			main = "KEIN ZIEL - SCHUSS GERADEAUS"
		if narrow():               # schmal: Abbruch-Hinweis in eine eigene Zeile darunter
			_ct(q, HH - 92, main, mcol)
			_ct(q, HH - 70, I18n.t(hint).strip_edges(), mcol, 2, 1.0, false, true)
		else:
			_t(q, Py.ifloordiv(HW, 2), HH - 92, main + hint, mcol, 2, "center")
	_t(q, HW - 48, HH - 44, "H HILFE  P PAUSE", SLATE, 2, "right")


func _target_panel(q: QP, world: Variant) -> void:
	var tg: Variant = world.target
	var x := 34
	var y := HH - 188
	var w := 306
	var h := 166
	if tg == null or not tg.alive:
		_box(q, x, y + 120, w, 42, INDIGO, [6, 8, 14], 170)
		_t(q, x + 12, y + 134, "KEIN ZIEL  (MAUS / Q / TAB)", SLATE)
		return
	var c: float = world.confidence_of(tg)
	_box(q, x, y, w, h, conf_color(c) if _truthy(tg.revealed) else STEEL)
	var subj := I18n.t("SUBJEKT #{:04d}", [tg.uid])
	_t(q, x + 12, y + 10, subj, WHITE)
	var sx := x + 12 + Pixfont.text_width(subj, 2) + 16
	if float(world.scan_t) >= 0 and is_same(world.scan_target, tg):
		var k: float = float(world.scan_t) / maxf(0.01, Config.SCAN_TIME * float(world.run.mods["scan_time"]))
		_t(q, sx, y + 10, I18n.t("SCAN {:3d}%", [int(k * 100)]), CYAN)
	elif tg.scanned:
		_t(q, sx, y + 10, "GESCANNT", TEAL)
	else:
		_t(q, sx, y + 10, "BEOBACHTE", SLATE if int(t * 2) % 2 else ASH)
	var yy := y + 30
	for nm: String in ORDER:
		var lbl := I18n.t(String(TELLS[nm][3]))
		var strong: bool = TELLS[nm][2]
		_t(q, x + 12, yy, lbl, ASH)
		if tg.revealed.has(nm):
			var present := _truthy(tg.tells.get(nm))
			_t(q, x + 104, yy, "AUFFÄLLIG" if present else "UNAUFFÄLLIG", AMBER if present else SLATE)
		else:
			var hint := "SCAN" if strong else "BEOBACHTEN"
			if nm == "serial":
				hint = "NAHSCAN"
			_t(q, x + 104, yy, "? " + hint, INDIGO)
		yy += 17
	_t(q, x + 12, yy + 4, "P(REP)", ASH)
	_bar(q, x + 86, yy + 6, 150, 9, c, conf_color(c))
	_t(q, x + 242, yy + 4, Py.fmt("{:3d}%", [Py.round(c * 100)]), conf_color(c))
	var ob: float = float(tg.exposure) / Config.OBSERVE_SECONDS
	var weak := 0
	for n: Variant in tg.revealed:
		if not TELLS[n][2]:
			weak += 1
	if ob > 0.02 and weak < 2:
		q.fill_rect(x + 12, y + h - 8, (w - 24) * minf(1.0, ob), 3, QP.rgb(TEAL))


# ------------------------------------------------------------------ Overlays
func _dim(q: QP, a: int = 170) -> void:
	q.fill_rect(0, 0, HW, HH, QP.c(4, 5, 10, a))


## Pseudo-Kanji 5x7 als Menge gesetzter Pixel (render/city._glyph, hier lokal).
static func _glyph(rng: PyRandom) -> Dictionary:
	var px: Dictionary = {}
	var strokes := rng.randint(3, 5)
	for _i in strokes:
		var kind := rng.random()
		if kind < 0.4:
			var y: int = rng.choice([0, 2, 3, 4, 6])
			var xr: Array = rng.choice([[0, 4], [0, 2], [2, 4], [1, 3]])
			for x in range(int(xr[0]), int(xr[1]) + 1):
				px[Vector2i(x, y)] = true
		elif kind < 0.8:
			var x: int = rng.choice([0, 2, 4, 1, 3])
			var yr: Array = rng.choice([[0, 6], [0, 3], [3, 6], [1, 5]])
			for y in range(int(yr[0]), int(yr[1]) + 1):
				px[Vector2i(x, y)] = true
		else:
			var d: int = rng.choice([1, -1])
			for i in 4:
				px[Vector2i(2 + d * (i - 1), 2 + i)] = true
	return px


## Pseudo-Kana-Reihe als Blade-Runner-Ornament (prozedural, kein Font nötig).
func _kana(q: QP, rng: PyRandom, x: float, y: float, n: int, col: Array, sc: int, t_: float) -> void:
	var adv := 8 * sc
	for i in n:
		var g := _glyph(rng)
		var on := int(t_ * 6 + i * 3) % 31 != 0
		var c: Array = col if on else [Py.ifloordiv(col[0], 2), Py.ifloordiv(col[1], 2), Py.ifloordiv(col[2], 2)]
		for gp: Vector2i in g:
			q.fill_rect(x + i * adv + gp.x * sc, y + gp.y * sc, sc, sc, QP.rgb(c))


func _title(q: QP, ui: Dictionary) -> void:
	var t_ := t
	_dim(q, 158)
	# (Original legt hier ein ungenutztes Random(7) an - ohne Wirkung)
	# --- Pseudo-Kana streifen (Neon) ---
	_kana(q, PyRandom.new(3), Py.ifloordiv(HW, 2) - 170, 96, 20, VIOLET, 2, t_)
	_kana(q, PyRandom.new(9), Py.ifloordiv(HW, 2) - 170, 600, 20, MAGENTA, 2, t_ + 1.3)

	# --- Titel mit RGB-Split, Doppelkontur und Glitch ---
	var title := "SHADEGUNNER"
	var sc := 9
	var tw := Pixfont.text_width(title, sc)
	var x0 := Py.ifloordiv(HW - tw, 2)
	var y0 := 150
	var glitch := (int(t_ * 9) % 47) == 0
	var ox := 4 if glitch else 0
	Pixfont.draw(q, x0 + 8 + ox, y0 + 7, title, MAGENTA, sc, null)       # Schatten
	Pixfont.draw(q, x0 - 6 - ox, y0 - 5, title, [26, 52, 110], sc, null)  # Kante
	Pixfont.draw(q, x0, y0, title, CYAN, sc, null)                        # Kern
	if not glitch:
		for i in title.length():
			if int(t_ * 3 + i) % 13 == 0:
				Pixfont.draw(q, x0 + i * Pixfont.ADV * sc, y0, title[i], WHITE, sc, null)
	# Neon-Leiste darunter
	var uy := y0 + 7 * sc + 8
	q.fill_rect(x0 - 12, uy, tw + 24, 3, QP.rgb(CYAN))
	q.fill_rect(x0 - 4, uy + 4, tw + 8, 1, QP.rgb(MAGENTA))

	# --- Jahreszahl: aktuelles Jahr + 1 ---
	var yr := str(int(Time.get_datetime_dict_from_system()["year"]) + 1)
	var chars := PackedStringArray()
	for i in yr.length():
		chars.append(yr[i])
	var year := " ".join(chars)
	var ysc := 7
	var yw := Pixfont.text_width(year, ysc)
	var yx := Py.ifloordiv(HW - yw, 2)
	var yy := uy + 28
	Pixfont.draw(q, yx + 6, yy + 5, year, MAGENTA, ysc, null)
	Pixfont.draw(q, yx, yy, year, AMBER, ysc, null)
	if int(t_ * 3) % 17 == 0:
		Pixfont.draw(q, yx, yy, year, [255, 230, 180], ysc, null)

	_t(q, Py.ifloordiv(HW, 2), yy + 7 * ysc + 12, "BLADE RUNNER UNIT  ·  REPLICANT DETECTION  ·  LAPD",
		ASH, 2, "center")
	_t(q, Py.ifloordiv(HW, 2), yy + 7 * ysc + 38, "LOS ANGELES   ·   NOVEMBER " + yr, SLATE, 2, "center")

	if int(t_ * 1.6) % 2 == 0:
		_t(q, Py.ifloordiv(HW, 2), 470, "ENTER  NEUER EINSATZ", WHITE, 3, "center")
	_t(q, Py.ifloordiv(HW, 2), 514, "H  STEUERUNG      S  EINSTELLUNGEN      ESC  ENDE", ASH, 2, "center")
	var best: Variant = ui.get("best")
	if _truthy(best):
		var bd: Dictionary = best
		_t(q, Py.ifloordiv(HW, 2), 554, I18n.t("BESTWERT {:06d}  RANG {}  EINSÄTZE {}",
			[bd.get("best", 0), bd.get("rank", "-"), bd.get("runs", 0)]), TEAL, 2, "center")
	_t(q, Py.ifloordiv(HW, 2), HH - 54, "REPLIKANTEN SIND WIE JEDE ANDERE MASCHINE.", SLATE, 2, "center")


func _intro(q: QP, world: Variant, ui: Dictionary) -> void:
	var k: float = float(ui.get("t", 0.0))
	var z: Dictionary = world.zone
	var w := 820
	var h := 280
	var x := Py.ifloordiv(HW - w, 2)
	var y := 190
	_box(q, x, y, w, h, CYAN, [6, 8, 14], 225)
	_t(q, Py.ifloordiv(HW, 2), y + 20, I18n.t("SEKTOR {} / 5", [int(world.zone_index) + 1]), ASH, 2, "center")
	var name_ := _upper(I18n.t(String(z["name"])))
	var n := int(name_.length() * minf(1.0, k * 2.5))
	_t(q, Py.ifloordiv(HW, 2), y + 46, name_.substr(0, n), WHITE, 6, "center")
	var line := I18n.t("AUFTRAG: {} VON {} REPLIKANTEN DEAKTIVIEREN", [world.quota, world.replicants_total])
	var n2 := int(line.length() * minf(1.0, maxf(0.0, k - 0.3) * 1.6))
	_t(q, Py.ifloordiv(HW, 2), y + 112, line.substr(0, n2), CYAN, 2, "center")
	if k > 0.9:
		var tarn := Py.round(float(z["camo"]) * 4)
		var agg := Py.round(float(z["aggression"]) * 4)
		_t(q, x + 120, y + 146, "TARNUNG", ASH)
		_t(q, x + 240, y + 146, "▮".repeat(tarn) + "▯".repeat(4 - tarn), AMBER)
		_t(q, x + 420, y + 146, "AGGRESSION", ASH)
		_t(q, x + 580, y + 146, "▮".repeat(agg) + "▯".repeat(4 - agg), RED)
		_t(q, x + 120, y + 170, I18n.t("PASSANTEN CA. {}", [(world.actors as Array).size() - 1]), ASH)
		_t(q, x + 420, y + 170, I18n.t("QUOTE {}%", [int(float(world.prior) * 100)]), ASH)
		if _ga(world, "bounty") != null and _truthy(world.bounty_desc):
			var b: Variant = world.bounty
			var btxt := I18n.t("KOPFGELD +{}: {}", [Config.POINTS_BOUNTY, b.name])
			if int(b.hp) > 1:
				btxt += I18n.t("  (ZÄH: 2 TREFFER)")
			_t(q, Py.ifloordiv(HW, 2), y + 200, btxt, AMBER, 2, "center")
			_t(q, Py.ifloordiv(HW, 2), y + 222, ", ".join(PackedStringArray(world.bounty_desc)), PALE, 2, "center")
	if k > 1.3 and int(t * 2) % 2 == 0:
		_t(q, Py.ifloordiv(HW, 2), y + h - 26, "BELIEBIGE TASTE", SLATE, 2, "center")


func _settings(q: QP, ui: Dictionary) -> void:
	_dim(q, 200)
	var s: Dictionary = ui.get("settings", {})
	var sel: int = ui.get("settings_sel", 0)
	_t(q, Py.ifloordiv(HW, 2), 120, "EINSTELLUNGEN", WHITE, 5, "center")
	var g := _settings_geom(sel)
	var w := SET_W
	var rowh := SET_ROWH
	var gap := SET_GAP
	var x: int = g["x"]
	var y: int = g["y"]
	var maxrows := SET_MAXROWS
	var first: int = g["first"]
	if first > 0:
		_t(q, Py.ifloordiv(HW, 2), y - 22, "▲ MEHR", SLATE, 2, "center")
	for i in range(first, int(g["last"])):
		var row: Array = SETTING_ROWS[i]
		var label: String = row[1]
		var val: Callable = row[2]
		var kind: String = row[3]
		var on := i == sel
		var y0 := y + (i - first) * (rowh + gap)
		_box(q, x, y0, w, rowh, CYAN if on else INDIGO, [6, 8, 14], 225)
		_t(q, x + 24, y0 + 13, label, WHITE if on else ASH, 3)
		_t(q, x + w - 24, y0 + 13, String(val.call(s)), CYAN if on else PALE, 3, "right")
		if kind == "range" and on:
			_t(q, x + Py.ifloordiv(w, 2) + 60, y0 + 15, "←  →", AMBER, 2, "center")
	if first + maxrows < SETTING_ROWS.size():
		_t(q, Py.ifloordiv(HW, 2), y + maxrows * (rowh + gap) - 6, "▼ MEHR", SLATE, 2, "center")
	# Hinweise unter der Liste (unter "▼ MEHR"), nicht mehr über der letzten Zeile
	var note := y + maxrows * (rowh + gap) + 16
	if s.get("renderer") == "software":
		_t(q, Py.ifloordiv(HW, 2), note, "RENDERER WECHSELT MIT DEM NÄCHSTEN START", SLATE, 2, "center")
		note += 22
	if str(s.get("aspect", "auto")) != View.aspect_used and View.aspect_used != "":
		_t(q, Py.ifloordiv(HW, 2), note, "BILDFORMAT WECHSELT MIT DEM NÄCHSTEN START", SLATE, 2, "center")
		note += 22
	if SETTING_ROWS[sel][0] == "difficulty":
		_t(q, Py.ifloordiv(HW, 2), note, "MEHR MENSCHEN JE VIERTEL - GILT AB DEM NÄCHSTEN EINSATZ", SLATE, 2, "center")
		note += 22
	elif SETTING_ROWS[sel][0] in ["quality", "reflections", "rain", "fog", "fx"]:
		_t(q, Py.ifloordiv(HW, 2), note, "WENIGER EFFEKTE = MEHR BILDER PRO SEKUNDE", SLATE, 2, "center")
		note += 22
	_t(q, Py.ifloordiv(HW, 2), maxi(HH - 70, note + 2), "▲▼  WÄHLEN      ← →  ÄNDERN      ESC / S  ZURÜCK", ASH, 2, "center")


## Lage der sichtbaren Einstellungszeilen: x, y (erste Zeile), first, last (exkl.).
static func _settings_geom(sel: int) -> Dictionary:
	var n := SETTING_ROWS.size()
	var first := clampi(sel - Py.ifloordiv(SET_MAXROWS, 2), 0, maxi(0, n - SET_MAXROWS))
	return {"x": Py.ifloordiv(HW - SET_W, 2), "y": SET_Y, "first": first, "last": mini(first + SET_MAXROWS, n)}


func _pause(q: QP) -> void:
	_dim(q, 150)
	_t(q, Py.ifloordiv(HW, 2), 230, "PAUSE", WHITE, 6, "center")
	_t(q, Py.ifloordiv(HW, 2), 330, "P / ESC  WEITER      S  EINSTELLUNGEN      H  HILFE      Q  ZUM TITEL", ASH, 2, "center")


func _clear(q: QP, world: Variant, ui: Dictionary) -> void:
	_dim(q, 175)
	var st: Dictionary = world.stats
	var missed := _truthy(_ga(world, "mission_failed", false))
	var head := "AUFTRAG VERFEHLT" if missed else "SEKTOR GESÄUBERT"
	_t(q, Py.ifloordiv(HW, 2), 70, head, RED if missed else GREEN, 5, "center")
	var tm := int(float(st["time"]))
	var origami: Array = world.origami if world.origami != null else []
	var ori_ok := _truthy(st.get("origami"))
	var rows: Array = [
		["REPLIKANTEN DEAKTIVIERT", "%d/%d" % [int(st["reps"]), int(world.replicants_total)], CYAN],
		["MENSCHEN GETÖTET", str(int(st["civs"])), RED if int(st["civs"]) else ASH],
		["ENTKOMMEN", str(int(st["escaped"])), AMBER if int(st["escaped"]) else ASH],
		["SCANS / SCHÜSSE", "%d / %d" % [int(st["scans"]), int(st["shots"])], ASH],
		["ZEIT", "%d:%s" % [Py.ifloordiv(tm, 60), Py.fmt("{:02d}", [Py.imod(tm, 60)])], ASH],
		["ORIGAMI", I18n.t(String((origami[0] as Dictionary)["name"])) if (not origami.is_empty() and ori_ok)
			else "NICHT GEFUNDEN", PALE if ori_ok else SLATE],
		["PUNKTE (SEKTOR)", Py.fmt("{:+d}", [int(st["score"])]), WHITE]]
	var y := 150
	for r: Array in rows:
		_t(q, Py.ifloordiv(HW, 2) - 300, y, r[0], ASH)
		_t(q, Py.ifloordiv(HW, 2) + 300, y, r[1], r[2], 2, "right")
		y += 26
	var opts: Array = ui.get("options") if ui.get("options") != null else []
	if opts.is_empty():
		if int(t * 2) % 2 == 0:
			_t(q, Py.ifloordiv(HW, 2), 560, "ENTER  WEITER", WHITE, 3, "center")
		return
	_t(q, Py.ifloordiv(HW, 2), 330, "AUSRÜSTUNG WÄHLEN", PALE, 3, "center")
	var sel: int = ui.get("sel", 0)
	var g := _clear_geom()
	var cw: int = g["cw"]
	var ch := CLEAR_H
	var gap: int = g["gap"]
	var x0: int = g["x0"]
	var chars: int = g["chars"]
	for i in opts.size():
		var o: Array = opts[i]
		var title: String = o[1]
		var desc: String = o[2]
		var x := x0 + i * (cw + gap)
		var yo := CLEAR_Y
		var on := i == sel
		var lift := -8 if on else 0
		_box(q, x, yo + lift, cw, ch, CYAN if on else INDIGO, [6, 8, 14], 235)
		_t(q, x + 16, yo + lift + 16, str(i + 1), AMBER if on else SLATE, 3)
		_t(q, x + 52, yo + lift + 22, I18n.t(title), WHITE if on else ASH, 2)
		var yy := yo + lift + 70
		for line: String in wrap_(I18n.t(desc), chars):
			_t(q, x + 16, yy, line, PALE if on else SLATE, 2)
			yy += 22
	_t(q, Py.ifloordiv(HW, 2), HH - 50, "1-3 / PFEILE + ENTER", SLATE, 2, "center")


## Kartenraster der Upgrade-Wahl: 3 x 360 mit 30 Abstand; schmal so breit wie möglich.
static func _clear_geom() -> Dictionary:
	var cw := 360
	var gap := 30
	var chars := 26
	if 3 * cw + 2 * gap > HW - 40:
		gap = 20
		cw = Py.ifloordiv(HW - 40 - 2 * gap, 3)
		chars = Py.ifloordiv(cw - 32, Pixfont.ADV * 2)
	return {"cw": cw, "gap": gap, "chars": chars, "x0": Py.ifloordiv(HW - (3 * cw + 2 * gap), 2)}


func _end(q: QP, world: Variant, ui: Dictionary, won: bool) -> void:
	_dim(q, 185)
	var run: Variant = world.run
	if won and _truthy(_ga(run, "roy_spared", false)):
		_t(q, Py.ifloordiv(HW, 2), 90, "ROY HAT DICH VERSCHONT", PALE, 5, "center")
		_t(q, Py.ifloordiv(HW, 2), 160, "SCHADE, DASS ER NICHT LEBEN WIRD.", ASH, 2, "center")
		_t(q, Py.ifloordiv(HW, 2), 184, "ABER WER LEBT SCHON?", ASH, 2, "center")
	elif won:
		_t(q, Py.ifloordiv(HW, 2), 90, "TYRELL HQ ERREICHT", GREEN, 5, "center")
		_t(q, Py.ifloordiv(HW, 2), 160, "SIE HABEN GANZE ARBEIT GELEISTET, SIR.", ASH, 2, "center")
	else:
		_t(q, Py.ifloordiv(HW, 2), 90, "EINSATZ BEENDET", RED, 5, "center")
		var reason := ("VERDACHT ZU HOCH - DIENSTMARKE ENTZOGEN" if world.fail_reason == "suspicion"
			else "INTEGRITÄT VERLOREN")
		_t(q, Py.ifloordiv(HW, 2), 170, reason, AMBER, 2, "center")
	var tot: Dictionary = run.totals
	var rank: String = ui.get("rank") if _truthy(ui.get("rank")) else rank_of(int(run.score), int(tot["civs"]), won)
	var ori: Variant = _ga(run, "origami", [])
	var rows: Array = [["SEKTOR ERREICHT", "%d/5" % (int(world.zone_index) + 1)],
		["REPLIKANTEN", str(int(tot["reps"]))], ["MENSCHEN", str(int(tot["civs"]))],
		["ENTKOMMEN", str(int(tot["escaped"]))], ["UPGRADES", str((run.upgrades as Array).size())],
		["ORIGAMI", "%d/5" % (ori as Array).size()],
		["PUNKTE", Py.fmt("{:06d}", [maxi(0, int(run.score))])]]
	var y := 240
	for r: Array in rows:
		_t(q, Py.ifloordiv(HW, 2) - 260, y, r[0], ASH)
		_t(q, Py.ifloordiv(HW, 2) + 260, y, r[1], WHITE, 2, "right")
		y += 28
	_t(q, Py.ifloordiv(HW, 2), y + 20, I18n.t("RANG {}", [rank]), CYAN if rank in "SA" else AMBER, 6, "center")
	if _truthy(ui.get("new_best")):
		_t(q, Py.ifloordiv(HW, 2), y + 90, "NEUER BESTWERT!", AMBER if int(t * 3) % 2 else WHITE, 3, "center")
	if int(t * 1.6) % 2 == 0:
		_t(q, Py.ifloordiv(HW, 2), HH - 60, "ENTER  ZUM TITEL     R  SOFORT NEU", WHITE, 2, "center")


func _help(q: QP) -> void:
	var lines: Array = [
		["STEUERUNG", WHITE],
		["A D / PFEILE        GEHEN            SHIFT  SPRINTEN", ASH],
		["W S / PFEILE        TIEFE (VOR / ZURÜCK IN DER STRASSE)", ASH],
		["SPACE               SPRINGEN (ÜBER HINDERNISSE, SCHLÄGEN AUSWEICHEN)", ASH],
		["V / MITTLERE MT     TIPPEN: ZIEL ANSPRECHEN   HALTEN+LOSLASSEN: \"ALLE RUNTER!\"", ASH],
		["MAUS ZEIGEN/KLICKEN ZIEL WÄHLEN    Q / TAB / RAD  ZIEL WECHSELN", ASH],
		["R / RECHTE MT       GEWÄHLTES ZIEL SCANNEN (1 LADUNG)", ASH],
		["E / LINKE MT        HALTEN = ZIELEN, LOSLASSEN = SCHIESSEN", ASH],
		["C / RECHTE MT       SCHUSS ABBRECHEN (WAFFE SENKEN, KEIN SCHUSS)", ASH],
		["P / ESC  PAUSE    F  VOLLBILD    M  TON    H  HILFE", ASH],
		["", ASH],
		["REGELN", WHITE],
		["REPLIKANTEN SEHEN AUS WIE MENSCHEN. KEIN TELL BEWEIST ETWAS.", PALE],
		["BEOBACHTEN (ZIEL HALTEN) DECKT GANG UND DETAIL AUF.", PALE],
		["AUGENREFLEX IM BLICK = PUPILLEN-TELL. SCAN ZEIGT DIE STARKEN TELLS,", PALE],
		["DIE SERIENNUMMER NUR AUS DER NÄHE. P(REP) IST EHRLICH KALIBRIERT.", PALE],
		["WER FLIEHT ODER ANGREIFT, VERRÄT SICH - MENSCHEN GREIFEN NIE AN.", PALE],
		["PASSANTEN IN DER SCHUSSLINIE FANGEN DIE KUGEL. TIEFE WECHSELN!", PALE],
		["MENSCH GETÖTET = VERDACHT. BEI 100% IST DER EINSATZ VORBEI.", PALE],
		["AUFTRAG ERFÜLLEN -> AUSGANG AM STRASSENENDE ÖFFNET SICH.", PALE],
		["KOPFGELD: DER BESCHRIEBENE NEXUS-6 BRINGT EXTRA - VORSICHT, DOPPELGÄNGER.", PALE],
		["FAHRZEUGE AUF DEN SPUREN AUSWEICHEN. SUCHLICHT UND STROMAUSFALL", PALE],
		["MACHEN AUGENREFLEXE SICHTBAR - ABER IM SUCHLICHT SIEHT DIE POLIZEI ZU.", PALE],
		["RUF: WER REGLOS STEHEN BLEIBT, ZEIGT DEN REIZ-TELL. GEDUCKTE: DIE KUGEL GEHT DRÜBER.", PALE],
		["JEDER RUF MACHT DIE STRASSE UNRUHIGER: MEHR LEUTE RENNEN, REPLIKANTEN WERDEN NERVÖS.", PALE],
		["LANDET EIN SPINNER: ABWIND SCHIEBT ALLE WEG, DANN KONTROLLE VOM BODEN AUS.", PALE],
		["NUDELBAR: KURZ AN DER THEKE STEHEN = +1 HERZ.  GAFFS ORIGAMI: SCANNER VOLL.", PALE],
	]
	var lh := 23
	var w := 1160
	if w > HW - 40:
		# schmal: Box an die Breite anpassen, lange Zeilen umbrechen (Folgezeilen eingerückt:
		# Steuerung unter die Beschreibungsspalte, Regeln um zwei Zeichen) und enger setzen
		w = HW - 40
		var wrapped: Array = []
		for e: Array in lines:
			var txt := I18n.t(String(e[0]))
			var indent := "                    " if e[1] == ASH else "  "
			var parts := _help_wrap(txt, Py.ifloordiv(w - 60 + 2, Pixfont.ADV * 2), indent)
			for ln: String in parts:
				wrapped.append([ln, e[1]])
		lines = wrapped
		lh = mini(23, Py.ifloordiv(HH - 20 - 40, lines.size()))
		var h2 := lines.size() * lh + 40
		var x2 := Py.ifloordiv(HW - w, 2)
		var y2 := Py.ifloordiv(HH - h2, 2)
		_box(q, x2, y2, w, h2, CYAN, [6, 8, 14], 240)
		for i in lines.size():
			Pixfont.draw(q, x2 + 30, y2 + 20 + i * lh, String(lines[i][0]), lines[i][1], 2, VOID)
		return
	var h := lines.size() * lh + 40
	var x := Py.ifloordiv(HW - w, 2)
	var y := Py.ifloordiv(HH - h, 2)
	_box(q, x, y, w, h, CYAN, [6, 8, 14], 240)
	var yy := y + 20
	for e: Array in lines:
		_t(q, x + 30, yy, e[0], e[1], 2)
		yy += lh


## Umbruch einer (bereits übersetzten) Hilfezeile auf n Zeichen; die Spalten der
## ersten Zeile bleiben erhalten (Leerzeichenfolgen werden nicht zusammengezogen).
static func _help_wrap(txt: String, n: int, indent: String) -> Array:
	if txt.length() <= n:
		return [txt]
	var out: Array = []
	var rest := txt
	var pre := ""
	while (pre + rest).length() > n:
		var room := n - pre.length()
		var cut := rest.rfind(" ", room)
		if cut <= 0:
			cut = room
		out.append(pre + rest.substr(0, cut).strip_edges(false, true))
		rest = rest.substr(cut).strip_edges(true, false)
		pre = indent
	if rest != "":
		out.append(pre + rest)
	return out
