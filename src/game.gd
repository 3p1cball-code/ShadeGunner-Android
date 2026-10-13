class_name Game
extends Node
## Das Spiel - 1:1 nach game.py (_GameMixin): Zustaende, Eingabe, HUD, Ton.
##
##   Baker -> Szene (640x360 + Glow-Kette) -> HUD (1280x720) -> CRT-Kette -> Bildschirm
##
## Zustaende: title -> intro -> play <-> pause -> clear (Upgrade) -> intro ... -> victory | over
## Eingabe: Tastatur wie im Original, dazu Gamepad (Retroid Pocket) und Touch.

const RW := Config.RENDER_W
const RH := Config.RENDER_H

var baker: Baker
var scene: Scene
var hud: HUD
var audio: Audio
var chain: CRTChain
var touch: TouchControls
var textmode: TextMode
var base_scene_tex: Texture2D
var text_scene_tex: Texture2D

var world: World
var best: Dictionary = {"score": 0, "rank": "D", "runs": 0}
var settings: Dictionary = {}
var options: Array = []
var sel := 0
var end_info: Dictionary = {}
var settings_sel := 0
var _settings_back := "title"

var mode := "title"
var mode_t := 0.0
var power := 0.0
var fade := 0.0
var help := false
var _trans: Variant = null          # [phase, callback]
var _dt := 1.0 / 60.0
var title_cam := 0.0

var mouse_scene: Variant = null
var mouse_t := 99.0
var mouse_aim := false
var mouse_mid := false
var _mouse_moved := false

# Debug/Test
var _shot_path := ""
var _shot_frames := 60
var _shot_at_mode := ""
var _frame := 0
var _tickn := 0
var _autoplay := false
var _set_over := ""
var _flick := false
var _flick_imgs: Array = []
var _flick_boxes: Array = []
var _flick_bakes: Array = []
var _devtest := false
var _show_fps := false
var _nocr := false
var _prof_scene := 0.0
var _prof_hud := 0.0


func _ready() -> void:
	_parse_args()
	_setup_input()
	best = Save.load_()
	settings = Settings.load_()
	if _set_over != "":
		for kv in _set_over.split(","):
			var pr := kv.split(":")
			if pr.size() == 2:
				settings[pr[0]] = (pr[1] == "true") if pr[1] in ["true", "false"] else pr[1]
	I18n.set_lang(str(settings.get("lang", "de")))

	# Alle Back-Ziele (Sprite-/Fahrzeug-Atlanten, Stadt-Ebenen, Reflexionen, Holos,
	# Schrift) haengen in einem eigenen Viewport, der als ERSTER angelegt wird. Godot
	# rendert verschachtelte Viewports vor ihrem Eltern-Viewport - so ist ein im selben
	# Frame gebackenes Bild fertig, bevor die Szene es zeichnet. Ohne das blieb ein neu
	# gebackenes Sprite genau einen Frame lang leer (Flackern von Figuren/Autos).
	var bake_host := SubViewport.new()
	bake_host.name = "BakeHost"
	bake_host.size = Vector2i(2, 2)
	bake_host.disable_3d = true
	bake_host.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(bake_host)
	baker = Baker.new()
	bake_host.add_child(baker)
	City.baker = baker
	Sprites.baker = baker
	Vehicles.baker = baker
	Pixfont.baker = baker
	Holo.baker = baker

	scene = Scene.new()
	var stex: Texture2D = scene.setup(self, baker)

	var stex_base: Texture2D = stex
	base_scene_tex = stex_base
	textmode = TextMode.new()
	text_scene_tex = textmode.setup(self, stex_base)
	textmode.set_cell_size(8)
	textmode.set_charset("ascii")
	textmode.set_enabled(false)

	hud = HUD.new()
	var htex: Texture2D = hud.setup(self)

	if _nocr:
		var cr := TextureRect.new()
		cr.texture = stex
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		cr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		add_child(cr)
	else:
		chain = CRTChain.new()
		chain.scene_tex = stex
		chain.hud_tex = htex
		chain.scan_on = bool(settings.get("scanlines", true))
		add_child(chain)

	touch = TouchControls.new()
	touch.setup(self, settings)

	audio = Audio.new()
	add_child(audio)
	audio.set_volumes(settings.get("music", 0.7), settings.get("sfx", 1.0))

	_title_world()
	_apply_display()
	_apply_settings()
	if _autoplay or _shot_path != "":
		_start_run()
		_set_mode("play" if _autoplay else _shot_at_mode if _shot_at_mode != "" else "play")


