class_name QImg
extends RefCounted
## Ersatz für QImage im Port: eine (premultiplizierte) Textur plus Ausschnitt.
##
## Alle Bilder des Spiels entstehen durch Backen (Baker) und sind daher
## premultipliziert - genau wie QImage.Format_ARGB32_Premultiplied im Original.

var tex: Texture2D
var region: Rect2        # Ausschnitt in Texturpixeln
var mirrored := false    # waagerecht gespiegelt (QImage.mirrored(True, False))


func _init(t: Texture2D = null, r: Rect2 = Rect2()) -> void:
	tex = t
	region = r if r.size != Vector2.ZERO or t == null else Rect2(Vector2.ZERO, t.get_size())


func width() -> int:
	return int(region.size.x)


func height() -> int:
	return int(region.size.y)


func is_valid() -> bool:
	return tex != null


## Waagerecht gespiegelte Sicht auf dasselbe Bild (kein Kopieren).
func mirror() -> QImg:
	var m := QImg.new(tex, region)
	m.mirrored = not mirrored
	return m


## Unterbereich (copy(x, y, w, h) im Original), ohne Kopieren.
func sub(x: float, y: float, w: float, h: float) -> QImg:
	var s := QImg.new(tex, Rect2(region.position + Vector2(x, y), Vector2(w, h)))
	s.mirrored = mirrored
	return s
