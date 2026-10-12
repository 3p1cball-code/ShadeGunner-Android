class_name Audio
extends Node
## Ton - Port von shadegunner/audio.py (Klasse Audio + Mixer).
##
## Die Klänge selbst sind mit dem Original-Synthesizer erzeugt (tools/build_audio.py)
## und liegen fertig in res://assets/audio/ (Mono-Effekte WAV, Stereo/Musik OGG).
## Panning und Doppler der Vorbeifahrten stecken bereits in den Stereo-Dateien.
## Mixer: statt eigenem Software-Mixer je Stimme ein AudioStreamPlayer auf einem
## eigenen Bus; dessen Effektkette bildet das weiche Limiting tanh(1.2*x)*32000/32768
## des Originals nach (Verstärkung + atan-Verzerrung, im linearen Bereich exakt).

const DIR := "res://assets/audio"
const MIX_BUS := "ShadeGunner"


static func _lazy(name: String) -> bool:
	## Zonen-Spuren werden nicht vorab geladen, sondern bei Zonenwechsel.
	return name.begins_with("music_z") or name.begins_with("pulse_z")


static func _ga(o: Variant, key: String, default: Variant) -> Variant:
	## getattr(o, key, default) für Objekte und Dictionaries.
	if o == null:
		return default
	if o is Dictionary:
		var d: Dictionary = o
		return d.get(key, default)
	if o is Object:
		var v: Variant = (o as Object).get(key)
		return default if v == null else v
	return default