func _setup_input() -> void:
	# k = Taste (logischer UND physischer Code - Android meldet D-Pad/Tasten oft nur
	# logisch), j = Gamepad-Taste, a = Gamepad-Achse
	var defs := {
		"move_left": [["k", KEY_A], ["k", KEY_LEFT], ["j", JOY_BUTTON_DPAD_LEFT], ["a", JOY_AXIS_LEFT_X, -1.0]],
		"move_right": [["k", KEY_D], ["k", KEY_RIGHT], ["j", JOY_BUTTON_DPAD_RIGHT], ["a", JOY_AXIS_LEFT_X, 1.0]],
		"depth_far": [["k", KEY_W], ["k", KEY_UP], ["j", JOY_BUTTON_DPAD_UP], ["a", JOY_AXIS_LEFT_Y, -1.0]],
		"depth_near": [["k", KEY_S], ["k", KEY_DOWN], ["j", JOY_BUTTON_DPAD_DOWN], ["a", JOY_AXIS_LEFT_Y, 1.0]],
		"up": [["k", KEY_W], ["k", KEY_UP], ["j", JOY_BUTTON_DPAD_UP], ["a", JOY_AXIS_LEFT_Y, -1.0]],
		"down": [["k", KEY_S], ["k", KEY_DOWN], ["j", JOY_BUTTON_DPAD_DOWN], ["a", JOY_AXIS_LEFT_Y, 1.0]],
		"sprint": [["k", KEY_SHIFT], ["a", JOY_AXIS_TRIGGER_LEFT, 1.0]],
		"aim": [["k", KEY_E], ["k", KEY_CTRL], ["a", JOY_AXIS_TRIGGER_RIGHT, 1.0]],
		"scan": [["k", KEY_R], ["j", JOY_BUTTON_X]],
		"jump": [["k", KEY_SPACE], ["j", JOY_BUTTON_A]],
		"cancel": [["k", KEY_C], ["k", KEY_BACKSPACE], ["j", JOY_BUTTON_B]],
		"shout": [["k", KEY_V], ["j", JOY_BUTTON_Y]],
		"confirm": [["k", KEY_ENTER], ["k", KEY_KP_ENTER], ["j", JOY_BUTTON_A]],
		"pause": [["k", KEY_P], ["k", KEY_ESCAPE], ["j", JOY_BUTTON_START]],
		"help": [["k", KEY_H], ["k", KEY_F1], ["j", JOY_BUTTON_BACK]],
		"cycle_next": [["k", KEY_TAB], ["k", KEY_Q], ["j", JOY_BUTTON_RIGHT_SHOULDER]],
		"cycle_prev": [["j", JOY_BUTTON_LEFT_SHOULDER]],
		"mute": [["k", KEY_M]],
		"fullscreen": [["k", KEY_F]],
		# Menue-Aktionen (Touch-Buttons, teils Tastatur)
		"open_settings": [["k", KEY_O]],
		"to_title": [["k", KEY_Q]],
		"restart": [["k", KEY_R]],
	}
	for name: String in defs:
		if InputMap.has_action(name):
			InputMap.erase_action(name)
		InputMap.add_action(name, 0.45)
		for ev: Array in defs[name]:
			match String(ev[0]):
				"k":
					var k1 := InputEventKey.new()
					k1.keycode = ev[1]
					InputMap.action_add_event(name, k1)
					var k2 := InputEventKey.new()
					k2.physical_keycode = ev[1]
					InputMap.action_add_event(name, k2)
				"j":
					var jb := InputEventJoypadButton.new()
					jb.button_index = ev[1]
					InputMap.action_add_event(name, jb)
				"a":
					var jm := InputEventJoypadMotion.new()
					jm.axis = ev[1]
					jm.axis_value = ev[2]
					InputMap.action_add_event(name, jm)


