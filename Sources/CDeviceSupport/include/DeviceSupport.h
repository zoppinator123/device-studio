#ifndef DEVICE_SUPPORT_H
#define DEVICE_SUPPORT_H
#include <stdint.h>

typedef struct DSUVCCamera DSUVCCamera;
typedef struct {
    int unit, selector, size, signed_value;
    int minimum, maximum, step, current, default_value, writable;
    char name[64];
} DSUVCControl;
DSUVCCamera *ds_uvc_open(uint16_t vendor, uint16_t product);
void ds_uvc_close(DSUVCCamera *camera);
uint32_t ds_uvc_location(DSUVCCamera *camera);
int ds_uvc_controls(DSUVCCamera *camera, DSUVCControl *controls, int capacity);
int ds_uvc_get(DSUVCCamera *camera, const DSUVCControl *control, int *value);
int ds_uvc_set(DSUVCCamera *camera, const DSUVCControl *control, int value);

// HID++ access is serialized by the caller; requests never seize the mouse.
typedef struct DSMouse DSMouse;
DSMouse *ds_mouse_open(void);
void ds_mouse_close(DSMouse *mouse);
int ds_mouse_probe(DSMouse *mouse);
const char *ds_mouse_name(DSMouse *mouse);
uint64_t ds_mouse_identifier(DSMouse *mouse);
int ds_mouse_dpi(DSMouse *mouse, int *value, int *minimum, int *maximum, int *step);
int ds_mouse_set_dpi(DSMouse *mouse, int value);
int ds_mouse_battery(DSMouse *mouse);
typedef void (*DSMouseButtonCallback)(void *context, int pressed);
typedef struct { int cid, task, flags; } DSMouseControl;
int ds_mouse_controls(DSMouse *mouse, DSMouseControl *controls, int capacity);
// Temporary diversion only. All calls and polling must use the same thread.
int ds_mouse_begin_button(DSMouse *mouse, int cid, DSMouseButtonCallback callback, void *context);
int ds_mouse_poll(DSMouse *mouse, double seconds);
int ds_mouse_end_button(DSMouse *mouse);
#endif
