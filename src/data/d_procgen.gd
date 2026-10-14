class_name DProcgen
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.procgen (tools/export_data.py) - nicht von Hand ändern.

const BRIDGE_W = [70.0, 210.0]
const OBSTACLE_KINDS = {
	"barrier": [20.0, 0.04, 14.0],
	"crates": [12.0, 0.055, 14.0],
	"bins": [10.0, 0.05, 10.0],
	"barrel": [6.3, 0.035, 12.6],
	"vending": [6.0, 0.03, 20.0],
	"wreck": [55.0, 0.07, 29.0],
	"dustbin": [5.6, 0.035, 12.6],
}
const OVERHANG_W = [150.0, 260.0]
const SPAN_PLAN = [
	["bridge", "bridge", "overhang"],
	["bridge", "overhang", "bridge"],
	["overhang", "bridge", "overhang", "bridge"],
	["bridge", "bridge", "overhang"],
	["overhang", "bridge"],
]
const TOWER_RATE = [[1.4, 0.6], [2.2, 0.8], [3.0, 1.2], [1.6, 0.6], [0.8, 0.4]]
const ZONE_OBSTACLES = [
	["barrel", "barrel", "bins", "crates", "wreck", "wreck", "dustbin", "dustbin"],
	["bins", "dustbin", "vending", "barrier", "barrel", "wreck", "dustbin"],
	["vending", "vending", "bins", "barrier", "crates", "dustbin", "dustbin"],
	["crates", "crates", "barrel", "barrier", "bins", "wreck", "dustbin"],
	["barrier", "barrier", "vending", "crates"],
]
const ZONE_RAIN = [0.55, 0.4, 1.0, 0.35, 0.3]
