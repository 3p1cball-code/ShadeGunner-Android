extends SceneTree
func _init() -> void:
	var n := 0
	for f in ["res://src/config.gd", "res://src/data/d_sim.gd", "res://src/data/d_detection.gd", "res://src/data/d_procgen.gd",
			"res://src/data/d_hud.gd", "res://src/data/d_audio.gd", "res://src/data/d_i18n.gd", "res://src/data/d_save.gd",
			"res://src/data/d_settings.gd", "res://src/data/d_scene.gd", "res://src/data/d_city.gd", "res://src/data/d_vehicles.gd",
			"res://src/data/d_holo.gd", "res://src/data/d_sprites.gd", "res://src/data/d_pixfont.gd", "res://src/data/d_shaders.gd"]:
		var s = load(f)
		if s == null:
			print("FEHLER ", f)
		else:
			n += 1
	print("geladen: ", n)
	quit()
