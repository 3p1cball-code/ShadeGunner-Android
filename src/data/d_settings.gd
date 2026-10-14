class_name DSettings
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.settings (tools/export_data.py) - nicht von Hand ändern.

const DEFAULTS = {
	"music": 0.7,
	"sfx": 1.0,
	"fullscreen": false,
	"resolution": [1280, 720],
	"scanlines": true,
	"renderer": "auto",
	"difficulty": "normal",
	"lang": "de",
	"quality": "hoch",
	"reflections": true,
	"rain": "viel",
	"fog": true,
	"fx": true,
}
const QUALITY = {
	"hoch": {"reflections": true, "rain": "viel", "fog": true, "fx": true},
	"mittel": {"reflections": false, "rain": "viel", "fog": true, "fx": true},
	"niedrig": {"reflections": false, "rain": "aus", "fog": false, "fx": false},
}
