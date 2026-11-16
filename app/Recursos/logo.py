# Desenha o logo da Cubo: cubo amarelo em pixel-art com olhos simpáticos.
import random
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# fundo: "squircle" azul-noite com gradiente
fundo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / S
    gd.line([(0, y), (S, y)], fill=(int(40 + 30 * t), int(70 + 20 * t), int(140 - 30 * t), 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([100, 100, 924, 924], radius=185, fill=255)
fundo.paste(grad, (0, 0), mask)
img.alpha_composite(fundo)

# sombra
sombra = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sombra).ellipse([300, 760, 724, 850], fill=(0, 0, 0, 110))
img.alpha_composite(sombra.filter(ImageFilter.GaussianBlur(18)))

d = ImageDraw.Draw(img)
N = 8
F = (512, 480)              # vértice frontal de cima
R = (250, -144)             # eixo para a direita/cima
L = (-250, -144)            # eixo para a esquerda/cima
D = (0, 290)                # eixo para baixo
random.seed(7)

def add(p, v, k=1.0): return (p[0] + v[0] * k, p[1] + v[1] * k)

def face(origem, a, b, cor_base, celulas=None):
    for i in range(N):
        for j in range(N):
            cor = (celulas or {}).get((i, j))
            if cor is None:
                v = random.randint(-14, 14)
                cor = tuple(max(0, min(255, c + v)) for c in cor_base)
            p0 = add(add(origem, a, i / N), b, j / N)
            p1 = add(p0, a, 1 / N); p2 = add(p1, b, 1 / N); p3 = add(p0, b, 1 / N)
            d.polygon([p0, p1, p2, p3], fill=cor + (255,))

# topo (mais claro)
face(add(F, (0, 0)), R, L, (255, 222, 70))
# face direita (mais escura)
face(F, R, D, (214, 150, 22))

# face esquerda com a cara: i=0 junto à aresta da frente, j de cima para baixo
B, P, W, K, ROSA = (255,255,255), (35,30,40), (255,255,255), (60,35,20), (255,140,150)
cara = {}
for (i0) in (1, 5):                    # olhos 2x3
    for di in range(2):
        for j in range(1, 4):
            cara[(i0 + di, j)] = W
for (i, j) in [(1, 2), (1, 3), (5, 2), (5, 3)]:   # pupilas (olhar para o lado de dentro/baixo)
    cara[(i, j)] = P
for (i, j) in [(2, 2), (5, 2)]:                   # brilho fica branco (já é)
    pass
cara[(2, 5)] = K; cara[(5, 5)] = K                 # sorriso
cara[(3, 6)] = K; cara[(4, 6)] = K
cara[(0, 4)] = ROSA; cara[(7, 4)] = ROSA           # bochechas
face(F, L, D, (245, 188, 35), cara)

# contorno escuro fino
cont = [add(F, L), add(add(F, L), (0, 0)), add(add(F, L), R), add(F, R), add(add(F, R), D), add(F, D), add(add(F, L), D)]
d.line([add(F, L), add(add(F, L), R), add(F, R), add(add(F, R), D), add(F, D), add(add(F, L), D), add(F, L)],
       fill=(90, 55, 10, 255), width=8, joint="curve")
img.save("logo-1024.png")
