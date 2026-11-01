"""Liest die USB-Deskriptoren (nur Lesen, kein Öffnen/Beanspruchen von Interfaces) des CZUR (04fc:6333) und gliedert sie.
Rohbytes der Konfiguration werden hexadezimal ausgegeben, UVC-Descriptoren werden interpretiert."""
import os, sys, struct, usb.core, usb.backend.libusb1 as lb
be = lb.get_backend(find_library=lambda x: "/opt/homebrew/lib/libusb-1.0.dylib")
dev = usb.core.find(idVendor=0x04fc, idProduct=0x6333, backend=be)
if dev is None: sys.exit("Gerät nicht gefunden")
print(f"Gerät {dev.idVendor:04x}:{dev.idProduct:04x} USB {dev.bcdUSB>>8}.{dev.bcdUSB&0xff:02x} Klasse={dev.bDeviceClass} bcdDevice={dev.bcdDevice:04x} Konfigurationen={dev.bNumConfigurations}")
for cfg in dev:
    print(f"Konfiguration {cfg.bConfigurationValue}: Interfaces={cfg.bNumInterfaces} MaxPower={cfg.bMaxPower*2}mA Länge={cfg.wTotalLength}")
    for intf in cfg:
        print(f"  Interface {intf.bInterfaceNumber} alt={intf.bAlternateSetting} Klasse={intf.bInterfaceClass:#04x} Sub={intf.bInterfaceSubClass:#04x} Endpunkte={[hex(e.bEndpointAddress)+'/'+str(e.wMaxPacketSize) for e in intf]}")
# Rohdeskriptor der Konfiguration holen und UVC-Teile deuten
raw = bytes(dev.ctrl_transfer(0x80, 6, 0x0200, 0, 4096))
total = struct.unpack_from("<H", raw, 2)[0]; raw = raw[:total]
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "config_descriptor.bin"), "wb").write(raw)
print("\nUVC-Class-Specific-Descriptoren:")
i = 0; cur = None
while i < len(raw):
    l, t = raw[i], raw[i+1]
    if t == 4: cur = (raw[i+2], raw[i+5], raw[i+6])
    if t == 0x24 and cur and cur[1] == 0x0e:
        sub = raw[i+2]
        if cur[2] == 1:   # Video Control
            names = {1:"VC_HEADER",2:"INPUT_TERMINAL",3:"OUTPUT_TERMINAL",4:"SELECTOR_UNIT",5:"PROCESSING_UNIT",6:"EXTENSION_UNIT"}
            line = f"  IF{cur[0]} {names.get(sub, sub)}"
            if sub == 5: line += f" ID={raw[i+3]} Controls={raw[i+8:i+8+raw[i+7]].hex()}"
            if sub == 2: line += f" ID={raw[i+3]} Typ={struct.unpack_from('<H', raw, i+4)[0]:#06x}" + (f" Camera-Controls={raw[i+15:i+15+raw[i+14]].hex()}" if struct.unpack_from('<H', raw, i+4)[0]==0x201 else "")
            if sub == 6: line += f" ID={raw[i+3]} GUID={raw[i+4:i+20].hex()} Controls={raw[i+22:i+22+raw[i+21]].hex()}"
            print(line)
        elif cur[2] == 2:  # Video Streaming
            names = {1:"VS_INPUT_HEADER",4:"FORMAT_UNCOMPRESSED",5:"FRAME_UNCOMPRESSED",6:"FORMAT_MJPEG",7:"FRAME_MJPEG",3:"STILL_IMAGE_FRAME",13:"COLORFORMAT"}
            if sub in (1,4,6,3,13) : print(f"  IF{cur[0]} {names.get(sub, sub)}" + (f" Methode_Standbild={raw[i+9]} Triggerung={raw[i+11]}" if sub==1 else ""))
            if sub in (5,7):
                w,h = struct.unpack_from("<HH", raw, i+5); print(f"  IF{cur[0]} {names[sub]} {w}x{h}")
            if sub == 3:
                n = raw[i+4]; print(f"     Standbild-Größen: {[struct.unpack_from('<HH', raw, i+5+4*k) for k in range(n)]}")
    i += l
