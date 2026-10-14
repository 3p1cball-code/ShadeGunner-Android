#!/usr/bin/env python3
"""Vergleicht die Godot-Aufnahme (tests/test_audio_render.gd) mit dem Original-Mixer.

Erwartung je Abschnitt = Original-Mixer: Summe(Mixer.load-Daten * vol), danach
tanh(1.2*x) * 32000/32768 (Mixer.pump). Die Referenz wird bandbegrenzt auf die
Godot-Mischrate gebracht, Ausrichtung per Kreuzkorrelation (sub-sample). Godots
Resampler läuft ~1e-5 zu langsam (0,4 Samples/s Drift, 0,02 Cent - unhörbar); die
Rate wird je Abschnitt geschätzt und mitgenommen. Fehler = Restsignal relativ zur
Erwartung (dB, 0-8 kHz).

  PYTHONPATH=/home/alex/ShadeGunner python3 tools/audio_render_check.py [tools/audio_render/render.wav]
"""
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "audio_build")
ASSETS = os.path.join(os.path.dirname(HERE), "assets", "audio")
sys.path.insert(0, HERE)
from build_audio import mixer_data  # noqa: E402


def rd(path):
    with wave.open(path, "rb") as w:
        sr, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32767.0
    x = x.reshape(-1, ch)
    return sr, (np.repeat(x, 2, axis=1) if ch == 1 else x)


def orig(name):
    """Was der Original-Mixer spielt (32 kHz, Stereo)."""
    return mixer_data(os.path.join(RAW, name + ".wav"))


def ogg(name):
    """OGG-Asset dekodiert (32 kHz) - für Tests der Godot-Wiedergabe selbst."""
    raw = subprocess.run(["/usr/bin/ffmpeg", "-v", "error", "-i", os.path.join(ASSETS, name + ".ogg"),
                          "-f", "s16le", "-"], check=True, capture_output=True).stdout
    return (np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32767.0).reshape(-1, 2)


def resample(x, sr_in, sr_out):
    n_out = int(round(len(x) * sr_out / sr_in))
    X = np.fft.rfft(x, axis=0)
    m = n_out // 2 + 1
    Y = np.zeros((m, x.shape[1]), complex)
    k = min(m, len(X))
    Y[:k] = X[:k]
    return np.fft.irfft(Y, n_out, axis=0) * (n_out / len(x))


def at_rate(x32, sr, n, off=0.0, stretch=1.0):
    """Referenz an den Godot-Ausgabezeitpunkten: Sample i <-> Quellzeit (i - off) / (sr*stretch)."""
    up = resample(x32, 32000, 4 * sr)
    p = (np.arange(n) - off) * 4.0 / stretch
    i0 = np.clip(np.floor(p).astype(int), 0, len(up) - 2)
    f = np.clip(p - i0, 0, 1)[:, None]
    y = up[i0] * (1 - f) + up[i0 + 1] * f
    y[(p < 0) | (p > len(up) - 1)] = 0
    return y


def lp(x, sr, cut=8000.0):
    X = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(len(x), 1 / sr)
    X[f > cut] = 0
    return np.fft.irfft(X, len(x), axis=0)


def frac_off(rec, ref, guess, span=400):
    seg = rec[max(0, guess - span):guess + len(ref) + span, 0]
    c = np.correlate(seg, ref[:, 0], "valid")
    k = int(np.argmax(c))
    k = min(max(k, 1), len(c) - 2)
    y0, y1, y2 = c[k - 1], c[k], c[k + 1]
    return max(0, guess - span) + k + 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)


def coarse(rec, ref):
    a, b = rec[:, 0], ref[:, 0]
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    return int(np.argmax(c[:len(a)]))


def fit(rec, x32, sr, t_a, t_b, dur=0.3):
    """Startversatz + Ratenfaktor aus zwei Fenstern bestimmen."""
    base = resample(x32, 32000, sr)
    o = coarse(rec[:int((t_a + 1.5) * sr)], base[int(t_a * sr):int((t_a + 0.6) * sr)]) - int(t_a * sr)
    pa = frac_off(rec, base[int(t_a * sr):int((t_a + dur) * sr)], o + int(t_a * sr)) - int(t_a * sr)
    pb = frac_off(rec, base[int(t_b * sr):int((t_b + dur) * sr)], o + int(t_b * sr)) - int(t_b * sr)
    stretch = 1.0 + (pb - pa) / ((t_b - t_a) * sr)
    off = pa - t_a * sr * (stretch - 1.0)
    return off, stretch


def tanh_mix(x):
    return np.tanh(1.2 * x) * 32000 / 32768


