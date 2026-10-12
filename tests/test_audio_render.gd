extends SceneTree
## Nimmt die echte Godot-Mischung auf (AudioEffectRecord am Master) und legt sie als
## WAV ab; tools/audio_render_check.py vergleicht mit dem Original-Mixer.
## Lauf: godot --headless --audio-driver Dummy --path . --script res://tests/test_audio_render.gd -- OUT.wav
##
## Ablauf (Sekunden ab Aufnahmestart):
##   0.5  shot (vol 0.55)                        -> Pegel/Limiter Kleinsignal
##   2.0  rain als Loop (vol 0.5) bis 9.0         -> Loop-Naht bei 3,5 s
##   9.5  pulse_z3 zweimal "taktgleich" (je 0.12) bis 14.5 -> Synchronität
##  15.0  thunder (1.0) + spinner_lr (1.0)         -> Sättigung des Limiters
##  23.0  music_z3 ab 1,5 s vor Loop-Ende (vol 0.4) -> OGG-Naht
##  27.0  Ende

var audio: Audio
var rec: AudioEffectRecord
var t := 0.0
var step := 0
var out_path := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out_path = args[0] if args.size() > 0 else "res://tools/audio_render/render.wav"
	audio = Audio.new()
	root.add_child(audio)
	audio.poll()
	rec = AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, rec)
	rec.set_recording_active(true)
	print("mix_rate ", AudioServer.get_mix_rate())


func _process(delta: float) -> bool:
	t += delta
	if step >= 100:
		step += 1
		if step == 140:
			audio.free()
		return step >= 145
	var m := audio.mixer
	if step == 0 and t >= 0.5:
		m.play("shot", 0.55, false, t)
		step = 1
	elif step == 1 and t >= 2.0:
		m.play("rain", 0.5, true)
		step = 2
	elif step == 2 and t >= 9.0:
		m.stop("rain")
		m.load_("pulse_z3", "res://assets/audio/pulse_z3.ogg")
		step = 3
	elif step == 3 and t >= 9.5:
		AudioServer.lock()
		m.play("pulse_z3", 0.12, true)
		m.play("pulse_z3", 0.12, true, 0.0, m.pos("pulse_z3"))
		AudioServer.unlock()
		step = 4
	elif step == 4 and t >= 14.5:
		m.stop("pulse_z3")
		step = 5
	elif step == 5 and t >= 15.0:
		m.play("thunder", 1.0, false, t)
		m.play("spinner_lr", 1.0, false, t)
		step = 6
	elif step == 6 and t >= 23.0:
		m.load_("music_z3", "res://assets/audio/music_z3.ogg")
		m.play("music_z3", 0.4, true, 0.0, int(m.lengths["music_z3"]) - 48000)
		step = 7
	elif step == 7 and t >= 27.0:
		rec.set_recording_active(false)
		var w := rec.get_recording()
		var err := w.save_to_wav(out_path)
		print("Aufnahme: ", out_path, " err=", err, " Länge=", w.get_length(), " fmt=", w.format, " stereo=", w.stereo, " rate=", w.mix_rate)
		audio.mixer.close()
		step = 100
		return false
	m.pump()
	return false
