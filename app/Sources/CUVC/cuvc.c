#include "cuvc.h"
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define PU_UNIT 3
#define PU_SHARPNESS 0x08

static long number_property(io_service_t service, CFStringRef key) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    long value = -1;
    if (ref) {
        if (CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue(ref, kCFNumberLongType, &value);
        CFRelease(ref);
    }
    return value;
}

// Öffnet das Video-Control-Interface (ohne USBInterfaceOpen) und gibt es an die Funktion weiter.
static int with_interface(int (*body)(IOUSBInterfaceInterface300 **, uint8_t, void *), void *context) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) != KERN_SUCCESS) return -1;
    io_service_t service, found = 0;
    while ((service = IOIteratorNext(iterator))) {
        if (number_property(service, CFSTR("idVendor")) == 0x04fc && number_property(service, CFSTR("idProduct")) == 0x6333
            && number_property(service, CFSTR("bInterfaceClass")) == 14 && number_property(service, CFSTR("bInterfaceSubClass")) == 1) {
            found = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!found) return -1;
    uint8_t interface_number = (uint8_t)number_property(found, CFSTR("bInterfaceNumber"));

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score;
    IOReturn status = IOCreatePlugInInterfaceForService(found, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(found);
    if (status != kIOReturnSuccess || !plugin) return status ? status : -1;
    IOUSBInterfaceInterface300 **interface = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&interface);
    (*plugin)->Release(plugin);
    if (!interface) return -1;
    int result = body(interface, interface_number, context);
    (*interface)->Release(interface);
    return result;
}

static int read_value(IOUSBInterfaceInterface300 **interface, uint8_t interface_number, uint8_t request, int *out) {
    uint8_t buffer[2] = {0, 0};
    IOUSBDevRequest r = { .bmRequestType = 0xA1, .bRequest = request, .wValue = (uint16_t)(PU_SHARPNESS << 8),
                          .wIndex = (uint16_t)((PU_UNIT << 8) | interface_number), .wLength = 2, .pData = buffer };
    IOReturn status = (*interface)->ControlRequest(interface, 0, &r);
    if (status != kIOReturnSuccess) return status;
    *out = buffer[0] | (buffer[1] << 8);
    return 0;
}

typedef struct { int *value, *min, *max, *def; } GetContext;
static int get_body(IOUSBInterfaceInterface300 **interface, uint8_t number, void *context) {
    GetContext *c = context;
    int status = read_value(interface, number, 0x81, c->value);
    if (!status && c->min) status = read_value(interface, number, 0x82, c->min);
    if (!status && c->max) status = read_value(interface, number, 0x83, c->max);
    if (!status && c->def) status = read_value(interface, number, 0x87, c->def);
    return status;
}
int cuvc_get_sharpness(int *value, int *min, int *max, int *def) {
    GetContext c = { value, min, max, def };
    return with_interface(get_body, &c);
}

static int set_body(IOUSBInterfaceInterface300 **interface, uint8_t number, void *context) {
    int wanted = *(int *)context, min = 0, max = 0;
    int status = read_value(interface, number, 0x82, &min);
    if (!status) status = read_value(interface, number, 0x83, &max);
    if (status) return status;
    if (wanted < min || wanted > max) return -2;       // außerhalb des gemeldeten Bereichs
    uint8_t buffer[2] = { (uint8_t)(wanted & 0xff), (uint8_t)(wanted >> 8) };
    IOUSBDevRequest r = { .bmRequestType = 0x21, .bRequest = 0x01 /* SET_CUR */, .wValue = (uint16_t)(PU_SHARPNESS << 8),
                          .wIndex = (uint16_t)((PU_UNIT << 8) | number), .wLength = 2, .pData = buffer };
    return (*interface)->ControlRequest(interface, 0, &r);
}
int cuvc_set_sharpness(int value) {
    return with_interface(set_body, &value);
}

// Liest die Konfigurationsbeschreibung über das Geräte-Objekt. Das öffnet das Gerät nicht und stört den Videostrom nicht.
int cuvc_config_descriptor(unsigned char *out, int capacity) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return -1;
    io_service_t service, found = 0;
    while ((service = IOIteratorNext(iterator))) {
        if (number_property(service, CFSTR("idVendor")) == 0x04fc && number_property(service, CFSTR("idProduct")) == 0x6333) {
            found = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!found) return -1;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score;
    IOReturn status = IOCreatePlugInInterfaceForService(found, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(found);
    if (status != kIOReturnSuccess || !plugin) return -2;
    IOUSBDeviceInterface320 **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (!device) return -3;
    IOUSBConfigurationDescriptorPtr descriptor = NULL;
    int result = -4;
    if ((*device)->GetConfigurationDescriptorPtr(device, 0, &descriptor) == kIOReturnSuccess && descriptor) {
        int length = descriptor->wTotalLength;
        if (out) for (int i = 0; i < length && i < capacity; i++) out[i] = ((unsigned char *)descriptor)[i];
        result = length;
    }
    (*device)->Release(device);
    return result;
}
