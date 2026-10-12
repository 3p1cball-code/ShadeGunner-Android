"""Vergrößert diff_<i>.png (Python | Godot | Abweichung) zum Ansehen: sprites_zoom.py <dir> <faktor> <i>..."""
import sys

from PyQt6.QtGui import QGuiApplication, QImage

app = QGuiApplication([])
d, f = sys.argv[1], int(sys.argv[2])
for n in sys.argv[3:]:
    im = QImage(f"{d}/diff_{n}.png")
    im.scaled(im.width() * f, im.height() * f).save(f"{d}/big_{n}.png")
