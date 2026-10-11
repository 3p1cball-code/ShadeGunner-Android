extends Control
## Einstieg (Übergang): Szene -> CRTChain. Wird durch game.gd ersetzt, sobald der
## Spielzustand portiert ist.

const RW := Config.RENDER_W
const RH := Config.RENDER_H
const WORLD := preload("res://src/world.gd")

var _scene_vp: SubViewport
var _chain: CRTChain

var _shot_path := ""
var _shot_frames := 45
var _frame := 0
var _flat := ""
var _crt_over := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			_shot_frames = int(a.substr(9))
		elif a.begins_with("--flat="):
			_flat = a.substr(7)
		elif a.begins_with("--crt="):
			_crt_over = a.substr(6)
		elif a.begins_with("--win="):
			var wh := a.substr(6).split("x")
			DisplayServer.window_set_size(Vector2i(int(wh[0]), int(wh[1])))

	_scene_vp = SubViewport.new()
	_scene_vp.size = Vector2i(RW, RH)
	_scene_vp.disable_3d = true
	_scene_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_scene_vp)
	if _flat != "":
		var fc := _flat.split(",")
		var cr := ColorRect.new()
		cr.color = Color8(int(fc[0]), int(fc[1]), int(fc[2]))
		cr.size = Vector2(RW, RH)
		_scene_vp.add_child(cr)
	else:
		var world := Node2D.new()
		world.set_script(WORLD)
		_scene_vp.add_child(world)

	_chain = CRTChain.new()
	_chain.scene_tex = _scene_vp.get_texture()
	add_child(_chain)
	if _crt_over != "":
		var lv: Dictionary = DShaders.CRT_LEVEL.duplicate(true)
		for kv in _crt_over.split(","):
			var pr := kv.split("=")
			lv[pr[0]] = float(pr[1])
		_chain.level = lv


func _process(_delta: float) -> void:
	if _shot_path != "":
		_frame += 1
		if _frame >= _shot_frames:
			get_viewport().get_texture().get_image().save_png(_shot_path)
			print("shot: ", _shot_path)
			get_tree().quit()
