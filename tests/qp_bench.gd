extends Node
## A/B-Mikrobenchmark QP: alter Stand (QPOld) gegen optimierten QP (QP).
##
##   godot --path . --rendering-driver opengl3 res://tests/qp_bench.tscn
##
## Beide bekommen dieselbe repräsentative Primitiv-Mischung; die Reihenfolge wird
## je Durchlauf gewechselt. Gemeldet wird der Median pro Durchlauf.

const RUNS := 40

var vp: SubViewport
var pa: QP
var pb: Variant = null
var frame := 0
var ta: Array = []
var tb: Array = []


func _ready() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var ha := Node2D.new()
	vp.add_child(ha)
	var hb := Node2D.new()
	vp.add_child(hb)
	pa = QP.new(ha.get_canvas_item())
	pb = (load("res://tests/qp_old.gd") as GDScript).new(hb.get_canvas_item())


func _process(_d: float) -> void:
	frame += 1
	if frame < 3:
		return
	if ta.size() < RUNS:
		if ta.size() % 2 == 0:
			ta.append(_time(pa))
			tb.append(_time(pb))
		else:
			tb.append(_time(pb))
			ta.append(_time(pa))
		return
	var ma := _med(ta)
	var mb := _med(tb)
	print("qp_bench neu=%.2fms alt=%.2fms  ->  %.1f%% schneller" % [ma, mb, (mb - ma) / mb * 100.0])
	get_tree().quit()


func _time(p) -> float:
	var t0 := Time.get_ticks_usec()
	_workload(p)
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _med(s: Array) -> float:
	var c := s.duplicate()
	c.sort()
	return c[c.size() / 2]


func _workload(p) -> void:
	p.begin()
	# Dünne Linien (Regen-Muster: ein Stift, viele Linien)
	p.set_pen(p.c(160, 175, 205, 120), 1.0)
	for i in 3000:
		var x := float(i % 640)
		var y := float((i * 7) % 360)
		p.draw_line(x, y, x - 4.0, y + 12.0)
	# Punkte (Spritzer/Funken)
	for i in 2000:
		p.draw_point(float((i * 13) % 640), float((i * 29) % 360))
	# Füllungen (Boden/Schilder)
	p.set_no_pen()
	for i in 1200:
		p.fill_rect(float((i * 11) % 620), float((i * 17) % 340), 8.0, 6.0, p.c(40, 44, 60))
	# Ellipsen (Laternen/Halos)
	p.set_brush(p.c(255, 138, 44, 90))
	for i in 300:
		p.draw_ellipse(float((i * 23) % 600), float((i * 31) % 340), 20.0, 12.0)
	# Polygon mit Kontur (Figuren-Umriss)
	p.set_pen(p.c(200, 200, 220), 1.0)
	p.set_brush(p.c(120, 80, 40))
	for i in 400:
		var bx := float((i * 19) % 600)
		var by := float((i * 37) % 320)
		p.draw_polygon(PackedVector2Array([Vector2(bx, by), Vector2(bx + 10, by + 4),
			Vector2(bx + 6, by + 14)]))
	p.end()
