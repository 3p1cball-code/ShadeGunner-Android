#!/bin/bash
# Paritätstest Fahrzeuge: Python-Referenz (einmal), Godot, Vergleich. Aufruf: tools/holo_run.sh [--diff]
T=/home/alex/.local/opt/shadegunner-tools
O=$T/out/holo
cd "$(dirname "$0")/.."
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
mkdir -p $O
[ -f $O/py_meta.json ] || PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/holo_reference.py $O
rm -f $O/gd_* $O/diff_*
DISPLAY=${DISPLAY:-:0} timeout 100 $T/bin/godot --path . --rendering-driver opengl3 --audio-driver Dummy \
  res://tests/holo_test.tscn -- --dir=$O "${@:2}" 2>&1 | grep -iE "error|holo_test|pose_at" -A2
QT_QPA_PLATFORM=offscreen python3 tools/generic_compare.py $O 8 $1
