#!/bin/bash
# Paritätstest Figuren: Python-Referenz, Godot, Vergleich. Aufruf: tools/sprites_run.sh [--diff] [godot-args]
set -e
T=/home/alex/.local/opt/shadegunner-tools
O=$T/out/sprites
cd "$(dirname "$0")/.."
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
mkdir -p $O
[ -f $O/py_meta.json ] || PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/sprites_reference.py $O
DISPLAY=${DISPLAY:-:0} timeout 120 $T/bin/godot --path . --rendering-driver opengl3 --audio-driver Dummy \
  res://tests/sprites_test.tscn -- --dir=$O "${@:2}" 2>&1 | grep -iE "error|sprites_test" || true
QT_QPA_PLATFORM=offscreen python3 tools/sprites_compare.py $O 8 $1
