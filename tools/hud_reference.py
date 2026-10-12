"""Referenzbilder/-daten für den HUD-/Pixfont-/FX-Port (echtes Python-Original).

PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen python3 tools/hud_reference.py <outdir>
Schreibt: pixfont_ref.png, hud_<fall>_<lang>_ref.png, fx_ref.png, tests/hud_cases.json, tests/fx_ref.json
"""
import json
import os
import random
import sys

from PyQt6.QtGui import QColor, QGuiApplication, QImage, QPainter

app = QGuiApplication([])

from shadegunner import i18n, persp  # noqa: E402
from shadegunner.hud import HUD  # noqa: E402
from shadegunner.render import fx as fxmod, pixfont  # noqa: E402
from shadegunner.sim import World  # noqa: E402

OUT = sys.argv[1]
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BG = (40, 44, 70)
os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------- Pixfont
PIX_TEXTS = [
    "SHADEGUNNER", "Integrität: ÄÖÜ äöü ß", "0123456789 +-/()%", "SEKTOR 3/5  KETTE X4",
    "→ FAHRZEUG", "FAHRZEUG ←", "♥♥♡ ▮▮▯ ✓ ✗ ▲▼ ◆", "\"ALLE RUNTER!\" [OK] #0042 *&_=<>;:,.'|·",
    "Kleinbuchstaben werden gross", "TRÄNEN IM REGEN.", "P(REP)  73%", "unbekannt: ~@€",
]


def pix_cases():
    cases = []
    y = 6
    for i, s in enumerate(PIX_TEXTS):
        sc = 1 + i % 4
        align = ("left", "center", "right")[i % 3]
        x = {"left": 10, "center": 640, "right": 1270}[align]
        shadow = [None, (4, 5, 10), (224, 72, 150)][i % 3]
        col = [(64, 210, 220), (255, 138, 44), (255, 255, 255), (162, 168, 180)][i % 4]
        op = 0.6 if i % 5 == 4 else 1.0
        cases.append([x, y, s, list(col), sc, list(shadow) if shadow else None, align, op])
        y += 7 * sc + 14
    return cases


def pixfont_ref():
    cases = pix_cases()
    img = QImage(1280, 720, QImage.Format.Format_RGB32)
    img.fill(QColor(*BG))
    p = QPainter(img)
    widths = []
    for x, y, s, col, sc, sh, al, op in cases:
        widths.append(pixfont.draw(p, x, y, s, tuple(col), sc, tuple(sh) if sh else None, al, op))
    p.end()
    img.save(os.path.join(OUT, "pixfont_ref.png"))
    return cases, widths


# ---------------------------------------------------------------- HUD-Fälle
class FakeScene:
    def __init__(self):
        self.screen = {}


def actor_d(a):
    return dict(uid=a.uid, x=a.x, depth=a.depth, player=a.player, alive=a.alive, escaped=a.escaped,
                state=a.state, revealed=sorted(a.revealed), tells=dict(a.tells), scanned=a.scanned,
                exposure=a.exposure, boss_invuln=a.boss_invuln, hp=a.hp, name=a.name)


