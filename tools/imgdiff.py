"""Pixelvergleich zweier PNGs: Anteil abweichender Pixel + Diff-Bild (rot = Abweichung)."""
import sys
import numpy as np
from PyQt6.QtGui import QGuiApplication, QImage
app = QGuiApplication([])
def arr(p):
    im = QImage(p).convertToFormat(QImage.Format.Format_RGB32)
    w, h = im.width(), im.height(); b = im.constBits(); b.setsize(im.sizeInBytes())
    return np.frombuffer(b, np.uint8).reshape(h, im.bytesPerLine() // 4, 4)[:, :w, :3][:, :, ::-1].astype(int)
a, b = arr(sys.argv[1]), arr(sys.argv[2])
d = np.abs(a - b).max(axis=2)
tol = int(sys.argv[4]) if len(sys.argv) > 4 else 8
bad = d > tol
print(f"abweichend (>{tol}): {bad.mean() * 100:.2f}%   mittlere Abw.: {d.mean():.2f}   max: {d.max()}")
if len(sys.argv) > 3:
    out = (b // 3).astype(np.uint8)
    out[bad] = [255, 40, 40]
    h, w = out.shape[:2]
    rgba = np.dstack([out[:, :, ::-1], np.full((h, w), 255, np.uint8)]).copy()
    QImage(rgba.data, w, h, w * 4, QImage.Format.Format_RGB32).copy().save(sys.argv[3])
