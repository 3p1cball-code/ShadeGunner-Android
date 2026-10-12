#!/bin/bash
# Paritätstest HUD/Pixfont/FX: Python-Referenz + Godot + Pixelvergleich
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
mkdir -p $W/shots
PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 $W/tools/hud_reference.py $W/shots || exit 1
DISPLAY=${DISPLAY:-:0} timeout 300 $T/bin/godot --path $W --rendering-driver opengl3 --audio-driver Dummy res://tests/hud_test.tscn -- --out=$W/shots 2>&1 | grep -E "pixfont:|fx:|  |ERROR|hud_test" | grep -v "shader cache\|RIDs\|_free_rids"
cd $W/shots
for r in *_ref.png; do
  g=${r%_ref.png}_godot.png
  printf "%-22s " "${r%_ref.png}"
  QT_QPA_PLATFORM=offscreen python3 $W/tools/imgdiff.py $r $g ${r%_ref.png}_diff.png ${TOL:-8}
done
