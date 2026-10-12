"""Referenz zu tests/scene_test.gd: Scene.frame(...) des Python-Originals mit echtem QPainter.

PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen \
    python3 tools/scene_reference.py <outdir>

Erzeugt py_z<zone>_c<cam>.png. Beide Seiten bauen dasselbe sim.World (Seed/Zone),
lassen es STEPS Schritte mit leerer Eingabe laufen und rendern dann dieselben
Kamerapositionen ueber dieselbe (eine) Scene - t, Nebel, Spinner wachsen mit.
"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtGui import QColor, QGuiApplication, QImage, QPainter  # noqa: E402

app = QGuiApplication([])

from shadegunner import sim  # noqa: E402
from shadegunner.render.scene import Scene  # noqa: E402

SEED = 12345
DT = 1.0 / 60.0
STEPS = 300
CAMS = [-1500.0, 0.0, 1500.0]

out = sys.argv[1] if len(sys.argv) > 1 else "shots/scene_ref"
os.makedirs(out, exist_ok=True)

names = []
sc = Scene()
for z in range(5):
    run = sim.Run(SEED)
    run.zone_index = z
    w = sim.World(run, SEED, z)
    for _ in range(STEPS):
        w.update(DT, {})
        w.events.clear()
    base = w.camera_x
    for ci, off in enumerate(CAMS):
        w.camera_x = max(0.0, min(w.length, base + off))
        img = sc.frame(w, DT)
        k = QImage(img.width(), img.height(), QImage.Format.Format_RGB32)
        k.fill(QColor(0, 0, 0))
        p = QPainter(k)
        p.drawImage(0, 0, img)
        p.end()
        nm = "z%d_c%d" % (z, ci)
        k.save(os.path.join(out, "py_" + nm + ".png"))
        names.append(nm)

open(os.path.join(out, "cases.txt"), "w").write("\n".join(names))
print("scene_reference:", len(names), "Bilder ->", out)
