class_name DAudio
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.audio (tools/export_data.py) - nicht von Hand ändern.

# übersprungen: BASIC (function)
const DONE_TAG = "ok-horn1"
const LOOPS = ["rain", "music"]
const MSR = 32000
const PULSE_LEVEL = {1: [0.22, 0.85], 2: [0.3, 0.9], 3: [0.38, 0.95], 4: [0.42, 1.0]}
const SR = 22050
const VERSION = "audio-v2"
const VOLUME = {
	"music": 0.5,
	"rain": 0.16,
	"target": 0.25,
	"ui": 0.4,
	"shot": 0.55,
	"spinner_lr": 0.45,
	"spinner_rl": 0.45,
	"car_lr": 0.38,
	"car_rl": 0.38,
	"truck_lr": 0.45,
	"truck_rl": 0.45,
	"bike_lr": 0.35,
	"bike_rl": 0.35,
	"patrol": 0.45,
	"thunder": 0.6,
	"honk": 0.75,
	"honk_meep": 0.5,
	"bump": 0.45,
	"jump": 0.3,
	"land": 0.3,
	"scan": 0.4,
	"alert": 0.4,
}
