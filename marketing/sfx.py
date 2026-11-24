# Sound effects for reel 2 (timed to reel2.html, 26.8 s): pencil, red strikes, message pops,
# paper crumple, throw whoosh, dustbin thud, seal crack, envelope whoosh, chimes, ticks.
import numpy as np, wave
SR = 44100; DUR = 28.6; N = int(SR * DUR)
rng = np.random.default_rng(11)
L = np.zeros(N); R = np.zeros(N)
def add(sig, t0, gain=1.0, pan=0.5):
    i = int(t0 * SR); j = min(N, i + len(sig)); s = sig[:j - i] * gain
    L[i:j] += s * (1 - pan) * 1.4
    R[i:j] += s * pan * 1.4
def tt(d): return np.arange(int(d * SR)) / SR
def lp(x, a):  # one-pole low-pass
    y = np.empty_like(x); acc = 0.0
    for i, v in enumerate(x): acc += a * (v - acc); y[i] = acc
    return y
def hp(x, a): return x - lp(x, a)
def noise(d): return rng.standard_normal(int(d * SR))

# pencil writing: short scratchy strokes while each line is written (A: lines at .4+.42i for .5 s)
for i in range(7):
    t0 = .4 + i * .42
    for k in range(5):
        d = .07 + rng.uniform(0, .05); n = hp(noise(d), .35) * np.hanning(int(d * SR))
        add(n * .09, t0 + k * .09 + rng.uniform(0, .02), pan=.55)
# red strike-throughs
for t0 in (3.0, 3.3):
    d = .22; n = hp(noise(d), .25) * np.linspace(1, .3, int(d * SR)); add(n * .16, t0, pan=.5)
# message pops (B: 4.6 + .5i)
for i in range(5):
    x = tt(.12); f = 1300 - 4000 * x; s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-x * 30)
    add(s * .25, 4.6 + i * .5, pan=.3 if i % 2 == 0 else .7)
# paper crumple: dense crackles 7.85 → 8.9
c0, c1 = 7.85, 8.9
t = c0
while t < c1:
    d = rng.uniform(.004, .02); n = hp(noise(d), .5) * np.hanning(int(d * SR)) * rng.uniform(.15, .45)
    add(n, t, pan=rng.uniform(.35, .65)); t += rng.exponential(.012)
rust = hp(noise(c1 - c0), .15) * np.hanning(int((c1 - c0) * SR)) * .05; add(rust, c0)
# throw whoosh (8.9 → 9.65)
d = .7; x = tt(d); n = noise(d); w = np.zeros_like(n); acc = 0
for i in range(len(n)):
    a = .02 + .25 * np.sin(np.pi * i / len(n)); acc += a * (n[i] - acc); w[i] = acc
add(w * np.hanning(len(w)) * .5, 8.95, pan=.7)
# dustbin: paper hits (soft thud + rattle) at 9.65
x = tt(.35); thud = np.sin(2 * np.pi * (90 - 60 * x) * x) * np.exp(-x * 14) * .6
clank = (np.sin(2 * np.pi * 410 * x) + .6 * np.sin(2 * np.pi * 1130 * x) + .3 * np.sin(2 * np.pi * 2270 * x)) * np.exp(-x * 11) * .12
add(thud + clank + hp(noise(.35), .3) * np.exp(-x * 25) * .2, 9.65, pan=.75)
# seal crack (10.65) + envelope flap whoosh (10.8) + letter rise shimmer (11.4)
x = tt(.08); add(hp(noise(.08), .6) * np.exp(-x * 60) * .5, 10.65)
d = .6; f = lp(noise(d), .05) * np.hanning(int(d * SR)) * .5; add(f, 10.8)
for k, m in enumerate([76, 79, 83, 88]):
    x = tt(1.2); fr = 440 * 2 ** ((m - 69) / 12); s = np.sin(2 * np.pi * fr * x) * np.exp(-x * 3.2) * .08
    add(s, 11.4 + k * .09, pan=.3 + k * .13)
# phone slide whooshes (13.3, 15.7)
for t0 in (13.3, 15.7):
    d = .5; n = lp(noise(d), .08) * np.hanning(int(d * SR)) * .45; add(n, t0)
# progress ticks (19.0, 19.5) + ding (19.9)
for t0 in (19.0, 19.5):
    x = tt(.08); add(np.sin(2 * np.pi * 1800 * x) * np.exp(-x * 70) * .25, t0)
x = tt(1.0); add((np.sin(2 * np.pi * 1318 * x) + .5 * np.sin(2 * np.pi * 1976 * x)) * np.exp(-x * 4) * .12, 19.9)
# feature swooshes (21.4 + .35i)
for i in range(4):
    d = .28; n = lp(noise(d), .12) * np.hanning(int(d * SR)) * .3; add(n, 21.4 + i * .35, pan=.25 if i % 2 == 0 else .75)
# ending chime (24.3)
for k, m in enumerate([72, 76, 79, 84]):
    x = tt(2.2); fr = 440 * 2 ** ((m - 69) / 12); add(np.sin(2 * np.pi * fr * x) * np.exp(-x * 1.8) * .07, 24.3 + k * .12, pan=.5)

st = np.stack([L, R], 1); st = st / max(1e-9, np.max(np.abs(st))) * .8
with wave.open('sfx.wav', 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes((st * 32767).astype(np.int16).tobytes())
print('ok')
