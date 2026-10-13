#!/bin/bash
# Regressionslauf (W=640 muss unverändert bleiben): Sim-Parität, Szene, City, QP, HUD.
#   tools/run_view_tests.sh [sim] [scene] [city] [qp] [hud]   (ohne Argument: alle)
T=/home/alex/.local/opt/shadegunner-tools
W=$(cd "$(dirname "$0")/.." && pwd)
export XDG_DATA_HOME=$T/godotdata XDG_CONFIG_HOME=$T/godotconfig
export DISPLAY=${DISPLAY:-:0}
G="$T/bin/godot"
O=$W/shots/vt
mkdir -p $O
[ -f $W/shots/.gdignore ] || touch $W/shots/.gdignore
want() { [ $# -eq 0 ] && return 0; [ -z "$SEL" ] || [[ " $SEL " == *" $1 "* ]]; }
SEL="$*"
PYR="env PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3"
# Vergleich mit einem früheren Godot-Lauf (shots/base, vor den Änderungen): exakt gleich?
B=$W/shots/base
same() {  # same <neu> <alt> : zählt Bilder mit mind. einem abweichenden Pixel (Toleranz 0)
  [ -e "$2" ] || return 0
  $PYR - "$1" "$2" <<'EOF'
import sys, glob, os
from PyQt6.QtGui import QGuiApplication, QImage
app = QGuiApplication([])
a, b = sys.argv[1], sys.argv[2]
fs = sorted(glob.glob(a)) if "*" in a else [a]
n = bad = 0
for f in fs:
    g = os.path.join(b, os.path.basename(f)) if os.path.isdir(b) else b
    if not os.path.exists(g): continue
    x, y = QImage(f).convertToFormat(QImage.Format.Format_ARGB32), QImage(g).convertToFormat(QImage.Format.Format_ARGB32)
    n += 1
    if x != y: bad += 1; print("    anders als vorher:", os.path.basename(f))
print(f"  gegen Stand vorher: {n - bad}/{n} Bilder bitgleich")
EOF
}
avg() { awk '/abweichend/{gsub("%","",$3); s+=$3; n++; if($3>m)m=$3} END{printf "  Mittel %.2f %%  max %.2f %%  (%d Bilder)\n", s/n, m, n}'; }

if want sim; then
  echo "== sim_parity"
  timeout 900 $G --headless --path $W --script res://tests/test_sim_parity.gd 2>&1 | grep -v "^\s*$" | tail -4
  timeout 300 $G --headless --path $W --script res://tests/test_sim.gd 2>&1 | grep -iE "ok|fail|bestanden|/" | tail -2
fi
if want scene; then
  echo "== scene"
  [ -f $O/scene/py_z0_c0.png ] || $PYR $W/tools/scene_reference.py $O/scene >/dev/null
  timeout 600 $G --path $W --rendering-driver opengl3 --audio-driver Dummy res://tests/scene_test.tscn -- --out=$O/scene >/dev/null 2>&1
  for p in $O/scene/py_*.png; do g=${p/py_/gd_}; $PYR $W/tools/imgdiff.py $p $g; done | avg
  same "$O/scene/gd_*.png" $B/scene
fi
if want city; then
  echo "== city"
  [ -f $O/city_ref/data.json ] || $PYR $W/tools/city_reference.py $O/city_ref >/dev/null
  timeout 600 $G --path $W --rendering-driver opengl3 --audio-driver Dummy res://tests/city_test.tscn -- --out=$O/city_gd 2>&1 | grep -iE "data|abweich|mismatch|fehler" | head -5
  python3 - $O/city_ref/data.json $O/city_gd/data.json <<'EOF'
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:3])
bad = []
def d(x, y, p=""):
    if isinstance(x, dict):
        for k in x:
            d(x[k], y.get(k) if isinstance(y, dict) else None, p + "/" + k)
    elif isinstance(x, list):
        if not isinstance(y, list) or len(x) != len(y): bad.append(p); return
        for i, (u, v) in enumerate(zip(x, y)): d(u, v, "%s[%d]" % (p, i))
    elif isinstance(x, (int, float)) and isinstance(y, (int, float)):
        if abs(x - y) > 1e-6 * max(1.0, abs(x)): bad.append(p)
    elif x != y: bad.append(p)
d(a, b)
print("  data.json: %s" % ("gleich (Zahlen 1e-6)" if not bad else "%d Abweichungen, z.B. %s" % (len(bad), bad[:3])))
EOF
  for p in $O/city_ref/*.png; do $PYR $W/tools/imgdiff.py $p $O/city_gd/$(basename $p); done | avg
  same "$O/city_gd/*.png" $B/city_gd
fi
if want qp; then
  echo "== qp"
  [ -f $O/qp_ref.png ] || $PYR $W/tools/qp_reference.py $O/qp_ref.png >/dev/null
  timeout 300 $G --path $W --rendering-driver opengl3 --audio-driver Dummy res://tests/qp_test.tscn -- --out=$O/qp_godot.png >/dev/null 2>&1
  printf "  "; $PYR $W/tools/imgdiff.py $O/qp_ref.png $O/qp_godot.png
  same $O/qp_godot.png $B/qp_godot.png
fi
if want hud; then
  echo "== hud"
  bash $W/tools/run_hud_test.sh 2>&1 | grep -E "^[a-z_0-9]+ +abweich|fx:|pixfont:" | awk '/fx:|pixfont:/{print "  " $0; next} {gsub("%","",$4); n++; if($1 ~ /settings/){if($4>ms)ms=$4} else if($1 == "fx"){fx=$4} else if($4>m){m=$4;w=$1}} END{printf "  %d Bilder: HUD max %.2f %% (%s), fx %.2f %%, Einstellungen max %.2f %% (Port hat mehr Zeilen als Python)\n", n, m, w, fx, ms}'
  same "$W/shots/*_godot.png" $B/hud
fi