# ====================================================================== Mixer
class Mixer extends Node:
	## Stimmenverwaltung wie im Original (Stimme = [name, player, vol, loop, pos0, frame0]),
	## gemischt wird nativ von Godot.
	const RATE := 32000
	const LATENCY := 0.11
	const MAX_VOICES := 28

	var data := {}            # name -> AudioStream
	var lengths := {}         # name -> Länge in RATE-Frames (wie len(data[name]) im Original)
	var voices: Array = []    # [name, AudioStreamPlayer, vol, loop, pos0, frame0]
	var _last_start := {}
	var _idle: Array[AudioStreamPlayer] = []
	var log_calls: Variant = null   # Array -> jeder Aufruf wird protokolliert (Tests)

	func _init() -> void:
		name = "Mixer"
		var idx := AudioServer.get_bus_index(MIX_BUS)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, MIX_BUS)
			AudioServer.set_bus_send(idx, "Master")
			_setup_limiter(idx)

	static func _setup_limiter(idx: int) -> void:
		## tanh(1.2*x) * 32000/32768 (Mixer.pump im Original):
		## Kleinsignal-Verstärkung s0 = 1.2*32000/32768 vorab, danach eine
		## Kennlinie mit Steigung 1: atan(b*y)/b, b per Fit gegen tanh (max. 0,2 dB).
		var s0 := 1.2 * 32000.0 / 32768.0
		var amp := AudioEffectAmplify.new()
		amp.volume_db = linear_to_db(s0)
		AudioServer.add_bus_effect(idx, amp)
		var b := 1.3660 / s0
		# Godot-ATAN: out = post * atan(pre*m*x) / (atan(m) * (1 + 8*drive)), m = 10^(3*drive^2) - 0.999
		var drive := sqrt(log(b + 0.999) / log(10.0) / 3.0)
		var m := pow(10.0, drive * drive * 3.0) - 1.0 + 0.001
		var dist := AudioEffectDistortion.new()
		dist.mode = AudioEffectDistortion.MODE_ATAN
		dist.drive = drive
		dist.pre_gain = linear_to_db(b / m)
		dist.post_gain = linear_to_db(atan(m) * (1.0 + 8.0 * drive) / b)
		dist.keep_hf_hz = 20000.0          # fast alles durch die Kennlinie
		AudioServer.add_bus_effect(idx, dist)

	func _log(entry: Array) -> void:
		if log_calls != null:
			(log_calls as Array).append(entry)

	func load_(nm: String, path: String) -> void:
		var s := load(path) as AudioStream
		if s == null:
			push_error("[audio] nicht ladbar: " + path)
			return
		_log(["load", nm])
		data[nm] = s
		lengths[nm] = maxi(1, int(round(s.get_length() * RATE)))

	func unload(nm: String) -> void:
		_log(["unload", nm])
		stop(nm)
		data.erase(nm)
		lengths.erase(nm)

	func pos(nm: String) -> int:
		for v: Array in voices:
			if v[0] == nm:
				var p: AudioStreamPlayer = v[1]
				if int(v[5]) == Engine.get_process_frames() or not p.playing:
					return int(v[4])          # im selben Frame gestartet: noch nicht gemischt
				var sec := p.get_playback_position() + AudioServer.get_time_since_last_mix()
				return int(sec * RATE) % int(lengths[nm])
		return 0

	func play(nm: String, vol: float, loop: bool = false, now: float = 0.0, pos_: int = 0) -> void:
		if not data.has(nm):
			return
		var acc := not (not loop and now - float(_last_start.get(nm, -1.0)) < 0.03)
		_log(["play", nm, vol, loop, pos_, acc])
		if not acc:
			return                              # gleiche Quelle doppelt im selben Frame
		_last_start[nm] = now
		if voices.size() >= MAX_VOICES:
			for v: Array in voices:
				if not v[3]:
					_free_voice(v)
					voices.erase(v)
					break
		var p: AudioStreamPlayer = _idle.pop_back() if not _idle.is_empty() else null
		if p == null:
			p = AudioStreamPlayer.new()
			p.bus = MIX_BUS
			add_child(p)
		var n: int = lengths[nm]
		var start := pos_ % n
		p.stream = data[nm]
		p.volume_linear = vol
		p.play(float(start) / RATE)
		voices.append([nm, p, vol, loop, start, Engine.get_process_frames()])

	func _free_voice(v: Array) -> void:
		var p: AudioStreamPlayer = v[1]
		p.stop()
		p.stream = null
		_idle.append(p)

	func stop(nm: String) -> void:
		_log(["stop", nm])
		var keep: Array = []
		for v: Array in voices:
			if v[0] == nm:
				_free_voice(v)
			else:
				keep.append(v)
		voices = keep

	func set_vol(nm: String, vol: float) -> void:
		_log(["set_vol", nm, vol])
		for v: Array in voices:
			if v[0] == nm:
				v[2] = vol
				(v[1] as AudioStreamPlayer).volume_linear = vol

	func playing(nm: String) -> bool:
		for v: Array in voices:
			if v[0] == nm:
				return true
		return false

	func clear_voices() -> void:
		## entspricht `mixer.voices = []`
		_log(["clear"])
		for v: Array in voices:
			_free_voice(v)
		voices = []

	func pump(silent: bool = false) -> void:
		## Gemischt wird von Godot; hier nur abgelaufene Einmal-Stimmen aufräumen.
		_log(["pump", silent])
		AudioServer.set_bus_mute(AudioServer.get_bus_index(MIX_BUS), silent)
		if silent:
			return
		var keep: Array = []
		var fr := Engine.get_process_frames()
		for v: Array in voices:
			var p: AudioStreamPlayer = v[1]
			if not v[3] and not p.playing and int(v[5]) != fr:
				_free_voice(v)
			else:
				keep.append(v)
		voices = keep

	func close() -> void:
		clear_voices()


# ====================================================================== Audio
var enabled := true
var muted := false
var _fx := {}
var _loaded := {}               # set()
var _started_loops := false
var _poll_t := 0.0
var _music_vol := 1.0
var music_vol := 1.0            # Nutzer-Lautstärke Musik (0..1)
var sfx_vol := 1.0              # Nutzer-Lautstärke Effekte (0..1)
var _t := 0.0
var mixer: Mixer = null
var dir := DIR
# Zonen-Musik: nur die aktuelle Spur ist aktiv, Wechsel per Überblendung
var _zone := 0
var _want := 0
var _mus := "music"
var _pulse: Variant = null      # String oder null
var _gain := {"music": 1.0}     # Überblend-Faktor je Musik-Stimme
var _tension := 0.0
var _veh_t: Array = []


