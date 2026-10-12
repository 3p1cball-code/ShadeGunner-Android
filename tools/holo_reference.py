"""Referenz für tests/holo_test.gd: holo.pose_at / render mit dem Original.

PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/holo_reference.py <outdir>
Je Fall: py_<i>_tex.png (interne Hologramm-Textur), py_<i>.png (Szene p), py_<i>_e.png (Leuchtschicht e).
"""
import json
import os
import sys

from PyQt6.QtGui import QGuiApplication, QImage, QPainter

app = QGuiApplication([])
from shadegunner.render import holo  # noqa: E402

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
W, H = 240, 260
CASES = []
for i, (seed, h, t, mirror, refl, col) in enumerate([
        (3, 40.0, 0.3, False, 0.0, (64, 210, 220)),
        (3, 75.0, 2.0002, False, 0.0, (64, 210, 220)),      # Glitch
        (11, 120.0, 3.1, True, 0.35, (224, 72, 150)),
        (3, 75.0, 5.0005, False, 0.0, (122, 74, 168)),      # Aussetzer
        (11, 96.0, 7.4, False, 0.35, (64, 210, 220)),
        (5, 58.0, 9.0, True, 0.0, (255, 138, 44)),
        (7, 150.0, 11.2, False, 0.2, (224, 72, 150)),
        (11, 88.0, 4.05, False, 0.0, (214, 220, 226))]):
    CASES.append(dict(seed=seed, h=h, t=t, mirror=mirror, reflect=refl, col=list(col), x=120.3, base=210.6))


def save(img, path):
    img = img.convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
    w, h = img.width(), img.height()
    b = img.constBits()
    b.setsize(img.sizeInBytes())
    raw = bytes(b)
    rgba = bytearray(len(raw))
    rgba[0::4], rgba[1::4], rgba[2::4], rgba[3::4] = raw[2::4], raw[1::4], raw[0::4], raw[3::4]
    QImage(bytes(rgba), w, h, img.bytesPerLine(), QImage.Format.Format_RGBA8888).copy().save(path)


meta = []
for i, c in enumerate(CASES):
    holo._TMP.clear()
    img = QImage(W, H, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(0xFF000000)       # deckender Grund wie in der Szene (Plus addiert dann nur Farbe)
    em = QImage(W, H, QImage.Format.Format_ARGB32_Premultiplied)
    em.fill(0xFF000000)
    p, e = QPainter(img), QPainter(em)
    holo.render(p, e, c["x"], c["base"], c["h"], c["col"], c["t"], c["seed"], c["reflect"], 0.62, c["mirror"])
    p.end()
    e.end()
    save(img, f"{out}/py_{i}.png")
    save(em, f"{out}/py_{i}_e.png")
    tex = list(holo._TMP.values())[0][1]
    save(tex, f"{out}/py_{i}_tex.png")
    meta.append(dict(ax=0, ay=0, extra=0, w=W, h=H, emit=True))

# pose_at an vielen Zeitpunkten (Zahlenvergleich)
poses = []
for k in range(60):
    t = k * 0.437 - 3.0
    pts, th = holo.pose_at(t)
    poses.append(dict(t=t, th=th, pts={key: list(v) for key, v in pts.items()}))

json.dump(dict(cases=CASES), open(f"{out}/cases.json", "w"), indent=1)
json.dump(meta, open(f"{out}/py_meta.json", "w"), indent=1)
json.dump(poses, open(f"{out}/py_poses.json", "w"))
print(len(CASES), "Fälle ->", out)
