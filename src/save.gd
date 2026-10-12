class_name Save
extends RefCounted
## Persistenter Spielstand (save.py): Bestwert, Rang, Zahl der Einsätze (global).
## Gleiches JSON-Format wie das Original, nur unter user://save.json.

const RANKS := DSave.RANKS


static func _path() -> String:
	return "user://save.json"


## JSON-Zahlen kommen in Godot als float an; ganze Zahlen zurück nach int (wie json.load).
static func _ints(v: Variant) -> Variant:
	if v is float and is_finite(v) and floorf(v) == v and absf(v) < 9.0e15:
		return int(v)
	if v is Dictionary:
		var d: Dictionary = {}
		for k: Variant in v:
			d[k] = _ints(v[k])
		return d
	if v is Array:
		var a: Array = []
		for e: Variant in v:
			a.append(_ints(e))
		return a
	return v


## Als JSON lesen (wie json.load). Datei fehlt/kaputt -> null.
static func _read_json(path: String, ints: bool = true) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var txt := FileAccess.get_file_as_string(path)
	var j := JSON.new()
	if j.parse(txt) != OK:
		return null
	return _ints(j.data) if ints else j.data


## Atomar schreiben (tmp + umbenennen), Fehler werden geschluckt wie im Original.
static func _write_json(path: String, d: Dictionary) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(d, " ", false))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))


static func load_() -> Dictionary:
	var d: Variant = _read_json(_path())
	return d if d is Dictionary else {}


## Ergebnis eintragen. Gibt [daten, neuer_bestwert] zurück.
static func record(score: int, rank: String, won: bool) -> Array:
	var d := load_()
	d["runs"] = int(d.get("runs", 0)) + 1
	d["wins"] = int(d.get("wins", 0)) + (1 if won else 0)
	var new_best := score > int(d.get("best", 0))
	if new_best:
		d["best"] = int(score)
	if RANKS.find(rank) > RANKS.find(String(d.get("rank", "D"))) or not d.has("rank"):
		d["rank"] = rank
	_write_json(_path(), d)
	return [d, new_best]
