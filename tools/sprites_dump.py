"""Pixel-Dump zweier Bilder (Python/Godot) als Hex-Raster: sprites_dump.py <dir> <i> [y0 y1 x0 x1] [_e]"""
import sys

from PyQt6.QtGui import QGuiApplication, QImage

app = QGuiApplication([])
d, i = sys.argv[1], sys.argv[2]
suf = sys.argv[7] if len(sys.argv) > 7 else ""
r = [int(v) for v in sys.argv[3:7]] if len(sys.argv) > 6 else None
for pre in ("py", "gd"):
    im = QImage(f"{d}/{pre}_{i}{suf}.png").convertToFormat(QImage.Format.Format_RGBA8888)
    y0, y1, x0, x1 = r or (0, im.height(), 0, im.width())
    print(pre, im.width(), im.height())
    for y in range(y0, min(y1, im.height())):
        row = []
        for x in range(x0, min(x1, im.width())):
            c = im.pixelColor(x, y)
            row.append("  .   " if c.alpha() == 0 else f"{c.red() >> 4:x}{c.green() >> 4:x}{c.blue() >> 4:x}{c.alpha() >> 4:x} ")
        print(f"{y:3} " + "".join(row))
