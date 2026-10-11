extends Control
## Einstieg: baut die Render-Kette auf.
##
##   Szene (640x360, prozedural)  ->  Dither-Shader (noir16)  ->  CRT  ->  Bildschirm
##
## Zwei SubViewports (Szene, Dither) und ein letterboxender TextureRect
## (CRT) im Hauptfenster - gleiche Logik wie die Python-Version.

const RW := Config.RENDER_W
const RH := Config.RENDER_H

const DITHER := preload("res://shaders/dither.gdshader")
const CRT := preload("res://shaders/crt.gdshader")
const WORLD := preload("res://src/world.gd")

var _scene_vp: SubViewport
var _post_vp: SubViewport
var _final: TextureRect
var _crt_mat: ShaderMaterial

var _shot_path := ""
var _shot_frames := 45
var _frame := 0


func _ready() -> void:
	_parse_args()

	_scene_vp = SubViewport.new()
	_scene_vp.size = Vector2i(RW, RH)
	_scene_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_scene_vp.disable_3d = true
	add_child(_scene_vp)

	var world := Node2D.new()
	world.set_script(WORLD)
	_scene_vp.add_child(world)

	_post_vp = SubViewport.new()
	_post_vp.size = Vector2i(RW, RH)
	_post_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_post_vp.disable_3d = true
	add_child(_post_vp)

	var mid := TextureRect.new()
	mid.texture = _scene_vp.get_texture()
	mid.position = Vector2.ZERO
	mid.size = Vector2(RW, RH)
	mid.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mid.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var dmat := ShaderMaterial.new()
	dmat.shader = DITHER
	dmat.set_shader_parameter("pal", Palette.v3())
	dmat.set_shader_parameter("spread", Config.DITHER_SPREAD)
	dmat.set_shader_parameter("contrast", Config.GRADE_CONTRAST)
	dmat.set_shader_parameter("saturation", Config.GRADE_SATURATION)
	dmat.set_shader_parameter("lift", Config.GRADE_LIFT)
	mid.material = dmat
	_post_vp.add_child(mid)

	_final = TextureRect.new()
	_final.texture = _post_vp.get_texture()
	_final.set_anchors_preset(Control.PRESET_FULL_RECT)
	_final.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_final.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_final.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_crt_mat = ShaderMaterial.new()
	_crt_mat.shader = CRT
	_final.material = _crt_mat
	add_child(_final)

	get_viewport().size_changed.connect(_update_screen_uniforms)
	_update_screen_uniforms()


func _update_screen_uniforms() -> void:
	var win := get_viewport().get_visible_rect().size
	var s := minf(win.x / float(RW), win.y / float(RH))
	var cw := float(RW) * s
	var ch := float(RH) * s
	_crt_mat.set_shader_parameter("screen_size", Vector2(cw, ch))
	_crt_mat.set_shader_parameter("aspect", cw / maxf(1.0, ch))
	_crt_mat.set_shader_parameter("scan_period", maxf(2.0, ch / float(RH)))


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			_shot_frames = int(a.substr(9))


func _process(_delta: float) -> void:
	if _shot_path != "":
		_frame += 1
		if _frame >= _shot_frames:
			var img := get_viewport().get_texture().get_image()
			img.save_png(_shot_path)
			print("shot: ", _shot_path)
			get_tree().quit()