## Ereignis trifft eine der Aktionen (Tastatur-Wiederholung nur fuer Navigation).
func _hit(e: InputEvent, names: Array, echo := false) -> bool:
	for n: String in names:
		if InputMap.has_action(n) and e.is_action_pressed(n, echo):
			return true
	return false


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			_shot_frames = int(a.substr(9))
		elif a.begins_with("--shot-mode="):
			_shot_at_mode = a.substr(12)
		elif a.begins_with("--win="):
			var wh := a.substr(6).split("x")
			if wh.size() == 2:
				DisplayServer.window_set_size(Vector2i(int(wh[0]), int(wh[1])))
		elif a == "--auto":
			_autoplay = true
		elif a == "--flickertest":
			_flick = true
		elif a.begins_with("--set="):
			_set_over = a.substr(6)
		elif a == "--nocr":
			_nocr = true
		elif a == "--fps":
			_show_fps = true
		elif a == "--devtest":
			_devtest = true
			_shot_frames = 400


# ---------------------------------------------------------------- Zustaende
func _title_world() -> void:
	world = World.new(null, randi() & 0xFFFF, 2)
	scene.ensure_zone(2, world.seed, world.length)
	title_cam = world.length * 0.2
	_set_mode("title")


func _start_run() -> void:
	var seed := randi() & 0xFFFF
	world = World.new(Run.new(seed, str(settings.get("difficulty", "normal"))), seed, 0)
	scene.ensure_zone(0, seed, world.length)
	_set_mode("intro")


func _set_mode(m: String) -> void:
	mode = m
	mode_t = 0.0


func _transition(cb: Callable) -> void:
	if _trans == null:
		_trans = ["out", cb]


func _choose(i: int) -> void:
	if i < 0 or i >= options.size():
		return
	world.run.apply(str(options[i][0]))
	audio.play("ui")
	options = []
	_transition(func() -> void:
		var nw: World = world.next_world()
		world = nw
		scene.ensure_zone(nw.zone_index, nw.seed, nw.length)
		_set_mode("intro"))


func _finish(won: bool) -> void:
	var run: Run = world.run
	var civs := int(run.totals.get("civs", 0))
	var rank := HUD.rank_of(run.score, civs, won)
	var res: Array = Save.record(maxi(0, run.score), rank, won)
	best = res[0]
	end_info = {"rank": rank, "new_best": res[1]}
	_set_mode("victory" if won else "over")


func _after_states() -> void:
	if mode == "cleared" and mode_t > 1.4:
		if world.zone_index + 1 >= DSim.ZONES.size():
			_finish(true)
		else:
			options = world.run.offer(PyRandom.new(world.seed + world.zone_index))
			sel = 0
			_set_mode("clear")
	elif mode == "failing" and mode_t > 2.2:
		_finish(false)


