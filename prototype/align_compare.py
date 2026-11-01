"""Legt unsere Aufnahme per SIFT/RANSAC auf den CZUR-Scan (lokale Homographie) und schreibt Vergleichsausschnitte.
Aufruf: align_compare.py czur.jpg unser.png ausgabeordner"""
import sys, cv2, numpy as np, os
czur = cv2.imread(sys.argv[1]); ours = cv2.imread(sys.argv[2]); out = sys.argv[3]; os.makedirs(out, exist_ok=True)
gc = cv2.cvtColor(czur, cv2.COLOR_BGR2GRAY); go = cv2.cvtColor(ours, cv2.COLOR_BGR2GRAY)
sift = cv2.SIFT_create(nfeatures=20000)
kc, dc = sift.detectAndCompute(gc, None); ko, do = sift.detectAndCompute(go, None)
m = cv2.BFMatcher().knnMatch(do, dc, k=2)
good = [a for a,b in m if a.distance < 0.7*b.distance]
print("Merkmale:", len(ko), len(kc), "gute Treffer:", len(good))
src = np.float32([ko[g.queryIdx].pt for g in good]); dst = np.float32([kc[g.trainIdx].pt for g in good])
# Lokale Region: linke Seite, oberer Textblock (Buchseite ist im CZUR-Scan entzerrt -> nur lokal gültig)
def fit(region):
    x0,y0,x1,y1 = region
    sel = (dst[:,0]>=x0)&(dst[:,0]<x1)&(dst[:,1]>=y0)&(dst[:,1]<y1)
    if sel.sum() < 12: return None
    A, inl = cv2.estimateAffinePartial2D(src[sel], dst[sel], method=cv2.RANSAC, ransacReprojThreshold=2.0)
    s = np.hypot(A[0,0], A[1,0]); return A, int(inl.sum()), s
for name, reg in {"links_oben":(250,120,950,520), "links_mitte":(250,560,950,960), "rechts_oben":(1050,120,1750,520), "rechts_unten":(1050,900,1750,1300)}.items():
    r = fit(reg)
    if not r: print(name, "zu wenige Treffer"); continue
    A, n, s = r
    print(f"{name}: Inlier={n}  Maßstab unsere->CZUR = {s:.3f}  (CZUR-Pixel je Pixel unserer 5696-Aufnahme; 1.0 = 1:1)")
    w = cv2.warpAffine(ours, A, (czur.shape[1], czur.shape[0]), flags=cv2.INTER_CUBIC)
    x0,y0,x1,y1 = reg; cx0,cy0 = x0+100, y0+80
    box = (cx0, cy0, cx0+300, cy0+110)
    a = czur[box[1]:box[3], box[0]:box[2]]; b = w[box[1]:box[3], box[0]:box[2]]
    f = 3
    a = cv2.resize(a, None, fx=f, fy=f, interpolation=cv2.INTER_NEAREST); b = cv2.resize(b, None, fx=f, fy=f, interpolation=cv2.INTER_NEAREST)
    cv2.putText(a, "CZUR (3273x2529)", (6,22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0,0,255), 2)
    cv2.putText(b, "unsere Aufnahme 5696x4272, auf CZUR-Raster", (6,22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0,0,255), 2)
    cv2.imwrite(f"{out}/{name}.jpg", np.vstack([a,b]), [cv2.IMWRITE_JPEG_QUALITY, 92])
    # Schärfemaß: mittlere Gradientenstärke im Text (Laplace-Varianz) auf gleichem Raster
    lc = cv2.Laplacian(cv2.cvtColor(a,cv2.COLOR_BGR2GRAY).astype(np.float64), cv2.CV_64F).var()
    lb = cv2.Laplacian(cv2.cvtColor(b,cv2.COLOR_BGR2GRAY).astype(np.float64), cv2.CV_64F).var()
    print(f"   Laplace-Varianz  CZUR={lc:.0f}  unsere={lb:.0f}")
