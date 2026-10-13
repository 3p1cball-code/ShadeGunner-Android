extends SceneTree
## Headless-Prüfung ohne Rendern: Touch-Eingaben lösen die richtigen
## InputMap-Aktionen aus (move_left/right, depth_far/near, up/down, aim, scan,
## jump, shout, cancel, pause, confirm).
##
##   godot --headless --path . --script res://tests/touch_actions.gd

var fails := 0


func _chk(name: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL ", name)


func _initialize() -> void:
	var tc := TouchControls.new()
	tc.setup(root, {"touch": "an"})
	tc.set_enabled("an")

	# Stick
	_stick(tc, Vector2(400.0, 0.0), ["move_right"])
	_stick(tc, Vector2(-400.0, 0.0), ["move_left"])
	_stick(tc, Vector2(0.0, 400.0), ["depth_near", "down"])
	_stick(tc, Vector2(0.0, -400.0), ["depth_far", "up"])
	tc.debug_touch(tc.stick_center(), true)
	_chk("stick neutral", not Input.is_action_pressed("move_right") and not Input.is_action_pressed("depth_far"))
	tc.debug_touch(tc.stick_center(), false)

	# Buttons
	for c: Array in [["aim", "aim"], ["aim", "confirm"], ["scan", "scan"], ["jump", "jump"],
			["shout", "shout"], ["cancel", "cancel"], ["pause", "pause"]]:
		var id := String(c[0])
		var act := String(c[1])
		tc.debug_touch(tc.button_center(id), true)
		_chk("button %s -> %s" % [id, act], Input.is_action_pressed(act))
		tc.debug_touch(tc.button_center(id), false)
		_chk("release %s -> %s" % [id, act], not Input.is_action_pressed(act))

	# "aus" deaktiviert und löst alles
	tc.debug_touch(tc.button_center("scan"), true)
	tc.set_enabled("aus")
	_chk("aus: scan gelöst", not Input.is_action_pressed("scan"))
	_chk("aus: inaktiv", not tc.is_active())

	print("touch_actions: ", "OK" if fails == 0 else "%d FEHLER" % fails)
	quit(0 if fails == 0 else 1)


func _stick(tc: TouchControls, off: Vector2, acts: Array) -> void:
	tc.debug_touch(tc.stick_center(), true)
	tc.debug_drag(tc.stick_center() + off)
	for a: String in acts:
		_chk("stick %s -> %s" % [off, a], Input.is_action_pressed(a))
	tc.debug_touch(tc.stick_center() + off, false)