# ---------------------------------------------------------------- Loop
func _process(delta: float) -> void:
	var dt := minf(0.05, delta)
	_tickn += 1
	_dt = dt
	mode_t += dt
	power = minf(1.0, power + dt * 1.4)
	audio.poll()
	if not audio.muted and not audio._started_loops and audio._ready_():
		audio.loops(true)

	if _trans != null:
		var phase: String = _trans[0]
		if phase == "out":
			fade = minf(1.0, fade + dt * 3.0)
			if fade >= 1.0:
				(_trans[1] as Callable).call()
				_trans = ["in", null]
		else:
			fade = maxf(0.0, fade - dt * 2.5)
			if fade <= 0.0:
				_trans = null

	if _devtest:
		_devtest_tick()
	_after_states()
	var paused := help or mode in ["pause", "settings"]
	if not paused:
		match mode:
			"title":
				title_cam += 16.0 * dt
				if title_cam > world.length - 200.0:
					title_cam = 200.0
				world.update(dt, {})
			"intro":
				world.update(dt, {})
				if mode_t > 4.5:
					_set_mode("play")
			"play":
				_play_tick(dt)
			_:
				world.update(dt, {})

	var events: Array = world.events.duplicate()
	world.events.clear()
	scene.consume(world, events)
	audio.handle_events(events, world)
	if not scene.sfx.is_empty():
		audio.handle_events(scene.sfx.duplicate(), world)
		scene.sfx.clear()
	audio.update(dt, world, mode)

	var cam: Variant = title_cam if mode == "title" else null
	var _t0 := Time.get_ticks_usec()
	scene.frame(world, dt if not paused else 0.0, mode != "title", fade, power, cam)
	var _t1 := Time.get_ticks_usec()
	hud.render(world, scene, dt, _hud_ui())
	var _t2 := Time.get_ticks_usec()
	_prof_scene = float(_t1 - _t0) / 1000.0
	_prof_hud = float(_t2 - _t1) / 1000.0
	_edges.clear()
	_mouse_moved = false

	if _flick:
		_flicker_probe()
	if _show_fps and _tickn % 30 == 0:
		print("fps=", Engine.get_frames_per_second(), "  szene=", "%.1f" % _prof_scene, "ms  figuren ok/null=", Scene.dbg_ok, "/", Scene.dbg_null, "  autos ok/null=", Scene.dbg_ok_v, "/", Scene.dbg_null_v)
	if _shot_path != "":
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		if _tickn >= _shot_frames:
			get_viewport().get_texture().get_image().save_png(_shot_path)
			print("shot: ", _shot_path)
			get_tree().quit()


var _edges := {}


## Flacker-Detektor: Folgebilder der Szene aufnehmen und Figuren-/Fahrzeugkaesten
## suchen, die genau einen Frame lang anders sind als davor UND danach.
func _flicker_probe() -> void:
	if _tickn < 40:
		return
	if _tickn <= 220:
		var im := base_scene_tex.get_image()
		im.convert(Image.FORMAT_RGB8)
		_flick_imgs.append(im)
		var boxes := []
		for uid in scene.screen:
			var sc: Array = scene.screen[uid]
			var cx: float = sc[0]
			var gy: float = sc[1]
			var hg: float = sc[2]
			if cx > 10 and cx < 630 and hg > 20:
				boxes.append(Rect2i(int(cx - hg * 0.25), int(gy - hg), int(hg * 0.5), int(hg)).intersection(Rect2i(0, 0, 640, 360)))
		_flick_boxes.append(boxes)
		_flick_bakes.append(Sprites.bake_n)
		Sprites.bake_n = 0
		return
	var ev := 0
	var tot := 0
	for t in range(1, _flick_imgs.size() - 1):
		var a: Image = _flick_imgs[t - 1]
		var b: Image = _flick_imgs[t]
		var c: Image = _flick_imgs[t + 1]
		for r: Rect2i in _flick_boxes[t]:
			if r.size.x < 4 or r.size.y < 8:
				continue
			tot += 1
			var dab := 0.0
			var dbc := 0.0
			var dac := 0.0
			var n := 0
			for y in range(r.position.y, r.end.y, 2):
				for x in range(r.position.x, r.end.x, 2):
					var pa := a.get_pixel(x, y)
					var pb := b.get_pixel(x, y)
					var pc := c.get_pixel(x, y)
					dab += absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b)
					dbc += absf(pb.r - pc.r) + absf(pb.g - pc.g) + absf(pb.b - pc.b)
					dac += absf(pa.r - pc.r) + absf(pa.g - pc.g) + absf(pa.b - pc.b)
					n += 1
			if n > 0 and minf(dab, dbc) / n > 0.08 and dac / n < 0.5 * minf(dab, dbc) / n:
				ev += 1
				if ev == 1:
					for q in 3:
						var src: Image = [a, b, c][q]
						var cr := src.get_region(r.grow(6).intersection(Rect2i(0, 0, 640, 360)))
						cr.resize(cr.get_width() * 6, cr.get_height() * 6, Image.INTERPOLATE_NEAREST)
						cr.save_png("res://shots/flick_%d.png" % q)
				if ev <= 8:
					print("    Bakes in t-1/t/t+1: %s/%s/%s" % [_flick_bakes[t - 1], _flick_bakes[t], _flick_bakes[t + 1]])
				if ev <= 5:
					print("  Flacker-Ereignis Frame %d Kasten %s: d(t-1,t)=%.3f d(t,t+1)=%.3f d(t-1,t+1)=%.3f" % [t, str(r), dab / n, dbc / n, dac / n])
	print("FLICKERTEST: %d Ereignisse in %d Kasten-Frames" % [ev, tot])
	get_tree().quit()


