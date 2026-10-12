#!/usr/bin/env python3
"""Referenz-Spur der Simulation aus dem Python-Original (Paritäts-Test des Godot-Ports).

Für Zonen 0-4 x SEEDS (plus Titel-World ohne Run) läuft die Sim STEPS Schritte mit
dt = 1/60 und geskripteten Eingaben (script_step, 1:1 in tests/test_sim_parity.gd).
Pro Schritt wird ein kompakter Zustand protokolliert (FIELDS). Ausgabe gzip-JSON.

  PYTHONPATH=/home/alex/ShadeGunner QT_QPA_PLATFORM=offscreen \
      python3 tools/sim_trace.py [--runs z0_s1234,title] [--out tests/sim_trace.json.gz]
Ohne --runs: alle Läufe. Mit --runs werden vorhandene Läufe in der Datei ergänzt/ersetzt.
"""

import argparse
import gzip
import json
import os
import sys

from shadegunner.sim import Run, World

DT = 1 / 60
STEPS = 1500
SEEDS = [1234, 777]
STATES = ["walk", "idle", "loiter", "panic", "flee", "attack", "cower", "duck", "freeze", "hands", "hurt",
          "dead", "run", "aim", "shoot", "scan", "punch", "leap"]
WSTATES = ["playing", "zone_clear", "failed", "finished"]
FIELDS = ["px", "pd", "pz", "php", "pst", "score", "susp", "unrest", "scan", "tgt", "alive", "esc", "dead",
          "sx", "sd", "sst", "sph", "sfr", "sexp", "nveh", "svx", "svs", "ev", "evn", "nfl", "nlog", "rng_i",
          "rng_0", "cam", "wst", "shout_cd", "pat", "nobs", "reps", "time"]


# Sonder-Läufe für seltene Mechaniken: Name = <art>_z<zone>_s<seed>
SPECIAL = ["ev_z2_s5", "boss_z4_s3", "bounty_z2_s8", "exit_z0_s5", "gate_z0_s6", "ramen_z1_s15"]


def all_runs():
    out = [f"z{z}_s{s}" for z in range(5) for s in SEEDS]
    out.append("title")
    return out + SPECIAL


def make_world(name):
    if name == "title":
        return World(seed=4711, zone_index=2)            # wie game._title_world (ohne Run)
    parts = name.split("_")
    z, s = int(parts[-2][1:]), int(parts[-1][1:])
    w = World(Run(s, "normal"), seed=s, zone_index=z)  # wie game._start_run, aber Zone z
    setup(w, parts[0] if len(parts) == 3 else "")
    return w


def _near(w, a, dx):
    w.player.x = a.x - dx
    w.player.depth = a.depth
    w.camera_x = w.player.x + 40


def setup(w, kind):
    """Startzustand der Sonder-Läufe (identisch in test_sim_parity.gd)."""
    p = w.player
    if kind == "ev":                     # Stromausfall + Patrouille früh
        w.blackout_at = 1.0
        w.patrol_cd = 2.0
    elif kind == "boss":                 # Tyrell-Auftrag erfüllt, kurz vor ROY
        w.stats["reps"] = w.quota
        p.x = w.length - 320.0 + 5
        w.camera_x = p.x + 40
    elif kind == "bounty":               # Kopfgeld (zäh) direkt vor dem Spieler
        _near(w, w.bounty, 30.0)
        w.set_target(w.bounty)
    elif kind == "exit":                 # alle Replikanten weg, Ausgang voraus
        for a in w.actors:
            if a.is_replicant:
                w._kill(a)
        p.x = w.length - 60.0
        w.camera_x = p.x + 40
    elif kind == "gate":                 # Ausgang ohne Auftrag
        p.x = w.length - 60.0
        w.camera_x = p.x + 40
    elif kind == "ramen":                # angeschlagen vor dem Nudelstand
        p.hp = w.run.max_hp - 1
        w.run.hp = p.hp
        p.x, p.depth = w.ramen[0]["x"] - 10, 0.3
        w.camera_x = p.x + 40


def shoot_step(i):
    """Dauerfeuer ohne Bewegung: 20 Schritte zielen, 10 loslassen."""
    return dict(aim=(i % 30) < 20, move=(0, 0))


