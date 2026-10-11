class_name Sprites
extends RefCounted
## Skelett-animierte Figuren - 1:1 aus shadegunner/render/sprites.py.
##
## Figurhöhe = 48 Design-Einheiten, Füße bei y = 0, Blickrichtung +x.
## Pro Frame wird die Pose analytisch aus (Animation, Phase) berechnet und ohne
## Kantenglättung gezeichnet.

const PI := 3.141592653589793

const COATS := [
	Color8(44, 52, 86), Color8(66, 80, 124), Color8(78, 80, 94), Color8(126, 32, 58),
	Color8(34, 96, 106), Color8(100, 66, 150), Color8(96, 120, 166), Color8(24, 24, 32),
	Color8(196, 150, 52), Color8(196, 200, 208), Color8(196, 70, 140), Color8(200, 104, 44),
]
const COAT_W := [5, 5, 4, 3, 3, 2, 3, 5, 1, 1, 1, 1]
const PANTS := [Color8(22, 24, 38), Color8(34, 40, 62), Color8(52, 58, 80), Color8(28, 30, 46), Color8(16, 16, 22)]
const SKINS := [Color8(206, 176, 158), Color8(164, 122, 100), Color8(118, 84, 70),
	Color8(226, 210, 200), Color8(186, 150, 124), Color8(92, 64, 54)]
const HAIRS := [Color8(14, 14, 20), Color8(40, 30, 30), Color8(170, 172, 180), Color8(138, 32, 56),
	Color8(122, 74, 168), Color8(64, 210, 220), Color8(226, 210, 160), Color8(10, 10, 14),
	Color8(224, 72, 150), Color8(200, 104, 44)]
static var NEON: Array[Color] = [Palette.NOIR16[Palette.CYAN], Palette.NOIR16[Palette.MAGENTA],
	Palette.NOIR16[Palette.AMBER], Palette.NOIR16[Palette.VIOLET], Palette.NOIR16[Palette.TEAL],
	Palette.NOIR16[Palette.PALE]]

const OUTFITS := ["trench", "trench", "long", "jacket", "jacket", "dress", "cloak", "robe", "hoodie",
	"vest", "suit", "overall"]
const HEADS := ["short", "short", "long", "bun", "fedora", "fedora", "cap", "hood", "conical", "conical",
	"mohawk", "bald", "beanie", "ponytail", "visor", "afro"]

const ANIMS := {
	"idle": 4, "walk": 8, "run": 6, "panic": 6, "die": 9, "aim": 1, "shoot": 2, "scan": 2,
	"hurt": 1, "punch": 3, "cower": 2, "jump": 1, "duck": 2, "hands": 2, "talk": 4,
}

var _c: CanvasItem
var _fog_c := Color(0, 0, 0)
var _fog := 0.0


static func mul(c: Color, f: float) -> Color:
	return Color(clampf(c.r * f, 0.0, 1.0), clampf(c.g * f, 0.0, 1.0), clampf(c.b * f, 0.0, 1.0))


static func pick(rng: RandomNumberGenerator, arr: Array) -> Variant:
	return arr[rng.randi_range(0, arr.size() - 1)]


static func pick_w(rng: RandomNumberGenerator, arr: Array, w: Array) -> Variant:
	var total := 0
	for v in w:
		total += int(v)
	var r := rng.randi_range(0, total - 1)
	for i in arr.size():
		r -= int(w[i])
		if r < 0:
			return arr[i]
	return arr[0]