## Selbsttest: alle Menuepfade und Aktionen einmal durchspielen (nur mit --devtest).
func _devtest_tick() -> void:
	var f := _tickn
	if f == 5:
		_open_settings("title")
	elif f >= 8 and f < 8 + _setting_keys().size() * 2:
		settings_sel = (f - 8) / 2
		_settings_adjust(1 if (f % 2 == 0) else -1)
	elif f == 40:
		_set_mode("title")
		help = true
	elif f == 45:
		help = false
	elif f == 50:
		_transition(_start_run)
	elif f == 90:
		_set_mode("pause")
	elif f == 95:
		_set_mode("play")
	elif f == 120:
		_edges["scan"] = true
		if world.target == null and not world.living().is_empty():
			world.set_target(world.living()[0])
	elif f == 130:
		mouse_aim = true
	elif f == 140:
		mouse_aim = false
	elif f == 160:
		_edges["jump"] = true
	elif f == 170:
		_edges["cycle"] = 1
	elif f == 180:
		options = world.run.offer(PyRandom.new(world.seed + world.zone_index))
		sel = 0
		_set_mode("clear")
	elif f == 200:
		_choose(0)
	elif f == 260:
		_finish(true)
	elif f == 280:
		_set_mode("over")
	elif f == 300:
		_transition(_title_world)


# ---------------------------------------------------------------- Spiel
func _play_tick(dt: float) -> void:
	var mx := (1 if Input.is_action_pressed("move_right") else 0) - (1 if Input.is_action_pressed("move_left") else 0)
	var md := (1 if Input.is_action_pressed("depth_near") else 0) - (1 if Input.is_action_pressed("depth_far") else 0)
	mouse_t += dt
	if _mouse_moved and not world.aiming and world.scan_t < 0.0:
		var a := _pick(mouse_scene)
		if a != null:
			world.set_target(a)
	var inp := {
		"move": [mx, md], "sprint": Input.is_action_pressed("sprint"),
		"aim": Input.is_action_pressed("aim") or mouse_aim,
		"scan": _edges.get("scan", false), "cycle": _edges.get("cycle", 0),
		"jump": _edges.get("jump", false), "cancel": _edges.get("cancel", false),
		"shout": Input.is_action_pressed("shout") or mouse_mid,
	}
	world.update(dt, inp)
	if world.state == "zone_clear" and mode_t > 0.0:
		_set_mode("cleared")
	elif world.state == "failed":
		_set_mode("failing")


func _scene_pos(pos: Vector2) -> Variant:
	return chain.scene_pos(pos)


