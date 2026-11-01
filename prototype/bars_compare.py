"""Legt mehrere Chart-Aufnahmen per SIFT-Homographie auf die erste (Referenz) und zeigt dieselben Balkengruppen nebeneinander.
Aufruf: bars_compare.py ausgabe.png x0 y0 x1 y1 referenz.png weitere.png ...   (Box in Referenzpixeln)"""
import sys, cv2, numpy as np
out=sys.argv[1]; x0,y0,x1,y1=map(int,sys.argv[2:6]); paths=sys.argv[6:]
ref=cv2.imread(paths[0]); sift=cv2.SIFT_create(nfeatures=20000)
gr=cv2.cvtColor(ref,cv2.COLOR_BGR2GRAY); kr,dr=sift.detectAndCompute(gr,None)
cols=[]
for p in paths:
    im=cv2.imread(p); h,w=im.shape[:2]
    if p!=paths[0]:
        g=cv2.cvtColor(im,cv2.COLOR_BGR2GRAY); k,d=sift.detectAndCompute(g,None)
        m=cv2.BFMatcher().knnMatch(d,dr,k=2); good=[a for a,b in m if a.distance<0.75*b.distance]
        H,inl=cv2.findHomography(np.float32([k[a.queryIdx].pt for a in good]),np.float32([kr[a.trainIdx].pt for a in good]),cv2.RANSAC,2.0)
        print(p.split('/')[-1], "Treffer", len(good), "Inlier", int(inl.sum()))
        im=cv2.warpPerspective(im,H,(ref.shape[1],ref.shape[0]),flags=cv2.INTER_LINEAR)
    c=im[y0:y1,x0:x1]; c=cv2.resize(c,None,fx=4,fy=4,interpolation=cv2.INTER_NEAREST)
    cv2.putText(c,f"{w}x{h}",(4,22),cv2.FONT_HERSHEY_SIMPLEX,0.7,(0,0,255),2); cols.append(c)
cv2.imwrite(out,np.hstack(cols))
