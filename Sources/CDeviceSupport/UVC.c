#include "DeviceSupport.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

struct DSUVCCamera { IOUSBDeviceInterface **device; uint8_t interface, processing, terminal; uint32_t location; uint32_t processing_bits, terminal_bits; };

DSUVCCamera *ds_uvc_open(uint16_t vendor, uint16_t product) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBDeviceClassName), &iterator)) return NULL;
    io_service_t service; DSUVCCamera *camera = NULL;
    while ((service = IOIteratorNext(iterator))) {
        IOCFPlugInInterface **plugin = NULL; IOUSBDeviceInterface **device = NULL; SInt32 score;
        IOReturn result = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (result || !plugin) continue;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (void **)&device);
        (*plugin)->Release(plugin);
        if (!device) continue;
        UInt16 vid = 0, pid = 0;
        (*device)->GetDeviceVendor(device, &vid); (*device)->GetDeviceProduct(device, &pid);
        if (vid != vendor || (product && pid != product) || camera) { (*device)->Release(device); continue; }
        IOUSBConfigurationDescriptorPtr descriptor = NULL;
        if ((*device)->GetConfigurationDescriptorPtr(device, 0, &descriptor) || !descriptor) { (*device)->Release(device); continue; }
        camera = calloc(1, sizeof(*camera)); camera->device = device;
        (*device)->GetLocationID(device, &camera->location);
        uint8_t *bytes = (uint8_t *)descriptor; int total = OSSwapLittleToHostInt16(descriptor->wTotalLength), in_control = 0;
        for (int i = 0; i + 2 <= total && bytes[i] >= 2 && i + bytes[i] <= total; i += bytes[i]) {
            uint8_t *d = bytes + i; int length = d[0];
            if (d[1] == 4 && length >= 9) { in_control = d[5] == 14 && d[6] == 1; if (in_control) camera->interface = d[2]; }
            if (!in_control || d[1] != 0x24 || length < 4) continue;
            if (d[2] == 5 && length >= 8) {
                camera->processing = d[3];
                for (int j = 0; j < d[7] && j < 4 && 8 + j < length; j++) camera->processing_bits |= (uint32_t)d[8+j] << (j*8);
            }
            if (d[2] == 2 && length >= 15 && d[4] == 1 && d[5] == 2) {
                camera->terminal = d[3];
                for (int j = 0; j < d[14] && j < 4 && 15+j < length; j++) camera->terminal_bits |= (uint32_t)d[15+j] << (j*8);
            }
        }
    }
    IOObjectRelease(iterator); return camera;
}
void ds_uvc_close(DSUVCCamera *c) { if (c) { (*c->device)->Release(c->device); free(c); } }
uint32_t ds_uvc_location(DSUVCCamera *c) { return c ? c->location : 0; }

static int transfer(DSUVCCamera *c, const DSUVCControl *control, int request, int *value) {
    if (!c || !control || control->size < 1 || control->size > 4) return -1;
    uint32_t data = OSSwapHostToLittleInt32((uint32_t)*value);
    IOUSBDevRequest q = { .bmRequestType = request == 1 ? 0x21 : 0xa1, .bRequest = request,
        .wValue = control->selector << 8, .wIndex = (control->unit << 8) | c->interface,
        .wLength = request == 0x86 ? 1 : control->size, .pData = &data };
    IOReturn result = (*c->device)->DeviceRequest(c->device, &q);
    if (result) return result;
    if (request != 1) {
        if (q.wLenDone != q.wLength) return -2;
        uint32_t raw = OSSwapLittleToHostInt32(data);
        if (request == 0x86) *value = raw & 0xff;
        else if (control->signed_value && control->size == 2) *value = (int16_t)raw;
        else *value = (int)raw;
    }
    return 0;
}
int ds_uvc_get(DSUVCCamera *c, const DSUVCControl *control, int *value) { *value = 0; return transfer(c, control, 0x81, value); }
int ds_uvc_set(DSUVCCamera *c, const DSUVCControl *control, int value) {
    if (!control->writable || value < control->minimum || value > control->maximum) return -3;
    return transfer(c, control, 1, &value);
}
int ds_uvc_controls(DSUVCCamera *c, DSUVCControl *controls, int capacity) {
    if (!c) return 0;
    const struct { const char *name; int terminal, selector, size, sign, bit; } definitions[] = {
        {"Brightness",0,2,2,1,0}, {"Contrast",0,3,2,0,1}, {"Saturation",0,7,2,0,3},
        {"Sharpness",0,8,2,0,4}, {"Gamma",0,9,2,0,5}, {"Gain",0,4,2,0,9},
        {"White balance",0,10,2,0,6}, {"Auto white balance",0,11,1,0,12},
        {"Backlight compensation",0,1,2,0,8}, {"Power line frequency",0,5,1,0,10},
        {"Auto exposure",1,2,1,0,1}, {"Exposure",1,4,4,0,3},
        {"Focus",1,6,2,0,5}, {"Auto focus",1,8,1,0,17}, {"Zoom",1,11,2,0,9}
    };
    int count = 0;
    for (unsigned i = 0; i < sizeof(definitions)/sizeof(definitions[0]) && count < capacity; i++) {
        uint32_t bits = definitions[i].terminal ? c->terminal_bits : c->processing_bits;
        if (!(bits & (1u << definitions[i].bit))) continue;
        DSUVCControl control = { .unit = definitions[i].terminal ? c->terminal : c->processing,
            .selector = definitions[i].selector, .size = definitions[i].size, .signed_value = definitions[i].sign };
        int info = 0;
        if (transfer(c, &control, 0x86, &info) || !(info & 1) || ds_uvc_get(c, &control, &control.current)) continue;
        control.writable = (info & 2) != 0;
        if (transfer(c, &control, 0x82, &control.minimum) || transfer(c, &control, 0x83, &control.maximum)) {
            if (control.size != 1) continue;
            control.minimum = 0; control.maximum = definitions[i].selector == 2 && definitions[i].terminal ? 8 : 1;
            if (!definitions[i].terminal && definitions[i].selector == 5) control.maximum = 2;
        }
        control.step = 1; transfer(c, &control, 0x84, &control.step); if (control.step < 1) control.step = 1;
        control.default_value = control.current; transfer(c, &control, 0x87, &control.default_value);
        if (control.maximum <= control.minimum) continue;
        strlcpy(control.name, definitions[i].name, sizeof(control.name)); controls[count++] = control;
    }
    return count;
}
