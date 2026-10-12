"""Referenz zu tests/ell_test.gd: Ellipsen wie die Bodenpfuetzen, echter QPainter."""
import os
import random
import sys

from PyQt6.QtCore import QRectF, Qt
from PyQt6.QtGui import QColor, QGuiApplication, QImage, QPainter

app = QGuiApplication([])
out = sys.argv[1] if len(sys.argv) > 1 else "shots/ell_r.png"
W, H = 4000, 194
rng = random.Random(7)
im = QImage(W, H, QImage.Format.Format_ARGB32_Premultiplied)
im.fill(0)
p = QPainter(im)
p.setPen(Qt.PenStyle.NoPen)
rows = H
for i in range(200):
    r = rng.randint(3, rows - 2)
    pw = rng.uniform(24, 92) * (0.5 + r / rows)
    ph = max(3, int(rng.uniform(3.0, 7.0) * (0.6 + r / rows)))
    px_ = rng.uniform(0, W)
    p.setBrush(QColor(26, 34, 52, 70))
    p.drawEllipse(QRectF(px_, r, pw, ph))
p.end()
flat = QImage(W, H, QImage.Format.Format_RGB32)
flat.fill(QColor(0, 0, 0))
q = QPainter(flat)
q.drawImage(0, 0, im)
q.end()
os.makedirs(os.path.dirname(out), exist_ok=True)
flat.save(out)
print("ok")
