extends Node
## Ellipsen wie die Bodenpfützen, über City._bake (QPExact). Vergleich mit tools/ell_reference.py.
var baker: Baker
var img: QImg
var frames := 0


func _ready() -> void:
	baker = Baker.new()
	add_child(baker)
	City.baker = baker
	var W := 4000
	var rows := 194
	var rng := PyRandom.new(7)
	img = City._bake(W, rows, func(p: QP) -> void:
		p.set_no_pen()
		for _i in 200:
			var r := rng.randint(3, rows - 2)
			var pw := rng.uniform(24, 92) * (0.5 + r / float(rows))
			var ph := maxf(3, int(rng.uniform(3.0, 7.0) * (0.6 + r / float(rows))))
			var px_ := rng.uniform(0, W)
			p.set_brush(QP.c(26, 34, 52, 70))
			p.draw_ellipse(px_, r, pw, ph))


func _process(_d: float) -> void:
	frames += 1
	if Engine.get_frames_drawn() < 3:
		RenderingServer.force_draw()
	if frames < 4:
		return
	var im := img.tex.get_image().get_region(Rect2i(img.region))
	im.convert(Image.FORMAT_RGBA8)
	var k := Image.create(im.get_width(), im.get_height(), false, Image.FORMAT_RGBA8)
	for y in im.get_height():
		for x in im.get_width():
			var c := im.get_pixel(x, y)
			k.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	k.save_png(OS.get_cmdline_user_args()[0])
	get_tree().quit()
