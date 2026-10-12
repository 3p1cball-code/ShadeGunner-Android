extends SceneTree
## CPU-Zeit für Cache-Fehlschläge (Backen) und Treffer: godot --headless -s res://tests/bake_timing.gd


func _initialize() -> void:
	var baker := Baker.new()
	root.add_child(baker)
	Sprites.baker = baker
	Vehicles.baker = baker
	Pixfont.baker = baker
	var look: Dictionary = DSprites.PLAYER_LOOK.duplicate(true)
	var t0 := Time.get_ticks_usec()
	for i in 40:
		Sprites.get_(look, "walk", i % 8, 30.0 + i, 1)
	var t1 := Time.get_ticks_usec()
	for i in 40:
		Sprites.get_(look, "walk", i % 8, 30.0 + i, 1)
	var t2 := Time.get_ticks_usec()
	var kinds := ["car", "taxi", "truck", "limo", "bike", "bus", "police"]
	for i in 28:
		Vehicles.vehicle_image(kinds[i % 7], i, 0.75 + 0.25 * (i % 4), [150, 160, 190], 1)
	var t3 := Time.get_ticks_usec()
	print("Figur backen: %.2f ms/Bild, Treffer: %.4f ms" % [(t1 - t0) / 40000.0, (t2 - t1) / 40000.0])
	print("Fahrzeug backen: %.2f ms/Bild" % [(t3 - t2) / 28000.0])
	quit()
