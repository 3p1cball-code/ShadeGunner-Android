class_name Palette
## Paletten (config.PALETTES / config.ZONE_LOOK) und die aktive Dither-Palette.
##
## Seit 14.10.2026 hat jede Zone ihre eigene 16-Farben-Palette (ein Komplementärpaar
## plus nahe Abstufungen). Die Szene setzt sie beim Zonenwechsel (Scene.frame ->
## Palette.active), die CRT-Kette liest sie pro Frame und schickt sie als Uniform an
## den Bayer-Shader. Das HUD liegt nach dem Dither darüber und behält noir16 (alt).

## Name der aktiven Dither-Palette (wie config.ACTIVE["palette"]).
static var active: String = Config.DEFAULT_PALETTE

static var _cache := {}        # Name -> PackedVector3Array (0..1)


static func zone_look(zone_index: int) -> Dictionary:
	return Config.ZONE_LOOK[Py.imod(zone_index, Config.ZONE_LOOK.size())]


## Farben der Zonenpalette zu einem Indexschlüssel ('neon' / 'people').
static func zone_colors(zone_index: int, key: String) -> Array:
	var z := zone_look(zone_index)
	var out := []
	for i: int in z[key]:
		out.append((z["pal"] as Array)[i])
	return out


static func colors(name: String) -> Array:
	if name == "noir16":
		return Config.NOIR16
	if name == "cga16":
		return Config.CGA16
	for z: Dictionary in Config.ZONE_LOOK:
		if z["name"] == name:
			return z["pal"]
	return Config.NOIR16


## Palette als vec3-Array (0..1) für den Shader-Uniform (immer 16 Einträge).
static func v3(name: String = "") -> PackedVector3Array:
	if name == "":
		name = active
	var hit: Variant = _cache.get(name)
	if hit != null:
		return hit
	var a := PackedVector3Array()
	for c: Array in colors(name):
		a.push_back(Vector3(float(c[0]) / 255.0, float(c[1]) / 255.0, float(c[2]) / 255.0))
	while a.size() < 16:
		a.push_back(a[a.size() - 1])
	_cache[name] = a
	return a
