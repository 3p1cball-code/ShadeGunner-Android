class_name DVehicles
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.render.vehicles (tools/export_data.py) - nicht von Hand ändern.

const ACCENT = [
	[196, 150, 52],
	[224, 72, 150],
	[64, 210, 220],
	[255, 138, 44],
	[122, 74, 168],
	[34, 96, 104],
	[138, 32, 56],
	[162, 168, 180],
]
const AMBER = [255, 148, 48]
const BODY = {
	"car": [
		[40, 46, 64],
		[64, 36, 46],
		[36, 58, 64],
		[78, 80, 92],
		[58, 50, 40],
		[52, 60, 96],
		[46, 66, 58],
		[70, 52, 74],
		[30, 36, 52],
		[86, 60, 52],
		[96, 84, 60],
		[58, 72, 84],
		[44, 40, 56],
		[72, 84, 68],
	],
	"taxi": [[196, 150, 52], [186, 120, 40], [206, 168, 74], [168, 132, 50], [120, 140, 150], [150, 158, 90]],
	"police": [[70, 82, 104]],
	"truck": [[70, 66, 62], [78, 52, 40], [52, 64, 76], [64, 72, 54], [84, 74, 58], [56, 58, 70]],
	"bike": [[30, 30, 40], [90, 20, 50], [24, 50, 60], [70, 58, 30], [40, 44, 66], [88, 44, 36]],
	"limo": [[14, 14, 20], [30, 16, 26]],
	"classic": [
		[70, 108, 106],
		[150, 140, 112],
		[90, 40, 44],
		[24, 24, 28],
		[96, 120, 140],
		[100, 136, 116],
		[120, 92, 60],
		[60, 64, 70],
	],
	"bus": [[54, 60, 78], [70, 52, 60], [40, 66, 70], [72, 66, 44], [58, 44, 64], [46, 54, 54], [84, 72, 52]],
}
const BUS_OP = ["OFF-WORLD", "SHIMATA", "TYRELL", "PAN AM", "KOBAYASHI"]
const BUS_ROUTE = ["4 CHINATOWN", "12 HADES", "9 SECTOR 4", "7 DNA ROW", "2 OFF-WORLD", "11 TYRELL", "6 EYE WORKS"]
const C = [
	[5, 8, 10],
	[12, 22, 28],
	[22, 38, 48],
	[34, 58, 70],
	[52, 86, 104],
	[92, 128, 144],
	[226, 38, 46],
	[156, 84, 40],
	[46, 104, 250],
	[148, 172, 170],
	[255, 255, 255],
	[30, 104, 104],
	[70, 220, 214],
	[224, 72, 150],
	[255, 148, 48],
	[80, 226, 110],
]
const CHROME = [128, 134, 148]
const CRIMSON = [150, 28, 40]
const CYAN = [70, 220, 214]
const GREEN = [80, 226, 110]
const HEAD = [255, 250, 230]
const LIVERY = [
	"TYRELL",
	"SHIMATA",
	"PAN AM",
	"OFF-WORLD",
	"NEXUS 6",
	"EYE WORKS",
	"DNA ROW",
	"KOBAYASHI",
	"WALLACE",
	"SECTOR 4",
	"HADES",
	"VOIGHT-KAMPFF",
]
const MAGENTA = [224, 72, 150]
const NBLUE = [46, 104, 250]
const OB_SCALE = {"barrier": 1.8, "wreck": 2.3, "barrel": 1.4, "dustbin": 1.4, "crates": 1.3, "bins": 1.25}
const PALE = [148, 172, 170]
const RED = [226, 38, 46]
const SPIN_BAR = [-14.0, -18.8, 10.0, 2.0]
const SPIN_L = 62.0
const SPIN_NOSE = [27.6, -8.0]
const SPIN_TAIL = [-31.0, -10.5]
const TAIL = [236, 34, 40]
const TAXI_SIGN = ["TAXI", "CAB", "TAXI", "METRO", "TAXI"]
const TEAL = [30, 104, 104]
const UNDERGLOW = [
	[70, 220, 214],
	[224, 72, 150],
	[46, 104, 250],
	[30, 104, 104],
	[255, 148, 48],
	[80, 226, 110],
	[226, 38, 46],
]
const VARIANTS = 32
const VEH_SCALE = 1.5
const WHITE = [255, 255, 255]
const WIN = [24, 34, 58]
