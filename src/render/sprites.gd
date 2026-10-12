class_name Sprites
extends RefCounted
## Port von render/sprites.py: prozedurale, skelett-animierte Pixel-Figuren.
##
## Gliederpuppe in Design-Einheiten (Figurhöhe 48 u, Füße bei y = 0, Blick +x),
## Pose analytisch aus (Animation, Phase), gezeichnet mit QP ohne Kantenglättung
## direkt in Zielgröße. Danach Umriss + Rimlight + Nebel (_postprocess).
##
## Cache = zwei Atlanten des Bakers (Sprites.baker muss vom Spiel gesetzt sein):
##   _raw  rohe Figur + Leuchtbild (emit)
##   _fin  fertiges Bild (Umriss/Rim/Nebel), liest aus _raw -> wird NACH _raw
##         angelegt und damit im selben Frame danach gerendert.
## Tabellen kommen aus DSprites (tools/export_data.py).

const PI_ := DSprites.PI
const ANIMS := DSprites.ANIMS

# private Konstanten aus sprites.py (nicht exportiert)
const _CACHE_MAX := 14000
const _PAD := 26.0     # Design-Einheiten Rand links/rechts (Schirm, Sturz)
const _TOP := 60.0
const _BOT := 4.0

## Vom Spiel zu setzen (Baker hängt im Baum vor dem Szenen-Viewport).
static var baker: Baker
## Kantenlänge der beiden Atlanten (Pixel).
static var atlas_size := 2048

static var _CACHE := {}
static var _raw: Baker.Atlas
static var _fin: Baker.Atlas
static var _dummy: QP                 # schluckt Leuchtteile, wenn kein emit gebraucht wird
static var _dummy_root := RID()
static var _fx_used: Array[RID] = []  # Postprocess-Items, warten auf den Atlas-Render
static var _fx_pool: Array[RID] = []
static var _fx_draw_index := 0
static var _mats := {}                # m -> ShaderMaterial
## Versatz der Formen im Zielraum (s. _SP); veränderbar für Tests.
static var shape_eps := 1.0 / 128.0


## QP mit Qt-Abtastregel für Formen: Qt füllt aliased jedes Pixel, dessen Mitte
## in (x0, x1] liegt. Die GPU füllt [x0, x1) - ein winziger Versatz +eps gleicht
## das an. (QP._gx versetzt um +0.5 px; das stimmt nur für ganzzahlige Koordinaten.)
class _SP extends QP:
	func _gx() -> Transform2D:
		return Transform2D(xf.x, xf.y, xf.origin + Vector2(Sprites.shape_eps, Sprites.shape_eps))


## Wie Baker.Atlas.painter_for, aber mit _SP.
static func _painter_for(a: Baker.Atlas, r: Rect2i) -> QP:
	var p := _SP.new(a.host.get_canvas_item())
	p.begin()
	p.set_clip_rect(r.position.x, r.position.y, r.size.x, r.size.y)
	p.translate(r.position.x, r.position.y)
	a._pending.append(p)
	return p


static func _mul(c: Array, f: float) -> Array:
	return [maxi(0, mini(255, int(float(c[0]) * f))), maxi(0, mini(255, int(float(c[1]) * f))),
		maxi(0, mini(255, int(float(c[2]) * f)))]


# ---------------------------------------------------------------------------- Pose

