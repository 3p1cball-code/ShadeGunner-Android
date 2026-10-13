extends Node
## Sichtbarkeits- und Aktionstest der Touchsteuerung.
##
##   godot --path . --rendering-driver opengl3 --audio-driver Dummy res://tests/touch_test.tscn
##   godot ... res://tests/touch_test.tscn -- --out=user://shots/touch.png
##
## Prüft, dass Stick/Buttons die richtigen InputMap-Aktionen drücken, und legt nach
## einigen Frames einen Screenshot der Bedienelemente ab.

var tc: TouchControls
var baker: Baker
var frames := 0
var bad := 0
var out := "res://shots/touch.png"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())

	# Stehplatz für die CRT-Kette: eine deckende Ebene auf Layer 100. Die
	# Touchsteuerung (Layer 110) muss darüber liegen - der Text verschwindet
	# teils hinter den Buttons.
	var crt := CanvasLayer.new()
	crt.layer = 100
	add_child(crt)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.04, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	crt.add_child(bg)
	var lbl := Label.new()
	lbl.text = "CRT / LAYER 100"
	lbl.position = Vector2(880.0, 600.0)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.25, 0.35))
	crt.add_child(lbl)

	baker = Baker.new()
	add_child(baker)
	Pixfont.baker = baker

	TouchControls.ensure_actions()
	tc = TouchControls.new()
	tc.setup(self, {"touch": "an"})
	tc.set_enabled("an")
	_checks()


func _checks() -> void:
	# Stick: rechts -> move_right, unten -> depth_near + down
	_stick(tc.stick_center() + Vector2(400.0, 0.0), ["move_right"])
	_stick(tc.stick_center() + Vector2(0.0, 400.0), ["depth_near", "down"])
	_stick(tc.stick_center() + Vector2(-400.0, -400.0), ["move_left", "depth_far", "up"])
	# Stickmitte: kein Druck
	tc.debug_touch(tc.stick_center(), true)
	_check("stick neutral", not Input.is_action_pressed("move_right") and not Input.is_action_pressed("move_left"))
	tc.debug_touch(tc.stick_center(), false)
	# Buttons (ZIELEN gibt zugleich confirm frei)
	var cases: Array = [
		["aim", "aim"], ["aim", "confirm"], ["scan", "scan"], ["jump", "jump"],
		["shout", "shout"], ["cancel", "cancel"], ["pause", "pause"],
	]
	for c: Array in cases:
		var id := String(c[0])
		var act := String(c[1])
		tc.debug_touch(tc.button_center(id), true)
		_check("button %s -> %s" % [id, act], Input.is_action_pressed(act))
		tc.debug_touch(tc.button_center(id), false)
		_check("release %s -> %s" % [id, act], not Input.is_action_pressed(act))
	# Sichtbarkeit: "aus" blendet aus und löst alles
	tc.set_enabled("aus")
	_check("aus unsichtbar", not tc.is_active())
	tc.set_enabled("an")
	print("touch_test Aktionen: ", "OK" if bad == 0 else "%d FEHLER" % bad)


func _stick(pos: Vector2, acts: Array) -> void:
	tc.debug_touch(tc.stick_center(), true)
	tc.debug_drag(pos)
	for a: String in acts:
		_check("stick -> %s" % a, Input.is_action_pressed(a))
	tc.debug_touch(pos, false)


func _check(name: String, ok: bool) -> void:
	if not ok:
		bad += 1
		print("FAIL ", name)


func _process(_dt: float) -> void:
	frames += 1
	if frames < 14:
		RenderingServer.force_draw()
		return
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("touch_test shot: ", out)
	get_tree().quit(0 if bad == 0 else 1)
