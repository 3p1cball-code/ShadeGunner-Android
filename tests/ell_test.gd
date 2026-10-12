extends Node
var baker: Baker
var img: QImg
var frames := 0
func _ready() -> void:
	baker = Baker.new()
	add_child(baker)
	var rnd := PyRandom.new(1)
	img = baker.bake(160, 1600, func(p: QP) -> void:
		p.set_no_pen()
		p.set_brush(QP.c(255, 255, 255))
		for k in 40:
			var x := rnd.uniform(5, 20)
			var y := rnd.uniform(5, 10)
			var w := rnd.uniform(30, 120)
			var h := rnd.uniform(4, 14)
			p.draw_ellipse(x, y + k * 40, w, h))
func _process(_d: float) -> void:
	frames += 1
	if Engine.get_frames_drawn() < 3:
		RenderingServer.force_draw()
	if frames < 4:
		return
	img.tex.get_image().get_region(Rect2i(img.region)).save_png(OS.get_cmdline_user_args()[0])
	get_tree().quit()
