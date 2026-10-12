class_name ExactCache
extends RefCounted
## Atlas-Cache für Sprites/Vehicles: rohes Bild (+ Leuchtbild) in "raw", daraus per
## Shader Umriss/Rimlight/Nebel nach "fin" (fin wird nach raw angelegt -> rendert
## im selben Frame danach). Zwei Paare im Wechsel: ist eines voll, wird das andere
## geleert (das alte bleibt in diesem Frame gültig) - entspricht _CACHE.clear().
##
## Freigabe der Painter über einen eigenen Zähler (RenderingServer.frame_post_draw):
## Engine.get_frames_drawn() (Baker.Atlas.frame_start) zählt RenderingServer.force_draw()
## nicht mit; Tests ohne Monitor würden sonst alte Einträge immer wieder zeichnen.

# Shader: rgb = tex.rgb * m * vc.a + vc.rgb * tex.a, a = tex.a * vc.a
#   Maske (SourceIn):  m = 0, vc = (Farbe * alpha, alpha)  (premultipliziert)
#   Bild mit Nebel:    m = 1 - f, vc = (fog * f, 1)   (SourceAtop-Füllung)
const _FX_SHADER := "shader_type canvas_item;\nrender_mode blend_premul_alpha;\nuniform float m;\nvarying vec4 vc;\nvoid vertex(){ vc = COLOR; }\nvoid fragment(){ vec4 t = texture(TEXTURE, UV); COLOR = vec4(t.rgb * m * vc.a + vc.rgb * t.a, t.a * vc.a); }"

static var _drawn := 0
static var _hooked := false
static var _mats := {}
static var _fx_pool: Array[RID] = []

var baker: Baker
var atlas_size := 2048
var cache: Dictionary              # Schlüssel -> Ergebnis (gehört dem Besitzer, wird hier geleert)
var gens: Array = []
var cur := 0
var dummy: QPExact                 # schluckt Zeichnungen ohne Ziel (z. B. emit nicht benötigt)


class Gen:
	var raw: Baker.Atlas
	var fin: Baker.Atlas
	var painters: Array = []
	var fx: Array[RID] = []
	var commit_drawn := -1
	var draw_index := 0


func _init(cache_dict: Dictionary) -> void:
	cache = cache_dict


func ensure(b: Baker) -> void:
	if dummy != null:
		return
	assert(b != null, "Baker fehlt")
	baker = b
	dummy = QPExact.new(RenderingServer.canvas_item_create())
	if not _hooked:
		_hooked = true
		RenderingServer.frame_post_draw.connect(_on_post_draw)


static func _on_post_draw() -> void:
	_drawn += 1


func gen() -> Gen:
	while gens.size() <= cur:
		var g := Gen.new()
		g.raw = baker.make_atlas(atlas_size)
		g.fin = baker.make_atlas(atlas_size)
		gens.append(g)
	return gens[cur]


## Einmal vor dem Backen: gerenderte Einträge freigeben.
func settle() -> void:
	for g: Gen in gens:
		if g.commit_drawn >= 0 and _drawn > g.commit_drawn:
			_release(g)
			g.raw.vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
			g.fin.vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
			g.raw.vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			g.fin.vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _release(g: Gen) -> void:
	for p: QP in g.painters:
		p.end()
		p.free_all()
	g.painters.clear()
	for it in g.fx:
		RenderingServer.canvas_item_clear(it)
		RenderingServer.canvas_item_set_visible(it, false)
		_fx_pool.append(it)
	g.fx.clear()
	g.draw_index = 0
	g.commit_drawn = -1


## Cache leeren = auf das andere Paar wechseln und dieses leeren.
func swap() -> void:
	cache.clear()
	if dummy == null:
		return
	cur = 1 - cur
	var g := gen()
	_release(g)
	g.raw.reset()
	g.fin.reset()