def world_d(w):
    uid = lambda a: None if a is None else a.uid  # noqa: E731
    return dict(
        actors=[actor_d(a) for a in w.actors], conf={str(a.uid): w.confidence_of(a) for a in w.actors},
        camera_x=w.camera_x, target=uid(w.target), aiming=w.aiming, aim_t=w.aim_t, blocker=uid(w.blocker),
        run=dict(mods=w.run.mods, max_hp=w.run.max_hp, score=w.run.score, totals=w.run.totals,
                 upgrades=w.run.upgrades, origami=w.run.origami),
        zone=dict(name=w.zone["name"], camo=w.zone["camo"], aggression=w.zone["aggression"]),
        zone_index=w.zone_index, quota=w.quota, stats=w.stats, reps_remaining=w.reps_remaining(),
        combo=w.combo, bounty=uid(w.bounty), bounty_desc=w.bounty_desc, scan_charges=w.scan_charges,
        scan_max=w.scan_max, suspicion=w.suspicion, shout_cd=w.shout_cd, unrest=w.unrest, length=w.length,
        player=w.player.uid, exit_open=w.exit_open(), log=list(w.log), shout_hold=w.shout_hold,
        scan_t=w.scan_t, scan_target=uid(w.scan_target), floaters=w.floaters,
        replicants_total=w.replicants_total, prior=w.prior, mission_failed=getattr(w, "mission_failed", False),
        origami=[dict(name=o["name"]) for o in w.origami] if w.origami else [], fail_reason=w.fail_reason,
        vehicles=[dict(x=v["x"], depth=v["depth"], dir=v["dir"], speed=v["speed"]) for v in w.vehicles],
        patrol=None if w.patrol is None else dict(phase=w.patrol.get("phase"), on=w.patrol.get("on", 0.0)),
        watched=w.watched, blackout_t=w.blackout_t,
        ramen=[dict(x=r["x"], used=r["used"], t=r["t"]) for r in w.ramen],
        boss=uid(w.boss), boss_speak_t=w.boss_speak_t, boss_line=w.boss_line)


def make_world(seed, zone, variant):
    w = World(seed=seed, zone_index=zone)
    near = sorted([a for a in w.actors if not a.player], key=lambda a: abs(a.x - w.camera_x))
    tg = near[0]
    tg.revealed |= {"gait", "pupils"}
    tg.scanned = variant == 1
    tg.exposure = 1.1
    w.target = tg
    for a in near[1:4]:
        a.revealed.add("anachron")
    near[2].state = "flee"
    near[3].state = "attack"
    w.stats["reps"] = 1
    w.run.score = 735
    w.combo = 3
    w.scan_charges = 2.4
    w.run.suspicion = 0.42
    w.unrest = 0.3
    w.shout_cd = 4.0 if variant == 0 else 0.0
    w.player.x = w.length * 0.37
    w.log.append("Replikant deaktiviert")
    w.floater("+150", tg, (64, 210, 220))
    w.floaters[0]["t"] = 0.4
    if variant == 1:
        w.aiming = True
        w.aim_t = 0.1
        w.blocker = near[1]
        w.shout_hold = 0.6
        w.watched = True
        w.blackout_t = 3.0
        w.ramen[0]["x"] = w.player.x
        w.player.depth = 0.3
        w.player.hp = 2
        w.ramen[0]["t"] = 0.5
        w.vehicles = [dict(x=w.camera_x - 200, depth=w.player.depth, dir=1, speed=90.0)]
        w.stats["bounty"] = False
    return w, near


def cases():
    w0, _ = make_world(11, 1, 0)
    w1, near1 = make_world(5, 2, 1)
    wo = World(seed=3, zone_index=3)
    wo.stats.update(reps=4, civs=1, escaped=2, scans=9, shots=7, time=193.4, score=-120, origami=True)
    wo.run.totals.update(reps=11, civs=1, escaped=3)
    wo.run.score = 2140
    wo.run.upgrades = ["akku", "auge"]
    wo.run.origami = ["huhn", "schaf"]
    wo.fail_reason = "suspicion"
    opts = wo.run.offer(random.Random(4))
    settings = dict(music=0.7, sfx=1.0, fullscreen=False, resolution=[1920, 1080], scanlines=True,
                    renderer="software", difficulty="schwer", lang="de")
    best = dict(best=12345, rank="A", runs=17)
    return [
        ("title", None, [[0.2, dict(mode="title", best=best)]]),
        ("settings3", None, [[0.2, dict(mode="settings", settings=settings, settings_sel=0)]]),
        ("settings6", None, [[0.2, dict(mode="settings", settings=settings, settings_sel=6)]]),
        ("pause", w0, [[0.2, dict(mode="pause")]]),
        ("intro", w0, [[0.2, dict(mode="intro", t=1.5)]]),
        ("play", w1, [[0.5, dict(mode="play", mouse=(300, 200))], ["reveal", near1[1].uid],
                      [0.02, dict(mode="play", mouse=(300, 200))]]),
        ("help", None, [[0.2, dict(mode="play", help=True)]]),
        ("clear", wo, [[0.2, dict(mode="clear", options=[list(o) for o in opts], sel=1)]]),
        ("clear0", wo, [[0.2, dict(mode="clear", options=[])]]),
        ("over", wo, [[0.2, dict(mode="over", new_best=True)]]),
        ("victory", wo, [[0.2, dict(mode="victory", rank="S")]]),
    ]


