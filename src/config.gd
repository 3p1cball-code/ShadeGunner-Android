class_name Config
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.config (tools/export_data.py) - nicht von Hand ändern.

const AIM_MIN = 0.18
const CAR_BRAKE = 300.0
const CAR_BUMP_INVULN = 0.8
const CAR_DANGER_SPEED = 42.0
const CGA16 = [
	[0, 0, 0],
	[0, 0, 170],
	[0, 170, 0],
	[0, 170, 170],
	[170, 0, 0],
	[170, 0, 170],
	[170, 85, 0],
	[170, 170, 170],
	[85, 85, 85],
	[85, 85, 255],
	[85, 255, 85],
	[85, 255, 255],
	[255, 85, 85],
	[255, 85, 255],
	[255, 255, 85],
	[255, 255, 255],
]
const COMBO_MAX = 5
const DEFAULT_PALETTE = "noir16"
const DEPTH_MAX = 1.0
const DEPTH_MIN = 0.1
const DEPTH_UNITS = 160.0
const DIFFICULTY = {
	"leicht": {"density": 0.7, "label": "LEICHT"},
	"normal": {"density": 1.0, "label": "NORMAL"},
	"schwer": {"density": 1.4, "label": "SCHWER"},
}
const DIFFICULTY_ORDER = ["leicht", "normal", "schwer"]
const DITHER_ORDER = 3
const DITHER_SPREAD = 0.24
const EMPTY_FROM = 0.72
const EMPTY_TO = 560.0
const FACADE_DEPTH = -0.075
const FIGURE_H_NEAR = 0.215
const FLOOR_BOTTOM_Y = 0.985
const FLOOR_TOP_Y = 0.5
const GRADE_CONTRAST = 0.36
const GRADE_LIFT = -0.025
const GRADE_SATURATION = 1.22
const GRAVITY = 640.0
const HUD_SCALE = 2
const JUMP_SAFE_Z = 5.0
const JUMP_V = 150.0
const LAND_ASCENT_S = 2.2
const LAND_DEPTH = 0.525
const LAND_DESCENT_S = 2.6
const LAND_PUSH = 55.0
const LAND_TIME = [7.0, 10.0]
const LANES = [[0.32, -1], [0.74, 1]]
const LANE_HALF = 0.085
const NOIR16 = [
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
const NOIR16_OLD = [
	[6, 8, 14],
	[18, 22, 38],
	[34, 40, 66],
	[52, 60, 96],
	[74, 92, 138],
	[104, 132, 178],
	[138, 32, 56],
	[156, 84, 40],
	[162, 168, 180],
	[214, 220, 226],
	[255, 255, 255],
	[34, 96, 104],
	[64, 210, 220],
	[224, 72, 150],
	[255, 138, 44],
	[122, 74, 168],
]
const NPC_DEPTH_MIN = 0.02
const OBSERVE_RANGE = 150.0
const OBSERVE_SECONDS = 2.4
const OBSTACLE_BANDS = [[0.12, 0.2], [0.45, 0.6], [0.88, 0.97]]
const PALETTES = {
	"noir16": [
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
	],
	"cga16": [
		[0, 0, 0],
		[0, 0, 170],
		[0, 170, 0],
		[0, 170, 170],
		[170, 0, 0],
		[170, 0, 170],
		[170, 85, 0],
		[170, 170, 170],
		[85, 85, 85],
		[85, 85, 255],
		[85, 255, 85],
		[85, 255, 255],
		[255, 85, 85],
		[255, 85, 255],
		[255, 255, 85],
		[255, 255, 255],
	],
	"hades16": [
		[6, 6, 12],
		[16, 16, 28],
		[28, 28, 48],
		[44, 44, 72],
		[64, 66, 102],
		[100, 104, 142],
		[140, 34, 44],
		[120, 64, 36],
		[196, 104, 44],
		[255, 156, 56],
		[255, 216, 140],
		[226, 214, 200],
		[255, 255, 255],
		[96, 60, 140],
		[150, 104, 220],
		[84, 128, 255],
	],
	"blocks16": [
		[5, 9, 10],
		[12, 22, 26],
		[20, 38, 44],
		[32, 58, 64],
		[50, 86, 92],
		[90, 128, 130],
		[160, 34, 64],
		[236, 86, 150],
		[156, 118, 98],
		[36, 120, 84],
		[70, 214, 120],
		[176, 242, 196],
		[60, 190, 214],
		[196, 218, 212],
		[255, 255, 255],
		[255, 170, 210],
	],
	"china16": [
		[5, 8, 10],
		[12, 22, 28],
		[22, 38, 48],
		[34, 58, 70],
		[52, 86, 104],
		[92, 128, 144],
		[150, 26, 36],
		[230, 40, 48],
		[250, 146, 52],
		[148, 172, 170],
		[255, 255, 255],
		[30, 104, 104],
		[70, 220, 214],
		[176, 246, 236],
		[160, 110, 82],
		[255, 196, 150],
	],
	"harbor16": [
		[6, 8, 10],
		[16, 20, 26],
		[28, 34, 42],
		[44, 52, 62],
		[66, 78, 90],
		[100, 114, 126],
		[140, 152, 162],
		[190, 198, 204],
		[255, 255, 255],
		[120, 40, 34],
		[110, 62, 34],
		[196, 108, 46],
		[255, 162, 66],
		[255, 214, 152],
		[70, 120, 150],
		[128, 180, 208],
	],
	"tyrell16": [
		[4, 5, 10],
		[12, 14, 24],
		[22, 26, 42],
		[36, 40, 62],
		[56, 64, 94],
		[96, 106, 140],
		[130, 30, 30],
		[100, 62, 30],
		[170, 110, 46],
		[240, 170, 70],
		[255, 222, 150],
		[220, 214, 200],
		[255, 255, 255],
		[60, 110, 200],
		[130, 180, 255],
		[100, 190, 220],
	],
}
const PANIC_RADIUS = 170.0
const PARK_BANDS = [[0.165, 0.75], [0.925, 0.25]]
const PLAYER_DEPTH_SPEED = 0.75
const PLAYER_HP = 3
const PLAYER_SPRINT_SPEED = 100.0
const PLAYER_WALK_SPEED = 58.0
const POINTS_BOUNTY = 400
const POINTS_CIVILIAN = -250
const POINTS_ESCAPE = -40
const POINTS_INSTINCT = 60
const POINTS_ORIGAMI = 250
const POINTS_REPLICANT = 100
const RAMEN_RANGE = 26.0
const RAMEN_TIME = 1.2
const RENDER_H = 360
const RENDER_W = 640
const RESOLUTIONS = [[1280, 720], [1366, 768], [1600, 900], [1920, 1080], [2560, 1440], [3840, 2160]]
const ROY_HP = 8
const ROY_LINES = [
	"Ganz schön, in Angst zu leben, nicht wahr? Das heißt es, ein Sklave zu sein.",
	"Ich habe Dinge gesehen, von denen ihr Menschen nicht einmal träumt.",
	"Angriffsschiffe in Flammen vor der Schulter des Orion.",
	"Ich sah C-Strahlen glitzern im Dunkeln am Tannhäuser Tor.",
	"All diese Momente werden verloren sein in der Zeit - wie Tränen im Regen.",
	"Zeit zu sterben.",
]
const ROY_MERCY_HP = 1
const ROY_MONO_S = 4.2
const ROY_PER_LINE = 2
const ROY_SPEAK_S = 2.6
const ROY_STAND = 240.0
const ROY_TAUNTS = [
	"Nicht sehr sportlich, auf einen unbewaffneten Gegner zu schießen.",
	"Ich dachte, du wärst gut. Bist du nicht der Gute?",
	"Komm schon. Zeig mir, was du drauf hast!",
	"Stolz auf dich, kleiner Mann?",
]
const ROY_TRIGGER = 480.0
const ROY_WAKE = 150.0
const SCALE_FAR = 0.42
const SCAN_CHARGES = 5
const SCAN_RANGE = 125.0
const SCAN_RECHARGE_S = 5.0
const SCAN_TIME = 0.85
const SHOOT_RANGE = 210.0
const SHOT_COOLDOWN = 0.45
const SHOUT_ALERT = 0.3
const SHOUT_CD = 10.0
const SHOUT_CHARGE = 1.0
const SHOUT_DUCK = [3.2, 4.6]
const SHOUT_RADIUS = [70.0, 160.0]
const SHOUT_SCATTER = 0.15
const SHOUT_SPEED = 240.0
const SHOUT_TAP = 0.3
const SIDEWALK = [0.02, 0.09]
const SPINNER_LAND_CHANCE = 0.45
const STRIDE_UNITS = 30.0
const SUSPICION_PER_CIVILIAN = 0.34
const SUSPICION_PER_ESCAPE = 0.06
const SUSPICION_WATCHED = 1.5
const TALK_ALERT = 0.45
const TALK_CD = 2.5
const TALK_RANGE = 110.0
const TARGET_RANGE = 190.0
const TRAFFIC_GAP = 14.0
const TRAFFIC_REF = 12.0
const UNREST_DECAY = 0.025
const UNREST_PER_SHOUT = 0.34
const VIEW_SPAN_NEAR = 300.0
const ZONE_LOOK = [
	{
		"name": "hades16",
		"pal": [
			[6, 6, 12],
			[16, 16, 28],
			[28, 28, 48],
			[44, 44, 72],
			[64, 66, 102],
			[100, 104, 142],
			[140, 34, 44],
			[120, 64, 36],
			[196, 104, 44],
			[255, 156, 56],
			[255, 216, 140],
			[226, 214, 200],
			[255, 255, 255],
			[96, 60, 140],
			[150, 104, 220],
			[84, 128, 255],
		],
		"neon": [9, 9, 8, 14, 15, 10],
		"people": [9, 10, 14, 15, 8, 11],
	},
	{
		"name": "blocks16",
		"pal": [
			[5, 9, 10],
			[12, 22, 26],
			[20, 38, 44],
			[32, 58, 64],
			[50, 86, 92],
			[90, 128, 130],
			[160, 34, 64],
			[236, 86, 150],
			[156, 118, 98],
			[36, 120, 84],
			[70, 214, 120],
			[176, 242, 196],
			[60, 190, 214],
			[196, 218, 212],
			[255, 255, 255],
			[255, 170, 210],
		],
		"neon": [10, 10, 12, 11, 7, 12],
		"people": [10, 11, 12, 7, 15, 13],
	},
	{
		"name": "china16",
		"pal": [
			[5, 8, 10],
			[12, 22, 28],
			[22, 38, 48],
			[34, 58, 70],
			[52, 86, 104],
			[92, 128, 144],
			[150, 26, 36],
			[230, 40, 48],
			[250, 146, 52],
			[148, 172, 170],
			[255, 255, 255],
			[30, 104, 104],
			[70, 220, 214],
			[176, 246, 236],
			[160, 110, 82],
			[255, 196, 150],
		],
		"neon": [12, 12, 7, 7, 13, 8],
		"people": [12, 13, 7, 8, 15, 9],
	},
	{
		"name": "harbor16",
		"pal": [
			[6, 8, 10],
			[16, 20, 26],
			[28, 34, 42],
			[44, 52, 62],
			[66, 78, 90],
			[100, 114, 126],
			[140, 152, 162],
			[190, 198, 204],
			[255, 255, 255],
			[120, 40, 34],
			[110, 62, 34],
			[196, 108, 46],
			[255, 162, 66],
			[255, 214, 152],
			[70, 120, 150],
			[128, 180, 208],
		],
		"neon": [12, 12, 11, 15, 13],
		"people": [12, 13, 15, 14, 7],
	},
	{
		"name": "tyrell16",
		"pal": [
			[4, 5, 10],
			[12, 14, 24],
			[22, 26, 42],
			[36, 40, 62],
			[56, 64, 94],
			[96, 106, 140],
			[130, 30, 30],
			[100, 62, 30],
			[170, 110, 46],
			[240, 170, 70],
			[255, 222, 150],
			[220, 214, 200],
			[255, 255, 255],
			[60, 110, 200],
			[130, 180, 255],
			[100, 190, 220],
		],
		"neon": [9, 10, 11, 14, 9],
		"people": [9, 10, 14, 15, 11],
	},
]
