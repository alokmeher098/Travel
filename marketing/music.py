# Original royalty-free 19 s travel tune: warm pads + plucked melody + soft beat, 96 BPM, in C major.
import numpy as np, wave
SR = 44100; DUR = 19.0; BPM = 96; beat = 60 / BPM
N = int(SR * DUR); t = np.arange(N) / SR
mix = np.zeros((N, 2))

def note(f): return 440.0 * 2 ** ((f - 69) / 12)
def env(n, a, d, s, r, sl):
    e = np.ones(n) * s
    A, D, R = int(a * SR), int(d * SR), int(r * SR)
    e[:A] = np.linspace(0, 1, A) if A else e[:A]
    e[A:A + D] = np.linspace(1, s, len(e[A:A + D]))
    if R: e[-R:] *= np.linspace(1, 0, R)
    return e
def add(sig, start, pan=0.5):
    i = int(start * SR); j = min(N, i + len(sig)); sig = sig[:j - i]
    mix[i:j, 0] += sig * (1 - pan); mix[i:j, 1] += sig * pan

# chords: Cmaj7, Am7, Fmaj7, G6 — 2 bars (8 beats) each would be slow; use 4 beats each
chords = [[60, 64, 67, 71], [57, 60, 64, 67], [53, 57, 60, 64], [55, 59, 62, 64]]
bass = [36, 33, 29, 31]
bar = 4 * beat
k = 0; st = 0.0
while st < DUR:
    ch = chords[k % 4]
    n = int(bar * SR) + int(0.4 * SR); tt = np.arange(n) / SR
    pad = sum(np.sin(2 * np.pi * note(m) * tt) * 0.5 + np.sin(2 * np.pi * note(m) * 1.003 * tt) * 0.5 for m in ch) / len(ch)
    pad *= env(n, 0.35, 0.3, 0.8, 0.5, 0) * 0.16
    add(pad, st, 0.45)
    bn = int(bar * SR); bt = np.arange(bn) / SR
    b = np.sin(2 * np.pi * note(bass[k % 4]) * bt) * env(bn, 0.01, 0.2, 0.6, 0.2, 0) * 0.22
    add(b, st, 0.5)
    k += 1; st += bar

# plucked melody (pentatonic), starts at bar 2
mel = [76, 79, 81, 79, 76, 74, 72, 74, 76, 79, 84, 81, 79, 76, 74, 76]
def pluck(m, dur=0.6):
    n = int(dur * SR); tt = np.arange(n) / SR
    s = (np.sin(2 * np.pi * note(m) * tt) + 0.35 * np.sin(2 * np.pi * note(m) * 2 * tt) + 0.1 * np.sin(2 * np.pi * note(m) * 3 * tt))
    return s * np.exp(-tt * 5.5) * 0.11
st = bar; i = 0
while st < DUR - 1.5:
    add(pluck(mel[i % len(mel)]), st, 0.3 + 0.4 * (i % 2)); st += beat / 2 * (2 if i % 4 == 3 else 1); i += 1

# soft beat from bar 2: kick on 1 & 3, shaker on 8ths
rng = np.random.default_rng(7)
st = bar; bi = 0
while st < DUR - 1.0:
    if bi % 2 == 0:
        n = int(0.25 * SR); tt = np.arange(n) / SR
        f = 110 * np.exp(-tt * 18) + 45
        kick = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9) * 0.32
        add(kick, st, 0.5)
    for h in range(2):
        n = int(0.06 * SR); sh = rng.standard_normal(n) * np.exp(-np.arange(n) / SR * 60) * 0.035
        sh = np.diff(np.concatenate([[0], sh]))  # brighter
        add(sh, st + h * beat / 2, 0.65)
    st += beat; bi += 1

# simple room reverb (feedback delays)
out = mix.copy()
for d, g in [(0.031, 0.35), (0.047, 0.28), (0.071, 0.22), (0.113, 0.15)]:
    s = int(d * SR)
    out[s:] += mix[:-s] * g
# fade in/out + normalise
fi, fo = int(0.8 * SR), int(2.0 * SR)
out[:fi] *= np.linspace(0, 1, fi)[:, None]; out[-fo:] *= np.linspace(1, 0, fo)[:, None]
out = out / np.max(np.abs(out)) * 0.85
pcm = (out * 32767).astype(np.int16)
with wave.open('music.wav', 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print('ok', len(pcm) / SR)
