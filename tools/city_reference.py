"""Referenz zu tests/city_test.gd: City Teil 1+2/3 mit echtem QPainter.
PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/city_reference.py <outdir>"""
import json
import os
import random
import sys

from PyQt6.QtCore import QRectF
from PyQt6.QtGui import QColor, QGuiApplication, QImage, QPainter

app = QGuiApplication([])
from shadegunner.render import city as cm  # noqa: E402

out = sys.argv[1] if len(sys.argv) > 1 else "shots/city_ref"
os.makedirs(out, exist_ok=True)
LENGTH, SEED = 3000.0, 12345
CAMS = [0.0, 800.0, 1600.0, 2400.0, 2900.0]


def save(name, img):
    w, h = img.width(), img.height()
    k = QImage(w, h, QImage.Format.Format_RGB32)
    k.fill(QColor(0, 0, 0))
    p = QPainter(k)
    p.drawImage(0, 0, img)
    p.end()
    k.save(os.path.join(out, name + ".png"))
    a = QImage(w, h, QImage.Format.Format_RGB32)
    src = img.convertToFormat(QImage.Format.Format_ARGB32)
    for y in range(h):
        for x in range(w):
            v = src.pixelColor(x, y).alpha()
            a.setPixelColor(x, y, QColor(v, v, v))
    a.save(os.path.join(out, name + "_a.png"))


def compose(c, cam):
    img = QImage(cm.W, cm.H, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(0)
    p = QPainter(img)
    c.sky and p.drawImage(0, 0, c.sky)
    c.far.draw(p, cam)
    c.mid.draw(p, cam)
    c.facade.draw(p, cam)
    c.draw_ground(p, cam)
    p.end()
    return img


shots, data = [], {}
for z in range(5):
    c = cm.City(z, LENGTH, SEED)
    shots.append((f"z{z}_sky", c.sky))
    for i, cl in enumerate(c.cloud_layers):
        shots.append((f"z{z}_clouds{i}", cl[0]))
    shots.append((f"z{z}_far", c.far.img))
    shots.append((f"z{z}_mid", c.mid.img))
    shots.append((f"z{z}_facade", c.facade.img))
    shots.append((f"z{z}_emit", c.facade_emit))
    shots.append((f"z{z}_ground", c.ground))
    for i, f in enumerate(c.fog_layers):
        shots.append((f"z{z}_fog{i}", f))
    shots.append((f"z{z}_bank", c.bank))
    shots.append((f"z{z}_cloud", c.cloud))
    for ci, cam in enumerate(CAMS):
        shots.append((f"z{z}_street{ci}", compose(c, cam)))
    data[f"z{z}"] = {
        "counts": {k: len(getattr(c, k)) for k in (
            "blinks", "flames", "billboards", "searchlights", "air", "signs", "lamps",
            "lanterns", "tvs", "vents", "holos", "ramen_spots", "manholes", "puddles")},
        "far": [c.far.lmin, c.far.width], "mid": [c.mid.lmin, c.mid.width],
        "gate": c.gate, "exit_L": c.exit_L, "g_wmin": c.g_wmin, "ground_y0": c.ground_y0,
        "holo_kinds": sorted(h["kind"] for h in c.holos),
        "rng": c.rng.random()}
r = random.Random(5)
s1 = cm._make_sign(r, cm.CYAN, "vertical")
s2 = cm._make_sign(r, cm.MAGENTA, "text", "SNAKE PIT")
s3 = cm._make_sign(r, cm.AMBER, "arrow")
s4 = cm._dragon_sign(r)
for k, nm in enumerate(("on", "off", "emit")):
    shots += [("sign_v_" + nm, s1[k]), ("sign_t_" + nm, s2[k]), ("sign_a_" + nm, s3[k]), ("dragon_" + nm, s4[k])]
shots.append(("refl_mid", cm.soft_reflection(shots[3][1])))
sg = cm.Sign(0, 0, s1[0], s1[1], s1[2], "buzz", 77, cm.CYAN)
lp = cm.Lamp(0, 0, 0, 0, cm.AMBER, 33, True)
data["lits"] = [[sg.lit(i * 0.137), lp.level(i * 0.137)] for i in range(200)]
for n, im in shots:
    save(n, im)
with open(os.path.join(out, "data.json"), "w") as f:
    json.dump(data, f)
print("fertig:", len(shots))
