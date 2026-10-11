class_name Baker
extends Node
## Offscreen-Zeichnen in Texturen (Ersatz für "QImage anlegen und mit QPainter bemalen").
##
## Zwei Werkzeuge:
##   bake(w, h, draw)  -> QImg   Einmalbild (Stadt-Ebenen, Nebeltexturen ...).
##                               draw: func(p: QP) zeichnet in Bildkoordinaten.
##   Atlas                       Sammelt viele kleine Bilder (Sprites, Fahrzeuge)
##                               in einer großen Textur; ersetzt die Caches.
##
## Godot rendert Geschwister-Viewports in Baumreihenfolge. Der Baker muss im Baum
## VOR dem Szenen-Viewport hängen - dann ist ein im selben Frame gebackenes Bild
## schon fertig, wenn die Szene es zeichnet.

var _bakes: Array[SubViewport] = []


func bake(w: int, h: int, draw: Callable) -> QImg:
	var vp := SubViewport.new()
	vp.size = Vector2i(maxi(1, w), maxi(1, h))
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	var host := Node2D.new()
	vp.add_child(host)
	add_child(vp)
	var p := QP.new(host.get_canvas_item())
	p.begin()
	draw.call(p)
	p.end()
	_bakes.append(vp)
	var img := QImg.new(vp.get_texture(), Rect2(0, 0, w, h))
	img.set_meta("vp", vp)
	return img


## Gebackenes Bild freigeben (z. B. beim Zonenwechsel).
func release(img: QImg) -> void:
	if img == null or not img.has_meta("vp"):
		return
	var vp: SubViewport = img.get_meta("vp")
	_bakes.erase(vp)
	vp.queue_free()


func release_all() -> void:
	for vp in _bakes:
		vp.queue_free()
	_bakes.clear()


## Neuen Atlas anlegen (Kind dieses Bakers, also vor der Szene gerendert).
func make_atlas(size: int = 2048) -> Atlas:
	var a := Atlas.new()
	a.setup(self, size)
	return a


class Atlas:
	## Regal-Packer in einer großen Textur. Neue Einträge werden nur einmal
	## gezeichnet (Viewport mit CLEAR_MODE_NEVER behält die alten Pixel).
	var vp: SubViewport
	var host: Node2D
	var size := 2048
	var _x := 0
	var _y := 0
	var _row_h := 0
	var _pending: Array = []        # Painter, die nach diesem Frame geleert werden
	var _cleared_frame := -1
	var full_resets := 0

	func setup(parent: Node, sz: int) -> void:
		size = sz
		vp = SubViewport.new()
		vp.size = Vector2i(sz, sz)
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		host = Node2D.new()
		vp.add_child(host)
		parent.add_child(vp)

	func texture() -> Texture2D:
		return vp.get_texture()

	## Platz für w x h reservieren; null, wenn der Atlas voll ist.
	func alloc(w: int, h: int) -> Variant:
		w += 1
		h += 1
		if w > size or h > size:
			return null
		if _x + w > size:
			_x = 0
			_y += _row_h
			_row_h = 0
		if _y + h > size:
			return null
		var r := Rect2i(_x, _y, w - 1, h - 1)
		_x += w
		_row_h = maxi(_row_h, h)
		return r

	## Alles verwerfen (wie _CACHE.clear() im Original). Der Aufrufer leert seine Schlüssel.
	func reset() -> void:
		_x = 0
		_y = 0
		_row_h = 0
		for p in _pending:
			(p as QP).free_all()
		_pending.clear()
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		full_resets += 1

	## Painter für einen reservierten Bereich: Ursprung = Bereichsecke, geclippt.
	func painter_for(r: Rect2i) -> QP:
		var p := QP.new(host.get_canvas_item())
		p.begin()
		p.set_clip_rect(r.position.x, r.position.y, r.size.x, r.size.y)
		p.translate(r.position.x, r.position.y)
		_pending.append(p)
		return p

	## Nach dem Zeichnen: einmal rendern, ohne die bisherigen Pixel zu löschen.
	func commit() -> void:
		if vp.render_target_clear_mode != SubViewport.CLEAR_MODE_ONCE:
			vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	## Einmal pro Frame aufrufen (vor dem Zeichnen neuer Einträge): Painter des
	## vorigen Frames freigeben - ihre Pixel stehen jetzt im Atlas.
	func frame_start() -> void:
		var f := Engine.get_frames_drawn()
		if f == _cleared_frame:
			return
		_cleared_frame = f
		if not _pending.is_empty() and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED:
			for p in _pending:
				(p as QP).end()
				(p as QP).free_all()
			_pending.clear()
			vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
