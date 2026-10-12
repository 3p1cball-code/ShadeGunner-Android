extends SceneTree
## Lädt die HUD-Port-Skripte (mit override.cfg: Warnungen = Fehler).
func _init() -> void:
	var bad := 0
	for f in ["res://src/render/pixfont.gd", "res://src/render/fx.gd", "res://src/hud.gd", "res://src/save.gd", "res://src/settings.gd", "res://src/assets.gd", "res://tests/hud_test.gd", "res://tests/test_save.gd"]:
		var s: GDScript = load(f)
		if s == null or not s.can_instantiate():
			print("FEHLER ", f)
			bad += 1
	print("compile_check: ", bad)
	quit(bad)