def hud_refs():
    out = []
    hud_restore = []
    for lang in ("de", "en"):
        i18n.set_lang(lang)
        for name, w, steps in CASES:
            hud = HUD()
            scene = FakeScene()
            wd = world_d(w) if (w is not None and lang == "de") else None
            jsteps = []
            for st in steps:
                if st[0] == "reveal":
                    a = next(a for a in w.actors if a.uid == st[1])
                    a.revealed.add("pupils")
                    was = (set(a.revealed), dict(a.tells))
                    a.revealed.add("pupils")
                    a.tells["pupils"] = True
                    jsteps.append(["reveal", st[1], w.confidence_of(a)])
                    hud_restore.append((a, was))
                    continue
                dt, ui = st
                hud.render(w, scene, dt, ui)
                jui = dict(ui)
                if "mouse" in jui:
                    jui["mouse"] = list(jui["mouse"])
                jsteps.append([dt, jui])
            img = QImage(1280, 720, QImage.Format.Format_RGB32)
            img.fill(QColor(*BG))
            p = QPainter(img)
            p.drawImage(0, 0, hud.img)
            p.end()
            img.save(os.path.join(OUT, f"hud_{name}_{lang}_ref.png"))
            for a, (rv, tl) in hud_restore:
                a.revealed, a.tells = rv, tl
            hud_restore.clear()
            if lang == "de":
                out.append(dict(name=name, world=wd, steps=jsteps))
    i18n.set_lang("de")
    return out


# ---------------------------------------------------------------- FX
def fx_ref():
    f = fxmod.FX(seed=42)
    f.set_rain(0.8)
    dt = 1 / 60
    log = []
    for i in range(150):
        f.update_rain(dt, 0.7 if i % 30 < 20 else -1.3)
        if i % 7 == 0:
            f.puff(100 + i, 250, scale=0.8)
        if i % 11 == 0:
            f.puff(-3 + i * 0.1, 280, wx=200.0 + i, depth=0.4, scale=1.2)
        if i == 20:
            f.impact(220.0, 0.5, -30.0, (255, 220, 160), n=10, blood=True)
            f.tracer(100.0, 0.5, 220.0, 0.5, 3)
        if i == 140:
            f.impact(240.0, 0.6, -20.0, (255, 220, 160), n=6, blood=False)
        f.update_steam(dt)
        f.update_combat(dt)
        bolt = f.update_weather(dt * 9, 0.8)
        sh = f.shake()
        log.append([bolt, list(sh), f.trauma, f.lightning])
    data = dict(rain=f.rain, splashes=f.splashes, steam=f.steam, sparks=[dict(s, c=list(s["c"])) for s in f.sparks],
                flashes=f.flashes, tracers=f.tracers, bolt=f.bolt, log=log, next_bolt=f._next_bolt,
                rnd=f.rng.random())
    img = QImage(640, 360, QImage.Format.Format_RGB32)
    img.fill(QColor(18, 22, 38))
    p = QPainter(img)
    f.draw_steam(p, 150.0, 0.3)
    f.draw_rain(p, (190, 196, 214))
    f.draw_splashes(p, (190, 196, 214))
    p.end()
    img.save(os.path.join(OUT, "fx_ref.png"))
    return data


if __name__ == "__main__":
    CASES = cases()
    pc, pw = pixfont_ref()
    hc = hud_refs()
    fd = fx_ref()
    with open(os.path.join(HERE, "tests", "hud_cases.json"), "w") as fh:
        json.dump(dict(pixfont=pc, pix_widths=pw, hud=hc, bg=BG), fh)
    with open(os.path.join(HERE, "tests", "fx_ref.json"), "w") as fh:
        json.dump(fd, fh)
    print("ref ok", len(hc))
