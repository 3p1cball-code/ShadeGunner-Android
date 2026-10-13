class_name Persp
## Perspektive der Belt-Ebene (Welt -> Bild), identisch zu shadegunner/persp.py.
##
## Tiefe d: 0 = hintere Bordsteinkante, 1 = vorne. Skala und Bild-y sind beide
## linear in d - exakt eine Zentralperspektive mit Horizont bei horizon_px().

## Bildbreite zur Laufzeit (View.W, 640 ohne View.setup); Höhe fest.
static var W: int:
	get: return View.W
const H := Config.RENDER_H
const _Y0 := Config.FLOOR_TOP_Y * Config.RENDER_H
const _Y1 := Config.FLOOR_BOTTOM_Y * Config.RENDER_H
# Maßstab: bleibt auf der Basisbreite 640 - eine breitere Ansicht zeigt mehr Straße,
# die Figuren werden nicht größer.
const PPU_NEAR := float(Config.RENDER_W) / Config.VIEW_SPAN_NEAR
const FACADE_Y := _Y0 + (_Y1 - _Y0) * Config.FACADE_DEPTH
const FACADE_PPU := PPU_NEAR * (Config.SCALE_FAR + (1.0 - Config.SCALE_FAR) * Config.FACADE_DEPTH)

static func scale(d: float) -> float:
	return Config.SCALE_FAR + (1.0 - Config.SCALE_FAR) * d


static func ground_y(d: float) -> float:
	var y0 := Config.FLOOR_TOP_Y * Config.RENDER_H
	var y1 := Config.FLOOR_BOTTOM_Y * Config.RENDER_H
	return y0 + (y1 - y0) * d


static func depth_at_y(y: float) -> float:
	var y0 := Config.FLOOR_TOP_Y * Config.RENDER_H
	var y1 := Config.FLOOR_BOTTOM_Y * Config.RENDER_H
	return (y - y0) / (y1 - y0)


static func ppu(d: float) -> float:
	## Bildschirm-Pixel pro Welt-Einheit in Tiefe d (Maßstab: Basisbreite, nicht View.W).
	return (Config.RENDER_W / Config.VIEW_SPAN_NEAR) * scale(d)


static func screen_x(x: float, d: float, cam_x: float) -> float:
	return View.W * 0.5 + (x - cam_x) * ppu(d)


static func world_x(sx: float, d: float, cam_x: float) -> float:
	return cam_x + (sx - View.W * 0.5) / ppu(d)


static func figure_h(d: float) -> float:
	return Config.FIGURE_H_NEAR * Config.RENDER_H * scale(d)


static func horizon_px() -> float:
	var y0 := Config.FLOOR_TOP_Y * Config.RENDER_H
	var y1 := Config.FLOOR_BOTTOM_Y * Config.RENDER_H
	var k := (y1 - y0) / (1.0 - Config.SCALE_FAR)
	return y0 - Config.SCALE_FAR * k
