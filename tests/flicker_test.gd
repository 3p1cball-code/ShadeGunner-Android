extends Node
## Flacker-Test v2: jedes Frame ALLE bisher gebackenen Sprites (Cache-Treffer) plus ein
## neues zeichnen und im naechsten Frame JEDES pruefen. Meldet leere Treffer (= Flackern)
## getrennt nach "neu gebacken" und "aus dem Cache".
var target: SubViewport
var p: QP
var look: Dictionary
var looks: Array = []
var swaps_seen := 0
var last_cache := 0
var frame := 0
var keys: Array = []          # Hoehen bereits gebackener Sprites
var pending: Array = []       # [rect, ist_neu]
var blank_new := 0
var blank_old := 0
var n_new := 0
var n_old := 0
var first_blank := -1
var nmax := 120

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			nmax = int(a.substr(4))
	target = SubViewport.new()
	target.size = Vector2i(1600, 1000)
	target.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	target.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(target)
	var hn := Node2D.new()
	target.add_child(hn)
	p = QP.new(hn.get_canvas_item())
	var baker := Baker.new()
	add_child(baker)
	Sprites.baker = baker
	Pixfont.baker = baker
	look = Looks.random_look(PyRandom.new(7), 1, 0.6)
	var rr := PyRandom.new(11)
	for u in 40:
		looks.append(Looks.random_look(rr, 100 + u, 0.6))

func _process(_d: float) -> void:
	frame += 1
	if frame > 3 and not pending.is_empty():
		var img := target.get_texture().get_image()
		for pd in pending:
			var r: Rect2i = pd[0]
			var n := 0
			for y in range(r.position.y, r.end.y, 2):
				for x in range(r.position.x, r.end.x, 2):
					if img.get_pixel(x, y).a > 0.1:
						n += 1
			if pd[1]:
				n_new += 1
				if n == 0:
					blank_new += 1
			else:
				n_old += 1
				if n == 0:
					blank_old += 1
					if first_blank < 0:
						first_blank = frame
		pending.clear()
	var cs := Sprites.cache_size()
	if cs < last_cache:
		swaps_seen += 1
	last_cache = cs
	if frame > nmax:
		print("FLICKER: neu leer %d/%d, Cache-Treffer leer %d/%d (erstmals Frame %d), Generationswechsel %d" % [blank_new, n_new, blank_old, n_old, first_blank, swaps_seen])
		get_tree().quit()
		return
	p.begin()
	var news: Array = []
	for j in 6:
		var kk := frame * 6 + j
		keys.append(kk)
		news.append(kk)
	if keys.size() > 240:
		keys = keys.slice(keys.size() - 240)
	var hs: Array = keys.duplicate()
	var i := 0
	for k in hs:
		var hpx := 24.0 + float(int(k) % 36) * 2.0
		var anim_f := int(k) % 8
		var lk: Dictionary = looks[int(k) / 288 % looks.size()]
		var r: Array = Sprites.get_(lk, "walk", anim_f, hpx, 1)
		var im: QImg = r[0]
		if im != null:
			var cx := 20 + (i % 26) * 60
			var cy := 10 + (i / 26) * 66
			p.draw_image_at(cx, cy, im)
			if frame > 4:
				pending.append([Rect2i(cx, cy, im.width(), im.height()).intersection(Rect2i(0, 0, 1600, 1000)), news.has(k)])
		i += 1
		if i >= 26 * 15:
			break
	p.end()
