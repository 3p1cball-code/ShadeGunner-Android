class_name CRTChain
extends Node
## GPU-Kette 1:1 nach shadegunner/render/glrender.py (CRTRenderer.render):
##
##   1. Bayer-Dither der Szene + HUD-Overlay  -> bayer   (Fenstergröße)
##   2. Phosphor-Nachleuchten (Ping-Pong)     -> persist (Fenstergröße)
##   3. Fokus-Blur H, dann V                  -> focus   (voll oder halb)
##   4. Bloom H (quadriert), dann V           -> bloom   (halbe Größe)
##   5. Röhre: Wölbung, Maske, Scanlines ...  -> Fenster
##
## Jeder Durchgang ist ein SubViewport mit einem bildschirmfüllenden ColorRect.
## Godot rendert Geschwister-Viewports in Baumreihenfolge; deshalb müssen Szene
## und HUD VOR diesem Knoten im Baum hängen.

const SH_BAYER := preload("res://shaders/chain/bayer.gdshader")
const SH_PERSIST := preload("res://shaders/chain/persist.gdshader")
const SH_FOCUS := preload("res://shaders/chain/focus.gdshader")
const SH_BLUR := preload("res://shaders/chain/blur.gdshader")
const SH_CRT := preload("res://shaders/chain/crt.gdshader")

const BLUR_HALF_PX := 1.5
const BLUR_ASPECT := 0.7

var scene_tex: Texture2D
var hud_tex: Texture2D
var vc := 640
var vr := 360
var scan_on := true
var force_dt := -1.0          # Tools: feste Frame-Zeit statt Wanduhr
var level: Dictionary = DShaders.CRT_LEVEL

var _size := Vector2i.ZERO
var _vp := {}                 # Name -> SubViewport
var _mat := {}                # Name -> ShaderMaterial
var _persist_ix := 0
var _persist_stale := true
var _last_t := -1.0
var _t0 := 0.0
var _seed := 0
var _out: ColorRect
var _layer: CanvasLayer


func _ready() -> void:
	_t0 = Time.get_ticks_msec() / 1000.0
	for name in ["bayer", "persist0", "persist1", "focus0", "focus1", "focus_half0", "focus_half1", "bloom0", "bloom1"]:
		var vp := SubViewport.new()
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		var cr := ColorRect.new()
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := ShaderMaterial.new()
		m.shader = _shader_for(name)
		cr.material = m
		vp.add_child(cr)
		add_child(vp)
		_vp[name] = vp
		_mat[name] = m
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	_out = ColorRect.new()
	_out.set_anchors_preset(Control.PRESET_FULL_RECT)
	var cm := ShaderMaterial.new()
	cm.shader = SH_CRT
	_out.material = cm
	_layer.add_child(_out)
	_mat["crt"] = cm


func _shader_for(name: String) -> Shader:
	if name == "bayer":
		return SH_BAYER
	if name.begins_with("persist"):
		return SH_PERSIST
	if name.begins_with("focus"):
		return SH_FOCUS
	return SH_BLUR


func _ensure(fw: int, fh: int) -> void:
	if _size == Vector2i(fw, fh):
		return
	_size = Vector2i(fw, fh)
	var bw := maxi(1, (fw + 1) / 2)
	var bh := maxi(1, (fh + 1) / 2)
	for name in _vp:
		var half: bool = name.begins_with("bloom") or name.begins_with("focus_half")
		var vp: SubViewport = _vp[name]
		vp.size = Vector2i(bw, bh) if half else Vector2i(fw, fh)
		(vp.get_child(0) as ColorRect).size = Vector2(vp.size)
	_persist_ix = 0
	_persist_stale = true
	_last_t = -1.0