func _pick(sp: Variant) -> Actor:
	if sp == null:
		return null
	var mx: float = sp.x
	var my: float = sp.y
	var best_a: Actor = null
	var bd := -1.0
	var near: Actor = null
	var nd := 14.0
	for a in world.living():
		if not scene.screen.has(a.uid):
			continue
		var sc: Array = scene.screen[a.uid]
		var cx: float = sc[0]
		var gy: float = sc[1]
		var hgt: float = sc[2]
		if absf(mx - cx) <= maxf(4.0, hgt * 0.24) and gy - hgt * 1.05 <= my and my <= gy + 2.0:
			if a.depth > bd:
				best_a = a
				bd = a.depth
		else:
			var d := sqrt((mx - cx) * (mx - cx) + (my - (gy - hgt * 0.55)) * (my - (gy - hgt * 0.55)))
			if d < nd:
				near = a
				nd = d
	return best_a if best_a != null else near


func _hud_ui() -> Dictionary:
	var hud_mode := "play" if mode in ["cleared", "failing"] else mode
	return {
		"mode": hud_mode, "help": help, "t": mode_t, "best": best, "options": options, "sel": sel,
		"mouse": mouse_scene if mouse_t < 2.5 else null, "settings": settings, "settings_sel": settings_sel,
		"rank": end_info.get("rank", ""), "new_best": end_info.get("new_best", false),
	}


# ---------------------------------------------------------------- Eingabe
func _input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and touch != null and touch.is_over_controls((e as InputEventMouseButton).position):
		return
	if e is InputEventMouseMotion:
		var sp: Variant = _scene_pos((e as InputEventMouseMotion).position)
		if sp != mouse_scene:
			mouse_scene = sp
			mouse_t = 0.0
			_mouse_moved = true
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_mouse_press(mb.position, mb.button_index)
		else:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				mouse_aim = false
			elif mb.button_index == MOUSE_BUTTON_MIDDLE:
				mouse_mid = false
	elif e is InputEventScreenTouch:
		var st := e as InputEventScreenTouch
		if touch != null and touch.is_over_controls(st.position):
			pass
		elif st.pressed:
			_mouse_press(st.position, MOUSE_BUTTON_LEFT)
	elif e.is_pressed():
		_on_action(e)



func _mouse_press(pos: Vector2, button: int) -> void:
	if mode == "play":
		mouse_scene = _scene_pos(pos)
		mouse_t = 0.0
		var a := _pick(mouse_scene)
		if a != null and not world.aiming:
			world.set_target(a)
		if button == MOUSE_BUTTON_LEFT:
			mouse_aim = true
		elif button == MOUSE_BUTTON_RIGHT:
			if world.aiming or mouse_aim or Input.is_action_pressed("aim"):
				_edges["cancel"] = true
			else:
				_edges["scan"] = true
		elif button == MOUSE_BUTTON_MIDDLE:
			mouse_mid = true
	elif mode == "title" and button == MOUSE_BUTTON_LEFT:
		audio.play("ui")
		_transition(_start_run)
	elif mode == "intro" and mode_t > 0.6:
		_set_mode("play")
	elif mode == "clear" and not options.is_empty():
		_choose(sel)


## Diskrete Aktionen als Ereignisse (wie keyPressEvent im Original). Ereignisse statt
## Abfrage pro Frame, damit kurze Tastendruecke (Android-D-Pad: Druecken und Loslassen
## im selben Frame) nicht verloren gehen. Godots ui_*-Aktionen dienen als Rueckfall.
const NAV_UP := ["up", "ui_up"]
const NAV_DOWN := ["down", "ui_down"]
const NAV_LEFT := ["move_left", "ui_left"]
const NAV_RIGHT := ["move_right", "ui_right"]
const NAV_OK := ["confirm", "ui_accept"]
const NAV_BACK := ["pause", "cancel", "ui_cancel"]


