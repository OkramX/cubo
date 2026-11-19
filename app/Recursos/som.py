# Gera Recursos/chegou.wav: um "ding-dong" suave, tipo marimba (2 notas, ~0,7 s).
import math, struct, wave
SR = 44100
def nota(f, inicio, dur, vol):
    out = []
    for n in range(int(dur * SR)):
        t = n / SR
        ataque = min(1.0, t / 0.006)
        env = ataque * math.exp(-t * 6.5)
        s = (math.sin(2*math.pi*f*t) + 0.25*math.sin(2*math.pi*f*2*t)*math.exp(-t*14)
             + 0.08*math.sin(2*math.pi*f*3.01*t)*math.exp(-t*25))
        out.append((int(inicio * SR) + n, vol * env * s))
    return out
total = int(0.75 * SR); buf = [0.0] * total
for i, v in nota(1318.5, 0.0, 0.55, 0.22) + nota(1975.5, 0.11, 0.62, 0.18):   # Mi6 -> Si6
    if i < total: buf[i] += v
fim = int(0.05 * SR)
for k in range(fim): buf[total - fim + k] *= 1 - k / fim
with wave.open(__file__.replace("som.py", "chegou.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x)) * 32767)) for x in buf))
