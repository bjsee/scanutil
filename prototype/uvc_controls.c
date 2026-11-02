// Liest Standard-UVC-Controls des CZUR (04fc:6333) per IOKit - nur GET_*, ohne Interface zu öffnen.
// Vorgehen wie uvc-util: ControlRequest auf dem Video-Control-Interface, ohne USBInterfaceOpen.
// Build: clang -O2 uvc_controls.c -framework IOKit -framework CoreFoundation -o uvc_controls
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static long num(io_service_t s, CFStringRef key) {
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0); long v = -1;
    if (r) { if (CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberLongType, &v); CFRelease(r); } return v;
}
typedef struct { const char *name; uint8_t unit, sel, len; int is_signed; } Ctl;
static IOUSBInterfaceInterface300 **intf; static uint8_t ifnum;

static int get(uint8_t unit, uint8_t sel, uint8_t req, uint8_t len, long long *out) {
    uint8_t buf[8] = {0};
    IOUSBDevRequest r = { .bmRequestType = 0xA1, .bRequest = req, .wValue = (uint16_t)(sel << 8),
                          .wIndex = (uint16_t)((unit << 8) | ifnum), .wLength = len, .pData = buf };
    IOReturn kr = (*intf)->ControlRequest(intf, 0, &r);
    if (kr != kIOReturnSuccess) return (int)kr;
    long long v = 0; for (int i = len - 1; i >= 0; i--) v = (v << 8) | buf[i]; *out = v; return 0;
}
static int set16(uint8_t unit, uint8_t sel, uint16_t value) {
    uint8_t buf[2] = { (uint8_t)(value & 0xff), (uint8_t)(value >> 8) };
    IOUSBDevRequest r = { .bmRequestType = 0x21, .bRequest = 0x01 /* SET_CUR */, .wValue = (uint16_t)(sel << 8),
                          .wIndex = (uint16_t)((unit << 8) | ifnum), .wLength = 2, .pData = buf };
    return (int)(*intf)->ControlRequest(intf, 0, &r);
}
int main(int argc, char **argv) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostInterface");
    io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, m, &it);
    io_service_t svc, found = 0;
    while ((svc = IOIteratorNext(it))) {
        if (num(svc, CFSTR("idVendor")) == 0x04fc && num(svc, CFSTR("idProduct")) == 0x6333
            && num(svc, CFSTR("bInterfaceClass")) == 14 && num(svc, CFSTR("bInterfaceSubClass")) == 1) { found = svc; break; }
        IOObjectRelease(svc);
    }
    if (!found) { fprintf(stderr, "Video-Control-Interface nicht gefunden\n"); return 1; }
    ifnum = (uint8_t)num(found, CFSTR("bInterfaceNumber"));
    IOCFPlugInInterface **plug; SInt32 score;
    IOReturn kr = IOCreatePlugInInterfaceForService(found, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || !plug) { fprintf(stderr, "PlugIn: 0x%x\n", kr); return 1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&intf);
    (*plug)->Release(plug);
    if (!intf) { fprintf(stderr, "Interface-Schnittstelle nicht verfügbar\n"); return 1; }
    printf("Video-Control-Interface %u gefunden (ControlRequest ohne Öffnen)\n\n", ifnum);
    // Einziger Schreibzugriff: ./uvc_controls set-sharpness <0..15>  (Bereich vorher per GET_MIN/GET_MAX geprüft)
    if (argc == 3 && strcmp(argv[1], "set-sharpness") == 0) {
        long long mn, mx, cur; int v = atoi(argv[2]);
        if (get(3, 0x08, 0x82, 2, &mn) || get(3, 0x08, 0x83, 2, &mx) || get(3, 0x08, 0x81, 2, &cur)) { fprintf(stderr, "Bereich nicht lesbar\n"); return 1; }
        if (v < mn || v > mx) { fprintf(stderr, "Wert %d außerhalb %lld..%lld\n", v, mn, mx); return 1; }
        IOReturn e = set16(3, 0x08, (uint16_t)v);
        long long after = -1; get(3, 0x08, 0x81, 2, &after);
        printf("Sharpness: %lld -> gesetzt %d (SET_CUR: 0x%x) -> zurückgelesen %lld\n", cur, v, e, after);
        return e ? 1 : (after == v ? 0 : 2);
    }
    const uint8_t PU = 3, CT = 10;
    Ctl c[] = {
        {"Brightness",PU,0x02,2,1},{"Contrast",PU,0x03,2,0},{"Hue",PU,0x06,2,1},{"Saturation",PU,0x07,2,0},
        {"Sharpness",PU,0x08,2,0},{"Gamma",PU,0x09,2,0},{"WB-Temperatur",PU,0x0A,2,0},{"WB-Temp. auto",PU,0x0B,1,0},
        {"Backlight-Comp.",PU,0x01,2,0},{"Gain",PU,0x04,2,0},{"Netzfrequenz",PU,0x05,1,0},
        {"AE-Modus",CT,0x02,1,0},{"Belichtungszeit (100us)",CT,0x04,4,0},{"Zoom abs",CT,0x0B,2,0}};
    const uint8_t reqs[5] = {0x81,0x82,0x83,0x84,0x87}; // CUR MIN MAX RES DEF
    printf("%-24s %10s %10s %10s %8s %10s\n", "Control", "aktuell", "min", "max", "Schritt", "Default");
    for (size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
        printf("%-24s", c[i].name);
        for (int k = 0; k < 5; k++) {
            long long v; int e = get(c[i].unit, c[i].sel, reqs[k], c[i].len, &v);
            if (e) printf(" %10s", "Fehler");
            else { if (c[i].is_signed && c[i].len == 2) v = (int16_t)v; printf(" %10lld", v); }
        }
        printf("\n");
    }
    return 0;
}
