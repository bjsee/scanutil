"""Gleicher Bildausschnitt (relative Koordinaten) aus mehreren Auflösungen, nearest-neighbor auf gleiche Breite vergrößert.
Aufruf: crop_compare.py out.png x0 y0 x1 y1 bild1 bild2 ...   (Koordinaten 0..1)"""
import sys, cv2, numpy as np
out = sys.argv[1]; x0,y0,x1,y1 = map(float, sys.argv[2:6]); W = 1000
rows = []
for p in sys.argv[6:]:
    im = cv2.imread(p); h, w = im.shape[:2]
    c = im[int(y0*h):int(y1*h), int(x0*w):int(x1*w)]
    s = W / c.shape[1]
    c = cv2.resize(c, (W, int(c.shape[0]*s)), interpolation=cv2.INTER_NEAREST)
    cv2.putText(c, f"{w}x{h}  (1 Bildpixel = {s:.1f} Anzeigepixel)", (8,24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0,0,255), 2)
    rows.append(c)
cv2.imwrite(out, np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 92])
