class_name Config
## Balancing und Layout - 1:1 aus shadegunner/config.py uebernommen.
## Alles, was Look oder Spielgefuehl betrifft, lebt hier.

# --- Bildschirm / Render ---
const RENDER_W := 640
const RENDER_H := 360
const DEFAULT_PALETTE := "noir16"
const DITHER_SPREAD := 0.24
const DITHER_ORDER := 3          # 8x8 Bayer
const GRADE_CONTRAST := 0.30
const GRADE_SATURATION := 1.22
const GRADE_LIFT := -0.012

# --- Spielebene (Belt-Scroller) ---
const FLOOR_TOP_Y := 0.50
const FLOOR_BOTTOM_Y := 0.985
const SCALE_FAR := 0.42
const FACADE_DEPTH := -0.075
const FIGURE_H_NEAR := 0.215
const VIEW_SPAN_NEAR := 300.0
const DEPTH_MIN := 0.10
const NPC_DEPTH_MIN := 0.02
const SIDEWALK := Vector2(0.02, 0.09)
const DEPTH_MAX := 1.0
const DEPTH_UNITS := 160.0

# --- Spieler ---
const PLAYER_WALK_SPEED := 58.0
const PLAYER_SPRINT_SPEED := 100.0
const PLAYER_DEPTH_SPEED := 0.75
const PLAYER_HP := 3
const STRIDE_UNITS := 30.0
const JUMP_V := 132.0
const GRAVITY := 640.0
const JUMP_SAFE_Z := 5.0

# --- Ruf (V) ---
const SHOUT_TAP := 0.3
const SHOUT_CHARGE := 1.0
const SHOUT_RADIUS := Vector2(70.0, 160.0)
const SHOUT_SPEED := 240.0
const SHOUT_CD := 10.0
const SHOUT_DUCK := Vector2(3.2, 4.6)
const SHOUT_SCATTER := 0.15
const SHOUT_ALERT := 0.3
const TALK_RANGE := 110.0
const TALK_CD := 2.5
const TALK_ALERT := 0.45
const UNREST_PER_SHOUT := 0.34
const UNREST_DECAY := 0.025

# --- Aktionen ---
const TARGET_RANGE := 190.0
const OBSERVE_RANGE := 150.0
const OBSERVE_SECONDS := 2.4
const SCAN_RANGE := 125.0
const SCAN_TIME := 0.85
const SHOOT_RANGE := 210.0
const AIM_MIN := 0.18
const SHOT_COOLDOWN := 0.45
const PANIC_RADIUS := 170.0
const SCAN_CHARGES := 5
const SCAN_RECHARGE_S := 5.0

# --- Straße ---
const LANES := [Vector2(0.32, -1.0), Vector2(0.74, 1.0)]
const LANE_HALF := 0.085
const PARK_BANDS := [Vector2(0.165, 0.75), Vector2(0.925, 0.25)]
const OBSTACLE_BANDS := [Vector2(0.12, 0.20), Vector2(0.45, 0.60), Vector2(0.88, 0.97)]

# --- Suspicion / Punkte ---
const SUSPICION_PER_CIVILIAN := 0.34
const SUSPICION_PER_ESCAPE := 0.06
const POINTS_REPLICANT := 100
const POINTS_INSTINCT := 60
const POINTS_CIVILIAN := -250
const POINTS_ESCAPE := -40
const POINTS_BOUNTY := 400
const COMBO_MAX := 5
const SUSPICION_WATCHED := 1.5
