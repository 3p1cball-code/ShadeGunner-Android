class_name Palette
## noir16 - die 16-Farben-Noir-Palette, identisch zu shadegunner/config.py.
##
## Der Dither-Shader bekommt sie als Uniform-Array; damit gibt es nur eine
## Quelle der Wahrheit und Palette/Szene koennen nicht auseinanderlaufen.

const VOID := 0
const NIGHT := 1
const NAVY := 2
const INDIGO := 3
const BLUE := 4
const STEEL := 5
const CRIMSON := 6
const SODIUM := 7
const ASH := 8
const PALE := 9
const WHITE := 10
const TEAL := 11
const CYAN := 12
const MAGENTA := 13
const AMBER := 14
const VIOLET := 15

static var NOIR16: Array[Color] = [
	Color("#06080e"), Color("#121626"), Color("#222842"), Color("#343c60"),
	Color("#4a5c8a"), Color("#6884b2"), Color("#8a2038"), Color("#9c5428"),
	Color("#a2a8b4"), Color("#d6dce2"), Color("#ffffff"), Color("#226068"),
	Color("#40d2dc"), Color("#e04896"), Color("#ff8a2c"), Color("#7a4aa8"),
]


static func get_color(i: int) -> Color:
	return NOIR16[i]


static func v3() -> PackedVector3Array:
	## Palette als vec3-Array (0..1). Der Shader hat sie derzeit fest eingebettet,
	## diese Funktion bleibt fuer Debug-Ausgaben.
	var a := PackedVector3Array()
	for c in NOIR16:
		a.push_back(Vector3(c.r, c.g, c.b))
	return a
