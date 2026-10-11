"""Exportiert alle Konstanten/Tabellen des Python-Originals als GDScript.

Statt Tabellen abzutippen, werden sie aus den echten Python-Modulen gelesen:
jede GROSSGESCHRIEBENE Modulvariable mit literalem Wert (Zahl, String, Liste,
Tupel, Dict, None, Bool) wird zu einer `const` in einer eigenen Klasse.

    python3 tools/export_data.py /home/alex/ShadeGunner

Erzeugt src/data/d_<modul>.gd (class_name D<Modul>) und src/config.gd (Config).
Tupel werden zu Arrays, Dicts zu Dictionaries; int bleibt int, float bleibt float.
"""
import importlib
import math
import os
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/home/alex/ShadeGunner"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
sys.path.insert(0, SRC)
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

MODULES = [
    # (Modul, Klassenname, Datei)
    ("shadegunner.config", "Config", "config.gd"),
    ("shadegunner.sim", "DSim", "data/d_sim.gd"),
    ("shadegunner.detection", "DDetection", "data/d_detection.gd"),
    ("shadegunner.procgen", "DProcgen", "data/d_procgen.gd"),
    ("shadegunner.hud", "DHud", "data/d_hud.gd"),
    ("shadegunner.audio", "DAudio", "data/d_audio.gd"),
    ("shadegunner.i18n", "DI18n", "data/d_i18n.gd"),
    ("shadegunner.save", "DSave", "data/d_save.gd"),
    ("shadegunner.settings", "DSettings", "data/d_settings.gd"),
    ("shadegunner.render.scene", "DScene", "data/d_scene.gd"),
    ("shadegunner.render.city", "DCity", "data/d_city.gd"),
    ("shadegunner.render.vehicles", "DVehicles", "data/d_vehicles.gd"),
    ("shadegunner.render.holo", "DHolo", "data/d_holo.gd"),
    ("shadegunner.render.sprites", "DSprites", "data/d_sprites.gd"),
    ("shadegunner.render.pixfont", "DPixfont", "data/d_pixfont.gd"),
    ("shadegunner.render.shaders", "DShaders", "data/d_shaders.gd"),
]

# Diese Namen sind Code/Laufzeitobjekte, keine Daten
SKIP = {"PLUS", "OVER", "ASCII_VERT", "BAYER_FRAG", "CRT_PERSIST_FRAG", "CRT_FOCUS_FRAG",
        "CRT_BLUR_FRAG", "CRT_FRAG", "K"}


# private Tabellen, die echte Daten sind (Laufzeit-Caches wie _CACHE bleiben draußen)
PRIVATE_DATA = {"_RAW", "_KP"}


class Unsupported(Exception):
    pass


def lit(v, ind=0):
    pad = "\t" * (ind + 1)
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isinf(v):
            return "INF" if v > 0 else "-INF"
        r = repr(v)
        if "e" in r or "E" in r:
            return r if "." in r.split("e")[0].split("E")[0] else r.replace("e", ".0e").replace("E", ".0E")
        return r if "." in r else r + ".0"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, (list, tuple, range)):
        items = [lit(x, ind + 1) for x in v]
        one = "[" + ", ".join(items) + "]"
        if len(one) < 100:
            return one
        return "[\n" + ",\n".join(pad + x for x in items) + ",\n" + "\t" * ind + "]"
    if isinstance(v, (set, frozenset)):
        return lit(sorted(v), ind)
    if isinstance(v, dict):
        items = [f"{lit(k, ind + 1)}: {lit(x, ind + 1)}" for k, x in v.items()]
        one = "{" + ", ".join(items) + "}"
        if len(one) < 100:
            return one
        return "{\n" + ",\n".join(pad + x for x in items) + ",\n" + "\t" * ind + "}"
    raise Unsupported(type(v).__name__)


def export(mod_name, cls, rel):
    m = importlib.import_module(mod_name)
    lines = [f"class_name {cls}", "extends RefCounted",
             f"## AUTOMATISCH ERZEUGT aus {mod_name} (tools/export_data.py) - nicht von Hand ändern.", ""]
    n = 0
    for name in sorted(vars(m)):
        if not name.isupper() or name.startswith("_") or name in SKIP:
            continue
        if not name[0].isalpha() and name[0] != "_":
            continue
        v = getattr(m, name)
        try:
            body = lit(v)
        except Unsupported as exc:
            lines.append(f"# übersprungen: {name} ({exc})")
            continue
        lines.append(f"const {name} = {body}")
        n += 1
    # private Tabellen mit führendem Unterstrich, die Daten sind (z. B. pixfont._RAW)
    for name in sorted(vars(m)):
        if name in PRIVATE_DATA:
            v = getattr(m, name)
            try:
                body = lit(v)
            except Unsupported:
                continue
            lines.append(f"const {name} = {body}")
            n += 1
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"{rel:28s} {n:4d} Konstanten")


if __name__ == "__main__":
    for mod, cls, rel in MODULES:
        export(mod, cls, rel)