static func random_look(rng: RandomNumberGenerator, uid: int, rain: float = 0.6) -> Dictionary:
	var outfit: String = pick(rng, OUTFITS)
	var head: String = pick(rng, HEADS)
	if outfit == "hoodie" and rng.randf() < 0.6:
		head = "hood"
	var umbrella: Variant = null
	if rng.randf() < 0.18 + 0.22 * rain:
		umbrella = pick(rng, [NEON[0], NEON[1], NEON[2], NEON[3], NEON[4], Color8(220, 230, 255)])
	if (head == "conical" or head == "afro") and rng.randf() < 0.7:
		umbrella = null
	var coat: Color = pick_w(rng, COATS, COAT_W)
	var old := rng.randf() < 0.07
	return {
		"id": uid, "outfit": outfit, "head": head, "umbrella": umbrella,
		"umb_style": "bubble" if rng.randf() < 0.3 else "flat",
		"wf": rng.randf_range(0.82, 1.28),
		"hf": rng.randf_range(0.88, 1.08) * (0.95 if old else 1.0),
		"coat": coat, "pants": pick(rng, PANTS), "skin": pick(rng, SKINS),
		"hair": Color8(170, 172, 180) if old else pick(rng, HAIRS),
		"accent": pick(rng, NEON), "bag": pick(rng, [null, null, null, null, "bag", "briefcase", "backpack"]),
		"collar": rng.randf() < 0.3, "cig": rng.randf() < 0.12, "led": rng.randf() < 0.16,
		"mask": rng.randf() < 0.1, "old": old,
	}


static func player_look() -> Dictionary:
	return {
		"id": -1, "outfit": "trench", "head": "short", "umbrella": null, "umb_style": "flat",
		"wf": 1.06, "hf": 1.03, "coat": Color8(150, 146, 140), "pants": Color8(34, 38, 56),
		"skin": Color8(206, 176, 158), "hair": Color8(40, 30, 30), "accent": Palette.NOIR16[Palette.CYAN],
		"bag": null, "collar": true, "player": true, "cig": false, "led": false, "mask": false, "old": false,
	}


