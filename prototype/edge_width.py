"""Misst die Kantenanstiegsbreite (10-90 %) einer Hell/Dunkel-Kante (Papierkante) in Bildpixeln.
Aufruf: edge_width.py x0 y0 x1 y1 bild...   (relative ROI; Kante verläuft grob waagerecht)
Echte Auflösung: Breite in Pixeln bleibt konstant. Hochskalierung: Breite wächst proportional zur Pixelzahl."""
import sys, cv2, numpy as np
x0,y0,x1,y1 = map(float, sys.argv[1:5])
print("Datei".ljust(22),"Größe".ljust(10),"Spalten","Anstieg px","Anstieg px @5696-Breite")
for p in sys.argv[5:]:
    g = cv2.imread(p, cv2.IMREAD_GRAYSCALE).astype(np.float64); h,w = g.shape
    roi = g[int(y0*h):int(y1*h), int(x0*w):int(x1*w)]
    # Kante je Spalte: Position der größten Steigung -> Profile darauf ausrichten
    half = int(30*w/5696)
    xs, ys = [], []
    for c in range(roi.shape[1]):
        col = cv2.GaussianBlur(roi[:,c:c+1],(1,0),2.0)[:,0] if False else roi[:,c]
        d = np.abs(np.diff(np.convolve(col, np.ones(5)/5, mode='same')))
        k = int(np.argmax(d[10:-10]))+10
        if k-half<0 or k+half>=len(col): continue
        pr = col[k-half:k+half]
        lo, hi = pr[:half//3].mean(), pr[-half//3:].mean()
        if abs(hi-lo) < 60: continue
        n = (pr-lo)/(hi-lo)
        cross = np.interp(0.5, n if hi>lo else n[::-1], np.arange(len(n)) if hi>lo else np.arange(len(n))[::-1]) if False else None
        # sub-pixel 50%-Kreuzung
        idx = np.where((n[:-1]<0.5)&(n[1:]>=0.5))[0]
        if len(idx)!=1: continue
        i = idx[0]; sp = i+(0.5-n[i])/(n[i+1]-n[i])
        xs.extend(np.arange(len(n))-sp); ys.extend(n)
    xs=np.array(xs); ys=np.array(ys)
    if len(xs)==0: print(p, "keine Kante"); continue
    bins = np.arange(-half, half, 0.25); b = np.digitize(xs,bins)
    esf = np.array([ys[b==i].mean() if (b==i).any() else np.nan for i in range(1,len(bins))]); bx = bins[:-1]+0.125
    ok = ~np.isnan(esf); esf, bx = esf[ok], bx[ok]
    r10 = np.interp(0.1, esf, bx); r90 = np.interp(0.9, esf, bx)
    wpx = r90-r10
    print(p.split('/')[-1].ljust(22), f"{w}x{h}".ljust(10), str(len(xs)//(2*half)).ljust(7), f"{wpx:10.2f}", f"{wpx*5696/w:10.2f}")
