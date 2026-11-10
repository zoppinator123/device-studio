#include "DeviceSupport.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdlib.h>
#include <string.h>

struct DSMouse {
    IOHIDManagerRef manager; IOHIDDeviceRef device;
    uint8_t buffer[64], reply[64], slot, feature, function; int reply_size, waiting, dpi_feature, battery_feature;
    char name[128];
    int controls_feature, active_cid, original_diverted, button_pressed, removed;
    uint8_t software_id;
    DSMouseButtonCallback button_callback; void *button_context;
};
static void report(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id, uint8_t *data, CFIndex length) {
    (void)sender; (void)type; (void)report_id;
    DSMouse *m = context;
    if (!result && !m->removed && length >= 12 && data[1] == m->slot && m->active_cid && data[2] == m->controls_feature && data[3] == 0) {
        int pressed = 0;
        for (int i = 4; i < 12; i += 2) if (data[i]*256 + data[i+1] == m->active_cid) pressed = 1;
        if (pressed != m->button_pressed) {
            m->button_pressed = pressed;
            if (m->button_callback) m->button_callback(m->button_context, pressed);
        }
    }
    if (!result && m->waiting && length >= 4 && data[1] == m->slot &&
        ((data[2] == m->feature && data[3] == m->function) || (length >= 6 && data[2] == 0xff && data[3] == m->feature && data[4] == m->function))) {
        m->reply_size = (int)(length > 64 ? 64 : length); memcpy(m->reply, data, m->reply_size); m->waiting = 0;
    }
}
static int request(DSMouse *m, uint8_t feature, uint8_t function, const uint8_t *parameters, int length) {
    uint8_t packet[20] = {0x11, m->slot, feature, (uint8_t)((function << 4) | m->software_id)};
    if (length > 16) return -1;
    if (parameters && length) memcpy(packet+4, parameters, length);
    m->feature = feature; m->function = packet[3]; m->reply_size = 0; m->waiting = 1;
    IOReturn r = IOHIDDeviceSetReport(m->device, kIOHIDReportTypeOutput, 0x11, packet, sizeof(packet));
    if (r) { m->waiting = 0; return r; }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.18;
    while (m->waiting && CFAbsoluteTimeGetCurrent() < deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    m->waiting = 0;
    return m->reply_size >= 4 && m->reply[2] != 0xff ? 0 : -1;
}
static int feature(DSMouse *m, uint16_t id) {
    uint8_t p[3] = {id >> 8, id & 255, 0};
    return request(m, 0, 0, p, 3) == 0 ? m->reply[4] : 0;
}
DSMouse *ds_mouse_open(void) {
    DSMouse *m = calloc(1, sizeof(*m)); m->software_id = 0xb; m->manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    int vendor = 0x46d, page = 0xff00;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor), p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    const void *keys[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDPrimaryUsagePageKey)}; const void *values[] = {v,p};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(m->manager, match); CFRelease(match); CFRelease(v); CFRelease(p);
    IOHIDManagerOpen(m->manager, 0);
    CFSetRef devices = IOHIDManagerCopyDevices(m->manager);
    if (devices) {
        CFIndex count = CFSetGetCount(devices); const void **items = calloc(count, sizeof(void *)); CFSetGetValues(devices, items);
        // Try each interface; a receiver may expose more than one vendor collection.
        for (CFIndex i = 0; i < count && !m->device; i++) {
            IOHIDDeviceRef candidate = (IOHIDDeviceRef)items[i];
            if (IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess) { m->device = candidate; CFRetain(candidate); }
        }
        free(items); CFRelease(devices);
    }
    if (!m->device) { ds_mouse_close(m); return NULL; }
    IOHIDDeviceRegisterInputReportCallback(m->device, m->buffer, sizeof(m->buffer), report, m);
    IOHIDDeviceScheduleWithRunLoop(m->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    strlcpy(m->name, "Logitech receiver", sizeof(m->name)); return m;
}
int ds_mouse_probe(DSMouse *m) {
    if (!m) return -1;
    // Direct Bluetooth HID++ devices use 0xff, receivers use paired slots 1–6.
    const uint8_t slots[] = {1,2,3,4,5,6,0xff};
    for (int i = 0; i < 7; i++) {
        m->slot = slots[i]; uint8_t p[3] = {0,0,0x42};
        if (request(m,0,1,p,3) || m->reply_size < 7 || m->reply[4] < 2 || m->reply[6] != 0x42) continue;
        m->dpi_feature = feature(m,0x2201); m->battery_feature = feature(m,0x1004);
        int n = feature(m,0x0005);
        if (n && !request(m,n,0,NULL,0)) {
            int total = m->reply[4]; if (total > 127) total = 127; int offset = 0;
            while (offset < total) {
                uint8_t index = offset; if (request(m,n,1,&index,1)) break;
                int length = m->reply_size-4; if (length > total-offset) length = total-offset;
                if (length <= 0) break;
                memcpy(m->name+offset,m->reply+4,length); offset += length;
            }
            m->name[offset] = 0;
        }
        return 0;
    }
    return -1;
}
const char *ds_mouse_name(DSMouse *m) { return m ? m->name : "Not connected"; }
uint64_t ds_mouse_identifier(DSMouse *m) {
    if (!m || !m->device) return 0;
    uint64_t registry = 0;
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(m->device), &registry);
    return (registry << 8) | m->slot;
}
int ds_mouse_dpi(DSMouse *m, int *value, int *minimum, int *maximum, int *step) {
    if (!m || !m->dpi_feature) return -1;
    uint8_t sensor = 0;
    if (request(m,m->dpi_feature,2,&sensor,1) || m->reply_size < 7) return -1;
    *value = m->reply[5]*256+m->reply[6];
    if (!*value && m->reply_size >= 9) *value = m->reply[7]*256+m->reply[8];
    if (request(m,m->dpi_feature,1,&sensor,1)) return -1;
    *minimum = 0; *maximum = 0; *step = 0;
    for (int i = 5; i+1 < m->reply_size; i+=2) {
        int v = m->reply[i]*256+m->reply[i+1]; if (!v) break;
        if ((v & 0xe000) == 0xe000) *step = v & 0x1fff;
        else { if (!*minimum) *minimum = v; *maximum = v; }
    }
    // Only expose a slider for devices advertising a continuous stepped range.
    return *minimum > 0 && *maximum > *minimum && *step > 0 ? 0 : -1;
}
int ds_mouse_set_dpi(DSMouse *m, int value) {
    int old, min, max, step;
    if (ds_mouse_dpi(m,&old,&min,&max,&step) || value < min || value > max || (value-min)%step) return -1;
    uint8_t p[] = {0, value >> 8, value & 255}; return request(m,m->dpi_feature,3,p,3);
}
int ds_mouse_battery(DSMouse *m) {
    if (!m || !m->battery_feature || request(m,m->battery_feature,1,NULL,0) || m->reply_size < 5) return -1;
    return m->reply[4] <= 100 ? m->reply[4] : -1;
}
static void removed(void *context, IOReturn result, void *sender) {
    (void)result; (void)sender;
    DSMouse *m = context; m->removed = 1;
    if (m->button_pressed && m->button_callback) m->button_callback(m->button_context, 0);
    m->button_pressed = 0;
}
int ds_mouse_controls(DSMouse *m, DSMouseControl *controls, int capacity) {
    if (!m) return -1;
    m->controls_feature = feature(m, 0x1b04);
    if (!m->controls_feature || request(m,m->controls_feature,0,NULL,0) || m->reply_size < 5) return -1;
    int total = m->reply[4], count = 0;
    for (int i = 0; i < total && i < 64 && count < capacity; i++) {
        uint8_t index = i;
        if (request(m,m->controls_feature,1,&index,1) || m->reply_size < 13) continue;
        controls[count++] = (DSMouseControl){ m->reply[4]*256+m->reply[5], m->reply[6]*256+m->reply[7], m->reply[8]|m->reply[12]<<8 };
    }
    return count;
}
int ds_mouse_begin_button(DSMouse *m, int cid, DSMouseButtonCallback callback, void *context) {
    if (!m || m->active_cid || !callback) return -1;
    m->software_id = 0xc; // Separate request replies from transient battery/DPI probes.
    DSMouseControl controls[64]; int count = ds_mouse_controls(m, controls, 64), found = 0;
    for (int i = 0; i < count; i++) if (controls[i].cid == cid && (controls[i].flags & 0x20)) found = 1;
    if (!found) return -2;
    uint8_t query[] = {cid >> 8, cid & 255};
    if (request(m,m->controls_feature,2,query,2) || m->reply_size < 9 || m->reply[4]*256+m->reply[5] != cid) return -3;
    m->original_diverted = m->reply[6] & 1;
    m->active_cid = cid; m->button_callback = callback; m->button_context = context;
    // DIVERTED + DIVERTED_VALID. No persistent or raw-motion flags are changed.
    uint8_t set[] = {cid >> 8, cid & 255, 3, 0, 0};
    if (request(m,m->controls_feature,3,set,5) || request(m,m->controls_feature,2,query,2) || m->reply_size < 7 || !(m->reply[6] & 1)) {
        ds_mouse_end_button(m); return -4;
    }
    IOHIDDeviceRegisterRemovalCallback(m->device, removed, m);
    return 0;
}
int ds_mouse_poll(DSMouse *m, double seconds) {
    if (!m || m->removed || !m->active_cid) return -1;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    return m->removed ? -1 : 0;
}
int ds_mouse_end_button(DSMouse *m) {
    if (!m || !m->active_cid) return 0;
    int cid = m->active_cid;
    m->active_cid = 0;
    if (m->button_pressed && m->button_callback) m->button_callback(m->button_context, 0);
    m->button_pressed = 0; m->button_callback = NULL; m->button_context = NULL;
    uint8_t restore[] = {cid >> 8, cid & 255, 2 | m->original_diverted, 0, 0};
    if (m->removed || request(m,m->controls_feature,3,restore,5)) return -1;
    uint8_t query[] = {cid >> 8, cid & 255};
    return request(m,m->controls_feature,2,query,2) || m->reply_size < 7 ||
        m->reply[4]*256+m->reply[5] != cid || (m->reply[6]&1) != m->original_diverted ? -1 : 0;
}
void ds_mouse_close(DSMouse *m) {
    if (!m) return;
    ds_mouse_end_button(m);
    if (m->device) { IOHIDDeviceUnscheduleFromRunLoop(m->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode); IOHIDDeviceClose(m->device,0); CFRelease(m->device); }
    if (m->manager) { IOHIDManagerClose(m->manager,0); CFRelease(m->manager); }
    free(m);
}