func _on_action(e: InputEvent) -> void:
	if _hit(e, ["mute"]):
		audio.toggle_mute()
		return
	if _hit(e, ["fullscreen"]):
		settings["fullscreen"] = not DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		_apply_display()
		Settings.save_(settings)
		return
	if _hit(e, ["help"]):
		help = not help
		audio.play("ui")
		return
	if help:
		if _hit(e, NAV_BACK + NAV_OK):
			help = false
		return
	match mode:
		"title":
			if _hit(e, NAV_OK) or _hit(e, ["jump"]):
				audio.play("ui")
				_transition(_start_run)
			elif _hit(e, ["open_settings"]) or _hit(e, NAV_DOWN):
				_open_settings("title")
			elif _hit(e, ["pause"]):
				get_tree().quit()
		"intro":
			if mode_t > 0.6 and (_hit(e, NAV_OK) or _hit(e, ["jump", "pause"])):
				_set_mode("play")
		"play":
			if _hit(e, ["scan"]):
				_edges["scan"] = true
			elif _hit(e, ["jump"]):
				_edges["jump"] = true
			elif _hit(e, ["cancel"]):
				_edges["cancel"] = true
			elif _hit(e, ["cycle_next"]):
				_edges["cycle"] = 1
			elif _hit(e, ["cycle_prev"]):
				_edges["cycle"] = -1
			elif _hit(e, ["pause"]):
				_set_mode("pause")
				audio.play("ui")
		"pause":
			if _hit(e, ["to_title"]):
				_transition(_title_world)
			elif _hit(e, ["open_settings"]) or _hit(e, NAV_DOWN):
				_open_settings("pause")
			elif _hit(e, NAV_BACK) or _hit(e, NAV_OK):
				_set_mode("play")
		"settings":
			if _hit(e, NAV_BACK):
				_close_settings()
			elif _hit(e, NAV_UP, true):
				_settings_move(-1)
			elif _hit(e, NAV_DOWN, true):
				_settings_move(1)
			elif _hit(e, NAV_LEFT, true):
				_settings_adjust(-1)
			elif _hit(e, NAV_RIGHT, true) or _hit(e, NAV_OK):
				_settings_adjust(1)
		"clear":
			if _hit(e, NAV_LEFT, true):
				sel = Py.imod(sel - 1, maxi(1, options.size()))
				audio.play("target")
			elif _hit(e, NAV_RIGHT, true):
				sel = Py.imod(sel + 1, maxi(1, options.size()))
				audio.play("target")
			elif _hit(e, NAV_OK):
				_choose(sel)
		"over", "victory":
			if mode_t > 1.0:
				if _hit(e, ["restart", "scan"]):
					_transition(_start_run)
				elif _hit(e, ["to_title"]) or _hit(e, NAV_OK) or _hit(e, NAV_BACK):
					_transition(_title_world)


func _settings_move(d: int) -> void:
	settings_sel = Py.imod(settings_sel + d, _setting_keys().size())
	audio.play("target")


func _close_settings() -> void:
	_set_mode(_settings_back)
	Settings.save_(settings)
	audio.play("ui")


## Android-Zuruecktaste/-geste: wie "zurueck" im jeweiligen Zustand.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if help:
		help = false
	elif mode == "settings":
		_close_settings()
	elif mode == "play":
		_set_mode("pause")
	elif mode == "pause":
		_set_mode("play")
	elif mode == "title":
		get_tree().quit()
	elif mode in ["over", "victory"]:
		_transition(_title_world)


# ---------------------------------------------------------------- Einstellungen
func _setting_keys() -> Array:
	var keys := []
	for row in HUD.SETTING_ROWS:
		keys.append(row[0])
	return keys


func _open_settings(back: String) -> void:
	_settings_back = back
	settings_sel = 0
	_set_mode("settings")
	audio.play("ui")


