"""Referenz für tests/vehicles_test.gd: Fahrzeuge/Spinner/Hindernisse/headlight mit dem Original.

PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/vehicles_reference.py <outdir>
Schreibt cases.json, py_<i>.png (Bild), py_<i>_e.png (Leuchtbild), py_meta.json.
"""
import json
import os
import sys

from PyQt6.QtGui import QGuiApplication, QImage, QPainter

app = QGuiApplication([])
from shadegunner.render import vehicles  # noqa: E402

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
RIMS = [(150, 160, 190), (64, 210, 220), (224, 72, 150), (90, 96, 120)]
PPU = [0.5, 0.75, 1.0, 1.3, 1.75, 2.25]

cases = []
kinds = ["car", "taxi", "truck", "limo", "bike", "bus", "police"]
for ki, kind in enumerate(kinds):
    for j in range(4):
        cases.append(dict(t="v", kind=kind, seed=ki * 7 + j * 5 + 1, ppu=PPU[(ki + j * 2) % len(PPU)],
                          rim=RIMS[(ki + j) % len(RIMS)], d=1 if j % 2 == 0 else -1))
for police in (True, False):
    for far in (False, True):
        for j, ppx in enumerate((0.6, 1.1, 1.6)):
            cases.append(dict(t="s", ppx=ppx, police=police, far=far, d=1 if (j + far) % 2 == 0 else -1))
for oi, kind in enumerate(["barrier", "crates", "bins", "barrel", "vending"]):
    for j in range(3):
        cases.append(dict(t="o", kind=kind, seed=oi + j * 2, ppu=PPU[(oi + j * 3) % len(PPU)],
                          rim=RIMS[(oi + j) % len(RIMS)]))
for j, (d, ppu, ln, a) in enumerate(((1, 1.0, 150.0, 70), (-1, 0.7, 120.0, 90), (1, 1.6, 60.0, 50))):
    cases.append(dict(t="h", d=d, ppu=ppu, length=ln, a=a))


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
for i, c in enumerate(cases):
    m = {}
    if c["t"] == "v":
        img, em, ax, ay, ln = vehicles.vehicle_image(c["kind"], c["seed"], c["ppu"], c["rim"], c["d"])
        m = dict(ax=ax, ay=ay, extra=ln)
    elif c["t"] == "s":
        img, em, ax, aym, ayg = vehicles.spinner_image(c["ppx"], c["police"], c["d"], c["far"])
        m = dict(ax=ax, ay=ayg, extra=aym)
    elif c["t"] == "o":
        img, em, ax, ay = vehicles.obstacle_image(c["kind"], c["seed"], c["ppu"], c["rim"])
        m = dict(ax=ax, ay=ay, extra=0)
    else:
        img = QImage(160, 60, QImage.Format.Format_ARGB32_Premultiplied)
        img.fill(0)
        p = QPainter(img)
        x = 20.0 if c["d"] > 0 else 140.0
        vehicles.headlight(p, x + 0.3, 30.4, c["d"], c["ppu"], 44.6, c["length"], a=c["a"])
        p.end()
        em = None
        m = dict(ax=0, ay=0, extra=0)
    m.update(w=img.width(), h=img.height(), emit=em is not None)
    save(img, f"{out}/py_{i}.png")
    if em is not None:
        save(em, f"{out}/py_{i}_e.png")
    meta.append(m)


def js(v):
    if isinstance(v, (tuple, list)):
        return [js(x) for x in v]
    if isinstance(v, dict):
        return {k: js(x) for k, x in v.items()}
    return v


json.dump(dict(cases=js(cases)), open(f"{out}/cases.json", "w"), indent=1)
json.dump(meta, open(f"{out}/py_meta.json", "w"), indent=1)
print(len(cases), "Fälle ->", out)
