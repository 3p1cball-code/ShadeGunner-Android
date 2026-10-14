extends SceneTree
## Lädt alle Skripte unter src/ (Parse-/Typfehler sichtbar machen).
##   godot --headless --path . --script res://tests/compile_all.gd
func _walk(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_walk(dir.path_join(sub), out)


func _init() -> void:
	var files := []
	_walk("res://src", files)
	var bad := 0
	for f: String in files:
		var s: GDScript = load(f)
		if s == null or not s.can_instantiate():
			print("FEHLER ", f)
			bad += 1
	print("compile_all: %d Dateien, %d Fehler" % [files.size(), bad])
	quit(bad)
