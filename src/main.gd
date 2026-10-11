extends Control
## Einstieg: baut die Render-Kette auf.
##
##   Szene (640x360, prozedural)  ->  Post-Shader (Dither noir16 + CRT)  ->  Bildschirm
##
## Ein SubViewport für die Szene und ein letterboxender TextureRect mit dem
## Post-Shader im Hauptfenster. So wird die SubViewport-Textur nur einmal
## abgetastet (sonst würde der sRGB-Abtastfaktor doppelt korrigiert).

const RW := Config.RENDER_W
const RH := Config.RENDER_H

const POST := preload("res://shaders/post.gdshader")
const WORLD := preload("res://src/world.gd")

var _scene_vp: SubViewport
var _final: TextureRect
var _mat: ShaderMaterial

var _shot_path := ""
var _shot_frames := 45
var _frame := 0
var _crt_over := ""
var _flat := ""
var _dump_scene := ""


func _ready() -> void:
	_parse_args()

	_scene_vp = SubViewport.new()
	_scene_vp.size = Vector2i(RW, RH)
	_scene_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_scene_vp.disable_3d = true
	add_child(_scene_vp)

	if _flat != "":
		var fc := _flat.split(",")
		var cr := ColorRect.new()
		cr.color = Color(float(fc[0]) / 255.0, float(fc[1]) / 255.0, float(fc[2]) / 255.0)
		cr.size = Vector2(RW, RH)
		cr.position = Vector2.ZERO
		_scene_vp.add_child(cr)
	else:
		var world := Node2D.new()
		world.set_script(WORLD)
		_scene_vp.add_child(world)

	_final = TextureRect.new()
	_final.texture = _scene_vp.get_texture()
	_final.set_anchors_preset(Control.PRESET_FULL_RECT)
	_final.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_final.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_final.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_mat = ShaderMaterial.new()
	_mat.shader = POST
	_mat.set_shader_parameter("grid", Vector2(RW, RH))
	_mat.set_shader_parameter("spread", Config.DITHER_SPREAD)
	_mat.set_shader_parameter("contrast", Config.GRADE_CONTRAST)
	_mat.set_shader_parameter("saturation", Config.GRADE_SATURATION)
	_mat.set_shader_parameter("lift", Config.GRADE_LIFT)
	_final.material = _mat
	add_child(_final)

	if _crt_over != "":
		for kv in _crt_over.split(","):
			var pr := kv.split("=")
			if pr.size() == 2:
				_mat.set_shader_parameter(pr[0], float(pr[1]))

	get_viewport().size_changed.connect(_update_screen_uniforms)
	_update_screen_uniforms()


func _update_screen_uniforms() -> void:
	var win := get_viewport().get_visible_rect().size
	var s := minf(win.x / float(RW), win.y / float(RH))
	var cw := float(RW) * s
	var ch := float(RH) * s
	_mat.set_shader_parameter("screen_size", Vector2(cw, ch))
	_mat.set_shader_parameter("aspect", cw / maxf(1.0, ch))
	_mat.set_shader_parameter("scan_period", maxf(2.0, ch / float(RH) * 1.5))
	_mat.set_shader_parameter("mask_px", maxf(1.0, round(ch / float(RH))))


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			_shot_frames = int(a.substr(9))
		elif a.begins_with("--crt="):
			_crt_over = a.substr(6)
		elif a.begins_with("--flat="):
			_flat = a.substr(7)
		elif a.begins_with("--dump-scene="):
			_dump_scene = a.substr(13)


func _process(_delta: float) -> void:
	if _shot_path != "":
		_frame += 1
		if _frame >= _shot_frames:
			if _dump_scene != "":
				_scene_vp.get_texture().get_image().save_png(_dump_scene)
			get_viewport().get_texture().get_image().save_png(_shot_path)
			print("shot: ", _shot_path)
			get_tree().quit()