func _init() -> void:
	name = "Audio"
	enabled = not (OS.get_environment("SHADEGUNNER_NOSOUND") in ["1", "true", "yes"])
	if not enabled:
		return
	mixer = Mixer.new()
	add_child(mixer)


func _ready_() -> bool:
	## Python-Property `_ready` (Name kollidiert mit Node._ready)
	return not _fx.is_empty()


func _names() -> PackedStringArray:
	## sorted(Dateinamen ohne Endung) - auch im Export (dort nur .import/.remap vorhanden)
	var out: Array[String] = []
	for fn in ResourceLoader.list_directory(dir):
		if fn.ends_with(".wav") or fn.ends_with(".ogg"):
			out.append(fn.get_basename())
	out.sort()
	return PackedStringArray(out)


func _path(nm: String) -> String:
	var p := dir.path_join(nm + ".ogg")
	return p if ResourceLoader.exists(p) else dir.path_join(nm + ".wav")


func poll() -> void:
	## Regelmäßig aufrufen; lädt beim ersten Mal alle (nicht-Zonen-)Klänge vorab.
	if not enabled:
		return
	_poll_t -= 1.0 / 60
	if _poll_t > 0:
		return
	_poll_t = 0.5
	for nm in _names():
		if _loaded.has(nm) or _lazy(nm):
			continue
		_loaded[nm] = true
		if mixer != null:
			mixer.load_(nm, _path(nm))
			_fx[nm] = true
		if nm in DAudio.LOOPS and _started_loops and not muted:
			if mixer != null and nm == "music":
				_start_music()
			else:
				_start_loop(nm)
	if _want != _zone:
		set_zone(_want)


# ---------------------------------------------------------------- Zonen-Musik
func set_zone(z: int) -> void:
	## Zone 0 = Titelthema, ab 1 eigener Track + Rhythmus-Spur.
	_want = z
	if mixer == null or z == _zone:
		return
	var mus := "music" if z == 0 else "music_z%d" % z
	var pulse: Variant = null if z == 0 else "pulse_z%d" % z
	for n: Variant in [mus, pulse]:
		if n != null and not ResourceLoader.exists(_path(n)):
			return
	for n: Variant in [mus, pulse]:
		if n != null and not mixer.data.has(n):
			mixer.load_(n, _path(n))
			if not mixer.data.has(n):
				push_error("[audio] Zonen-Musik nicht ladbar: %s" % n)
				_want = _zone
				return
	_zone = z
	_mus = mus
	_pulse = pulse
	_fx[mus] = true
	if not _gain.has(mus):
		_gain[mus] = 0.0
	if pulse != null and not _gain.has(pulse):
		_gain[pulse] = 0.0
	if _started_loops and not muted:
		_start_music()


func _start_music() -> void:
	## Aktuelle Musik + Rhythmus starten - die Rhythmus-Spur immer taktgleich.
	var m := mixer
	if m == null or not m.data.has(_mus):
		return
	AudioServer.lock()                  # beide Stimmen im selben Mischschritt beginnen
	if not m.playing(_mus):
		m.play(_mus, 0.0, true)
	if _pulse != null and m.data.has(_pulse) and not m.playing(_pulse):
		m.play(_pulse, 0.0, true, 0.0, m.pos(_mus))
	AudioServer.unlock()


func _tension_of(world: Variant, mode: String) -> float:
	## 0..1: wie angespannt die Lage ist (treibt die Rhythmus-Spur).
	if world == null or not (mode in ["play", "pause"]):
		return 0.0
	var t := 0.8 * float(_ga(world, "unrest", 0.0))
	if _ga(world, "aiming", false):
		t = maxf(t, 0.55)
	if _ga(world, "boss", null) != null:
		t = maxf(t, 0.9)
	if float(_ga(world, "blackout_t", 0)) > 0:
		t = maxf(t, 0.5)
	var run: Variant = _ga(world, "run", null)
	t = maxf(t, 0.6 * float(_ga(run, "suspicion", 0.0)))
	for a: Variant in _ga(world, "actors", []):
		if _ga(a, "alive", false) and _ga(a, "alert", false) and _ga(a, "state", "") in ["flee", "attack", "punch", "leap"]:
			t = 1.0
			break
	return minf(1.0, t)


