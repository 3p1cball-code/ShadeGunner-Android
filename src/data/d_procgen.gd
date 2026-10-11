class_name DProcgen
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.procgen (tools/export_data.py) - nicht von Hand ändern.

const OBSTACLE_KINDS = {
	"barrier": [11.0, 0.035, 9.0],
	"crates": [9.0, 0.05, 11.0],
	"bins": [8.0, 0.045, 8.0],
	"barrel": [4.5, 0.03, 9.0],
	"vending": [6.0, 0.03, 20.0],
}
const ZONE_OBSTACLES = [
	["barrel", "barrel", "bins", "crates", "barrier"],
	["bins", "bins", "vending", "barrier", "barrel"],
	["vending", "vending", "bins", "barrier", "crates"],
	["crates", "crates", "barrel", "barrier", "bins"],
	["barrier", "barrier", "vending", "crates"],
]
const ZONE_RAIN = [0.55, 0.4, 1.0, 0.35, 0.3]
