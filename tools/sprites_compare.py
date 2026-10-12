"""Vergleicht py_<i>.png mit gd_<i>.png (premultipliziertes RGBA, Toleranz je Kanal) + Meta.

python3 tools/sprites_compare.py <outdir> [toleranz] [--diff]
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
        return None, "fehlt"
    if a.shape != b.shape:
        return None, f"Größe {a.shape} vs {b.shape}"
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
    return bad.mean() * 100, f"max {dd.max()}"


cases = json.load(open(f"{d}/cases.json"))
pm = json.load(open(f"{d}/py_meta.json"))
gm = json.load(open(f"{d}/gd_meta.json"))
looks = cases["looks"]
worst = 0.0
print(f"{'#':>2} {'Look':<16} {'Anim':<7} {'h':>5} {'f':>2} {'rim':<4} {'fog':>4}  {'Bild%':>6} {'Emit%':>6}  Meta")
for i, c in enumerate(cases["cases"]):
    lk = looks[c["look"]]
    p1, s1 = cmp(arr(f"{d}/py_{i}.png"), arr(f"{d}/gd_{i}.png"), str(i))
    pe = f"{d}/py_{i}_e.png"
    p2 = None
    if pm[i]["emit"] or gm[i]["emit"]:
        p2, _s = cmp(arr(pe), arr(f"{d}/gd_{i}_e.png"), f"{i}_e")
    a, b = pm[i], gm[i]
    md = max(abs(a[k][j] - b[k][j]) for k in ("eye", "hand", "head") for j in (0, 1))
    mok = (a["ax"], a["ay"], a["w"], a["h"], a["emit"]) == (b["ax"], b["ay"], b["w"], b["h"], b["emit"]) \
        and md < 1e-3 and abs(a["head_top"] - b["head_top"]) < 1e-6
    worst = max(worst, p1 if p1 is not None else 100.0, p2 or 0.0)
    name = f"{lk['outfit']}/{lk['head']}"
    print(f"{i:>2} {name:<16} {c['anim'] + str(c['frame']):<7} {c['h']:>5} {c['facing']:>2} "
          f"{'ja' if c['rim'] else '-':<4} {c['fog']:>4}  {p1 if p1 is None else round(p1, 2):>6} "
          f"{'-' if p2 is None else round(p2, 2):>6}  {'ok' if mok else 'ABW ' + str(round(md, 4))} {s1}")
print(f"schlechtester Wert: {worst:.2f} % (Toleranz {tol})")
