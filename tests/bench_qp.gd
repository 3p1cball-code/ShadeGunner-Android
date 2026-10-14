extends Node
func _ready() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	add_child(vp)
	var h := Node2D.new()
	vp.add_child(h)
	var p := QP.new(h.get_canvas_item())
	p.begin()
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		p.fill_rect(i % 600, 10, 3, 3, QP.c(200, 100, 50))
	print("fill_rect: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		p.set_pen(QP.c(200, 100, 50), 1.0)
		p.draw_line(i % 600, 10, i % 600 + 20, 30)
	print("line: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		var g := QGrad.radial(100, 100, 30)
		g.set_color_at(0, QP.c(200, 100, 50, 80))
		g.set_color_at(1, QP.c(0, 0, 0, 0))
		p.fill_rect(70, 70, 60, 60, g)
	print("radial fill: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		var g := QGrad.radial(100, 100, 30)
		g.set_color_at(0, QP.c(200, 100, 50, 80))
		g.set_color_at(1, QP.c(0, 0, 0, 0))
	print("grad create: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var g2 := QGrad.radial(100, 100, 30)
	g2.set_color_at(0, QP.c(200, 100, 50, 80))
	g2.set_color_at(1, QP.c(0, 0, 0, 0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		g2._tex = null
		g2.texture()
	print("grad texture(): %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		p.fill_rect(70, 70, 60, 60, g2)
	print("fill w/ ready grad: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		p.set_no_pen()
		p.set_brush(QP.c(200, 100, 50))
		p.draw_ellipse(100, 100, 20, 10)
	print("ellipse: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		p.set_mode(QP.PLUS if i % 2 else QP.OVER)
		p.fill_rect(i % 600, 10, 3, 3, QP.c(200, 100, 50))
	print("mode-switch rect: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		p.save()
		p.translate(5, 5)
		p.scale(1, 0.3)
		p.restore()
	print("save/tr/restore: %.2f us" % ((Time.get_ticks_usec() - t0) / 1000.0))
	p.end()
	get_tree().quit()
