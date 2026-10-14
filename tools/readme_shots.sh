#!/bin/bash
# README-Screenshots (englisch) aus dem echten Spiel -> screenshots/.
#   tools/readme_shots.sh
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_CONFIG_HOME=$T/godotconfig DISPLAY=${DISPLAY:-:0}
O=$W/screenshots
mkdir -p $O
shot() {   # name groesse touch argumente...
  local name=$1 size=$2 touch=$3; shift 3
  local w=${size%x*} h=${size#*x}
  local D=$T/shotdata/readme_${size}_${touch}
  mkdir -p $D/godot/app_userdata/ShadeGunner
  printf '{"music":0.0,"sfx":0.0,"fullscreen":false,"resolution":[%d,%d],"aspect":"auto","touch":"%s","lang":"en","quality":"hoch","reflections":true}\n' \
    $w $h $touch > $D/godot/app_userdata/ShadeGunner/settings.json
  XDG_DATA_HOME=$D timeout 180 $T/bin/godot --path $W --rendering-driver opengl3 --audio-driver Dummy -- \
    --shot=$O/$name.png --win=$size "$@" 2>&1 | grep -E "SCRIPT ERROR" | head -3
  echo "$name ($size)"
}
shot menu      1280x720 aus --shot-mode=title --frames=200
shot settings  1280x720 aus --shot-mode=settings --settings-sel=2 --frames=120
shot level0    1280x720 aus --seed=1000 --zone=0 --x=600  --frames=240
shot level1    1280x720 aus --seed=1000 --zone=1 --x=1000 --frames=240
shot level2    1280x720 aus --seed=1000 --zone=2 --x=1000 --frames=240
shot level3    1280x720 aus --seed=1000 --zone=3 --x=900  --frames=240
shot level4    1280x720 aus --seed=1000 --zone=4 --x=1500 --frames=240
shot roy       1280x720 aus --seed=1000 --zone=4 --x=3600 --frames=240
shot phone     1600x720 an  --seed=1000 --zone=2 --x=1300 --frames=240
shot handheld  1280x960 an  --seed=1000 --zone=0 --x=900  --frames=240
