"""Liest Wertebereiche und aktuelle Werte der Standard-UVC-Controls (nur GET_*-Anfragen, nichts wird gesetzt).
Extension Units (herstellerspezifisch) werden bewusst NICHT angefasst."""
import sys, struct, usb.core, usb.backend.libusb1 as lb
be = lb.get_backend(find_library=lambda x: "/opt/homebrew/lib/libusb-1.0.dylib")
dev = usb.core.find(idVendor=0x04fc, idProduct=0x6333, backend=be)
if dev is None: sys.exit("Gerät nicht gefunden")
VC_IF, CT, PU = 0, 10, 3
REQ = {"CUR":0x81, "MIN":0x82, "MAX":0x83, "RES":0x84, "DEF":0x87}
# (Name, Unit, Selector, Länge, signiert)
CTRLS = [("Brightness",PU,0x02,2,True),("Contrast",PU,0x03,2,False),("Hue",PU,0x06,2,True),("Saturation",PU,0x07,2,False),
         ("Sharpness",PU,0x08,2,False),("Gamma",PU,0x09,2,False),("WB-Temperatur",PU,0x0A,2,False),("WB-Temp. auto",PU,0x0B,1,False),
         ("Backlight-Comp.",PU,0x01,2,False),("Gain",PU,0x04,2,False),("Netzfrequenz",PU,0x05,1,False),
         ("AE-Modus",CT,0x02,1,False),("Belichtungszeit abs (100 µs)",CT,0x04,4,False),("Zoom abs",CT,0x0B,2,False)]
def get(unit, sel, ln, signed, req):
    try:
        d = bytes(dev.ctrl_transfer(0xA1, REQ[req], sel<<8, (unit<<8)|VC_IF, ln, timeout=1000))
    except Exception as e:
        return f"Fehler:{type(e).__name__}"
    return int.from_bytes(d, "little", signed=signed)
print(f"{'Control':30s} {'aktuell':>9s} {'min':>9s} {'max':>9s} {'Schritt':>8s} {'Default':>9s}")
for name, unit, sel, ln, sg in CTRLS:
    print(f"{name:30s} " + " ".join(f"{str(get(unit, sel, ln, sg, r)):>{w}s}" for r, w in [("CUR",9),("MIN",9),("MAX",9),("RES",8),("DEF",9)]))
