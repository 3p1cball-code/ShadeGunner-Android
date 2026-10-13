class_name Settings
extends RefCounted
## Spiel-Einstellungen (settings.py), persistiert als JSON unter user://settings.json.
## renderer: "auto" (OpenGL, sonst Software) | "software" (immer CPU)

const DEFAULTS := DSettings.DEFAULTS
## Nur im Port vorhandene Einstellungen (nicht in DEFAULTS, Vorgaben liefert game.gd per
## get(..., default)). Ohne diese Liste verwarf load_() sie - z. B. "aspect" galt nie
## über einen Neustart hinaus.
const PORT_KEYS := ["aspect", "quality", "reflections", "rain", "fog", "fx", "render_mode", "touch"]


static func _path() -> String:
	return "user://settings.json"


static func load_() -> Dictionary:
	var d: Dictionary = DEFAULTS.duplicate(true)
	var data: Variant = Save._read_json(_path(), false)
	if data is Dictionary:
		for k: Variant in data:
			if DEFAULTS.has(k) or k in PORT_KEYS:
				d[k] = data[k]
	var r: Variant = d.get("resolution")
	if r is Array:
		r = Save._ints(r)      # JSON-Zahlen sind float; ganze Werte gelten als int
		d["resolution"] = r
	var ok := r is Array and (r as Array).size() == 2
	if ok:
		for v: Variant in r:
			if not (v is int):
				ok = false
	if not ok:
		d["resolution"] = (DEFAULTS["resolution"] as Array).duplicate()
	if not (d.get("difficulty") in ["leicht", "normal", "schwer"]):
		d["difficulty"] = "normal"
	if not (d.get("lang") in ["de", "en"]):
		d["lang"] = "de"
	return d


static func save_(d: Dictionary) -> void:
	Save._write_json(_path(), d)
