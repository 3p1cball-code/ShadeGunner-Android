#!/usr/bin/env python3
"""Referenz-Protokoll für den Audio-Port.

Erzeugt ein deterministisches Szenario (Spielmodi, Zonenwechsel, Stromausfall,
Spannung, alle Ereignistypen, Mute, Lautstärken) und spielt es durch die
ORIGINAL-Klasse shadegunner.audio.Audio. Der Mixer ist durch eine Attrappe ersetzt,
die jeden Aufruf protokolliert (load/unload/play/stop/set_vol/pump/clear).

  PYTHONPATH=/home/alex/ShadeGunner python3 tools/audio_ref.py
  -> tests/audio_scenario.json, tests/audio_ref_log.json
Gegenstück: tests/test_audio_log.gd (gleiche Ereignisfolge, gleiche Aufrufliste).
"""
import json
import os
import random
import sys
import wave
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
WT = os.path.dirname(HERE)
RAW = os.path.join(HERE, "audio_build")

from shadegunner import audio  # noqa: E402

LOG = []


class FakeMixer:
    RATE = 32000
    MAX_VOICES = 28

    def __init__(self):
        self.data = {}
        self._v = []
        self._last_start = {}

    # `mixer.voices = []` (toggle_mute) mitprotokollieren
    @property
    def voices(self):
        return self._v

    @voices.setter
    def voices(self, val):
        LOG.append(["clear"])
        self._v = list(val)

    def load(self, name, path):
        LOG.append(["load", name])
        with wave.open(path, "rb") as w:
            sr, n = w.getframerate(), w.getnframes()
        self.data[name] = n if sr == self.RATE else int(round(n * self.RATE / sr))

    def unload(self, name):
        LOG.append(["unload", name])
        self.stop(name)
        self.data.pop(name, None)

    def pos(self, name):
        for v in self._v:
            if v[0] == name:
                return v[1]
        return 0

    def play(self, name, vol, loop=False, now=0.0, pos=0):
        if name not in self.data:
            return
        acc = not (not loop and now - self._last_start.get(name, -1.0) < 0.03)
        LOG.append(["play", name, vol, loop, pos, acc])
        if not acc:
            return
        self._last_start[name] = now
        if len(self._v) >= self.MAX_VOICES:
            one = [v for v in self._v if not v[3]]
            if one:
                self._v.remove(one[0])
        self._v.append([name, pos % self.data[name], vol, loop])

    def stop(self, name):
        LOG.append(["stop", name])
        self._v = [v for v in self._v if v[0] != name]

    def set_vol(self, name, vol):
        LOG.append(["set_vol", name, vol])
        for v in self._v:
            if v[0] == name:
                v[2] = vol

    def playing(self, name):
        return any(v[0] == name for v in self._v)

    def pump(self, silent=False):
        LOG.append(["pump", silent])
        # Einmal-Stimmen enden hier sofort (Lebensdauer ist Sache der Engine,
        # protokolliert wird nur, was Audio aufruft)
        if not silent:
            self._v = [v for v in self._v if v[3]]

    def close(self):
        pass