def resid_db(got, want, sr):
    g, w = lp(got, sr), lp(want, sr)
    return 10 * np.log10(np.sum((g - w) ** 2) / max(1e-20, np.sum(w ** 2)))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "audio_render", "render.wav")
    sr, rec = rd(path)
    ok = True

    def seg(t0, t1):
        return rec[int(t0 * sr):int(t1 * sr)]

    # 1) Einzel-Effekt, Kleinsignal (22,05-kHz-Quelle, Mixer.load-Daten)
    x = orig("shot")
    r = seg(0.3, 1.9)
    off, st = fit(r, x, sr, 0.0, 0.2, 0.15)
    want_lin = at_rate(x, sr, len(r), off, st)
    e = resid_db(r, tanh_mix(0.55 * want_lin), sr)
    lin = resid_db(r, 0.55 * want_lin, sr)
    print(f"shot:     Rest {e:.1f} dB gegen Original-Mixer (ohne Limiter-Nachbau wären es {lin:.1f} dB)")
    ok &= e < -30

    # 2) Regen-Loop über die Naht (3,5 s Länge, Loop ab Sample 0)
    x = np.concatenate([orig("rain")] * 3)
    r = seg(1.8, 8.9)
    off, st = fit(r, x, sr, 0.5, 6.0)
    want = tanh_mix(0.5 * at_rate(x, sr, len(r), off, st))
    i_seam = int(off + 3.5 * sr * st)
    for lab, a, b in (("Fläche", int(off) + int(0.2 * sr), i_seam - int(0.2 * sr)),
                      ("Naht", i_seam - int(0.2 * sr), i_seam + int(0.2 * sr)),
                      ("Fläche", i_seam + int(0.2 * sr), len(r) - int(0.2 * sr))):
        e = resid_db(r[a:b], want[a:b], sr)
        print(f"rain {lab:6s} {a / sr:4.1f}-{b / sr:4.1f} s: Rest {e:.1f} dB")
        ok &= e < -30
    print(f"          (Godot-Ratenfaktor {st:.7f})")

    # 3) Zwei taktgleiche Musik-Stimmen (pulse_z3) -> muss exakt 2x sein, sonst Kammfilter
    x = ogg("pulse_z3")[:int(5.5 * 32000)]
    r = seg(9.3, 14.3)
    off, st = fit(r, x, sr, 0.3, 4.0)
    one = at_rate(x, sr, len(r), off, st)
    n = int(off + 4.6 * sr)
    want = tanh_mix(0.24 * one)[:n]
    e = resid_db(r[:n], want, sr)
    e1 = resid_db(tanh_mix(0.12 * one + 0.12 * np.roll(one, 1, axis=0))[:n], want, sr)
    print(f"pulse x2: Rest {e:.1f} dB (2. Stimme 1 Sample versetzt ergäbe {e1:.1f} dB)")
    ok &= e < e1 - 6

    # 4) Laut: Stromausfall + Spinner bei vol 1 -> Sättigung des Limiters
    th, sp = ogg("blackout"), ogg("spinner_lr")
    mix = np.zeros((max(len(th), len(sp)), 2))
    mix[:len(th)] += th
    mix[:len(sp)] += sp
    r = seg(14.8, 20.5)
    off, st = fit(r, sp, sr, 0.5, 5.0)
    lin_in = at_rate(mix, sr, len(r), off, st)
    e = resid_db(r, tanh_mix(lin_in), sr)
    lin = resid_db(r, np.clip(lin_in * 1.171875, -1, 1), sr)
    print(f"laut:     Spitze Eingang {np.abs(lin_in).max():.2f}, Rest {e:.1f} dB gegen tanh "
          f"(lineare Verstärkung + Clip: {lin:.1f} dB)")
    ok &= e < -25
    # 5) OGG-Loop-Naht: music_z3 ab 1,5 s vor Ende, läuft über den Loop-Punkt
    x = ogg("music_z3")
    x = np.concatenate([x[-48000:], x[:3 * 32000]])
    r = seg(22.5, 26.7)
    off, st = fit(r, x, sr, 0.3, 3.0)
    want = tanh_mix(0.4 * at_rate(x, sr, len(r), off, st))
    i_seam = int(off + 1.5 * sr * st)
    for lab, a, b in (("vor", i_seam - int(1.2 * sr), i_seam - int(0.1 * sr)),
                      ("Naht", i_seam - int(0.1 * sr), i_seam + int(0.1 * sr)),
                      ("nach", i_seam + int(0.1 * sr), i_seam + int(2.0 * sr))):
        e = resid_db(r[a:b], want[a:b], sr)
        print(f"music_z3 {lab:4s}: Rest {e:.1f} dB")
        ok &= e < -30
    print("OK" if ok else "FEHLER")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
