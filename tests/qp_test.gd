extends Node
## Gegenstück zu tools/qp_reference.py: dieselben Befehle mit QP.
## godot --path . --rendering-driver opengl3 res://tests/qp_test.tscn -- --out=<png>

var vp: SubViewport
var frame := 0
var out := "res://shots/qp_godot.png"
var baker: Baker


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	baker = Baker.new()
	add_child(baker)
	var sub := baker.bake(40, 30, func(q: QP) -> void:
		q.fill_rect(0, 0, 40, 30, QP.c(224, 72, 150, 180))
		q.fill_rect(10, 8, 20, 14, QP.c(64, 210, 220)))
	vp = SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var host := Node2D.new()
	vp.add_child(host)
	var p := QP.new(host.get_canvas_item())
	p.begin()
	p.fill_rect(0, 0, 640, 360, QP.c(18, 22, 38))
	p.fill_rect(10, 10, 100, 50, QP.c(255, 138, 44))
	p.fill_rect(20.5, 70.25, 60.5, 20.5, QP.c(64, 210, 220, 128))
	p.set_no_pen()
	p.set_brush(QP.c(122, 74, 168))
	p.draw_ellipse(130, 10, 80, 50)
	p.draw_ellipse_c(260, 40, 20.0, 12.0)
	p.set_brush(QP.c(214, 220, 226))
	p.draw_polygon(PackedVector2Array([Vector2(300, 10), Vector2(360, 60), Vector2(290, 55)]))
	p.set_pen(QP.c(255, 255, 255), 1.0)
	p.draw_line(10, 110, 200, 110)
	p.draw_line(10, 120, 200, 150)
	p.set_pen(QP.c(224, 72, 150), 4.0, QP.CAP_ROUND)
	p.draw_line(220, 110, 320, 150)
	p.set_pen(QP.c(255, 138, 44), 3.0)
	p.draw_line(220, 160, 320, 160)
	p.set_no_pen()
	var g := QGrad.linear(10, 180, 210, 180)
	g.set_color_at(0, QP.c(6, 8, 14))
	g.set_color_at(0.5, QP.c(64, 210, 220))
	g.set_color_at(1, QP.c(255, 255, 255, 0))
	p.fill_rect(10, 180, 200, 30, g)
	var r := QGrad.radial(300, 230, 50)
	r.set_color_at(0, QP.c(255, 138, 44, 255))
	r.set_color_at(1, QP.c(255, 138, 44, 0))
	p.set_brush(r)
	p.draw_ellipse_c(300, 230, 50.0, 50.0)
	p.save()
	p.translate(420, 60)
	p.scale(2.0, 2.0)
	p.rotate(20)
	p.fill_rect(0, 0, 30, 15, QP.c(34, 96, 104))
	p.restore()
	p.set_mode(QP.PLUS)
	p.fill_rect(400, 120, 120, 60, QP.c(80, 40, 120))
	p.set_mode(QP.OVER)
	p.set_opacity(0.5)
	p.draw_image(Rect2(400, 200, 80, 60), sub)
	p.set_opacity(1.0)
	p.draw_image_at(530, 200, sub)
	p.draw_image(Rect2(530, 250, 40, 30), sub.mirror())
	p.set_clip_rect(20, 260, 60, 40)
	p.fill_rect(0, 250, 200, 100, QP.c(162, 168, 180))
	p.set_clipping(false)
	p.set_pen(QP.c(255, 255, 255), 1.0)
	p.set_no_brush()
	p.draw_rect(100, 260, 50, 30)
	p.draw_point(170.4, 270.6)
	p.end()


func _process(_d: float) -> void:
	frame += 1
	if frame == 6:
		vp.get_texture().get_image().save_png(out)
		print("godot ok")
		get_tree().quit()
