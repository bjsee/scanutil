"""Slanted-Edge-MTF aus den vier 25-mm-Quadraten des Testcharts (make_chart.py).
Aufruf: slanted_edge_mtf.py bild.png ...   Ausgabe: MTF50/MTF10 in Zyklen/mm und Zyklen/Pixel, Mittel über alle senkrechten Kanten."""
import sys, cv2, numpy as np
SIDE_MM = 25.0
def squares(g):
    h, w = g.shape; s = w/5696
    blur = cv2.GaussianBlur(g, (0,0), 3*s)
    mask = (blur < 110).astype(np.uint8)
    n, lab, st, cen = cv2.connectedComponentsWithStats(mask)
    out = []
    for i in range(1, n):
        x,y,bw,bh,a = st[i]
        if x==0 or y==0 or x+bw>=w or y+bh>=h: continue
        if not (40000*s*s < a < 250000*s*s): continue
        if a/(bw*bh) < 0.7: continue
        cnt = cv2.findContours((lab==i).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0][0]
        (cx,cy),(rw,rh),ang = cv2.minAreaRect(cnt)
        if abs(rw-rh) > 0.1*max(rw,rh): continue
        out.append((x,y,bw,bh,(rw+rh)/2))
    return out
def edge_mtf(g, x0, x1, y0, y1):
    """Senkrechte Kante in Box; liefert (freq_cyc_per_px, mtf)."""
    roi = g[y0:y1, x0:x1].astype(np.float64)
    ys, xs = np.mgrid[y0:y1, x0:x1]
    # Kantenposition je Zeile: 50%-Kreuzung
    lo, hi = np.percentile(roi, 3), np.percentile(roi, 97)
    n = (roi-lo)/(hi-lo)
    pts = []
    for r in range(roi.shape[0]):
        row = n[r]; idx = np.where(((row[:-1]-0.5)*(row[1:]-0.5) <= 0) & (row[:-1]!=row[1:]))[0]
        if len(idx)!=1: continue
        i = idx[0]; pts.append((y0+r, x0+i+(0.5-row[i])/(row[i+1]-row[i])))
    if len(pts) < 50: return None
    pts = np.array(pts); a, b = np.polyfit(pts[:,0], pts[:,1], 1)   # x = a*y + b
    d = (xs - (a*ys + b)) / np.sqrt(1+a*a)
    sign = 1.0 if np.mean(n[:, -3:]) > np.mean(n[:, :3]) else -1.0
    bins = np.arange(-12, 12.001, 0.25); idx = np.digitize(d.ravel(), bins)
    v = n.ravel(); esf = np.array([v[idx==k].mean() if (idx==k).sum()>3 else np.nan for k in range(1, len(bins))])
    ok = ~np.isnan(esf)
    if ok.sum() < len(esf)*0.9: return None
    esf = np.interp(np.arange(len(esf)), np.where(ok)[0], esf[ok])
    lsf = np.diff(esf)*sign; lsf *= np.hanning(len(lsf))
    mtf = np.abs(np.fft.rfft(lsf, 4096)); mtf /= mtf[0]
    f = np.fft.rfftfreq(4096, d=0.25)          # Zyklen je Pixel
    return f, mtf
def at(f, m, level):
    below = np.where(m < level)[0]
    if len(below)==0: return f[-1]
    k = below[0]; return np.interp(level, [m[k], m[k-1]], [f[k], f[k-1]])
for p in sys.argv[1:]:
    g = cv2.imread(p, cv2.IMREAD_GRAYSCALE); h,w = g.shape
    sq = squares(g); res50, res10, ppm, mt = [], [], [], []
    for (x,y,bw,bh,side) in sq:
        px_mm = side/SIDE_MM; m = int(0.18*bh)
        for (ex0, ex1) in [(x-14, x+15), (x+bw-14, x+bw+15)]:
            r = edge_mtf(g, max(0,ex0), ex1, y+m, y+bh-m)
            if r is None: continue
            f, mm = r; res50.append(at(f,mm,0.5)); res10.append(at(f,mm,0.1)); ppm.append(px_mm)
    if not res50: print(p.split('/')[-1], "keine auswertbaren Kanten"); continue
    ppm = np.mean(ppm); a50=np.mean(res50); a10=np.mean(res10)
    print(f"{p.split('/')[-1]:26s} {w}x{h}  Quadrate={len(sq)} Kanten={len(res50)}  {ppm:5.2f} px/mm  "
          f"MTF50={a50:.3f} c/px = {a50*ppm:.2f} lp/mm (±{np.std(res50)*ppm:.2f})   MTF10={a10:.3f} c/px = {a10*ppm:.2f} lp/mm")