def input_for(name, w, i):
    if name == "title":
        return {}
    kind = name.split("_")[0]
    if kind in ("boss", "bounty"):
        return shoot_step(i)
    if kind == "ramen":
        return {} if i < 240 else script_step(w, i)
    return script_step(w, i)


def script_step(w, i):
    """Geskriptete Eingabe für Schritt i (240er Zyklus). Wählt vor dem Scan das nächste
    lebende Ziel per set_target (wie die Maus im Spiel)."""
    c, ph = divmod(i, 240)
    inp = {}
    mx, md = 0, 0
    if ph < 60 or ph >= 220:
        mx = 1
    if 30 <= ph < 60:
        inp["sprint"] = True
    if ph == 60:
        best, bd = None, 1e9
        for a in w.living():
            d = w.dist(w.player, a)
            if d < bd:
                best, bd = a, d
        if best is not None:
            w.set_target(best)
        inp["scan"] = True
    if ph == 120:
        inp["cycle"] = 1 if c % 2 == 0 else -1
    if 125 <= ph < 160:
        inp["aim"] = True
    if ph == 150:
        t = w.target
        shoot = t is not None and ((t.scanned and w.confidence_of(t) >= 0.4) or c % 3 == 0)
        if not shoot:
            inp["cancel"] = True
    if ph == 170:
        inp["jump"] = True
    if 175 <= ph < 215:
        md = 1 if c % 2 == 0 else -1
        mx = -1 if ph < 190 else 1
    if c % 2 == 1 and 200 <= ph < 230:
        inp["shout"] = True
    if c % 2 == 0 and ph in (200, 201):
        inp["shout"] = True
    inp["move"] = (mx, md)
    return inp


def _code(s, table):
    return table.index(s) if s in table else 99


def snapshot(w):
    p = w.player
    alive = esc = dead = 0
    sx = sd = sph = sexp = 0.0
    sst = sfr = 0
    for i, a in enumerate(w.actors):
        if a.escaped:
            esc += 1
        elif not a.alive:
            dead += 1
        elif not a.player:
            alive += 1
        sx += a.x
        sd += a.depth
        sph += a.phase
        sexp += a.exposure
        sst += (i + 1) * _code(a.state, STATES)
        sfr += (i + 1) * a.frame
    svx = svs = 0.0
    for v in w.vehicles:
        svx += v["x"]
        svs += v["speed"]
    kinds = []
    evn = 0.0
    for e in w.events:
        kinds.append(e[0])
        for x in e[1:]:
            if isinstance(x, (int, float)) and not isinstance(x, bool):
                evn += x
    st = w.rng.getstate()[1]
    return [p.x, p.depth, p.z, p.hp, _code(p.state, STATES), w.run.score, w.suspicion, w.unrest, w.scan_charges,
            w.target.uid if w.target is not None else -1, alive, esc, dead, sx, sd, sst, sph, sfr, sexp,
            len(w.vehicles), svx, svs, ",".join(kinds), evn, len(w.floaters), len(w.log), st[624], st[0],
            w.camera_x, _code(w.state, WSTATES), w.shout_cd, w.patrol["x"] if w.patrol is not None else -1.0,
            len(w.obstacles), w.stats["reps"], w.time]


def trace(name):
    w = make_world(name)
    rows = [snapshot(w)]
    w.events.clear()
    for i in range(STEPS):
        w.update(DT, input_for(name, w, i))
        rows.append(snapshot(w))
        w.events.clear()
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default="")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "tests", "sim_trace.json.gz"))
    args = ap.parse_args()
    names = [n for n in args.runs.split(",") if n] or all_runs()
    data = dict(fields=FIELDS, steps=STEPS, dt=DT, runs={})
    if args.runs and os.path.exists(args.out):
        with gzip.open(args.out, "rt") as f:
            data = json.load(f)
    for n in names:
        data["runs"][n] = trace(n)
        r = data["runs"][n][-1]
        print(f"{n}: x={r[0]:.1f} hp={r[3]} score={r[5]} susp={r[6]:.2f} reps={r[33]} wst={r[29]}", file=sys.stderr)
    with gzip.open(args.out, "wt") as f:
        json.dump(data, f, separators=(",", ":"))


if __name__ == "__main__":
    main()