func _settings_adjust(d: int) -> void:
	var key: String = _setting_keys()[settings_sel]
	match key:
		"music":
			settings["music"] = clampf(float(settings.get("music", 0.7)) + 0.1 * d, 0.0, 1.0)
			audio.set_volumes(settings["music"], null)
		"sfx":
			settings["sfx"] = clampf(float(settings.get("sfx", 1.0)) + 0.1 * d, 0.0, 1.0)
			audio.set_volumes(null, settings["sfx"])
		"quality":
			var order := ["hoch", "mittel", "niedrig"]
			var i := order.find(str(settings.get("quality", "mittel")))
			if i < 0:
				i = 1
			settings["quality"] = order[Py.imod(i + (1 if d > 0 else -1), order.size())]
			_apply_quality(settings["quality"])
		"reflections":
			settings["reflections"] = not bool(settings.get("reflections", true))
		"rain":
			var ro := ["viel", "wenig", "aus"]
			var ri := ro.find(str(settings.get("rain", "viel")))
			if ri < 0:
				ri = 0
			settings["rain"] = ro[Py.imod(ri + (1 if d > 0 else -1), ro.size())]
		"fog":
			settings["fog"] = not bool(settings.get("fog", true))
		"fx":
			settings["fx"] = not bool(settings.get("fx", true))
		"aspect":
			settings["aspect"] = "letterbox" if settings.get("aspect", "auto") == "auto" else "auto"
		"render_mode":
			settings["render_mode"] = "crt" if settings.get("render_mode", "crt") == "text" else "text"
		"touch":
			var to := ["auto", "an", "aus"]
			var ti := to.find(str(settings.get("touch", "auto")))
			if ti < 0:
				ti = 0
			settings["touch"] = to[Py.imod(ti + (1 if d > 0 else -1), to.size())]
		"fullscreen":
			settings["fullscreen"] = not bool(settings.get("fullscreen", false))
		"resolution":
			var res: Array = Config.RESOLUTIONS
			var ri2 := 0
			for j in res.size():
				if res[j] == settings.get("resolution", [1280, 720]):
					ri2 = j
			ri2 = Py.imod(ri2 + (1 if d > 0 else -1), res.size())
			settings["resolution"] = res[ri2]
		"scanlines":
			settings["scanlines"] = not bool(settings.get("scanlines", true))
		"difficulty":
			var order2: Array = Config.DIFFICULTY_ORDER
			var cur := str(settings.get("difficulty", "normal"))
			var di := order2.find(cur)
			if di < 0:
				di = 1
			settings["difficulty"] = order2[Py.imod(di + (1 if d > 0 else -1), order2.size())]
		"lang":
			settings["lang"] = "en" if settings.get("lang") != "en" else "de"
			I18n.set_lang(settings["lang"])
		"renderer":
			settings["renderer"] = "software" if settings.get("renderer") != "software" else "auto"
	_apply_settings()
	_apply_display()
	Settings.save_(settings)
	audio.play("target")


## Qualitaetsstufe setzt die Einzeloptionen.
func _apply_quality(q: String) -> void:
	match q:
		"hoch":
			settings["reflections"] = true
			settings["rain"] = "viel"
			settings["fog"] = true
			settings["fx"] = true
		"mittel":
			settings["reflections"] = false
			settings["rain"] = "viel"
			settings["fog"] = true
			settings["fx"] = true
		_:
			settings["reflections"] = false
			settings["rain"] = "aus"
			settings["fog"] = false
			settings["fx"] = false


## Alle Darstellungs-/Leistungsoptionen an Szene, CRT, Textmodus und Touch weitergeben.
func _apply_settings() -> void:
	scene.opt_reflections = bool(settings.get("reflections", true))
	scene.opt_rain = str(settings.get("rain", "viel"))
	scene.opt_fog = bool(settings.get("fog", true))
	scene.opt_fx = bool(settings.get("fx", true))
	scene.opt_quality = str(settings.get("quality", "mittel"))
	chain.aspect_mode = "auto" if str(settings.get("aspect", "auto")) == "auto" else "letterbox"
	chain.scan_on = bool(settings.get("scanlines", true))
	var want_text := str(settings.get("render_mode", "crt")) == "text"
	if textmode != null:
		textmode.set_enabled(want_text)
		chain.scene_tex = text_scene_tex if want_text else base_scene_tex
	if touch != null:
		touch.refresh_visibility(settings)


func _apply_display() -> void:
	if bool(settings.get("fullscreen", false)):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var res: Array = settings.get("resolution", [1280, 720])
		DisplayServer.window_set_size(Vector2i(int(res[0]), int(res[1])))