## Platz für n_raw rohe Bilder und ein fertiges Bild: [Rect2i raw..., Rect2i fin] oder [].
func alloc(w: int, h: int, n_raw: int) -> Array:
	for attempt in 2:
		var g := gen()
		var out: Array = []
		var ok := true
		for i in n_raw:
			var r: Variant = g.raw.alloc(w, h)
			if r == null:
				ok = false
				break
			out.append(r)
		var rf: Variant = g.fin.alloc(w, h) if ok else null
		if ok and rf != null:
			out.append(rf)
			return out
		swap()
	return []


## Painter (QPExact) für einen raw-Bereich: Ursprung = Bereichsecke, geclippt.
func painter(r: Rect2i) -> QPExact:
	var g := gen()
	var p := QPExact.new(g.raw.host.get_canvas_item())
	p.begin()
	p.set_clip_rect(r.position.x, r.position.y, r.size.x, r.size.y)
	p.translate(r.position.x, r.position.y)
	g.painters.append(p)
	return p


func dummy_painter() -> QPExact:
	dummy.begin()
	return dummy


func raw_img(r: Rect2i) -> QImg:
	return QImg.new(gen().raw.texture(), Rect2(r))


static func _mat(m: float) -> ShaderMaterial:
	var hit: Variant = _mats.get(m)
	if hit != null:
		return hit
	var sh := Shader.new()
	sh.code = _FX_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("m", m)
	_mats[m] = mat
	return mat


func _fx_item(g: Gen, mat: ShaderMaterial, clip: Rect2) -> RID:
	var it: RID
	if _fx_pool.is_empty():
		it = RenderingServer.canvas_item_create()
	else:
		it = _fx_pool.pop_back()
	g.fx.append(it)
	RenderingServer.canvas_item_set_parent(it, g.fin.host.get_canvas_item())
	RenderingServer.canvas_item_set_visible(it, true)
	RenderingServer.canvas_item_set_draw_index(it, 100000 + g.draw_index)
	g.draw_index += 1
	RenderingServer.canvas_item_set_material(it, mat.get_rid())
	RenderingServer.canvas_item_set_default_texture_filter(it, RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	RenderingServer.canvas_item_set_custom_rect(it, true, clip)
	RenderingServer.canvas_item_set_clip(it, true)
	return it


## Fertiges Bild nach fin[dst] aus raw[src]:
##   masks: [[rgb, alpha, dx, dy], ...]  Silhouetten (SourceIn-Masken) in Reihenfolge
##   dann das Bild selbst; f/fog_rgb: SourceAtop-Füllung mit Deckkraft f (0..1).
##   fog_masks: true = Füllung über das Gesamtbild (Masken mitgefärbt), false = nur übers Bild.
## Danach raw und fin committen. Rückgabe: QImg im fin-Atlas.
func finish(src: Rect2i, dst: Rect2i, masks: Array, f: float, fog_rgb: Array, fog_masks: bool) -> QImg:
	var g := gen()
	var fogc := Color(float(fog_rgb[0]) / 255.0, float(fog_rgb[1]) / 255.0, float(fog_rgb[2]) / 255.0)
	var tex := g.raw.texture().get_rid()
	var srcr := Rect2(src)
	var clip := Rect2(dst)
	var size := Vector2(dst.size)
	var pos := Vector2(dst.position)
	var mf := f if fog_masks else 0.0
	if not masks.is_empty():
		var mk := _fx_item(g, _mat(0.0), clip)
		for m: Array in masks:
			var rgb: Array = m[0]
			var a := float(m[1]) / 255.0
			var c := Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0, float(rgb[2]) / 255.0)
			c = c * (1.0 - mf) + fogc * mf
			RenderingServer.canvas_item_add_texture_rect_region(mk, Rect2(pos + Vector2(float(m[2]), float(m[3])), size),
				tex, srcr, Color(c.r * a, c.g * a, c.b * a, a), false, true)
	var fi := _fx_item(g, _mat(1.0 - f), clip)
	RenderingServer.canvas_item_add_texture_rect_region(fi, Rect2(pos, size), tex, srcr,
		Color(fogc.r * f, fogc.g * f, fogc.b * f, 1.0), false, true)
	g.raw.commit()
	g.fin.commit()
	g.commit_drawn = _drawn
	return QImg.new(g.fin.texture(), clip)