# ---------------------------------------------------------------------------- Pose
static func pose(anim: String, t: float) -> Dictionary:
	var phi := 2.0 * PI * t
	var s := sin(phi)
	var c := cos(phi)
	var P := {
		"lean": 0.0, "bob": 0.0, "crouch": 0.0, "rot": 0.0,
		"legs": [Vector2(0.0, 0.05), Vector2(0.0, 0.05)],
		"arms": [Vector2(0.08, 0.15), Vector2(0.08, 0.15)],
		"flutter": 0.0, "gun": false, "scanner": false, "muzzle": false,
	}
	match anim:
		"walk":
			var A := 0.42
			P["legs"] = [Vector2(-A * s, 0.12 + 0.8 * maxf(0.0, -c)), Vector2(A * s, 0.12 + 0.8 * maxf(0.0, c))]
			P["arms"] = [Vector2(0.36 * s + 0.05, 0.25), Vector2(-0.36 * s + 0.05, 0.25)]
			P["bob"] = -0.9 * (1.0 - absf(s))
			P["lean"] = 0.04
			P["flutter"] = 0.3
		"run", "panic":
			var A := 0.78
			P["legs"] = [Vector2(-A * s, 0.25 + 1.45 * maxf(0.0, -c)), Vector2(A * s, 0.25 + 1.45 * maxf(0.0, c))]
			P["bob"] = -1.6 * (1.0 - absf(s)) + 0.5
			P["lean"] = 0.24
			P["flutter"] = 1.0
			if anim == "run":
				P["arms"] = [Vector2(0.9 * s, 1.55), Vector2(-0.9 * s, 1.55)]
			else:
				P["arms"] = [Vector2(2.55 + 0.35 * sin(2.0 * phi), 0.35), Vector2(2.75 - 0.35 * sin(2.0 * phi), 0.3)]
				P["lean"] = 0.1
		"idle":
			var b := sin(phi)
			P["legs"] = [Vector2(-0.07, 0.06), Vector2(0.08, 0.05)]
			P["arms"] = [Vector2(0.06 + 0.03 * b, 0.18), Vector2(0.04 - 0.03 * b, 0.2)]
			P["bob"] = 0.25 * b
		"aim", "shoot":
			P["legs"] = [Vector2(-0.2, 0.12), Vector2(0.22, 0.18)]
			var rec := 0.28 if (anim == "shoot" and t < 0.5) else 0.0
			P["arms"] = [Vector2(1.25 + rec * 0.5, 0.32), Vector2(PI / 2.0 - 0.04 + rec, -rec * 0.4)]
			P["lean"] = -0.05 - rec * 0.25
			P["gun"] = true
			P["muzzle"] = anim == "shoot" and t < 0.5
		"scan":
			P["legs"] = [Vector2(-0.12, 0.08), Vector2(0.14, 0.1)]
			P["arms"] = [Vector2(0.1, 0.25), Vector2(1.8 + 0.05 * s, -0.25)]
			P["scanner"] = true
		"hurt":
			P["legs"] = [Vector2(-0.3, 0.3), Vector2(0.12, 0.4)]
			P["arms"] = [Vector2(0.9, 0.6), Vector2(-0.7, 0.4)]
			P["lean"] = -0.35
			P["crouch"] = 1.5
		"cower":
			var tr := 0.06 * s
			P["legs"] = [Vector2(-0.12, 0.35), Vector2(0.1, 0.4)]
			P["arms"] = [Vector2(2.7 + tr, 0.55), Vector2(2.85 - tr, 0.5)]
			P["lean"] = -0.1
			P["crouch"] = 1.2
		"duck":
			var tr := 0.05 * s
			P["legs"] = [Vector2(1.2, 2.35), Vector2(1.0, 2.2)]
			P["arms"] = [Vector2(2.6 + tr, 0.7), Vector2(2.8 - tr, 0.6)]
			P["lean"] = 0.42
			P["crouch"] = 12.6
		"hands":
			P["legs"] = [Vector2(-0.08, 0.06), Vector2(0.1, 0.05)]
			P["arms"] = [Vector2(2.55 + 0.04 * s, -0.5), Vector2(2.7 - 0.04 * s, -0.45)]
			P["lean"] = -0.06
		"talk":
			var g := maxf(0.0, sin(phi))
			P["legs"] = [Vector2(-0.1, 0.06), Vector2(0.12 + 0.04 * c, 0.08)]
			P["arms"] = [Vector2(0.08, 0.2), Vector2(0.35 + 0.55 * g, 0.9 + 0.5 * g)]
			P["bob"] = 0.2 * c
			P["lean"] = 0.03
		"jump":
			P["legs"] = [Vector2(-0.55, 1.5), Vector2(0.85, 1.75)]
			P["arms"] = [Vector2(-0.9, 0.9), Vector2(1.9, 0.6)]
			P["lean"] = 0.18
			P["crouch"] = 2.0
			P["flutter"] = 1.4
		"punch":
			var k := sin(PI * t)
			P["legs"] = [Vector2(-0.3, 0.15), Vector2(0.32, 0.3)]
			P["arms"] = [Vector2(0.6, 1.2), Vector2(0.6 + 1.0 * k, 1.3 - 1.2 * k)]
			P["lean"] = 0.15 + 0.2 * k
		"die":
			if t < 0.38:
				var k := t / 0.38
				P["legs"] = [Vector2(-0.1 - 0.4 * k, 0.2 + 1.3 * k), Vector2(0.15 + 0.5 * k, 0.2 + 1.5 * k)]
				P["arms"] = [Vector2(0.2 + 0.6 * k, 0.3 + 0.4 * k), Vector2(0.4 + 0.9 * k, 0.5)]
				P["crouch"] = 7.0 * k
				P["lean"] = 0.35 * k
			else:
				var k := minf(1.0, (t - 0.38) / 0.5)
				var ke := 1.0 - (1.0 - k) * (1.0 - k)
				P["legs"] = [Vector2(-0.5 + 0.5 * ke, 1.5 - 1.35 * ke), Vector2(0.65 - 0.5 * ke, 1.7 - 1.5 * ke)]
				P["arms"] = [Vector2(0.8 + 1.6 * ke, 0.7), Vector2(1.3 + 1.5 * ke, 0.5)]
				P["crouch"] = 7.0 * (1.0 - ke)
				P["lean"] = 0.35 * (1.0 - ke)
				P["rot"] = -PI / 2.0 * ke
	return P


