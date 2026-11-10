// Exercise the actual production input-report parser without opening hardware.
#include "../Sources/CDeviceSupport/HIDMouse.c"
#include <assert.h>
#include <stdio.h>

static int presses, releases;
static void changed(void *context, int pressed) {
    (void)context;
    if (pressed) presses++; else releases++;
}
static void deliver(DSMouse *mouse, uint8_t *packet, int length) {
    report(mouse, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x11, packet, length);
}
int main(void) {
    DSMouse mouse = { .slot = 1, .controls_feature = 13, .active_cid = 0x1a0, .button_callback = changed };
    uint8_t down[20] = {0x11, 1, 13, 0, 0x01, 0xa0};
    uint8_t up[20] = {0x11, 1, 13, 0};
    deliver(&mouse, up, 20); assert(!presses && !releases);
    deliver(&mouse, down, 20); assert(presses == 1 && releases == 0);
    deliver(&mouse, down, 20); assert(presses == 1 && releases == 0);
    uint8_t wrong_device[20] = {0x11, 2, 13, 0};
    deliver(&mouse, wrong_device, 20); assert(releases == 0);
    deliver(&mouse, up, 5); assert(releases == 0);
    deliver(&mouse, up, 20); assert(presses == 1 && releases == 1);
    deliver(&mouse, up, 20); assert(releases == 1);
    deliver(&mouse, down, 20); assert(presses == 2);
    removed(&mouse, 0, NULL); assert(releases == 2 && !mouse.button_pressed);
    deliver(&mouse, down, 20); assert(presses == 2); // no stuck key from reports queued at disconnect
    removed(&mouse, 0, NULL); assert(releases == 2);
    puts("PASS: production HID++ parser handles thumb down/up, duplicates, wrong devices, truncated packets, and disconnect release");
    return 0;
}