def scenario():
    r = random.Random(4711)
    frames = []
    unrest, susp = 0.0, 0.0
    kinds = ["car", "truck", "bus", "bike", "police", "sedan"]
    plan = [(0, 240, "title", 2), (240, 420, "intro", 0), (420, 1100, "play", 0), (1100, 1250, "pause", 0),
            (1250, 1900, "play", 1), (1900, 2500, "play", 2), (2500, 3000, "play", 3),
            (3000, 3600, "play", 4), (3600, 3700, "zone_clear", 4), (3700, 4100, "title", 2),
            (4100, 4400, "play", 0)]
    for i in range(4400):
        mode, zi = next((m, z) for a, b, m, z in plan if a <= i < b)
        dt = r.choice((1 / 60, 1 / 60, 1 / 60, 0.015, 0.017, 0.033, 0.05))
        unrest = min(1.0, max(0.0, unrest + r.uniform(-0.02, 0.021)))
        susp = min(1.0, max(0.0, susp + r.uniform(-0.01, 0.0105)))
        bl = 3.0 if (700 <= i < 900 or 2700 <= i < 2800) else 0.0
        actors = []
        for _k in range(r.randint(0, 6)):
            actors.append(dict(alive=r.random() < 0.9, alert=r.random() < 0.05,
                               state=r.choice(("walk", "idle", "flee", "attack", "punch", "leap", "stand"))))
        world = dict(zone_index=zi, unrest=round(unrest, 6), aiming=(i // 90) % 3 == 1,
                     boss=({"hp": 3, "alive": True} if 3300 <= i < 3500 else None), blackout_t=bl,
                     run=(dict(suspicion=round(susp, 6)) if mode != "title" else None), actors=actors)
        ev = []
        n_ev = 0 if r.random() < 0.85 else r.randint(1, 4)
        for _k in range(n_ev):
            k = r.choice(("shot", "scan_start", "scan_done", "target", "tell", "kill", "hurt", "escape",
                          "gate_locked", "quota", "zone_clear", "fail", "no_charge", "no_target",
                          "scan_abort", "attack", "flee", "jump", "land", "leap", "tough", "bounty",
                          "ramen", "holster", "boss", "boss_line", "boss_hit", "boss_blocked", "honk",
                          "car_hit", "bump", "jam_honk", "vehicle", "vehicle", "vehicle", "patrol",
                          "spinner_land", "spinner_lift", "spinner_touch", "shout", "talk", "origami",
                          "greet", "blackout", "blackout_end", "punch", "boss_dead", "unknown"))
            if k == "kill":
                ev.append([k, r.randint(0, 40), r.random() < 0.5])
            elif k == "land":
                ev.append([k, r.choice((0, 0, 3, 7))])
            elif k == "vehicle":
                e = [k, r.choice(kinds), r.choice((-1, 1)), round(r.uniform(0.3, 1.0), 3)]
                ev.append(e if r.random() < 0.8 else e[:3])
            elif k in ("spinner_land", "spinner_lift"):
                ev.append([k, r.choice((-1, 1))])
            elif k == "shot":
                ev.append([k, 1.0, 0.5, 2.0, 0.4, None])
            else:
                ev.append([k, r.randint(0, 40)])
        if 1000 <= i < 1010:                    # Burst: viele Fahrzeuge -> Grenze 4
            ev.append(["vehicle", "car", 1, 0.9])
            ev.append(["shot", 1, 2, 3, 4, None])     # doppelte Quelle im selben Frame
            ev.append(["shot", 1, 2, 3, 4, None])
        sfx = []
        if r.random() < 0.03:
            sfx.append(["spinner", r.choice((-1, 1)), round(r.uniform(0.45, 1.6), 4)])
        if r.random() < 0.01:
            sfx.append(["thunder"])
        calls = []
        if i == 5:
            calls.append(["set_volumes", 0.8, 0.7])
        if i == 900:
            calls.append(["set_volumes", 0.6, None])
        if i == 1500 or i == 1650 or i == 2200 or i == 2205:
            calls.append(["toggle_mute"])
        if i == 2100:
            calls.append(["set_volumes", None, 0.3])
        if i == 3000:
            calls.append(["set_volumes", 1.2, -0.1])
        if i == 3050:
            calls.append(["set_volumes", 0.9, 1.0])
        if r.random() < 0.01:
            calls.append(["play", r.choice(("ui", "target"))])
        if r.random() < 0.005:
            calls.append(["play", "honk", round(r.uniform(0, 1.5), 3)])
        frames.append(dict(dt=dt, mode=mode, world=(None if 4380 <= i < 4390 else world),
                           events=ev, sfx=sfx, calls=calls))
    return frames


def ns(d):
    if d is None:
        return None
    w = SimpleNamespace(**d)
    w.actors = [SimpleNamespace(**a) for a in d["actors"]]
    w.run = SimpleNamespace(**d["run"]) if d["run"] is not None else None
    w.boss = SimpleNamespace(**d["boss"]) if d["boss"] is not None else None
    return w


def main():
    audio.cache_dir = lambda: RAW
    audio.Mixer = FakeMixer
    os.environ.pop("SHADEGUNNER_NOSOUND", None)
    frames = scenario()
    a = audio.Audio()
    assert a.mixer is not None and a._proc is None, "Audio-Build unvollständig? tools/build_audio.py laufen lassen"
    for i, f in enumerate(frames):
        LOG.append(["frame", i])
        a.poll()
        if a._fx and not a._started_loops and not a.muted:
            a.loops(True)
        for c in f["calls"]:
            if c[0] == "set_volumes":
                a.set_volumes(c[1], c[2])
            elif c[0] == "toggle_mute":
                LOG.append(["muted", a.toggle_mute()])
            elif c[0] == "play":
                a.play(c[1], c[2] if len(c) > 2 else None)
        w = ns(f["world"])
        a.handle_events([tuple(e) for e in f["events"]], w)
        if f["sfx"]:
            a.handle_events([tuple(e) for e in f["sfx"]], w)
        a.update(f["dt"], w, f["mode"])
        if i % 100 == 0:
            LOG.append(["state", a._zone, a._mus, a._pulse, a._tension, a._music_vol, sorted(a._gain)])
    with open(os.path.join(WT, "tests", "audio_scenario.json"), "w") as fh:
        json.dump(frames, fh)
    with open(os.path.join(WT, "tests", "audio_ref_log.json"), "w") as fh:
        json.dump(LOG, fh)
    kinds = {}
    for e in LOG:
        kinds[e[0]] = kinds.get(e[0], 0) + 1
    print(len(frames), "Frames,", len(LOG), "Einträge", kinds)
    played = sorted({e[1] for e in LOG if e[0] == "play"})
    print("gespielt:", len(played), played)


if __name__ == "__main__":
    sys.exit(main())
