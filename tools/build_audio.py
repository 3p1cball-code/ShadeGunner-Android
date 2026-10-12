#!/usr/bin/env python3
"""Alle Klänge mit dem ORIGINAL-Synthesizer (shadegunner.audio.build) erzeugen und
als Godot-Assets nach assets/audio/ legen.

  PYTHONPATH=/home/alex/ShadeGunner python3 tools/build_audio.py [--force]

- Rohdaten (WAV, ~140 MB) landen in tools/audio_build/ (gitignored, nicht im Home-Cache).
- Abgelegt wird genau das, was der Original-Mixer spielt: Mixer.load bringt alles
  per linearer Interpolation auf 32 kHz (das prägt den Klang der 22,05-kHz-Effekte:
  Höhenabfall + Spiegelfrequenzen) - hier mit dem Original-Code vorab erledigt.
- Mono-Effekte -> WAV PCM16 (mono; der Mixer dupliziert nur auf beide Kanäle).
- Stereo (Vorbeifahrten, Donner, ...) -> OGG Vorbis q8, Musik/Rhythmus -> OGG q5.
- Die .import-Dateien schreiben wir selbst: WAV unkomprimiert (kein QOA), Loops
  (rain, music*, pulse*) mit loop=true ab Sample 0 - wie Mixer.play(loop=True).
- Prüft am Ende die Loop-Naht und die Länge der dekodierten OGGs.
"""
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WT = os.path.dirname(HERE)
RAW = os.path.join(HERE, "audio_build")
OUT = os.path.join(WT, "assets", "audio")
FFMPEG = "/usr/bin/ffmpeg"


def is_loop(name):
    return name == "rain" or name == "music" or name.startswith("music_z") or name.startswith("pulse_z")


def is_music(name):
    return name == "music" or name.startswith("music_z") or name.startswith("pulse_z")


def read_wav(path):
    with wave.open(path, "rb") as w:
        sr, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32767.0
    return sr, x.reshape(-1, ch)


def decode(path, sr, ch):
    raw = subprocess.run([FFMPEG, "-v", "error", "-i", path, "-f", "s16le", "-ac", str(ch), "-ar", str(sr), "-"],
                         check=True, capture_output=True).stdout
    return (np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32767.0).reshape(-1, ch)


WAV_IMPORT = """[remap]

importer="wav"
type="AudioStreamWAV"

[deps]

source_file="res://assets/audio/{name}.wav"

[params]

force/8_bit=false
force/mono=false
force/max_rate=false
force/max_rate_hz=44100
edit/trim=false
edit/normalize=false
edit/loop_mode={loop_mode}
edit/loop_begin=0
edit/loop_end={loop_end}
compress/mode=0
"""

OGG_IMPORT = """[remap]

importer="oggvorbisstr"
type="AudioStreamOggVorbis"

[deps]

source_file="res://assets/audio/{name}.ogg"

[params]

loop={loop}
loop_offset=0.0
bpm=0.0
beat_count=0
bar_beats=4
"""


def mixer_data(path):
    """Exakt die Daten, die der Original-Mixer spielt: Mixer.load (np.interp auf
    32 kHz, mono -> beide Kanäle) - per Original-Code, ohne Qt-Audiosenke."""
    from shadegunner import audio
    m = audio.Mixer.__new__(audio.Mixer)
    m.np = np
    m.data = {}
    audio.Mixer.load(m, "x", path)
    return m.data["x"].astype(np.float64)


def write_wav(path, x, sr):
    data = np.round(np.clip(x, -1, 1) * 32767).astype("<i2")
    tmp = path + ".tmp"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(x.shape[1])
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(data.tobytes())
    os.replace(tmp, path)


def write_import(path, text):
    """[params] setzen, uid/path einer vorhandenen .import-Datei behalten."""
    if os.path.exists(path):
        old = open(path).read()
        head = old.split("[params]")[0]
        text = head + "[params]" + text.split("[params]")[1]
    with open(path, "w") as f:
        f.write(text)


def main():
    force = "--force" in sys.argv
    os.makedirs(RAW, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    from shadegunner import audio
    audio.build(RAW)                       # Original-Code, schreibt nur fehlende Dateien
    rate = audio.Mixer.RATE
    names = sorted(fn[:-4] for fn in os.listdir(RAW) if fn.endswith(".wav"))
    report = []
    for name in names:
        src = os.path.join(RAW, name + ".wav")
        sr0, x0 = read_wav(src)
        x = mixer_data(src)                # (n, 2) bei 32 kHz
        mono = x0.shape[1] == 1
        if mono:
            assert np.array_equal(x[:, 0], x[:, 1])
            dst = os.path.join(OUT, name + ".wav")
            if force or not os.path.exists(dst):
                write_wav(dst, x[:, :1], rate)
            # loop_end exklusiv; der Standard -1 ergibt n-1 (ein Sample pro Durchlauf zu kurz)
            write_import(dst + ".import", WAV_IMPORT.format(
                name=name, loop_mode=2 if is_loop(name) else 0, loop_end=len(x) if is_loop(name) else -1))
            report.append((name, "wav", sr0, 1, len(x), os.path.getsize(dst), 0.0, 0.0))
            continue
        dst = os.path.join(OUT, name + ".ogg")
        q = "5" if is_music(name) else "8"
        if force or not os.path.exists(dst):
            tmp = os.path.join(RAW, name + ".32k.wav")
            write_wav(tmp, x, rate)
            subprocess.run([FFMPEG, "-v", "error", "-y", "-i", tmp, "-c:a", "libvorbis", "-q:a", q, dst], check=True)
            os.remove(tmp)
        write_import(dst + ".import", OGG_IMPORT.format(name=name, loop="true" if is_loop(name) else "false"))
        y = decode(dst, rate, 2)
        n = min(len(x), len(y))
        err = float(np.sqrt(np.mean((x[:n] - y[:n]) ** 2)) / max(1e-9, np.sqrt(np.mean(x[:n] ** 2))))
        seam = 0.0
        if is_loop(name):
            # Sprung an der Naht relativ zum größten Sample-Sprung des Originals
            d_orig = np.abs(np.diff(x, axis=0)).max()
            seam = float(np.abs(y[0] - y[-1]).max() / max(1e-9, d_orig))
        report.append((name, "ogg q" + q, sr0, 2, len(y) - len(x), os.path.getsize(dst), err, seam))
    tot = 0
    for name, fmt, sr, ch, nn, size, err, seam in report:
        tot += size
        extra = f" dLen={nn} relErr={err:.4f}" if fmt.startswith("ogg") else ""
        if seam:
            extra += f" naht={seam:.2f}"
        print(f"{name:12s} {fmt:7s} {sr:5d}->32000 Hz {ch}ch {size / 1024:8.1f} KiB{extra}")
    print(f"gesamt {tot / 1048576:.2f} MiB, {len(report)} Dateien")


if __name__ == "__main__":
    main()
