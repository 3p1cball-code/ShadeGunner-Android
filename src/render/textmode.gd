class_name TextMode
extends RefCounted
## Optionaler Text-/ASCII-Darstellungsmodus (Gimmick): zeichnet die View.W x 360-
## Szene als Zeichenraster in den 16 Farben von noir16.
##
## Ausgabe ist WIEDER eine View.W x 360-Textur (640x360 bei 16:9). Die vorhandene CRT-Kette laeuft
## unveraendert darueber, der Roehren-Effekt bleibt also erhalten.
##
## Einbindung (nach Scene.setup, VOR CRTChain im Baum - Reihenfolge zaehlt!):
##
##   var tm := TextMode.new()
##   var ttex := tm.setup(self, stex)   # stex = Scene.setup(...)
##   chain.scene_tex = ttex             # statt stex
##   tm.set_cell_size(8)                # 640/8 x 360/8 = 80x45 Zellen
##   tm.set_charset("ascii")            # "ascii" | "blocks"
##   tm.set_enabled(true)               # false = Szene unveraendert durchreichen
##
## An/aus ohne Neuverdrahtung: `tm.set_enabled(false)` reicht die Szene 1:1
## durch (u_enabled = 0 im Shader); `true` schaltet das Raster wieder ein.
##
## Wichtig: Der TextMode-Viewport muss im Baum NACH der Szene (liest deren
## img-Textur) und VOR der CRT-Kette haengen, sonst ist die Szene einen Frame
## alt bzw. die Kette liest einen Frame zu spaet.

const SH := preload("res://shaders/text.gdshader")
## Bildbreite zur Laufzeit (View.W), Höhe fest.
static var RW: int:
	get: return View.W
const RH := Config.RENDER_H
const MIN_CELL := 4
const MAX_CELL := 32

# ascii: klassische Dichtestufen-Rampe (5x7, wie die Spiel-Pixelschrift)
const ASCII_ORDER := [" ", ".", ":", "-", "=", "+", "*", "#", "%", "@"]
const ASCII_GLYPHS := {
	" ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
	".": [".....", ".....", ".....", ".....", ".....", "..#..", "....."],
	":": [".....", ".....", ".....", "..#..", ".....", "..#..", "....."],
	"-": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
	"=": [".....", ".....", ".###.", ".....", ".###.", ".....", "....."],
	"+": [".....", ".....", "..#..", ".###.", "..#..", ".....", "....."],
	"*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
	"#": [".....", ".#.#.", ".#.#.", "#####", ".#.#.", ".#.#.", "....."],
	"%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
	"@": [".###.", "##.##", "#####", "#####", "#####", ".###.", "....."],
}
# blocks: Unicode-Blöcke, gut lesbar auch auf kleinen Zellen
const BLOCK_ORDER := [" ", "░", "▒", "▓", "█"]

var vp: SubViewport
var tex: Texture2D
var enabled := true
var cell_px := 8
var charset := "ascii"
var gain := 1.0
var gamma := 0.7

var _mat: ShaderMaterial
var _scene: Texture2D
var _pal := ""


## Baut den Text-Viewport unter parent und liefert dessen View.W x 360-Textur.
func setup(parent: Node, scene_tex: Texture2D) -> Texture2D:
	_scene = scene_tex
	vp = SubViewport.new()
	vp.name = "TextMode"
	vp.size = Vector2i(RW, RH)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	var cr := ColorRect.new()
	cr.position = Vector2.ZERO
	cr.size = Vector2(RW, RH)
	_mat = ShaderMaterial.new()
	_mat.shader = SH
	cr.material = _mat
	vp.add_child(cr)
	parent.add_child(vp)
	tex = vp.get_texture()
	_apply()
	return tex


## Zellkante in Pixeln (klein = feiner, gross = lesbarer). 8 = 80x45 Zellen.
func set_cell_size(px: int) -> void:
	cell_px = clampi(px, MIN_CELL, MAX_CELL)
	if _mat != null:
		_apply()


## "ascii" (Dichtestufen-Rampe) oder "blocks" (░▒▓█).
func set_charset(set_name: String) -> void:
	if set_name == "ascii" or set_name == "blocks":
		charset = set_name
	if _mat != null:
		_apply()


## true = Zeichenraster, false = Szene unveraendert durchreichen.
func set_enabled(on: bool) -> void:
	enabled = on
	if _mat != null:
		_mat.set_shader_parameter("u_enabled", 1 if enabled else 0)


## Helligkeitsverstaerkung / Gamma-Kurve fuer die Zeichendichte (Tuning).
func set_curve(gain_: float, gamma_: float) -> void:
	gain = gain_
	gamma = gamma_
	if _mat != null:
		_apply()


## Aktive Zonenpalette übernehmen (nur bei Wechsel).
func sync_palette() -> void:
	if _mat != null and _pal != Palette.active:
		_pal = Palette.active
		_mat.set_shader_parameter("PAL", Palette.v3())


func _apply() -> void:
	_pal = Palette.active
	_mat.set_shader_parameter("PAL", Palette.v3())
	_mat.set_shader_parameter("u_scene", _scene)
	_mat.set_shader_parameter("u_atlas", _build_atlas(cell_px, charset))
	_mat.set_shader_parameter("u_res", Vector2(RW, RH))
	_mat.set_shader_parameter("u_cell_px", float(cell_px))
	_mat.set_shader_parameter("u_n", _order().size())
	_mat.set_shader_parameter("u_gain", gain)
	_mat.set_shader_parameter("u_gamma", gamma)
	_mat.set_shader_parameter("u_enabled", 1 if enabled else 0)


func _order() -> Array:
	return ASCII_ORDER if charset == "ascii" else BLOCK_ORDER


## Zeichen-Atlas: eine waagerechte Kachelreihe, weiße Glyphen auf transparent.
func _build_atlas(cp: int, set_name: String) -> ImageTexture:
	var order := _order()
	var n := order.size()
	var img := Image.create(n * cp, cp, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var white := Color(1, 1, 1, 1)
	for k in n:
		var x0 := k * cp
		for y in cp:
			for x in cp:
				if _on(set_name, k, x, y, cp):
					img.set_pixel(x0 + x, y, white)
	return ImageTexture.create_from_image(img)


func _on(set_name: String, k: int, x: int, y: int, cp: int) -> bool:
	if set_name == "ascii":
		var rows: Array = ASCII_GLYPHS[ASCII_ORDER[k]]
		var ox := Py.ifloordiv(cp - 5, 2)
		var oy := Py.ifloordiv(cp - 7, 2)
		var gx := x - ox
		var gy := y - oy
		if gx < 0 or gx >= 5 or gy < 0 or gy >= 7:
			return false
		return String(rows[gy])[gx] == "#"
	match k:
		1:
			return (x % 2 == 0) and (y % 2 == 0)
		2:
			return (x + y) % 2 == 0
		3:
			return (x % 2 == 0) or (y % 2 == 0)
		4:
			return true
	return false