func _start_loop(nm: String) -> void:
	var base: float = float(DAudio.VOLUME.get(nm, 0.6)) * (music_vol if nm == "music" else sfx_vol)
	if mixer != null and not mixer.playing(nm):
		mixer.play(nm, base, true)


func loops(on: bool = true) -> void:
	for nm: String in DAudio.LOOPS:
		if mixer != null and nm == "music":      # Zonen-Musik (eigene Logik)
			if on and not muted:
				_start_music()
			else:
				for n: String in _gain.keys():
					mixer.stop(n)
			continue
		if not _fx.has(nm):
			continue
		if on and not muted:
			_start_loop(nm)
		elif mixer != null:
			mixer.stop(nm)
	_started_loops = on


func play(nm: String, vol: Variant = null) -> void:
	if not enabled or muted or not _fx.has(nm):
		return
	var v: float = float(DAudio.VOLUME.get(nm, 0.6)) if vol == null else maxf(0.0, minf(1.0, float(vol)))
	v = maxf(0.0, minf(1.0, v * (music_vol if nm == "music" else sfx_vol)))
	if mixer != null:
		mixer.play(nm, v, false, _t)


func toggle_mute() -> bool:
	muted = not muted
	loops(not muted)
	if muted and mixer != null:
		mixer.clear_voices()
	return muted


func update(dt: float, world: Variant = null, mode: String = "play") -> void:
	## Mixer führen; Musik bei Stromausfall absenken, Überblendung, Rhythmus nach Spannung.
	if not enabled:
		return
	_t += dt
	var goal := 0.35 if (world != null and float(_ga(world, "blackout_t", 0)) > 0) else 1.0
	_music_vol += (goal - _music_vol) * minf(1.0, dt * 1.5)
	var mus: float = DAudio.VOLUME["music"] * music_vol * _music_vol
	var rain: float = DAudio.VOLUME["rain"] * sfx_vol
	if mixer == null:
		return
	if world != null:
		var z: int = int(_ga(world, "zone_index", 0)) if mode != "title" else 0
		if z != _want or z != _zone:
			set_zone(z)
	var tg := _tension_of(world, mode)
	# schnell rein, langsam raus - die Spannung soll nachklingen
	var k := dt * (1.2 if tg > _tension else 0.18)
	_tension += (tg - _tension) * minf(1.0, k)
	var lohi: Array = DAudio.PULSE_LEVEL.get(_zone, [0.0, 0.0])
	var lo: float = lohi[0]
	var hi: float = lohi[1]
	for n: String in _gain.keys():
		var goal_g: float
		if n == _mus:
			goal_g = 1.0
		elif _pulse != null and n == _pulse:
			goal_g = lo + (hi - lo) * _tension
		else:
			goal_g = 0.0
		var g: float = _gain[n]
		g += maxf(-dt / 2.5, minf(dt / 2.5, goal_g - g))      # 2,5 s Überblendung
		_gain[n] = g
		if g <= 0.0 and goal_g == 0.0 and n != _mus and not (_pulse != null and n == _pulse):
			_gain.erase(n)
			mixer.unload(n)                 # Speicher frei
			_fx.erase(n)
			_loaded.erase(n)
		else:
			mixer.set_vol(n, mus * g)
	mixer.set_vol("rain", rain)
	mixer.pump(muted)


