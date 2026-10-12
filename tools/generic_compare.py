"""Vergleicht py_<i>(_e).png mit gd_<i>(_e).png (premultipliziertes RGBA) + Meta (ax, ay, extra, w, h, emit).

python3 tools/generic_compare.py <outdir> [toleranz] [--diff]
"""
import json
import sys

import numpy as np
from PyQt6.QtGui import QGuiApplication, QImage

app = QGuiApplication([])
d = sys.argv[1]
tol = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 8
want_diff = "--diff" in sys.argv


def arr(p):
    im = QImage(p)
    if im.isNull():
        return None
    im = im.convertToFormat(QImage.Format.Format_RGBA8888)
    w, h = im.width(), im.height()
    b = im.constBits()
    b.setsize(im.sizeInBytes())
    return np.frombuffer(b, np.uint8).reshape(h, im.bytesPerLine() // 4, 4)[:, :w].astype(int)


def cmp(a, b, name):
    if a is None or b is None:
        return None
    if a.shape != b.shape:
        return None
    dd = np.abs(a - b).max(axis=2)
    bad = dd > tol
    if want_diff and bad.any():
        out = np.zeros((a.shape[0], a.shape[1] * 3, 4), np.uint8)
        out[:, :a.shape[1]] = a
        out[:, a.shape[1]:2 * a.shape[1]] = b
        m = out[:, 2 * a.shape[1]:]
        m[..., 3] = 255
        m[bad] = [255, 40, 40, 255]
        QImage(out.tobytes(), out.shape[1], out.shape[0], out.shape[1] * 4,
               QImage.Format.Format_RGBA8888).copy().save(f"{d}/diff_{name}.png")
    # nur Pixel zählen, die in einem der Bilder belegt sind (große leere Ränder verwässern sonst)
    used = (a[..., 3] > 0) | (b[..., 3] > 0)
    return bad.mean() * 100, bad.sum() / max(1, used.sum()) * 100


cases = json.load(open(f"{d}/cases.json"))["cases"]
pm = json.load(open(f"{d}/py_meta.json"))
gm = json.load(open(f"{d}/gd_meta.json"))
worst = 0.0
for i, c in enumerate(cases):
    r1 = cmp(arr(f"{d}/py_{i}.png"), arr(f"{d}/gd_{i}.png"), str(i))
    r2 = None
    if pm[i].get("emit") or gm[i].get("emit"):
        r2 = cmp(arr(f"{d}/py_{i}_e.png"), arr(f"{d}/gd_{i}_e.png"), f"{i}_e")
    a, b = pm[i], gm[i]
    mok = all(abs(float(a[k]) - float(b.get(k, -999))) < 1e-6 for k in a if k != "emit") and a["emit"] == b["emit"]
    desc = " ".join(f"{k}={v}" for k, v in c.items() if k not in ("rim",))
    worst = max(worst, 100.0 if r1 is None else r1[0], 0.0 if r2 is None else r2[0])
    f = lambda r: "FEHLT" if r is None else f"{r[0]:5.2f} ({r[1]:5.2f})"
    print(f"{i:>2} {desc:<52} Bild {f(r1)}  Emit {'-' if r2 is None and not a['emit'] else f(r2)}  "
          f"{'ok' if mok else 'META ' + str(a) + ' / ' + str(b)}")
print(f"schlechtester Wert: {worst:.2f} % (Toleranz {tol}; in Klammern: Anteil an belegten Pixeln)")
