#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/// Minimal C wrapper over IOUSBHost device capture + bulk pipes.
typedef struct usbh_dev usbh_dev;

/// Captures the first device with vid:pid (terminates its kernel drivers; needs root),
/// opens interface `iface` and its first bulk IN/OUT pipes.
/// On failure returns NULL and writes a message into err.
usbh_dev *usbh_open(uint16_t vid, uint16_t pid, uint8_t iface, char *err, size_t errlen);

/// Bulk transfer on the IN (in=true) or OUT pipe. Returns bytes moved, or -1 (err filled).
/// *stalled is set when the endpoint stalled (the stall is cleared before returning).
long usbh_bulk(usbh_dev *d, bool in, void *buf, size_t len, double timeout_s,
               bool *stalled, char *err, size_t errlen);

/// Bulk-Only Mass Storage Reset (class request) + clear both stalls.
bool usbh_bot_reset(usbh_dev *d, uint8_t iface, char *err, size_t errlen);

/// Releases the device. macOS resets it and lets its normal drivers match again.
void usbh_close(usbh_dev *d);
