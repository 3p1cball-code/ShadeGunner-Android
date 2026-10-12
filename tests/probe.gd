extends Node
var baker: Baker
var q: QImg
var frames := 0


func _ready() -> void:
	baker = Baker.new()
	add_child(baker)
	q = baker.bake(8, 8, func(p: QP) -> void:
		p.fill_rect(0, 0, 8, 8, QP.c(200, 100, 50, 128)))
	var im0 := q.tex.get_image().get_region(Rect2i(q.region))
	print("SOFORT px=", im0.get_pixel(2, 2))
	RenderingServer.force_draw()
	var im1 := q.tex.get_image().get_region(Rect2i(q.region))
	print("FORCED px=", im1.get_pixel(2, 2))


func _process(_d: float) -> void:
	frames += 1
	if Engine.get_frames_drawn() < 3:
		RenderingServer.force_draw()
	if frames < 4:
		return
	var im := q.tex.get_image().get_region(Rect2i(q.region))
	print("fmt=", im.get_format(), " px=", im.get_pixel(2, 2))
	var t := ImageTexture.create_from_image(im)
	print("tex ok ", t.get_size())
	get_tree().quit()
