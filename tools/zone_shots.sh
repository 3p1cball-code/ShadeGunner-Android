#!/bin/bash
# Spiel-Screenshots (mit Dither/CRT/HUD) je Zone an einer Weltposition -> shots/zones/.
#   tools/zone_shots.sh [zone:x[:frames] ...]      z. B. 4:3700 2:1990
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_CONFIG_HOME=$T/godotconfig DISPLAY=${DISPLAY:-:0}
O=$W/shots/zones
mkdir -p $O
[ $# -eq 0 ] && set -- 0:600 1:900 2:1000 3:900 4:1500 4:3640
D=$T/shotdata/zones
mkdir -p $D/godot/app_userdata/ShadeGunner
printf '{"music":0.0,"sfx":0.0,"fullscreen":false,"resolution":[1280,720],"aspect":"auto","touch":"aus","lang":"de"}\n' \
  > $D/godot/app_userdata/ShadeGunner/settings.json
for spec in "$@"; do
  IFS=: read z x f <<< "$spec"
  XDG_DATA_HOME=$D timeout 180 $T/bin/godot --path $W --rendering-driver opengl3 --audio-driver Dummy -- \
    --shot=$O/z${z}_x${x}.png --frames=${f:-120} --win=1280x720 --zone=$z --x=$x 2>&1 \
    | grep -E "SCRIPT ERROR|^ERROR" | grep -v "RIDs" | head -3
  echo "z$z x$x -> $O/z${z}_x${x}.png"
done
