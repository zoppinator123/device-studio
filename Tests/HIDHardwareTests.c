#include "../Sources/CDeviceSupport/HIDMouse.c"
#include <stdio.h>

// Explicit opt-in integration check. No keyboard events or recordings are made.
static void observed(void *context, int pressed) { (void)context; (void)pressed; }
int main(void) {
    DSMouse *mouse = ds_mouse_open();
    if (!mouse) { puts("Hardware unavailable: allow Input Monitoring for the calling app."); return 2; }
    int connected = 0;
    for (int attempt = 0; attempt < 3 && !connected; attempt++) connected = ds_mouse_probe(mouse) == 0;
    if (!connected) { ds_mouse_close(mouse); puts("Hardware unavailable: wake or reconnect the Logitech mouse."); return 2; }
    printf("Hardware: %s\n", ds_mouse_name(mouse));
    int capture = ds_mouse_begin_button(mouse, 0x01a0, observed, NULL);
    int restored = ds_mouse_end_button(mouse);
    ds_mouse_close(mouse);
    printf("Temporary haptic thumb capture: %s\n", capture == 0 ? "PASS" : "FAIL");
    printf("Original diversion restored and read back: %s\n", restored == 0 ? "PASS" : "FAIL");
    return capture || restored ? 1 : 0;
}
