"""Erzeugt synthetische, schiefe Testvorlagen aus einem Textausschnitt (unregelmäßiger Rand, dunkler Grund).
Aufruf: make_skewed.py quelle.png ausgabeordner winkel1 winkel2 ...   (Winkel in Grad, positiv = gegen den Uhrzeigersinn)"""
import sys, os, cv2, numpy as np
src = cv2.imread(sys.argv[1]); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
h, w = src.shape[:2]
crop = src[int(.13*h):int(.62*h), int(.50*w):int(.73*w)].copy()
ch, cw = crop.shape[:2]
rng = np.random.default_rng(7)
def jitter(n, amp):                      # Zufallsweg für ausgefranste Kanten
    v = np.cumsum(rng.normal(0, 1, n)); v -= np.linspace(v[0], v[-1], n); return v / (np.abs(v).max()+1e-9) * amp
# Maske mit unregelmäßigem Rand
mask = np.zeros((ch, cw), np.uint8)
top, bot = jitter(cw, 14), jitter(cw, 14); left, right = jitter(ch, 14), jitter(ch, 14)
poly = [(x, 20 + top[x]) for x in range(cw)] + [(cw-20 + right[y], y) for y in range(ch)] \
     + [(x, ch-20 + bot[x]) for x in range(cw-1, -1, -1)] + [(20 + left[y], y) for y in range(ch-1, -1, -1)]
cv2.fillPoly(mask, [np.array(poly, np.int32)], 255)
for ang in map(float, sys.argv[3:]):
    canvas = np.zeros((h, w, 3), np.uint8) + 8
    M = cv2.getRotationMatrix2D((cw/2, ch/2), ang, 1.0)
    # Ausgabegröße so wählen, dass nichts abgeschnitten wird
    cos, sin = abs(M[0,0]), abs(M[0,1]); nw, nh = int(ch*sin + cw*cos), int(ch*cos + cw*sin)
    M[0,2] += nw/2 - cw/2; M[1,2] += nh/2 - ch/2
    rc = cv2.warpAffine(crop, M, (nw, nh), flags=cv2.INTER_CUBIC)
    rm = cv2.warpAffine(mask, M, (nw, nh), flags=cv2.INTER_LINEAR)
    x0, y0 = (w-nw)//2, (h-nh)//2
    roi = canvas[y0:y0+nh, x0:x0+nw]
    canvas[y0:y0+nh, x0:x0+nw] = np.where(rm[..., None] > 127, rc, roi)
    p = os.path.join(out, f"skew_{ang:+.1f}.png"); cv2.imwrite(p, canvas); print(p)
