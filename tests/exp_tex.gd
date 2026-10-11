extends Control
## Experiment: woher kommt der Faktor 0.503? Vier Wege, eine graue Fläche (128) zu zeigen.
var vp: SubViewport
var frame := 0
func _ready() -> void:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color8(128, 128, 128))
	var it := ImageTexture.create_from_image(img)
	vp = SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cr := ColorRect.new(); cr.color = Color8(128, 128, 128); cr.size = Vector2(64, 64); vp.add_child(cr)
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment(){ COLOR = texture(TEXTURE, UV); }"
	var cases = [[it, null], [it, sh], [vp.get_texture(), null], [vp.get_texture(), sh]]
	for i in cases.size():
		var tr := TextureRect.new()
		tr.texture = cases[i][0]
		tr.position = Vector2(i * 80, 0)
		tr.size = Vector2(64, 64)
		if cases[i][1] != null:
			var m := ShaderMaterial.new(); m.shader = cases[i][1]; tr.material = m
		add_child(tr)
	var r := ColorRect.new(); r.color = Color8(128, 128, 128); r.position = Vector2(320, 0); r.size = Vector2(64, 64); add_child(r)
func _process(_d: float) -> void:
	frame += 1
	if frame == 10:
		var im := get_viewport().get_texture().get_image()
		var names = ["ImageTex", "ImageTex+Shader", "ViewportTex", "ViewportTex+Shader", "ColorRect direkt"]
		for i in 5:
			print(names[i], ": ", im.get_pixel(i * 80 + 32, 32).r8)
		get_tree().quit()
