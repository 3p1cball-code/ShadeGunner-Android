#!/bin/bash
# HUD-Layoutprobe bei anderen Bildbreiten: rendert alle HUD-Fälle aus tests/hud_cases.json
# mit View.W = <w> nach shots/hud_w<w>/ (kein Paritätsvergleich - zum Ansehen).
#   tools/hud_layout.sh 480 886 960
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig DISPLAY=${DISPLAY:-:0}
for w in "$@"; do
  mkdir -p $W/shots/hud_w$w
  timeout 300 $T/bin/godot --path $W --rendering-driver opengl3 --audio-driver Dummy res://tests/hud_test.tscn -- --out=$W/shots/hud_w$w --view-w=$w 2>&1 | grep -E "SCRIPT ERROR|ERROR:" | grep -v "RIDs\|_free_rids" | head -5
  echo "w=$w: $(ls $W/shots/hud_w$w/hud_*_godot.png 2>/dev/null | wc -l) Bilder -> shots/hud_w$w"
done
