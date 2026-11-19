# Gera Recursos/chegou.wav: uma gota de água a cair ("plip"), ~0,6 s.
import math, struct, wave, random, os
SR = 44100; random.seed(7)
def bolha(f0, sobe, dur, dec):   # bolha de ar que sobe de tom ao fechar
    out, ph = [], 0.0
    for n in range(int(dur * SR)):
        t = n / SR; ph += 2 * math.pi * f0 * (1 + sobe * t / dur) / SR
        out.append(math.sin(ph) * min(1, t / 0.0015) * math.exp(-t * dec))
    return out
def salpico(dur, vol):           # pequeno ruído agudo do impacto
    out, lp = [], 0.0
    for n in range(int(dur * SR)):
        r = random.uniform(-1, 1); lp += 0.35 * (r - lp)
        out.append(vol * (r - lp) * math.exp(-(n / SR) * 90))
    return out
b = [0.0] * int(0.6 * SR)
for ini, am in [(0, salpico(0.02, 0.25)), (0.003, bolha(700, 1.6, 0.16, 22))]:
    o = int(ini * SR)
    for i, v in enumerate(am): b[o + i] += v
for atraso, g in [(0.031, 0.22), (0.053, 0.17), (0.089, 0.12), (0.137, 0.08)]:   # eco de sala
    d = int(atraso * SR)
    for i in range(len(b) - 1, d, -1): b[i] += g * b[i - d]
m = max(abs(x) for x in b); f = int(0.05 * SR)
for k in range(f): b[-f + k] *= 1 - k / f
with wave.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "chegou.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b"".join(struct.pack("<h", int(x / m * 0.7 * 32767)) for x in b))