func set_volumes(music: Variant = null, sfx: Variant = null) -> void:
	## Nutzer-Lautstärken setzen und sofort anwenden (0..1).
	if music != null:
		music_vol = maxf(0.0, minf(1.0, float(music)))
	if sfx != null:
		sfx_vol = maxf(0.0, minf(1.0, float(sfx)))
	if not enabled:
		return
	var mus: float = DAudio.VOLUME["music"] * music_vol * _music_vol
	var rain: float = DAudio.VOLUME["rain"] * sfx_vol
	if mixer != null:
		for n: String in _gain:
			mixer.set_vol(n, mus * float(_gain[n]))
		mixer.set_vol("rain", rain)


func _dir(d: Variant) -> String:
	return "lr" if float(d) > 0 else "rl"


func handle_events(events: Array, world: Variant = null) -> void:
	for ev: Array in events:
		var k: String = ev[0]
		if k == "shot":
			play("shot")
		elif k == "scan_start":
			play("scan")
		elif k == "scan_done":
			play("scan_done")
		elif k == "target":
			play("target")
		elif k == "tell":
			play("tell")
		elif k == "kill":
			play("kill_rep" if ev[2] else "kill_civ")
		elif k == "hurt":
			play("hurt")
		elif k == "escape":
			play("escape")
		elif k == "gate_locked":
			play("gate")
		elif k == "quota":
			play("quota")
		elif k == "zone_clear":
			play("clear")
		elif k == "fail":
			play("fail")
		elif k in ["no_charge", "no_target", "scan_abort"]:
			play("no")
		elif k in ["attack", "flee"]:
			play("alert")
		elif k == "jump":
			play("jump")
		elif k == "land":
			if world != null and ev[1] == 0:
				play("land")
		elif k == "leap":
			play("leap")
		elif k == "tough":
			play("tough")
		elif k == "bounty":
			play("bounty")
		elif k == "ramen":
			play("ramen")
		elif k == "holster":
			play("ui")
		elif k == "boss":
			play("boss")
		elif k == "boss_line":
			play("tell")
		elif k == "boss_hit":
			play("tough")
		elif k == "boss_blocked":
			play("no")
		elif k == "honk":
			play("honk")
		elif k == "car_hit":
			play("car_hit")
		elif k == "bump":
			play("bump")
		elif k == "jam_honk":
			play("honk_meep", DAudio.VOLUME["honk_meep"] * 0.8)
		elif k == "vehicle":
			var kind: String = ev[1]
			var d: Variant = ev[2]
			var vol: float = float(ev[3]) if ev.size() > 3 else 1.0     # leiser bei dichter Fahrt
			# dichter Verkehr: höchstens 4 Vorbeifahrten gleichzeitig anstoßen
			var keep: Array = []
			for x: float in _veh_t:
				if _t - x < 2.5:
					keep.append(x)
			_veh_t = keep
			if _veh_t.size() >= 4:
				continue
			_veh_t.append(_t)
			if kind == "police":        # Boden-Spinner: Turbinen statt Motor
				play("spinner_" + _dir(d), DAudio.VOLUME["spinner_lr"] * 0.8 * vol)
			else:
				var cls := "truck" if kind in ["truck", "bus"] else (kind if kind == "bike" else "car")
				var nm := cls + "_" + _dir(d)
				play(nm, float(DAudio.VOLUME.get(nm, 0.4)) * vol)
		elif k == "spinner":
			var s: float = ev[2]
			play("spinner_" + _dir(ev[1]), DAudio.VOLUME["spinner_lr"] * minf(1.0, 0.5 + s * 0.35))
		elif k == "patrol":
			play("patrol")
		elif k in ["spinner_land", "spinner_lift"]:
			play("spinner_" + _dir(ev[1]), DAudio.VOLUME["spinner_lr"])
		elif k == "spinner_touch":
			play("car_hit", float(DAudio.VOLUME.get("car_hit", 0.5)) * 0.45)
		elif k == "shout":
			play("shout")
		elif k == "talk":
			play("talk")
		elif k == "origami":
			play("bounty")
		elif k == "greet":
			play("ui")
		elif k == "thunder":
			play("thunder")
		elif k == "blackout":
			play("blackout")
		elif k == "blackout_end":
			play("power_up")
