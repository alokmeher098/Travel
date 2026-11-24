# Voice-over for reel 2 with Festival (offline TTS), placed at scene times, then mixed with the sound effects.
import subprocess, wave, numpy as np, os
SR = 44100; DUR = 28.6
LINES = [
    (0.3, "Me, planning our trip with pen and paper."),
    (4.4, "And the group chat? Total chaos."),
    (7.9, "There has to be a better way."),
    (10.5, "Meet Envelora."),
    (13.4, "Plan together, day by day."),
    (15.8, "One private chat for your whole group."),
    (18.3, "Always know what's next."),
    (21.2, "Split costs, live map, games and tickets."),
    (23.8, "Less planning. More travelling. Coming soon on Google Play."),
]
os.makedirs('vo', exist_ok=True)
track = np.zeros(int(DUR * SR))
for k, (t0, text) in enumerate(LINES):
    open(f'vo/l{k}.txt', 'w').write(text)
    subprocess.run(['text2wave', '-eval', '(voice_cmu_us_slt_arctic_hts)', f'vo/l{k}.txt', '-o', f'vo/l{k}_raw.wav'], check=True)
    # resample to 44.1 kHz mono, slightly slower & warmer
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', f'vo/l{k}_raw.wav', '-af', 'atempo=0.97,highpass=f=90,lowpass=f=7500,acompressor=threshold=-18dB:ratio=3', '-ar', str(SR), '-ac', '1', f'vo/l{k}.wav'], check=True)
    with wave.open(f'vo/l{k}.wav') as w:
        a = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float) / 32768
    i = int(t0 * SR); j = min(len(track), i + len(a)); track[i:j] += a[:j - i]
    print(f'{t0:5.1f}s  {len(a)/SR:4.2f}s  {text}')
track = track / max(1e-9, np.abs(track).max()) * .9
with wave.open('vo.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((track * 32767).astype(np.int16).tobytes())
print('ok')