func _process(_delta: float) -> void:
	if scene_tex == null:
		return
	var win := get_viewport().get_visible_rect().size
	var fw := maxi(1, int(win.x))
	var fh := maxi(1, int(win.y))
	_ensure(fw, fh)
	var dpr := 1.0
	var lvl := level

	var cell := minf(float(fw) / vc, float(fh) / vr)
	var pw := vc * cell
	var ph := vr * cell
	var ox := (fw - pw) / 2.0
	var oy := (fh - ph) / 2.0

	# 1. Bayer + HUD
	var mb: ShaderMaterial = _mat["bayer"]
	mb.set_shader_parameter("u_frame", scene_tex)
	mb.set_shader_parameter("u_res", Vector2(fw, fh))
	mb.set_shader_parameter("u_origin", Vector2(ox, oy))
	mb.set_shader_parameter("u_cell", Vector2(cell, cell))
	mb.set_shader_parameter("u_grid", Vector2(vc, vr))
	mb.set_shader_parameter("u_spread", Config.DITHER_SPREAD)
	mb.set_shader_parameter("u_order", Config.DITHER_ORDER)
	mb.set_shader_parameter("u_contrast", Config.GRADE_CONTRAST)
	mb.set_shader_parameter("u_sat", Config.GRADE_SATURATION)
	mb.set_shader_parameter("u_lift", Config.GRADE_LIFT)
	if hud_tex != null:
		mb.set_shader_parameter("u_hud", hud_tex)
		mb.set_shader_parameter("u_has_hud", 1)
		mb.set_shader_parameter("u_hud_scale", float(hud_tex.get_width()) / vc)
	else:
		mb.set_shader_parameter("u_has_hud", 0)

	# Zeit für das Nachleuchten
	var now := Time.get_ticks_msec() / 1000.0
	var dt := 0.0 if _last_t < 0.0 else minf(0.1, maxf(0.0, now - _last_t))
	if force_dt >= 0.0:
		dt = force_dt
	_last_t = now
	_seed = (_seed + 1) & 0xFFFF

	# 2. Nachleuchten (Ping-Pong: nur der aktuelle Puffer rendert)
	var prev_name := "persist%d" % _persist_ix
	var cur_name := "persist%d" % (1 - _persist_ix)
	_persist_ix = 1 - _persist_ix
	var vcur: SubViewport = _vp[cur_name]
	var vprev: SubViewport = _vp[prev_name]
	vcur.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vprev.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var mp: ShaderMaterial = _mat[cur_name]
	var tau: Array = lvl["tau"]
	mp.set_shader_parameter("u_cur", (_vp["bayer"] as SubViewport).get_texture())
	if _persist_stale:
		mp.set_shader_parameter("u_prev", (_vp["bayer"] as SubViewport).get_texture())
		mp.set_shader_parameter("u_decay", Vector3.ZERO)
		_persist_stale = false
	else:
		mp.set_shader_parameter("u_prev", vprev.get_texture())
		mp.set_shader_parameter("u_decay", Vector3(exp(-dt / float(tau[0])), exp(-dt / float(tau[1])), exp(-dt / float(tau[2]))))
	mp.set_shader_parameter("u_floor", dt * 0.5)
	mp.set_shader_parameter("u_dtn", dt * 60.0)
	mp.set_shader_parameter("u_tint", Vector3.ZERO)
	mp.set_shader_parameter("u_tint_mix", 0.0)
	var lit: Texture2D = vcur.get_texture()

	# 3. Fokus-Blur
	var s := maxf(0.5, cell * 0.5)
	var sigma := float(lvl["blur"]) * s
	for nm in ["focus0", "focus1", "focus_half0", "focus_half1"]:
		(_vp[nm] as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	if sigma > 0.02:
		var half := sigma > BLUR_HALF_PX * dpr
		var a := "focus_half0" if half else "focus0"
		var b := "focus_half1" if half else "focus1"
		var va: SubViewport = _vp[a]
		var vb: SubViewport = _vp[b]
		va.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vb.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var tw := float(va.size.x)
		var th := float(va.size.y)
		var s_px := sigma * 0.5 if half else sigma
		var m0: ShaderMaterial = _mat[a]
		m0.set_shader_parameter("u_src", lit)
		m0.set_shader_parameter("u_dir", Vector2(1.0 / tw, 0.0))
		m0.set_shader_parameter("u_sigma", s_px)
		var m1: ShaderMaterial = _mat[b]
		m1.set_shader_parameter("u_src", va.get_texture())
		m1.set_shader_parameter("u_dir", Vector2(0.0, 1.0 / th))
		m1.set_shader_parameter("u_sigma", s_px * BLUR_ASPECT)
		lit = vb.get_texture()

	# 4. Bloom
	var vb0: SubViewport = _vp["bloom0"]
	var vb1: SubViewport = _vp["bloom1"]
	var bh2 := float(vb0.size.y)
	var mb0: ShaderMaterial = _mat["bloom0"]
	mb0.set_shader_parameter("u_src", lit)
	mb0.set_shader_parameter("u_dir", Vector2(2.0 * dpr / fw, 0.0))
	mb0.set_shader_parameter("u_prep", 1)
	var mb1: ShaderMaterial = _mat["bloom1"]
	mb1.set_shader_parameter("u_src", vb0.get_texture())
	mb1.set_shader_parameter("u_dir", Vector2(0.0, dpr / bh2))
	mb1.set_shader_parameter("u_prep", 0)

	# 5. Röhre
	var scan_period := cell * maxi(1, int(round(3.0 * dpr / cell)))
	var so := 1.0 if scan_on else 0.0
	var mc: ShaderMaterial = _mat["crt"]
	mc.set_shader_parameter("u_scene", lit)
	mc.set_shader_parameter("u_bloom", vb1.get_texture())
	mc.set_shader_parameter("u_res", Vector2(fw, fh))
	mc.set_shader_parameter("u_rect", Vector4(ox, oy, pw, ph))
	mc.set_shader_parameter("u_curve", float(lvl["curve"]))
	mc.set_shader_parameter("u_corner", 0.035 * minf(pw, ph))
	mc.set_shader_parameter("u_mask", float(lvl["mask"]) * so)
	mc.set_shader_parameter("u_mask_px", maxf(1.0, round(dpr)))
	mc.set_shader_parameter("u_scan", float(lvl["scan"]) * so)
	mc.set_shader_parameter("u_scan_period", scan_period)
	mc.set_shader_parameter("u_bloom_amt", float(lvl["bloom"]))
	mc.set_shader_parameter("u_grain", float(lvl["grain"]))
	mc.set_shader_parameter("u_hum", float(lvl["hum"]))
	mc.set_shader_parameter("u_vignette", float(lvl["vignette"]))
	mc.set_shader_parameter("u_aberr", float(lvl["aberr"]) * s)
	mc.set_shader_parameter("u_time", fmod(now - _t0, 3600.0))
	mc.set_shader_parameter("u_seed", _seed)


## Fensterpixel -> Szenenpixel inkl. CRT-Wölbung (wie game.py _scene_pos). null = außerhalb.
func scene_pos(pos: Vector2) -> Variant:
	var win := get_viewport().get_visible_rect().size
	var cell := minf(win.x / vc, win.y / vr)
	var pw := vc * cell
	var ph := vr * cell
	var ox := (win.x - pw) / 2.0
	var oy := (win.y - ph) / 2.0
	var nx := (pos.x - ox) / pw * 2.0 - 1.0
	var ny := (pos.y - oy) / ph * 2.0 - 1.0
	var cv := float(level["curve"])
	var sx := nx * (1.0 + cv * ny * ny)
	var sy := ny * (1.0 + cv * nx * nx)
	if absf(sx) > 1.0 or absf(sy) > 1.0:
		return null
	return Vector2((sx * 0.5 + 0.5) * vc, (sy * 0.5 + 0.5) * vr)
