#!/bin/bash
# Screenshots des echten Spiels bei mehreren Fenstergrößen (aspect:auto) -> shots/view/.
# Jede Größe bekommt ein eigenes Benutzerdaten-Verzeichnis mit passender "resolution"
# (game._apply_display() setzt das Fenster sonst auf die gespeicherte Auflösung zurück,
# --win allein reicht deshalb nicht).
#   tools/view_shots.sh [WxH[:modus] ...]     modus = play (Default) | pause | settings
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_CONFIG_HOME=$T/godotconfig DISPLAY=${DISPLAY:-:0}
O=$W/shots/view
mkdir -p $O
[ $# -eq 0 ] && set -- 1280x720 1280x592 1280x548 1280x520 960x720 1280x520:pause 960x720:pause 1280x520:settings 960x720:settings
for spec in "$@"; do
  size=${spec%%:*}; mode=${spec#*:}; [ "$mode" = "$spec" ] && mode=play
  w=${size%x*}; h=${size#*x}
  D=$T/shotdata/$size
  mkdir -p $D/godot/app_userdata/ShadeGunner
  printf '{"music":0.0,"sfx":0.0,"fullscreen":false,"resolution":[%d,%d],"aspect":"auto","touch":"%s","lang":"de"}\n' $w $h ${TOUCH:-aus} \
    > $D/godot/app_userdata/ShadeGunner/settings.json
  args="--shot=$O/${size}_${mode}.png --frames=${FRAMES:-240} --win=$size --set=aspect:auto"
  [ "$mode" = play ] && args="$args --auto" || args="$args --shot-mode=$mode"
  XDG_DATA_HOME=$D timeout 180 $T/bin/godot --path $W --rendering-driver opengl3 --audio-driver Dummy -- $args 2>&1 \
    | grep -E "SCRIPT ERROR|^ERROR" | grep -v "RIDs" | head -3
  python3 - "$O/${size}_${mode}.png" "$size" <<'EOF'
import sys
from PyQt6.QtGui import QGuiApplication, QImage
app = QGuiApplication([])
im = QImage(sys.argv[1])
w, h = im.width(), im.height()
def dark_col(x): return all(max(im.pixelColor(x, y).getRgb()[:3]) < 14 for y in range(0, h, 7))
def dark_row(y): return all(max(im.pixelColor(x, y).getRgb()[:3]) < 14 for x in range(0, w, 7))
l = next((x for x in range(w) if not dark_col(x)), w); r = next((x for x in range(w - 1, -1, -1) if not dark_col(x)), -1)
t = next((y for y in range(h) if not dark_row(y)), h); b = next((y for y in range(h - 1, -1, -1) if not dark_row(y)), -1)
print(f"{sys.argv[2]:>9} -> Bild {w}x{h}, dunkler Rand links {l} rechts {w-1-r} oben {t} unten {h-1-b} px")
EOF
done