## Gelenkwinkel für Animation `anim` bei Zyklusphase t (0..1).
static func pose(anim: String, t: float) -> Dictionary:
	var phi := 2 * PI_ * t
	var s := sin(phi)
	var c := cos(phi)
	var P := {"lean": 0.0, "bob": 0.0, "crouch": 0.0, "rot": 0.0,
		"legs": [[0.0, 0.05], [0.0, 0.05]],     # (fern, nah): (Oberschenkel, Kniebeuge)
		"arms": [[0.08, 0.15], [0.08, 0.15]],   # (fern, nah): (Oberarm, Unterarm)
		"flutter": 0.0, "gun": false, "scanner": false, "muzzle": false}
	if anim == "walk":
		var A := 0.42
		P["legs"] = [[-A * s, 0.12 + 0.8 * maxf(0.0, -c)], [A * s, 0.12 + 0.8 * maxf(0.0, c)]]
		P["arms"] = [[0.36 * s + 0.05, 0.25], [-0.36 * s + 0.05, 0.25]]
		P["bob"] = -0.9 * (1 - absf(s))
		P["lean"] = 0.04
		P["flutter"] = 0.3
	elif anim in ["run", "panic"]:
		var A := 0.78
		P["legs"] = [[-A * s, 0.25 + 1.45 * maxf(0.0, -c)], [A * s, 0.25 + 1.45 * maxf(0.0, c)]]
		P["bob"] = -1.6 * (1 - absf(s)) + 0.5
		P["lean"] = 0.24
		P["flutter"] = 1.0
		if anim == "run":
			P["arms"] = [[0.9 * s, 1.55], [-0.9 * s, 1.55]]
		else:
			P["arms"] = [[2.55 + 0.35 * sin(2 * phi), 0.35], [2.75 - 0.35 * sin(2 * phi), 0.3]]
			P["lean"] = 0.1
	elif anim == "idle":
		var b := sin(phi)
		P["legs"] = [[-0.07, 0.06], [0.08, 0.05]]
		P["arms"] = [[0.06 + 0.03 * b, 0.18], [0.04 - 0.03 * b, 0.2]]
		P["bob"] = 0.25 * b
	elif anim in ["aim", "shoot"]:
		P["legs"] = [[-0.2, 0.12], [0.22, 0.18]]
		var rec := 0.28 if (anim == "shoot" and t < 0.5) else 0.0
		P["arms"] = [[1.25 + rec * 0.5, 0.32], [PI_ / 2 - 0.04 + rec, -rec * 0.4]]
		P["lean"] = -0.05 - rec * 0.25
		P["gun"] = true
		P["muzzle"] = anim == "shoot" and t < 0.5
	elif anim == "scan":
		P["legs"] = [[-0.12, 0.08], [0.14, 0.1]]
		P["arms"] = [[0.1, 0.25], [1.8 + 0.05 * s, -0.25]]
		P["scanner"] = true
	elif anim == "hurt":
		P["legs"] = [[-0.3, 0.3], [0.12, 0.4]]
		P["arms"] = [[0.9, 0.6], [-0.7, 0.4]]
		P["lean"] = -0.35
		P["crouch"] = 1.5
	elif anim == "cower":
		var tr_ := 0.06 * s
		P["legs"] = [[-0.12, 0.35], [0.1, 0.4]]
		P["arms"] = [[2.7 + tr_, 0.55], [2.85 - tr_, 0.5]]
		P["lean"] = -0.1
		P["crouch"] = 1.2
	elif anim == "duck":
		# In Deckung: tief in der Hocke, Hände über dem Kopf
		var tr_ := 0.05 * s
		P["legs"] = [[1.2, 2.35], [1.0, 2.2]]
		P["arms"] = [[2.6 + tr_, 0.7], [2.8 - tr_, 0.6]]
		P["lean"] = 0.42
		P["crouch"] = 12.6
	elif anim == "hands":
		# Hände hoch (angesprochen)
		P["legs"] = [[-0.08, 0.06], [0.1, 0.05]]
		P["arms"] = [[2.55 + 0.04 * s, -0.5], [2.7 - 0.04 * s, -0.45]]
		P["lean"] = -0.06
	elif anim == "talk":
		# Herumstehen und reden: Gewicht verlagern, eine Hand gestikuliert
		var g := maxf(0.0, sin(phi))
		P["legs"] = [[-0.1, 0.06], [0.12 + 0.04 * c, 0.08]]
		P["arms"] = [[0.08, 0.2], [0.35 + 0.55 * g, 0.9 + 0.5 * g]]
		P["bob"] = 0.2 * c
		P["lean"] = 0.03
	elif anim == "jump":
		P["legs"] = [[-0.55, 1.5], [0.85, 1.75]]
		P["arms"] = [[-0.9, 0.9], [1.9, 0.6]]
		P["lean"] = 0.18
		P["crouch"] = 2.0
		P["flutter"] = 1.4
	elif anim == "punch":
		var k := sin(PI_ * t)
		P["legs"] = [[-0.3, 0.15], [0.32, 0.3]]
		P["arms"] = [[0.6, 1.2], [0.6 + 1.0 * k, 1.3 - 1.2 * k]]
		P["lean"] = 0.15 + 0.2 * k
	elif anim == "die":
		if t < 0.38:
			var k := t / 0.38
			P["legs"] = [[-0.1 - 0.4 * k, 0.2 + 1.3 * k], [0.15 + 0.5 * k, 0.2 + 1.5 * k]]
			P["arms"] = [[0.2 + 0.6 * k, 0.3 + 0.4 * k], [0.4 + 0.9 * k, 0.5]]
			P["crouch"] = 7.0 * k
			P["lean"] = 0.35 * k
		else:
			var k := minf(1.0, (t - 0.38) / 0.5)
			var ke := 1 - (1 - k) ** 2
			P["legs"] = [[-0.5 + 0.5 * ke, 1.5 - 1.35 * ke], [0.65 - 0.5 * ke, 1.7 - 1.5 * ke]]
			P["arms"] = [[0.8 + 1.6 * ke, 0.7], [1.3 + 1.5 * ke, 0.5]]
			P["crouch"] = 7.0 * (1 - ke)
			P["lean"] = 0.35 * (1 - ke)
			P["rot"] = -PI_ / 2 * ke
	return P


static func _limb(origin: Vector2, a: float, l: float) -> Vector2:
	return Vector2(origin.x + l * sin(a), origin.y + l * cos(a))


# ---------------------------------------------------------------------------- Zeichnen

static func _pen(p: QP, col: Array, w: float, alpha: float = 255.0) -> void:
	# Qt zeichnet Stifte <= 1 Gerätepixel mit dem Cosmetic-Stroker und Deckkraft
	# int(256 * Breite * Skala) / 256 (QCosmeticStroker::setup); QP nicht -> hier nachbilden.
	var spx := w * sqrt(absf(p.transform().determinant()))
	if w > 0.0 and spx <= 1.0:
		alpha = alpha * clampi(int(256.0 * spx), 0, 256) / 256.0
	p.set_pen(QP.rgb(col, alpha), w, QP.CAP_ROUND)


static func _fill(p: QP, col: Array, alpha: float = 255.0) -> void:
	p.set_no_pen()
	p.set_brush(QP.rgb(col, alpha))


static func _poly(p: QP, pts: Array, col: Array, alpha: float = 255.0) -> void:
	_fill(p, col, alpha)
	p.draw_polygon(_pa(pts))


