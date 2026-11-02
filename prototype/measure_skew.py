"""Unabhängige Schräglagenmessung per Projektionsprofil: Winkel, bei dem die Zeilensumme die größte Varianz hat.
Aufruf: measure_skew.py bild.png ...   Ausgabe: Winkel in Grad (positiv = Text steigt nach rechts, gegen den Uhrzeigersinn)."""
import sys, cv2, numpy as np
def skew(path):
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    s = 1000 / max(g.shape); g = cv2.resize(g, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    b = (g < cv2.threshold(g, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[0]).astype(np.float32)
    # nur Bereiche mit Text (Hell-/Dunkel-Rand ausblenden): mittleres Rechteck
    h, w = b.shape; b = b[int(.1*h):int(.9*h), int(.1*w):int(.9*w)]
    def score(a):
        M = cv2.getRotationMatrix2D((b.shape[1]/2, b.shape[0]/2), a, 1.0)
        r = cv2.warpAffine(b, M, (b.shape[1], b.shape[0]), flags=cv2.INTER_LINEAR)
        p = r.sum(axis=1); return float(np.var(p))
    coarse = max(np.arange(-15, 15.01, 0.5), key=score)
    return max(np.arange(coarse-0.6, coarse+0.61, 0.05), key=score)
for p in sys.argv[1:]: print(f"{p.split('/')[-1]:40s} {skew(p):+6.2f}°")
