"""Erzeugt ein Auflösungs-Testchart (A4, Linienpaare je mm) als PDF. Druck: 100 % / 'Tatsächliche Größe', ohne Skalierung.
Je Frequenz zwei Balkengruppen (waagerecht und senkrecht), je 5 Balken; Kantenquadrate für Schärfemessung."""
import sys
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm
from reportlab.lib.pagesizes import A4
out = sys.argv[1] if len(sys.argv) > 1 else "resolution_chart_A4.pdf"
FREQS = [1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7, 8]   # Linienpaare je mm
c = canvas.Canvas(out, pagesize=A4); W, H = A4
c.setTitle("Aufloesungs-Testchart")
c.setFont("Helvetica-Bold", 11); c.drawString(15*mm, H-12*mm, "Auflösungs-Testchart  -  Druck mit 100 % (Tatsächliche Größe), schwarz/weiß, kein Graustufen-Dithering")
c.setFont("Helvetica", 8); c.drawString(15*mm, H-17*mm, "Frequenz in Linienpaaren je mm (lp/mm). Unten: Maßstab zur Kontrolle der Druckgröße.")
y = H-28*mm
for f in FREQS:
    period = 1.0/f              # mm je Linienpaar
    bar = period/2
    c.setFont("Helvetica", 8); c.drawString(15*mm, y-3*mm, f"{f:g} lp/mm")
    # senkrechte Balken (Linien verlaufen senkrecht)
    x0 = 40*mm
    for i in range(5):
        c.rect(x0+i*period*mm, y-8*mm, bar*mm, 10*mm, stroke=0, fill=1)
    # waagerechte Balken
    x1 = 90*mm
    for i in range(5):
        c.rect(x1, y-8*mm+i*period*mm, 10*mm, bar*mm, stroke=0, fill=1)
    # leicht geneigte Balken (5°) gegen Aliasing-Täuschung
    import math
    c.saveState(); c.translate(140*mm, y-8*mm); c.rotate(5)
    for i in range(5):
        c.rect(i*period*mm, 0, bar*mm, 10*mm, stroke=0, fill=1)
    c.restoreState()
    y -= 17*mm
# Kantenquadrate (leicht gedreht, für Kantenmessung)
c.saveState(); c.translate(165*mm, H-60*mm); c.rotate(5); c.rect(0,0,25*mm,25*mm,stroke=0,fill=1); c.restoreState()
c.saveState(); c.translate(165*mm, H-110*mm); c.rotate(5); c.rect(0,0,25*mm,25*mm,stroke=0,fill=1); c.restoreState()
c.saveState(); c.translate(165*mm, H-160*mm); c.rotate(5); c.rect(0,0,25*mm,25*mm,stroke=0,fill=1); c.restoreState()
c.saveState(); c.translate(165*mm, H-210*mm); c.rotate(5); c.rect(0,0,25*mm,25*mm,stroke=0,fill=1); c.restoreState()
# Maßstab 100 mm
c.setLineWidth(0.3); c.line(15*mm, 12*mm, 115*mm, 12*mm)
for i in range(11):
    c.line((15+i*10)*mm, 10.5*mm, (15+i*10)*mm, 13.5*mm)
c.setFont("Helvetica", 8); c.drawString(15*mm, 6*mm, "Linie = 100 mm. Bitte nachmessen: weicht sie ab, wurde skaliert.")
c.showPage(); c.save(); print("geschrieben:", out)
