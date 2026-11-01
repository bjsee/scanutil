"""Radiales Leistungsspektrum je Bild: zeigt, bis zu welcher Ortsfrequenz echte Details vorhanden sind.
Aufruf: analyze_spectrum.py bild1.png bild2.png ...   (Frequenz in Zyklen/Pixel, Nyquist = 0.5)"""
import sys, numpy as np, cv2

BANDS = [(0.02,0.05),(0.05,0.1),(0.1,0.15),(0.15,0.2),(0.2,0.3),(0.3,0.4),(0.4,0.5)]
print("Datei".ljust(24), "Größe".ljust(11), *[f"{a:.2f}-{b:.2f}".rjust(10) for a,b in BANDS], " [dB relativ zu Band 0.02-0.05]")
for p in sys.argv[1:]:
    img = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
    h, w = img.shape
    # mittlerer 2048x2048-Ausschnitt (Pixelraster, kein Resampling), gefenstert
    s = min(2048, h, w); y0, x0 = (h-s)//2, (w-s)//2
    c = img[y0:y0+s, x0:x0+s].astype(np.float64)
    c -= c.mean(); c *= np.outer(np.hanning(s), np.hanning(s))
    P = np.abs(np.fft.fftshift(np.fft.fft2(c)))**2
    yy, xx = np.indices(P.shape); r = np.hypot(yy-s/2, xx-s/2)/s
    vals = [P[(r>=a)&(r<b)].mean() for a,b in BANDS]
    ref = vals[0]
    print(p.split('/')[-1].ljust(24), f"{w}x{h}".ljust(11), *[f"{10*np.log10(v/ref):10.1f}" for v in vals])