static func _pa(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		if q is Vector2:
			out.append(q)
		else:
			out.append(Vector2(float(q[0]), float(q[1])))
	return out


static func _line(p: QP, a: Vector2, b: Vector2) -> void:
	p.draw_line(a.x, a.y, b.x, b.y)


static func _point(p: QP, a: Vector2) -> void:
	p.draw_point(a.x, a.y)

## Zeichnet die Figur in Design-Einheiten (Füße bei 0,0). emit: Painter für Leuchtteile.
## Rückgabe [eye, hc, hand] (Vector2, Design-Einheiten).
static func _draw_figure(p: QP, look: Dictionary, P: Dictionary, emit: QP) -> Array:
	var wf: float = look["wf"]
	var hf: float = look["hf"]
	var coat: Array = look["coat"]
	var pants: Array = look["pants"]
	var skin: Array = look["skin"]
	var accent: Array = look["accent"]
	var outfit: String = look["outfit"]
	var head: String = look["head"]
	if outfit == "overall":
		pants = _mul(coat, 0.9)
	var far_coat := _mul(coat, 0.62)
	var far_pants := _mul(pants, 0.7)
	var leg_w := 3.9 * wf
	var arm_w := 3.1 * wf
	var rot: float = P["rot"]
	var crouch: float = P["crouch"]
	var flutter: float = P["flutter"]
	var gun: bool = P["gun"]
	var scanner: bool = P["scanner"]
	var old := bool(look.get("old", false)) and rot == 0.0

	var hip := Vector2(0.0, -22.0 * hf + crouch + float(P["bob"]) + (1.0 if old else 0.0))
	var lean: float = float(P["lean"]) + (0.2 if old else 0.0)
	var sh := Vector2(hip.x + 14.0 * hf * sin(lean), hip.y - 14.0 * hf * cos(lean))
	var hc := Vector2(sh.x + 6.2 * hf * sin(lean * 1.3) + 0.6, sh.y - 6.2 * hf * cos(lean * 1.3))

	var legs: Array = []
	for i in 2:
		var lg: Array = P["legs"][i]
		var th: float = lg[0]
		var bend: float = lg[1]
		var k := _limb(hip, th, 11.0 * hf)
		var a := _limb(k, th - bend, 11.2 * hf)
		legs.append([k, a, th - bend])
	var arms: Array = []
	for i in 2:
		var am: Array = P["arms"][i]
		var al: float = am[0]
		var be: float = am[1]
		var e := _limb(sh, al, 8.0 * hf)
		var h := _limb(e, al + be, 7.2 * hf)
		arms.append([e, h])

	var sleeve_far := _mul(skin, 0.7) if outfit == "vest" else far_coat
	var sleeve: Array = skin if outfit == "vest" else (coat if outfit != "cloak" else accent)
	var bag: Variant = look.get("bag")

	# --- Rucksack (hinter allem)
	if bag is String and bag == "backpack":
		_poly(p, [[sh.x - 4.6 * wf, sh.y + 0.5], [sh.x - 1.5, sh.y + 0.5], [hip.x - 2.0, hip.y - 2],
			[hip.x - 5.8 * wf, hip.y - 2.5]], _mul(coat, 0.5))

	# --- ferner Arm
	var e0: Vector2 = arms[0][0]
	var h0: Vector2 = arms[0][1]
	_pen(p, sleeve_far, arm_w)
	_line(p, sh, e0)
	_line(p, e0, h0)
	_pen(p, _mul(skin, 0.7), arm_w * 0.9)
	_point(p, h0)

	# --- Beine (fern, nah)
	for i in 2:
		var k: Vector2 = legs[i][0]
		var a: Vector2 = legs[i][1]
		var sa: float = legs[i][2]
		var col := far_pants if i == 0 else pants
		_pen(p, col, leg_w)
		_line(p, hip, k)
		_line(p, k, a)
		var shoe := _mul(col, 0.55)
		_pen(p, shoe, leg_w * 0.85)
		var fx := a.x + 2.4 * cos(sa)
		var fy := a.y - 2.4 * sin(sa) * 0.3
		_line(p, a, Vector2(fx, fy))
		if outfit == "overall":   # Reflexstreifen
			var m := Vector2(k.x * 0.5 + a.x * 0.5, k.y * 0.5 + a.y * 0.5)
			_pen(p, [214, 220, 226] if i else [150, 156, 166], leg_w * 0.9)
			_point(p, m)

	# --- Torso / Mantel
	var kxax: Array = [(legs[0][0] as Vector2).x, (legs[1][0] as Vector2).x,
		(legs[0][1] as Vector2).x, (legs[1][1] as Vector2).x]
	var w := 4.9 * wf * (1.12 if outfit in ["long", "suit"] else 1.0)
	var sx := sh.x
	var sy := sh.y
	var hx := hip.x
	var hy := hip.y
	if outfit in ["trench", "robe", "cloak", "dress", "long"]:
		var hem_y: float
		if outfit == "trench":
			hem_y = -6.0 * hf + crouch * 0.6
		elif outfit == "long":
			hem_y = -2.4 * hf + crouch * 0.6
		elif outfit == "robe":
			hem_y = -0.8
		elif outfit == "cloak":
			hem_y = -5.0 * hf + crouch * 0.6
		else:
			hem_y = -11.0 * hf + crouch * 0.5
		var spread_f := maxf(3.8 * wf, float(kxax.max()) * 0.75 + 1.8)
		var spread_b := minf(-3.6 * wf, float(kxax.min()) * 0.75 - 1.8)
		if outfit == "dress":
			spread_f += 1.2
			spread_b -= 1.2
		var hem_b_x := spread_b - 2.5 * flutter
		var hem_b_y := hem_y - 3.0 * flutter
		if outfit == "cloak":
			# Unterkleid sichtbar unter der Klarsicht-Folie
			_poly(p, [[sx - w * 0.8, sy], [sx + w * 0.9, sy], [hx + w, hy], [hx - w * 0.9, hy]], accent)
			_poly(p, [[hx - w * 0.9, hy], [hx + w, hy], [spread_f * 0.8, hem_y + 4], [spread_b * 0.8, hem_y + 4]],
				_mul(accent, 0.6))
		var body_col: Array = [176, 200, 222] if outfit == "cloak" else coat
		var alpha := 84.0 if outfit == "cloak" else 255.0
		var pts: Array = [[sx - w * 0.85, sy - 0.6], [sx + w * 0.75, sy - 0.6], [sx + w * 1.0, sy + 4.5],
			[hx + w * 0.9, hy - 1.0], [spread_f, hem_y], [hem_b_x, hem_b_y], [hx - w * 0.95, hy]]
		_poly(p, pts, body_col, alpha)
		if outfit == "cloak":
			_pen(p, [226, 236, 244], 0.8, 170)
			_polyline(p, _pa(pts + [pts[0]]))
		else:
			# Schattenseite + Saum
			_poly(p, [[sx - w * 0.85, sy - 0.6], [sx - w * 0.2, sy], [hx - w * 0.3, hy],
				[hem_b_x + 1.5, hem_b_y], [hem_b_x, hem_b_y], [hx - w * 0.95, hy]], _mul(body_col, 0.72))
		if outfit in ["trench", "long"]:
			_pen(p, _mul(coat, 0.55), 1.2)
			_line(p, Vector2(hx - w * 0.9, hy + 1.2), Vector2(hx + w * 0.95, hy + 0.5))
			if look.get("collar", false) or outfit == "long":
				_poly(p, [[sx - w * 0.95, sy - 3.4], [sx + w * 0.5, sy - 1.0], [sx - w * 0.2, sy + 3.0]],
					_mul(coat, 1.18))
		elif outfit == "robe":
			_pen(p, accent, 1.0)
			_line(p, Vector2(sx + w * 0.7, sy + 1), Vector2(spread_f - 0.6, hem_y - 0.5))
	else:
		# Jacke / Hoodie / Weste / Anzug / Overall: kurzer Oberkörper, Hose sichtbar
		var hem := hy + 2.2
		_poly(p, [[sx - w * 0.85, sy - 0.6], [sx + w * 0.8, sy - 0.6], [sx + w * 1.0, sy + 4.5],
			[hx + w * 0.95, hem], [hx - w * 1.0, hem]], coat)
		_poly(p, [[sx - w * 0.85, sy - 0.6], [sx - w * 0.15, sy], [hx - w * 0.25, hem], [hx - w * 1.0, hem]],
			_mul(coat, 0.72))
		if outfit == "suit":
			_poly(p, [[sx + w * 0.35, sy - 0.4], [sx + w * 0.85, sy - 0.4], [sx + w * 0.75, sy + 4.0]],
				[214, 220, 226])
			_pen(p, accent, 0.9)
			_line(p, Vector2(sx + w * 0.72, sy + 0.4), Vector2(sx + w * 0.8, sy + 4.4))
		elif outfit == "overall":
			_pen(p, [214, 220, 226], 1.0)
			_line(p, Vector2(hx - w * 0.9, (sy + hy) / 2), Vector2(hx + w * 0.95, (sy + hy) / 2 - 0.3))
		else:
			_pen(p, accent, 1.0)
			if outfit in ["jacket", "vest"]:
				_line(p, Vector2(sx + w * 0.95, sy + 2.0), Vector2(hx + w * 0.9, hem - 0.5))
			else:
				_line(p, Vector2(hx - w * 0.9, hem - 0.3), Vector2(hx + w * 0.9, hem - 0.3))

	# Leuchtstreifen am Mantel (LED-Kleidung)
	if look.get("led", false) and outfit != "cloak":
		for q: QP in [p, emit]:
			_pen(q, accent, 0.9)
			_line(q, Vector2(sx + w * 0.85, sy + 1.0), Vector2(hx + w * 0.92, hy - 0.5))

	if (bag is String and bag == "bag") or (bag is bool and bag == true):
		_poly(p, [[hx - w * 1.3, hy - 3], [hx - w * 0.2, hy - 3], [hx - w * 0.3, hy + 3], [hx - w * 1.2, hy + 3]],
			_mul(coat, 0.45))
		_pen(p, _mul(coat, 0.4), 0.8)
		_line(p, Vector2(hx - w * 0.7, hy - 3), Vector2(sx + w * 0.4, sy + 0.5))

	var eye := _draw_head(p, emit, look, P, hc, sy)

	# --- naher Arm
	var e1: Vector2 = arms[1][0]
	var h1: Vector2 = arms[1][1]
	_pen(p, sleeve, arm_w)
	_line(p, sh, e1)
	_line(p, e1, h1)
	if bag is String and bag == "briefcase" and not (gun or scanner) and rot == 0.0:
		_poly(p, [[h1.x - 2.6, h1.y + 0.6], [h1.x + 2.8, h1.y + 0.6], [h1.x + 2.8, h1.y + 4.6],
			[h1.x - 2.6, h1.y + 4.6]], [30, 24, 26])
	if old and not (gun or scanner):
		_pen(p, [60, 52, 50], 0.9)
		_line(p, h1, Vector2(h1.x + 2.0, 0.0))
	if outfit == "cloak":
		_pen(p, [210, 222, 232], arm_w + 0.6, 80)
		_line(p, sh, e1)
		_line(p, e1, h1)
	_pen(p, skin, arm_w * 0.9)
	_point(p, h1)

	if gun:
		var al: float = float(P["arms"][1][0]) + float(P["arms"][1][1])
		var dx := sin(al)
		var dy := cos(al)
		var tip := Vector2(h1.x + dx * 4.4, h1.y + dy * 4.4)
		_pen(p, [24, 26, 34], 1.9)
		_line(p, h1, tip)
		_pen(p, [24, 26, 34], 1.4)
		_line(p, h1, Vector2(h1.x - dy * 1.6, h1.y + dx * 1.6 + 0.6))
		_pen(p, [64, 210, 220], 0.8)
		_point(p, Vector2(h1.x + dx * 2.2, h1.y + dy * 2.2 - 0.5))
		if P["muzzle"]:
			var mx := tip.x + dx * 2.6
			var my := tip.y + dy * 2.6
			for q: QP in [p, emit]:
				_fill(q, [255, 240, 200])
				q.draw_ellipse(mx - 2.4, my - 1.6, 4.8, 3.2)
				_fill(q, [255, 160, 60], 200)
				q.draw_polygon(_pa([[mx - 1, my - 2.6], [mx + 6.5, my], [mx - 1, my + 2.6]]))
	if scanner:
		var al: float = float(P["arms"][1][0]) + float(P["arms"][1][1])
		var dx := sin(al)
		var dy := cos(al)
		_pen(p, [162, 168, 180], 2.2)
		_line(p, h1, Vector2(h1.x + dx * 2.4, h1.y + dy * 2.4))
		for q: QP in [p, emit]:
			_pen(q, [64, 210, 220], 1.4)
			_point(q, Vector2(h1.x + dx * 2.6, h1.y + dy * 2.6))

	if look.get("umbrella") != null and rot == 0.0:
		_umbrella(p, emit, look, hc)
	return [eye, hc, h1]

## Kopf-Abschnitt aus _draw_figure (ausgelagert, Reihenfolge unverändert). Gibt eye zurück.
static func _draw_head(p: QP, emit: QP, look: Dictionary, P: Dictionary, hc: Vector2, sy: float) -> Vector2:
	var head: String = look["head"]
	var coat: Array = look["coat"]
	var skin: Array = look["skin"]
	var accent: Array = look["accent"]
	var hair: Array = look["hair"]
	var flutter: float = P["flutter"]
	var rx := 3.5 * pow(float(look["wf"]), 0.3)
	var ry := 4.0
	var x := hc.x
	var y := hc.y
	if head == "afro":
		_fill(p, hair)
		p.draw_ellipse(x - rx - 2.2, y - ry - 2.6, 2 * rx + 3.6, 2 * ry + 3.0)
	if head == "ponytail":
		_pen(p, hair, 1.8)
		_line(p, Vector2(x - rx * 0.8, y - ry * 0.6), Vector2(x - rx - 2.6 - flutter, y + 2.5))
	if head == "long":
		_poly(p, [[x - rx - 0.6, y - 1], [x + 0.5, y - ry], [x - 0.2, sy + 4], [x - rx - 1.6, sy + 3]], hair)
	if head == "hood":
		_fill(p, _mul(coat, 0.85))
		p.draw_ellipse(x - rx - 1.6, y - ry - 1.6, 2 * rx + 2.6, 2 * ry + 3.4)
	_fill(p, skin)
	p.draw_ellipse(x - rx, y - ry, 2 * rx, 2 * ry)
	# Kinn/Gesicht nach vorn + Schatten am Hinterkopf
	_fill(p, _mul(skin, 0.7))
	p.draw_ellipse(x - rx, y - ry * 0.4, rx * 0.9, ry * 1.2)
	_pen(p, _mul(skin, 0.35), 0.7)
	var eye := Vector2(x + rx * 0.55, y - 0.5)
	_point(p, eye)
	var top := y - ry
	if head == "short":
		_poly(p, [[x - rx - 0.3, y + 0.5], [x - rx * 0.6, top - 0.6], [x + rx * 0.9, top - 0.3],
			[x + rx * 0.3, top + 1.6], [x - rx * 0.3, y - 0.5]], hair)
	elif head == "long":
		_poly(p, [[x - rx - 0.6, y], [x - rx * 0.4, top - 0.7], [x + rx, top], [x + rx * 0.2, top + 1.8]], hair)
	elif head == "bun":
		_poly(p, [[x - rx - 0.2, y], [x - rx * 0.5, top - 0.5], [x + rx * 0.9, top], [x + rx * 0.2, top + 1.5]], hair)
		_fill(p, hair)
		p.draw_ellipse(x - rx - 2.4, top - 0.4, 2.8, 2.8)
	elif head == "fedora":
		_poly(p, [[x - rx * 0.9, top + 1.2], [x - rx * 0.7, top - 2.6], [x + rx * 0.8, top - 2.6],
			[x + rx * 0.95, top + 1.2]], _mul(coat, 0.75))
		_pen(p, _mul(coat, 0.6), 1.3)
		_line(p, Vector2(x - rx - 2.4, top + 1.4), Vector2(x + rx + 2.4, top + 1.2))
		_pen(p, accent, 0.7)
		_line(p, Vector2(x - rx * 0.75, top + 0.2), Vector2(x + rx * 0.85, top + 0.2))
	elif head == "cap":
		_poly(p, [[x - rx, top + 2], [x - rx * 0.6, top - 0.8], [x + rx * 0.8, top - 0.6], [x + rx * 1.0, top + 1.6]],
			accent)
		_pen(p, _mul(accent, 0.6), 1.0)
		_line(p, Vector2(x + rx * 0.6, top + 1.7), Vector2(x + rx + 2.6, top + 2.1))
	elif head == "conical":
		_poly(p, [[x - rx - 4.6, top + 2.6], [x + 0.2, top - 3.2], [x + rx + 4.6, top + 2.6]], [150, 138, 104])
		_pen(p, [90, 80, 60], 0.8)
		_line(p, Vector2(x - rx - 4.6, top + 2.6), Vector2(x + rx + 4.6, top + 2.6))
	elif head == "mohawk":
		_pen(p, hair, 1.6)
		_line(p, Vector2(x - rx * 0.6, top - 0.3), Vector2(x + rx * 0.6, top - 1.8))
		_line(p, Vector2(x - rx * 0.9, top + 1), Vector2(x - rx * 0.2, top - 1.5))
	elif head == "hood":
		_poly(p, [[x - rx - 1.6, y + 1], [x - rx * 0.6, top - 1.6], [x + rx * 0.9, top - 1.0],
			[x + rx * 0.4, top + 1.2], [x - rx * 0.4, y + 0.5]], _mul(coat, 0.85))
	elif head == "beanie":
		_poly(p, [[x - rx - 0.4, top + 2.4], [x - rx * 0.7, top - 1.2], [x + rx * 0.2, top - 1.8],
			[x + rx * 0.95, top - 0.6], [x + rx * 1.05, top + 2.0]], _mul(accent, 0.7))
		_pen(p, _mul(accent, 0.45), 1.0)
		_line(p, Vector2(x - rx - 0.4, top + 2.2), Vector2(x + rx * 1.05, top + 1.9))
	elif head in ["ponytail", "visor"]:
		_poly(p, [[x - rx - 0.3, y + 0.5], [x - rx * 0.6, top - 0.6], [x + rx * 0.9, top - 0.3],
			[x + rx * 0.3, top + 1.6], [x - rx * 0.3, y - 0.5]], hair)
		if head == "visor":
			for q: QP in [p, emit]:
				_pen(q, accent, 1.3)
				_line(q, Vector2(x - rx * 0.1, y - 0.8), Vector2(x + rx + 0.6, y - 0.8))
	elif head == "afro":
		_fill(p, _mul(hair, 1.2))
		p.draw_ellipse(x - rx - 1.2, top - 2.2, 2 * rx + 1.6, 3.4)
	if look.get("mask", false):
		_poly(p, [[x + rx * 0.1, y + 0.6], [x + rx + 0.4, y + 0.4], [x + rx + 0.2, y + 3.2], [x + rx * 0.2, y + 3.4]],
			[30, 32, 40])
		_pen(p, accent, 0.8)
		_point(p, Vector2(x + rx * 0.75, y + 2.0))
	if look.get("cig", false) and float(P["rot"]) == 0.0:
		var tip := Vector2(x + rx + 1.8, y + 1.6)
		_pen(p, [214, 220, 226], 0.7)
		_line(p, Vector2(x + rx + 0.2, y + 1.6), tip)
		for q: QP in [p, emit]:
			_pen(q, [255, 138, 44], 1.0)
			_point(q, tip)
	return eye


## drawPolyline. Dünne Stifte: Qt zeichnet den Pfad am Stück (jedes Pixel einmal);
## QP strichelt Segmente einzeln und deckt Stoßpixel doppelt -> Pixelmenge selbst bilden.
static func _polyline(p: QP, pts: PackedVector2Array) -> void:
	var xf := p.transform()
	if p.pen_w * sqrt(absf(xf.determinant())) > 1.0 or pts.size() < 2:
		p.draw_polyline(pts)
		return
	var seen := {}
	var cells: Array[Vector2i] = []
	for i in range(1, pts.size()):
		var a := Vector2i((xf * pts[i - 1]).floor())
		var b := Vector2i((xf * pts[i]).floor())
		for c in _bresenham(a, b):
			if not seen.has(c):
				seen[c] = true
				cells.append(c)
	var col := p.pen_col
	p.save()
	p.reset_transform()
	for c in cells:
		p.fill_rect(c.x, c.y, 1, 1, col)
	p.restore()


static func _bresenham(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var c := a
	while true:
		out.append(c)
		if c == b:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			c.x += sx
		if e2 <= dx:
			err += dx
			c.y += sy
	return out


static func _umbrella(p: QP, emit: QP, look: Dictionary, hc: Vector2) -> void:
	var uc: Array = look["umbrella"]
	var hand := Vector2(hc.x + 3.0, hc.y + 10.5)
	var apex := Vector2(hand.x - 1.0, hc.y - 15.0)
	var R := 11.5
	var pts: Array = []
	for i in 13:
		var a := PI_ * i / 12
		pts.append(Vector2(apex.x + R * cos(a), apex.y + 7.0 - 7.0 * pow(sin(a), 0.7)))
	# Wellenkante
	for i in 7:
		pts.append(Vector2(apex.x - R + 2 * R * i / 6, apex.y + 7.6 + (0.9 if i % 2 else 0.0)))
	var rim_pts := pts.slice(13)
	rim_pts.reverse()
	var canopy := _pa(pts.slice(0, 13) + rim_pts)
	var bubble: bool = look.get("umb_style") == "bubble"
	var core: Array = [mini(255, int(uc[0]) + 120), mini(255, int(uc[1]) + 120), mini(255, int(uc[2]) + 120)]
	if bubble:
		# Transparente Kuppel, vom Leuchtstab von innen angestrahlt
		_fill(p, [190, 210, 230], 70)
		p.draw_polygon(canopy)
		_fill(p, uc, 90)
		p.draw_ellipse(apex.x - R * 0.5, apex.y + 0.5, R, 6.0)
		_pen(p, [220, 232, 244], 0.8, 150)
		_polyline(p, _pa(pts.slice(0, 13)))
	else:
		_fill(p, _mul(uc, 0.32), 215)
		p.draw_polygon(canopy)
		# Innenseite um den Stab heller (Licht fällt aufs Tuch)
		_fill(p, _mul(uc, 0.75), 160)
		p.draw_polygon(_pa([[apex.x - R * 0.35, apex.y + 7.4], apex, [apex.x + R * 0.35, apex.y + 7.4]]))
	for q: QP in [p, emit]:
		_pen(q, uc, 1.0)
		_line(q, Vector2(apex.x - R, apex.y + 7.4), Vector2(apex.x + R, apex.y + 7.4))
		# Leuchtender Schaft (wie im Film): heller Kern über die ganze Länge
		_pen(q, uc, 1.9)
		_line(q, apex, hand)
		_pen(q, core, 0.9)
		_line(q, apex, hand)
	_fill(emit, uc, 90)
	emit.draw_polygon(canopy)
	var sk: Array = look["skin"]
	_pen(p, sk, 2.2)
	_point(p, hand)


## Liegender Schirm neben einem Körper; der Stab leuchtet weiter.
static func _fallen_umbrella(p: QP, emit: QP, look: Dictionary) -> void:
	var uc: Array = look["umbrella"]
	var core: Array = [mini(255, int(uc[0]) + 120), mini(255, int(uc[1]) + 120), mini(255, int(uc[2]) + 120)]
	var x0 := -26.0
	var y0 := 1.0
	_fill(p, _mul(uc, 0.32), 215)
	p.draw_polygon(_pa([[x0, y0], [x0 + 6, y0 - 7], [x0 + 11, y0 - 8], [x0 + 12, y0]]))
	for q: QP in [p, emit]:
		_pen(q, uc, 1.8)
		_line(q, Vector2(x0 - 10, y0 + 0.5), Vector2(x0 + 6, y0 - 3))
		_pen(q, core, 0.8)
		_line(q, Vector2(x0 - 10, y0 + 0.5), Vector2(x0 + 6, y0 - 3))

# ---------------------------------------------------------------------------- Cache / API

# Postprocess-Shader: rgb = tex.rgb * m * vc.a + vc.rgb * tex.a, a = tex.a * vc.a
#   Maske (SourceIn):  m = 0, vc = (Farbe * alpha, alpha)  (premultipliziert)
#   Figur mit Nebel:   m = 1 - f, vc = (fog * f, 1)
# Der Nebel (SourceAtop über das Gesamtbild) ist linear in (rgb, a) und verteilt sich
# deshalb exakt auf jede einzelne Ebene.
const _FX_SHADER := "shader_type canvas_item;\nrender_mode blend_premul_alpha;\nuniform float m;\nvarying vec4 vc;\nvoid vertex(){ vc = COLOR; }\nvoid fragment(){ vec4 t = texture(TEXTURE, UV); COLOR = vec4(t.rgb * m * vc.a + vc.rgb * t.a, t.a * vc.a); }"


static func _mat(m: float) -> ShaderMaterial:
	var hit: Variant = _mats.get(m)
	if hit != null:
		return hit
	var sh := Shader.new()
	sh.code = _FX_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("m", m)
	_mats[m] = mat
	return mat


static func _ensure() -> void:
	if _raw != null:
		return
	assert(baker != null, "Sprites.baker muss gesetzt sein")
	_raw = baker.make_atlas(atlas_size)
	_fin = baker.make_atlas(atlas_size)     # nach _raw angelegt -> rendert danach
	_dummy_root = RenderingServer.canvas_item_create()
	_dummy = _SP.new(_dummy_root)


## Postprocess-Items freigeben, sobald der Atlas sie gerendert hat.
static func _fx_frame_start() -> void:
	if _fx_used.is_empty() or _fin.vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		return
	_fx_release()


static func _fx_release() -> void:
	for it in _fx_used:
		RenderingServer.canvas_item_clear(it)
		RenderingServer.canvas_item_set_visible(it, false)
		_fx_pool.append(it)
	_fx_used.clear()
	_fx_draw_index = 0


static func _fx_item(mat: ShaderMaterial, clip: Rect2) -> RID:
	var it: RID
	if _fx_pool.is_empty():
		it = RenderingServer.canvas_item_create()
	else:
		it = _fx_pool.pop_back()
	_fx_used.append(it)
	RenderingServer.canvas_item_set_parent(it, _fin.host.get_canvas_item())
	RenderingServer.canvas_item_set_visible(it, true)
	RenderingServer.canvas_item_set_draw_index(it, 100000 + _fx_draw_index)
	_fx_draw_index += 1
	RenderingServer.canvas_item_set_material(it, mat.get_rid())
	RenderingServer.canvas_item_set_default_texture_filter(it, RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	RenderingServer.canvas_item_set_custom_rect(it, true, clip)
	RenderingServer.canvas_item_set_clip(it, true)
	return it


## Umriss + Rimlight + Nebel: liest das rohe Bild img (Atlas _raw) und schreibt
## das Ergebnis in den Bereich dst des Atlas _fin. Rückgabe: fertiges Bild.
static func _postprocess(img: QImg, dst: Rect2i, rim_rgb: Variant, rim_side: int, fog_rgb: Array, fog: float,
		outline: Array = [4, 5, 10]) -> QImg:
	var f := float(int(255 * fog)) / 255.0 if fog > 0.0 else 0.0
	var fogc := Color(float(fog_rgb[0]) / 255.0, float(fog_rgb[1]) / 255.0, float(fog_rgb[2]) / 255.0)
	var tex := img.tex.get_rid()
	var src := img.region
	var clip := Rect2(dst)
	var size := Vector2(dst.size)
	var pos := Vector2(dst.position)
	var mk := _fx_item(_mat(0.0), clip)
	var mask := func(rgb: Array, alpha: float, d: Vector2) -> void:
		var a := alpha / 255.0
		var c := Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0, float(rgb[2]) / 255.0)
		c = c * (1.0 - f) + fogc * f
		RenderingServer.canvas_item_add_texture_rect_region(mk, Rect2(pos + d, size), tex, src,
			Color(c.r * a, c.g * a, c.b * a, a), false, true)
	for d: Vector2 in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		mask.call(outline, 255.0, d)
	if rim_rgb != null:
		mask.call(rim_rgb, 235.0, Vector2(rim_side, 0))
		mask.call(_mul(rim_rgb, 0.6), 160.0, Vector2(0, -1))
	var fi := _fx_item(_mat(1.0 - f), clip)
	RenderingServer.canvas_item_add_texture_rect_region(fi, Rect2(pos, size), tex, src,
		Color(fogc.r * f, fogc.g * f, fogc.b * f, 1.0), false, true)
	return QImg.new(_fin.texture(), clip)


static func frame_count(anim: String) -> int:
	return int(ANIMS.get(anim, 1))


## Alles verwerfen (Atlanten voll oder Zonenwechsel).
static func clear_cache() -> void:
	_CACHE.clear()
	if _raw != null:
		_fx_release()
		_raw.reset()
		_fin.reset()


static func _alloc(w: int, h: int, emit_used: bool) -> Array:
	# [raw, emit|null, fin] - bei vollem Atlas einmal alles verwerfen
	for attempt in 2:
		var r: Variant = _raw.alloc(w, h)
		var re: Variant = _raw.alloc(w, h) if emit_used and r != null else Rect2i()
		var rf: Variant = _fin.alloc(w, h)
		if r != null and re != null and rf != null:
			return [r, re if emit_used else null, rf]
		clear_cache()
	return []


## Fertiges Figurenbild. Rückgabe [img: QImg, emit: QImg|null, ax: int, ay: int, meta: Dictionary].
## anchor = Fußpunkt im Bild. meta: eye/hand/head (Vector2, relativ zum Anker, px), head_top (float).
static func get_(look: Dictionary, anim: String, frame: int, height_px: float, facing: int = 1,
		rim: Variant = null, rim_side: int = 1, fog_rgb: Array = [0, 0, 0], fog: float = 0.0,
		outline: Array = [4, 5, 10]) -> Array:
	var hpx := maxi(8, Py.round(height_px))
	var fogq := float(Py.round(fog * 8)) / 8.0
	var key := [look["id"], anim, frame, hpx, facing, rim, rim_side, fog_rgb, fogq, outline]
	var hit: Variant = _CACHE.get(key)
	if hit != null:
		return hit
	_ensure()
	if _CACHE.size() > _CACHE_MAX:     # wie _CACHE.clear() im Original, aber vor dem Zeichnen
		clear_cache()
	_raw.frame_start()
	_fin.frame_start()
	_fx_frame_start()

	var k := hpx / 48.0
	var left := 60.0 if anim == "die" else _PAD
	var right := 36.0 if anim == "die" else _PAD
	var W := int(ceilf((left + right) * k)) + 4
	var H := int(ceilf((_TOP + _BOT) * k)) + 4
	var ax := int(left * k) + 2
	var ay := int(_TOP * k) + 2

	var n := frame_count(anim)
	var t := (float(frame) / maxi(1, n - 1)) if anim == "die" else (float(frame) / n)
	var P := pose(anim, t)
	var rot: float = P["rot"]
	var umb: bool = look.get("umbrella") != null
	var fallen := anim == "die" and frame >= n - 3 and umb
	var emit_used: bool = (P["muzzle"] or P["scanner"] or fallen or (umb and rot == 0.0)
		or bool(look.get("led", false)) or look.get("head") == "visor" or (bool(look.get("cig", false)) and rot == 0.0))

	var slots := _alloc(W, H, emit_used)
	if slots.is_empty():
		return [null, null, ax, ay, {}]
	var r: Rect2i = slots[0]
	var p := _painter_for(_raw, r)
	var pe: QP
	if emit_used:
		pe = _painter_for(_raw, slots[1])
	else:
		_dummy.begin()
		pe = _dummy
	for q: QP in [p, pe]:
		q.translate(ax, ay)
		q.scale(k, k)
		q.save()
	if rot != 0.0:
		for q: QP in [p, pe]:
			q.translate(-3.0, 0.0)
			q.rotate(rad_to_deg(rot))
			q.translate(0.0, -2.5 * absf(rot) / (PI_ / 2))
	var res := _draw_figure(p, look, P, pe)
	var tr_ := p.transform()
	for q: QP in [p, pe]:
		q.restore()
	if fallen:
		_fallen_umbrella(p, pe, look)
	if not emit_used:
		_dummy.end()
	_raw.commit()

	var org := Vector2(r.position)
	var e_pt := tr_ * (res[0] as Vector2) - org
	var h_pt := tr_ * (res[2] as Vector2) - org
	var c_pt := tr_ * (res[1] as Vector2) - org
	var out := _postprocess(QImg.new(_raw.texture(), Rect2(r)), slots[2], rim, rim_side, fog_rgb, fogq, outline)
	_fin.commit()
	var emit: Variant = QImg.new(_raw.texture(), Rect2(slots[1] as Rect2i)) if emit_used else null
	if facing < 0:
		out = out.mirror()
		if emit != null:
			emit = (emit as QImg).mirror()
		e_pt = Vector2(W - 1 - e_pt.x, e_pt.y)
		h_pt = Vector2(W - 1 - h_pt.x, h_pt.y)
		c_pt = Vector2(W - 1 - c_pt.x, c_pt.y)
		ax = W - 1 - ax
	var meta := {"eye": Vector2(e_pt.x - ax, e_pt.y - ay), "hand": Vector2(h_pt.x - ax, h_pt.y - ay),
		"head": Vector2(c_pt.x - ax, c_pt.y - ay), "head_top": -(_TOP - 12) * k}
	var result := [out, emit, ax, ay, meta]
	_CACHE[key] = result
	return result