# ---------------------------------------------------------------------------- Zeichnen
func _f(col: Color) -> Color:
	return col if _fog <= 0.001 else col.lerp(_fog_c, _fog)


func _line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
	var e := _f(col)
	_c.draw_line(a, b, e, w, false)
	var r := w * 0.5
	_c.draw_circle(a, r, e)
	_c.draw_circle(b, r, e)


func _poly(pts: PackedVector2Array, col: Color) -> void:
	if pts.size() >= 3:
		_c.draw_colored_polygon(pts, _f(col))


func _dot(center: Vector2, col: Color, r: float) -> void:
	_c.draw_circle(center, r, _f(col))


func _limb(origin: Vector2, a: float, l: float) -> Vector2:
	return Vector2(origin.x + l * sin(a), origin.y + l * cos(a))


func _leg(hip: Vector2, pair: Vector2, hf: float) -> Array:
	var k := _limb(hip, pair.x, 11.0 * hf)
	var a := _limb(k, pair.x - pair.y, 11.2 * hf)
	return [k, a, pair.x - pair.y]


func _arm(sh: Vector2, pair: Vector2, hf: float) -> Array:
	var e := _limb(sh, pair.x, 8.0 * hf)
	var h := _limb(e, pair.x + pair.y, 7.2 * hf)
	return [e, h]


