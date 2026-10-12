extends SceneTree
## Audio-Port gegen das Python-Original: gleiche Ereignisfolge -> gleiche Mixer-Aufrufe.
## Referenz: tools/audio_ref.py (tests/audio_scenario.json, tests/audio_ref_log.json).
## Lauf: godot --headless --audio-driver Dummy --path . --script res://tests/test_audio_log.gd

var audio: Audio
var frames: Array
var ref: Array
var log_: Array = []
var i := 0
var max_voices := 0


func _initialize() -> void:
	frames = JSON.parse_string(FileAccess.get_file_as_string("res://tests/audio_scenario.json"))
	ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/audio_ref_log.json"))
	audio = Audio.new()
	root.add_child(audio)
	audio.mixer.log_calls = log_


func _process(_delta: float) -> bool:
	if _rc >= 0:
		return _done_tick()
	if i >= frames.size():
		_finish()
		return false
	var f: Dictionary = frames[i]
	log_.append(["frame", i])
	audio.poll()
	if audio._ready_() and not audio._started_loops and not audio.muted:
		audio.loops(true)
	for c: Array in f["calls"]:
		if c[0] == "set_volumes":
			audio.set_volumes(c[1], c[2])
		elif c[0] == "toggle_mute":
			log_.append(["muted", audio.toggle_mute()])
		elif c[0] == "play":
			audio.play(c[1], c[2] if c.size() > 2 else null)
	var w: Variant = f["world"]
	audio.handle_events(f["events"], w)
	if not (f["sfx"] as Array).is_empty():
		audio.handle_events(f["sfx"], w)
	audio.update(f["dt"], w, f["mode"])
	if i % 100 == 0:
		var keys: Array = audio._gain.keys()
		keys.sort()
		log_.append(["state", audio._zone, audio._mus, audio._pulse, audio._tension, audio._music_vol, keys])
	max_voices = maxi(max_voices, audio.mixer.voices.size())
	i += 1
	return false


func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= 1e-9
	if a is Array and b is Array:
		var x: Array = a
		var y: Array = b
		if x.size() != y.size():
			return false
		for k in x.size():
			if not _same(x[k], y[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func _finish() -> void:
	var fails := 0
	var n := mini(log_.size(), ref.size())
	for k in n:
		if not _same(log_[k], ref[k]):
			fails += 1
			if fails <= 10:
				print("ABWEICHUNG #", k, " godot=", log_[k], " python=", ref[k])
	if log_.size() != ref.size():
		fails += 1
		print("Länge: godot=", log_.size(), " python=", ref.size())
	var plays := 0
	for e: Array in log_:
		if e[0] == "play":
			plays += 1
	print("Audio-Protokoll: %d Einträge, %d play-Aufrufe, max. %d Stimmen gleichzeitig, Abweichungen %d"
		% [log_.size(), plays, max_voices, fails])
	audio.mixer.close()
	_rc = 1 if fails else 0


var _rc := -1
var _wait := 0


func _done_tick() -> bool:
	## Ein paar Frames warten, bis der AudioServer die gestoppten Wiedergaben freigibt.
	_wait += 1
	if _wait == 40:
		audio.free()
	if _wait >= 45:
		quit(_rc)
	return false
