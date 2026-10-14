class_name Looks
extends RefCounted
## Nicht-zeichnende Teile aus render/sprites.py, die die Simulation braucht:
## random_look, describe, frame_count, PLAYER_LOOK, _adj. Tabellen: DSprites.


## Frische (beschreibbare) Kopie von sprites.PLAYER_LOOK.
static func player_look() -> Dictionary:
	return DSprites.PLAYER_LOOK.duplicate(true)


static func frame_count(anim: String) -> int:
	return int(DSprites.ANIMS.get(anim, 1))


## Python str.upper(): wie String.to_upper, aber ß -> SS.
static func _upper(s: String) -> String:
	return s.to_upper().replace("ß", "SS").replace("ẞ", "SS")


static func _adj(word: String, genus: String) -> String:
	return _upper(word) + {"m": "ER", "f": "E", "n": "ES"}[genus]


## Zwei sagbare Merkmale [Kleidung, Kopf] für Kopfgeld-Briefings.
static func describe(look: Dictionary) -> Array:
	var out: String = look["outfit"]
	var cloth := ""
	var head := ""
	if I18n.get_lang() == "en":
		cloth = DSprites.OUTFIT_NAME_EN[out]
		var color: String = DSprites.COAT_COLOR_EN.get(look["coat_name"], look["coat_name"])
		if out == "cloak":
			cloth = "TRANSPARENT RAIN CAPE"
		elif out == "long":
			cloth = _upper(color) + " LONG COAT"
		else:
			cloth = _upper(color) + " " + cloth
		head = DSprites.HEAD_NAME_EN[look["head"]]
		if look.get("umbrella"):
			head += ", GLOWING UMBRELLA"
		return [cloth, head]
	var wg: Array = DSprites.OUTFIT_NAME[out]
	var word: String = wg[0]
	var g: String = wg[1]
	if out == "cloak":
		cloth = "TRANSPARENTES REGENCAPE"
	elif out == "long":
		cloth = _adj(look["coat_name"], "m") + " LANGMANTEL"
	else:
		cloth = _adj(look["coat_name"], g) + " " + word
	head = DSprites.HEAD_NAME[look["head"]]
	if look.get("umbrella"):
		head += ", LEUCHTSCHIRM"
	return [cloth, head]


static func _c(col: Array) -> Array:
	return col.duplicate()


## Schirmart: transparente Kuppel, Papierschirm (beige, wie im Film) oder Stoff.
static func umb_style_of(r: float) -> String:
	return "bubble" if r < 0.3 else ("paper" if r < 0.55 else "flat")


## Zufallsaussehen - Zufallsaufrufe in exakt der Reihenfolge von sprites.random_look.
## accents: Leuchtfarben für Schirm/Akzent (Zonenpalette); null = DSprites.NEON.
static func random_look(rng: PyRandom, uid: int, rain: float = 0.6, accents: Variant = null) -> Dictionary:
	var acc: Array = accents if accents != null and not (accents as Array).is_empty() else DSprites.NEON
	var outfit: String = rng.choice(DSprites.OUTFITS)
	var head: String = rng.choice(DSprites.HEADS)
	if outfit == "hoodie" and rng.random() < 0.6:
		head = "hood"
	var umbrella: Variant = null
	if rng.random() < 0.18 + 0.22 * rain:
		umbrella = _c(rng.choice(acc))
	if head in ["conical", "afro"]:
		umbrella = null if rng.random() < 0.7 else umbrella
	var idx: Array = range(DSprites.COATS.size())
	var ci: int = rng.choices1(idx, DSprites.COAT_W)
	var coat_row: Array = DSprites.COATS[ci]
	var coat: Array = _c(coat_row[0])
	var cname: String = coat_row[1]
	var old := rng.random() < 0.07
	var bag: Variant = rng.choice([null, null, null, null, "bag", "briefcase", "backpack"])
	# Reihenfolge wie im dict(...)-Literal
	var umb_style := umb_style_of(rng.random())
	var wf := rng.uniform(0.82, 1.28)
	var hf := rng.uniform(0.88, 1.08) * (0.95 if old else 1.0)
	var pants: Array = _c(rng.choice(DSprites.PANTS))
	var skin: Array = _c(rng.choice(DSprites.SKINS))
	var hair: Array = [170, 172, 180] if old else _c(rng.choice(DSprites.HAIRS))
	var accent: Array = _c(rng.choice(acc))
	var collar := rng.random() < 0.3
	var cig := rng.random() < 0.12
	var led := rng.random() < 0.16
	var mask := rng.random() < 0.1
	return {
		"id": uid, "outfit": outfit, "head": head, "umbrella": umbrella,
		"umb_style": umb_style, "wf": wf, "hf": hf,
		"coat": coat, "coat_name": cname, "pants": pants, "skin": skin,
		"hair": hair, "accent": accent, "bag": bag, "collar": collar,
		"cig": cig, "led": led, "mask": mask, "old": old,
	}