func draw_figure(canvas: CanvasItem, pos: Vector2, look: Dictionary, anim: String,
		t: float, hpx: float, facing: int, fog_col: Color = Color(0, 0, 0), fog: float = 0.0) -> void:
	_c = canvas
	_fog_c = fog_col
	_fog = fog
	var k := maxf(1.0, hpx) / 48.0
	var P := pose(anim, t)
	_c.draw_set_transform(pos, float(P["rot"]) * float(facing), Vector2(k * facing, k))

	var wf: float = look["wf"]
	var hf: float = look["hf"]
	var coat: Color = look["coat"]
	var pants: Color = look["pants"]
	var skin: Color = look["skin"]
	var outfit: String = look["outfit"]
	var head: String = look["head"]
	if outfit == "overall":
		pants = mul(coat, 0.9)
	var far_coat := mul(coat, 0.62)
	var far_pants := mul(pants, 0.7)
	var leg_w := 3.9 * wf
	var arm_w := 3.1 * wf
	var old: bool = look.get("old", false) and float(P["rot"]) == 0.0

	var hip := Vector2(0.0, -22.0 * hf + float(P["crouch"]) + float(P["bob"]) + (1.0 if old else 0.0))
	var lean: float = float(P["lean"]) + (0.2 if old else 0.0)
	var sh := Vector2(hip.x + 14.0 * hf * sin(lean), hip.y - 14.0 * hf * cos(lean))
	var hc := Vector2(sh.x + 6.2 * hf * sin(lean * 1.3) + 0.6, sh.y - 6.2 * hf * cos(lean * 1.3))
	var legs := [_leg(hip, P["legs"][0], hf), _leg(hip, P["legs"][1], hf)]
	var arms := [_arm(sh, P["arms"][0], hf), _arm(sh, P["arms"][1], hf)]

	var sleeve_far: Color = mul(skin, 0.7) if outfit == "vest" else far_coat
	var sleeve: Color = skin if outfit == "vest" else (coat if outfit != "cloak" else look["accent"])

	# Rucksack (hinter allem)
	if look.get("bag") == "backpack":
		_poly(PackedVector2Array([Vector2(sh.x - 4.6 * wf, sh.y + 0.5), Vector2(sh.x - 1.5, sh.y + 0.5),
			Vector2(hip.x - 2.0, hip.y - 2.0), Vector2(hip.x - 5.8 * wf, hip.y - 2.5)]), mul(coat, 0.5))

	# ferner Arm
	_line(sh, arms[0][0], sleeve_far, arm_w)
	_line(arms[0][0], arms[0][1], sleeve_far, arm_w)
	_dot(arms[0][1], mul(skin, 0.7), arm_w * 0.45)

	# Beine
	for i in 2:
		var col := far_pants if i == 0 else pants
		var knee: Vector2 = legs[i][0]
		var ank: Vector2 = legs[i][1]
		var sa: float = legs[i][2]
		_line(hip, knee, col, leg_w)
		_line(knee, ank, col, leg_w)
		var shoe := mul(col, 0.55)
		var fx := ank.x + 2.4 * cos(sa)
		var fy := ank.y - 2.4 * sin(sa) * 0.3
		_line(ank, Vector2(fx, fy), shoe, leg_w * 0.85)

	# Torso / Mantel
	var kx := [legs[0][0].x, legs[1][0].x]
	var w := 4.9 * wf * (1.12 if outfit in ["long", "suit"] else 1.0)
	var sx := sh.x
	var sy := sh.y
	var hx := hip.x
	var hy := hip.y
	if outfit in ["trench", "robe", "cloak", "dress", "long"]:
		var hem_y := -6.0 * hf + float(P["crouch"]) * 0.6
		match outfit:
			"long": hem_y = -2.4 * hf + float(P["crouch"]) * 0.6
			"robe": hem_y = -0.8
			"cloak": hem_y = -5.0 * hf + float(P["crouch"]) * 0.6
			"dress": hem_y = -11.0 * hf + float(P["crouch"]) * 0.5
		var spread_f := maxf(3.8 * wf, maxf(kx[0], kx[1]) * 0.75 + 1.8)
		var spread_b := minf(-3.6 * wf, minf(kx[0], kx[1]) * 0.75 - 1.8)
		var fl: float = P["flutter"]
		var hem_b_x := spread_b - 2.5 * fl
		var hem_b_y := hem_y - 3.0 * fl
		if outfit == "cloak":
			_poly(PackedVector2Array([Vector2(sx - w * 0.8, sy), Vector2(sx + w * 0.9, sy),
				Vector2(hx + w, hy), Vector2(hx - w * 0.9, hy)]), look["accent"])
			_poly(PackedVector2Array([Vector2(hx - w * 0.9, hy), Vector2(hx + w, hy),
				Vector2(spread_f * 0.8, hem_y + 4.0), Vector2(spread_b * 0.8, hem_y + 4.0)]), mul(look["accent"], 0.6))
		var body_col := Color8(176, 200, 222) if outfit == "cloak" else coat
		var pts := PackedVector2Array([Vector2(sx - w * 0.85, sy - 0.6), Vector2(sx + w * 0.75, sy - 0.6),
			Vector2(sx + w * 1.0, sy + 4.5), Vector2(hx + w * 0.9, hy - 1.0), Vector2(spread_f, hem_y),
			Vector2(hem_b_x, hem_b_y), Vector2(hx - w * 0.95, hy)])
		_poly(pts, body_col)
		if outfit != "cloak":
			_poly(PackedVector2Array([Vector2(sx - w * 0.85, sy - 0.6), Vector2(sx - w * 0.2, sy),
				Vector2(hx - w * 0.3, hy), Vector2(hem_b_x + 1.5, hem_b_y), Vector2(hem_b_x, hem_b_y),
				Vector2(hx - w * 0.95, hy)]), mul(body_col, 0.72))
		if outfit in ["trench", "long"]:
			_line(Vector2(hx - w * 0.9, hy + 1.2), Vector2(hx + w * 0.95, hy + 0.5), mul(coat, 0.55), 1.2)
			if look.get("collar", false) or outfit == "long":
				_poly(PackedVector2Array([Vector2(sx - w * 0.95, sy - 3.4), Vector2(sx + w * 0.5, sy - 1.0),
					Vector2(sx - w * 0.2, sy + 3.0)]), mul(coat, 1.18))
		elif outfit == "robe":
			_line(Vector2(sx + w * 0.7, sy + 1.0), Vector2(spread_f - 0.6, hem_y - 0.5), look["accent"], 1.0)
	else:
		var hem := hy + 2.2
		_poly(PackedVector2Array([Vector2(sx - w * 0.85, sy - 0.6), Vector2(sx + w * 0.8, sy - 0.6),
			Vector2(sx + w * 1.0, sy + 4.5), Vector2(hx + w * 0.95, hem), Vector2(hx - w * 1.0, hem)]), coat)
		_poly(PackedVector2Array([Vector2(sx - w * 0.85, sy - 0.6), Vector2(sx - w * 0.15, sy),
			Vector2(hx - w * 0.25, hem), Vector2(hx - w * 1.0, hem)]), mul(coat, 0.72))
		if outfit == "suit":
			_poly(PackedVector2Array([Vector2(sx + w * 0.35, sy - 0.4), Vector2(sx + w * 0.85, sy - 0.4),
				Vector2(sx + w * 0.75, sy + 4.0)]), Color8(214, 220, 226))
			_line(Vector2(sx + w * 0.72, sy + 0.4), Vector2(sx + w * 0.8, sy + 4.4), look["accent"], 0.9)
		elif outfit == "overall":
			_line(Vector2(hx - w * 0.9, (sy + hy) / 2.0), Vector2(hx + w * 0.95, (sy + hy) / 2.0 - 0.3),
				Color8(214, 220, 226), 1.0)
		else:
			if outfit in ["jacket", "vest"]:
				_line(Vector2(sx + w * 0.95, sy + 2.0), Vector2(hx + w * 0.9, hem - 0.5), look["accent"], 1.0)
			else:
				_line(Vector2(hx - w * 0.9, hem - 0.3), Vector2(hx + w * 0.9, hem - 0.3), look["accent"], 1.0)

	if look.get("led", false) and outfit != "cloak":
		_line(Vector2(sx + w * 0.85, sy + 1.0), Vector2(hx + w * 0.92, hy - 0.5), look["accent"], 0.9)

	var bag: Variant = look.get("bag")
	if bag == "bag":
		_poly(PackedVector2Array([Vector2(hx - w * 1.3, hy - 3.0), Vector2(hx - w * 0.2, hy - 3.0),
			Vector2(hx - w * 0.3, hy + 3.0), Vector2(hx - w * 1.2, hy + 3.0)]), mul(coat, 0.45))
		_line(Vector2(hx - w * 0.7, hy - 3.0), Vector2(sx + w * 0.4, sy + 0.5), mul(coat, 0.4), 0.8)

	# Kopf
	var rx := 3.5 * pow(wf, 0.3)
	var ry := 4.0
	var hair: Color = look["hair"]
	if head == "afro":
		_c.draw_circle(Vector2(hc.x, hc.y), rx + 1.8, _f(hair))
	if head == "ponytail":
		_line(Vector2(hc.x - rx * 0.8, hc.y - ry * 0.6),
			Vector2(hc.x - rx - 2.6 - float(P["flutter"]), hc.y + 2.5), hair, 1.8)
	_dot(hc, skin, ry)  # Kopf (Ellipse genaehert als Kreis)
	_dot(Vector2(hc.x - rx * 0.4, hc.y + 0.2), mul(skin, 0.7), ry * 0.55)
	var top := hc.y - ry
	match head:
		"short", "ponytail", "visor":
			_poly(PackedVector2Array([Vector2(hc.x - rx - 0.3, hc.y + 0.5), Vector2(hc.x - rx * 0.6, top - 0.6),
				Vector2(hc.x + rx * 0.9, top - 0.3), Vector2(hc.x + rx * 0.3, top + 1.6), Vector2(hc.x - rx * 0.3, hc.y - 0.5)]), hair)
			if head == "visor":
				_line(Vector2(hc.x - rx * 0.1, hc.y - 0.8), Vector2(hc.x + rx + 0.6, hc.y - 0.8), look["accent"], 1.3)
		"long":
			_poly(PackedVector2Array([Vector2(hc.x - rx - 0.6, hc.y), Vector2(hc.x - rx * 0.4, top - 0.7),
				Vector2(hc.x + rx, top), Vector2(hc.x + rx * 0.2, top + 1.8)]), hair)
		"bun":
			_poly(PackedVector2Array([Vector2(hc.x - rx - 0.2, hc.y), Vector2(hc.x - rx * 0.5, top - 0.5),
				Vector2(hc.x + rx * 0.9, top), Vector2(hc.x + rx * 0.2, top + 1.5)]), hair)
			_dot(Vector2(hc.x - rx - 1.0, top + 1.0), hair, 1.4)
		"fedora":
			_poly(PackedVector2Array([Vector2(hc.x - rx * 0.9, top + 1.2), Vector2(hc.x - rx * 0.7, top - 2.6),
				Vector2(hc.x + rx * 0.8, top - 2.6), Vector2(hc.x + rx * 0.95, top + 1.2)]), mul(coat, 0.75))
			_line(Vector2(hc.x - rx - 2.4, top + 1.4), Vector2(hc.x + rx + 2.4, top + 1.2), mul(coat, 0.6), 1.3)
		"cap":
			_poly(PackedVector2Array([Vector2(hc.x - rx, top + 2.0), Vector2(hc.x - rx * 0.6, top - 0.8),
				Vector2(hc.x + rx * 0.8, top - 0.6), Vector2(hc.x + rx * 1.0, top + 1.6)]), look["accent"])
			_line(Vector2(hc.x + rx * 0.6, top + 1.7), Vector2(hc.x + rx + 2.6, top + 2.1), mul(look["accent"], 0.6), 1.0)
		"conical":
			_poly(PackedVector2Array([Vector2(hc.x - rx - 4.6, top + 2.6), Vector2(hc.x + 0.2, top - 3.2),
				Vector2(hc.x + rx + 4.6, top + 2.6)]), Color8(150, 138, 104))
			_line(Vector2(hc.x - rx - 4.6, top + 2.6), Vector2(hc.x + rx + 4.6, top + 2.6), Color8(90, 80, 60), 0.8)
		"mohawk":
			_line(Vector2(hc.x - rx * 0.6, top - 0.3), Vector2(hc.x + rx * 0.6, top - 1.8), hair, 1.6)
			_line(Vector2(hc.x - rx * 0.9, top + 1.0), Vector2(hc.x - rx * 0.2, top - 1.5), hair, 1.6)
		"hood":
			_c.draw_circle(Vector2(hc.x - 0.3, hc.y - 0.4), rx + 0.9, _f(mul(coat, 0.85)))
			_poly(PackedVector2Array([Vector2(hc.x - rx - 1.6, hc.y + 1.0), Vector2(hc.x - rx * 0.6, top - 1.6),
				Vector2(hc.x + rx * 0.9, top - 1.0), Vector2(hc.x + rx * 0.4, top + 1.2), Vector2(hc.x - rx * 0.4, hc.y + 0.5)]),
				mul(coat, 0.85))
		"beanie":
			_poly(PackedVector2Array([Vector2(hc.x - rx - 0.4, top + 2.4), Vector2(hc.x - rx * 0.7, top - 1.2),
				Vector2(hc.x + rx * 0.2, top - 1.8), Vector2(hc.x + rx * 0.95, top - 0.6), Vector2(hc.x + rx * 1.05, top + 2.0)]),
				mul(look["accent"], 0.7))
			_line(Vector2(hc.x - rx - 0.4, top + 2.2), Vector2(hc.x + rx * 1.05, top + 1.9), mul(look["accent"], 0.45), 1.0)
		"afro":
			_dot(Vector2(hc.x, top + 0.4), mul(hair, 1.2), rx + 0.8)

	if look.get("mask", false):
		_poly(PackedVector2Array([Vector2(hc.x + rx * 0.1, hc.y + 0.6), Vector2(hc.x + rx + 0.4, hc.y + 0.4),
			Vector2(hc.x + rx + 0.2, hc.y + 3.2), Vector2(hc.x + rx * 0.2, hc.y + 3.4)]), Color8(30, 32, 40))
	if look.get("cig", false) and float(P["rot"]) == 0.0:
		var tip := Vector2(hc.x + rx + 1.8, hc.y + 1.6)
		_line(Vector2(hc.x + rx + 0.2, hc.y + 1.6), tip, Color8(214, 220, 226), 0.7)
		_dot(tip, Color8(255, 138, 44), 0.9)

	# naher Arm
	_line(sh, arms[1][0], sleeve, arm_w)
	_line(arms[1][0], arms[1][1], sleeve, arm_w)
	var hand: Vector2 = arms[1][1]
	if bag == "briefcase" and not (P["gun"] or P["scanner"]) and float(P["rot"]) == 0.0:
		_poly(PackedVector2Array([Vector2(hand.x - 2.6, hand.y + 0.6), Vector2(hand.x + 2.8, hand.y + 0.6),
			Vector2(hand.x + 2.8, hand.y + 4.6), Vector2(hand.x - 2.6, hand.y + 4.6)]), Color8(30, 24, 26))
	_dot(hand, skin, arm_w * 0.45)

	if P["gun"]:
		var al := float(P["arms"][1].x) + float(P["arms"][1].y)
		var dx := sin(al)
		var dy := cos(al)
		var tip := Vector2(hand.x + dx * 4.4, hand.y + dy * 4.4)
		_line(hand, tip, Color8(24, 26, 34), 1.9)
		_line(hand, Vector2(hand.x - dy * 1.6, hand.y + dx * 1.6 + 0.6), Color8(24, 26, 34), 1.4)
		_dot(Vector2(hand.x + dx * 2.2, hand.y + dy * 2.2 - 0.5), Palette.NOIR16[Palette.CYAN], 0.7)
		if P["muzzle"]:
			var mx := tip.x + dx * 2.6
			var my := tip.y + dy * 2.6
			_dot(Vector2(mx, my), Color8(255, 240, 200), 1.8)
	if P["scanner"]:
		var al := float(P["arms"][1].x) + float(P["arms"][1].y)
		var dx := sin(al)
		var dy := cos(al)
		_line(hand, Vector2(hand.x + dx * 2.4, hand.y + dy * 2.4), Color8(162, 168, 180), 2.2)
		_dot(Vector2(hand.x + dx * 2.6, hand.y + dy * 2.6), Palette.NOIR16[Palette.CYAN], 1.2)

	if look.get("umbrella") != null and float(P["rot"]) == 0.0:
		_umbrella(look, hc)

	_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _umbrella(look: Dictionary, hc: Vector2) -> void:
	var uc: Color = look["umbrella"]
	var hand := Vector2(hc.x + 3.0, hc.y + 10.5)
	var apex := Vector2(hand.x - 1.0, hc.y - 15.0)
	var R := 11.5
	var pts := PackedVector2Array()
	for i in 13:
		var a := PI * i / 12.0
		pts.append(Vector2(apex.x + R * cos(a), apex.y + 7.0 - 7.0 * pow(sin(a), 0.7)))
	var flat: bool = look.get("umb_style", "flat") == "flat"
	if flat:
		_poly(pts, mul(uc, 0.32))
		_poly(PackedVector2Array([Vector2(apex.x - R * 0.35, apex.y + 7.4), apex,
			Vector2(apex.x + R * 0.35, apex.y + 7.4)]), mul(uc, 0.75))
	else:
		_poly(pts, Color(190.0 / 255.0, 210.0 / 255.0, 230.0 / 255.0, 0.35))
	_line(Vector2(apex.x - R, apex.y + 7.4), Vector2(apex.x + R, apex.y + 7.4), uc, 1.0)
	_line(apex, hand, uc, 1.9)
	_dot(hand, look["skin"], 1.1)
