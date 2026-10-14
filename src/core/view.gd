class_name View
## Variable interne Bildbreite: die Höhe bleibt 360, die Breite folgt dem
## Seitenverhältnis des Bildschirms (400 = 10:9, 480 = 4:3 … 960 = 24:9). Der Belt-Scroller
## zeigt dann links/rechts mehr bzw. weniger Straße - ohne Balken, ohne Beschnitt.
##
## Der MASSSTAB bleibt dabei fest: Persp.PPU_NEAR = Config.RENDER_W / VIEW_SPAN_NEAR
## (Basisbreite 640) - Figuren werden nicht größer. Alles, was die BILDBREITE meint
## (Bildmitte, Ränder, Viewports, Breitenschleifen, "ist im Bild"), liest View.W.
##
## View.setup() läuft einmal beim Start, VOR dem Aufbau von Szene/HUD/Kette; ein
## Wechsel (Einstellung "aspect", Fenstergröße) gilt ab dem nächsten Start.
## Ohne setup() gilt die Basisbreite 640 (Tests, Parität).

const BASE_W := Config.RENDER_W
const MIN_W := 400          # 10:9 - Retroid Pocket Classic (1240x1080 = 31:27) braucht 414
const MAX_W := 960

static var W := BASE_W
static var H := Config.RENDER_H
static var aspect_used := ""     # Einstellung, mit der setup() lief ("" = nie)


## "auto": Breite aus dem Fenster-Seitenverhältnis (gerade, 400..960);
## alles andere ("16:9"/"letterbox"): Basisbreite 640.
static func setup(aspect_setting: String, win_size: Vector2) -> void:
	aspect_used = aspect_setting
	if aspect_setting == "auto" and win_size.x >= 1.0 and win_size.y >= 1.0:
		W = clampi(int(round(H * win_size.x / win_size.y / 2.0)) * 2, MIN_W, MAX_W)
	else:
		W = BASE_W


## Breite des HUD-Ziels (HUD_SCALE x Bildbreite; 1280 bei 640).
static func hud_w() -> int:
	return W * Config.HUD_SCALE


## Fenstergröße, mit der das Spiel tatsächlich läuft: Auf dem Desktop setzt
## game._apply_display() das Fenster erst NACH dem Aufbau auf Vollbild bzw. die
## eingestellte Auflösung - deshalb diese statt der momentanen Größe. Mobil ist der
## Bildschirm fest (fallback = sichtbares Rechteck).
static func target_size(settings: Dictionary, fallback: Vector2) -> Vector2:
	if OS.has_feature("mobile") or DisplayServer.get_name() == "headless":
		return fallback
	if bool(settings.get("fullscreen", false)):
		return Vector2(DisplayServer.screen_get_size())
	var res: Variant = settings.get("resolution")
	if res is Array and (res as Array).size() == 2 and float(res[0]) > 0 and float(res[1]) > 0:
		return Vector2(float(res[0]), float(res[1]))
	return fallback
