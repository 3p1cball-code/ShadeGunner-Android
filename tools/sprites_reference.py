"""Referenz für tests/sprites_test.gd: Figuren mit dem Original (render/sprites.py).

PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/sprites_reference.py <outdir>
Schreibt <outdir>/cases.json (Looks + Parameter) und je Fall py_<i>.png / py_<i>_e.png
(premultiplizierte RGBA-Bytes unverändert) sowie py_meta.json.
"""
import json
import os
import random
import sys

from PyQt6.QtGui import QGuiApplication, QImage

app = QGuiApplication([])
from shadegunner.render import sprites  # noqa: E402

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = random.Random(1234)


def look(uid, **kw):
    lk = sprites.random_look(rng, uid, rain=0.6)
    lk.update(kw)
    return lk


# Looks: alle Mantelformen und Köpfe, Schirm flach/Kuppel, LED, Visier, Maske, Zigarette, Taschen, alt
LOOKS = [
    look(0, outfit="trench", head="short", umbrella=None, collar=True, bag=None, led=False, cig=False),
    look(1, outfit="long", head="fedora", umbrella=(64, 210, 220), umb_style="flat", bag="briefcase"),
    look(2, outfit="cloak", head="hood", umbrella=(224, 72, 150), umb_style="bubble", led=True),
    look(3, outfit="dress", head="bun", umbrella=None, bag="bag", mask=True),
    look(4, outfit="robe", head="conical", umbrella=None, cig=True),
    look(5, outfit="jacket", head="visor", umbrella=None, led=True, bag="backpack"),
    look(6, outfit="hoodie", head="hood", umbrella=(255, 138, 44), umb_style="flat"),
    look(7, outfit="vest", head="mohawk", umbrella=None, cig=True, mask=False),
    look(8, outfit="suit", head="cap", umbrella=None, bag="briefcase"),
    look(9, outfit="overall", head="beanie", umbrella=None, led=True),
    look(10, outfit="trench", head="ponytail", umbrella=(220, 230, 255), umb_style="bubble", old=True),
    look(11, outfit="long", head="afro", umbrella=None, old=True, hair=(170, 172, 180)),
    look(12, outfit="jacket", head="bald", umbrella=None, bag=True),
    look(13, outfit="dress", head="long", umbrella=(122, 74, 168), umb_style="flat", cig=True),
    dict(sprites.PLAYER_LOOK),
]
ANIM_FRAMES = [("idle", 0), ("idle", 2), ("walk", 1), ("walk", 5), ("run", 2), ("panic", 3), ("die", 2),
               ("die", 5), ("die", 8), ("aim", 0), ("shoot", 0), ("shoot", 1), ("scan", 1), ("hurt", 0),
               ("punch", 1), ("cower", 1), ("jump", 0), ("duck", 1), ("hands", 0), ("talk", 1)]
HEIGHTS = [20, 27.4, 34, 41, 48, 55.5, 63, 72, 84, 96, 110]
RIMS = [None, (64, 210, 220), (224, 72, 150), (255, 138, 44)]
FOGS = [((0, 0, 0), 0.0), ((18, 22, 38), 0.25), ((34, 40, 66), 0.5), ((52, 60, 96), 0.12)]

cases = []
i = 0
for li, lk in enumerate(LOOKS):
    for j in range(3):
        anim, frame = ANIM_FRAMES[(li * 3 + j) % len(ANIM_FRAMES)]
        rim = RIMS[(li + j) % len(RIMS)]
        fog_rgb, fog = FOGS[(li * 2 + j) % len(FOGS)]
        cases.append(dict(look=li, anim=anim, frame=frame, h=HEIGHTS[(li * 3 + j * 4) % len(HEIGHTS)],
                          facing=1 if (li + j) % 2 == 0 else -1, rim=rim, rim_side=1 if j != 1 else -1,
                          fog_rgb=fog_rgb, fog=fog))
        i += 1


def save(img, path):
    img = img.convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
    w, h = img.width(), img.height()
    b = img.constBits()
    b.setsize(img.sizeInBytes())
    raw = bytes(b)
    # BGRA (premultipliziert, little endian) -> RGBA unverändert als PNG
    rgba = bytearray(len(raw))
    rgba[0::4], rgba[1::4], rgba[2::4], rgba[3::4] = raw[2::4], raw[1::4], raw[0::4], raw[3::4]
    QImage(bytes(rgba), w, h, img.bytesPerLine(), QImage.Format.Format_RGBA8888).copy().save(path)


meta = []
for i, c in enumerate(cases):
    img, emit, ax, ay, m = sprites.get(LOOKS[c["look"]], c["anim"], c["frame"], c["h"], c["facing"], c["rim"],
                                       c["rim_side"], c["fog_rgb"], c["fog"])
    save(img, f"{out}/py_{i}.png")
    if emit is not None:
        save(emit, f"{out}/py_{i}_e.png")
    meta.append(dict(w=img.width(), h=img.height(), ax=ax, ay=ay, emit=emit is not None,
                     eye=list(m["eye"]), hand=list(m["hand"]), head=list(m["head"]), head_top=m["head_top"]))


def js(v):
    if isinstance(v, tuple):
        return [js(x) for x in v]
    if isinstance(v, dict):
        return {k: js(x) for k, x in v.items()}
    if isinstance(v, list):
        return [js(x) for x in v]
    return v


json.dump(dict(looks=js(LOOKS), cases=js(cases)), open(f"{out}/cases.json", "w"), indent=1)
json.dump(meta, open(f"{out}/py_meta.json", "w"), indent=1)
print(len(cases), "Fälle ->", out)
