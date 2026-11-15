#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include "CUSBHost.h"

struct usbh_dev {
    __strong IOUSBHostDevice *device;
    __strong IOUSBHostInterface *interface;
    __strong IOUSBHostPipe *in;
    __strong IOUSBHostPipe *out;
};

static void seterr(char *err, size_t n, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);
static void seterr(char *err, size_t n, NSString *fmt, ...) {
    if (!err || !n) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    strlcpy(err, s.UTF8String ?: "?", n);
}

static io_service_t findDevice(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    CFDictionarySetValue(m, CFSTR("idVendor"), (__bridge CFNumberRef)@(vid));
    CFDictionarySetValue(m, CFSTR("idProduct"), (__bridge CFNumberRef)@(pid));
    return IOServiceGetMatchingService(kIOMainPortDefault, m); // consumes m
}

static io_service_t findInterface(io_service_t dev, uint8_t number) {
    io_iterator_t it = 0;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return 0;
    io_service_t s, found = 0;
    while (!found && (s = IOIteratorNext(it))) {
        if (IOObjectConformsTo(s, "IOUSBHostInterface")) {
            CFTypeRef n = IORegistryEntryCreateCFProperty(s, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
            if (n && [(__bridge NSNumber *)n unsignedIntValue] == number) found = s;
            if (n) CFRelease(n);
        }
        if (s != found) IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

usbh_dev *usbh_open(uint16_t vid, uint16_t pid, uint8_t ifaceNum, char *err, size_t errlen) {
    @autoreleasepool {
        io_service_t svc = findDevice(vid, pid);
        if (!svc) { seterr(err, errlen, @"USB device %04x:%04x not found", vid, pid); return NULL; }

        NSError *e = nil;
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:svc
                                                                  options:IOUSBHostObjectInitOptionsDeviceCapture
                                                                    queue:nil error:&e interestHandler:nil];
        if (!dev) {
            IOObjectRelease(svc);
            seterr(err, errlen, @"capture failed (run as root?): %@", e.localizedDescription);
            return NULL;
        }

        // Capture terminates the device's drivers asynchronously. Wait until that has settled,
        // then open our interface; until the old clients are gone the open fails, so retry
        // with a fresh lookup for a few seconds.
        mach_timespec_t settle = { .tv_sec = 5, .tv_nsec = 0 };
        IOServiceWaitQuiet(svc, &settle);
        IOUSBHostInterface *iface = nil;
        NSError *lastErr = nil;
        for (int i = 0; i < 60 && !iface; i++) {
            io_service_t ifSvc = findInterface(svc, ifaceNum);
            if (ifSvc) {
                mach_timespec_t t = { .tv_sec = 1, .tv_nsec = 0 };
                IOServiceWaitQuiet(ifSvc, &t);
                iface = [[IOUSBHostInterface alloc] initWithIOService:ifSvc options:IOUSBHostObjectInitOptionsNone
                                                                queue:nil error:&lastErr interestHandler:nil];
                IOObjectRelease(ifSvc);
            } else if (i == 10) {
                [dev configureWithValue:1 matchInterfaces:NO error:nil];
            }
            if (!iface) [NSThread sleepForTimeInterval:0.1];
        }
        IOObjectRelease(svc);
        if (!iface) {
            [dev destroy];
            seterr(err, errlen, @"could not open the scanner's USB interface: %@", lastErr.localizedDescription ?: @"not found");
            return NULL;
        }

        uint8_t inAddr = 0, outAddr = 0;
        const IOUSBConfigurationDescriptor *cfg = iface.configurationDescriptor;
        const IOUSBInterfaceDescriptor *ifd = iface.interfaceDescriptor;
        const IOUSBEndpointDescriptor *ep = NULL;
        while (cfg && ifd && (ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep))) {
            if ((ep->bmAttributes & 0x3) != 2) continue; // bulk only
            if (ep->bEndpointAddress & 0x80) { if (!inAddr) inAddr = ep->bEndpointAddress; }
            else if (!outAddr) outAddr = ep->bEndpointAddress;
        }
        if (!inAddr || !outAddr) {
            [iface destroy]; [dev destroy];
            seterr(err, errlen, @"bulk endpoints not found"); return NULL;
        }
        IOUSBHostPipe *pin = [iface copyPipeWithAddress:inAddr error:&e];
        IOUSBHostPipe *pout = pin ? [iface copyPipeWithAddress:outAddr error:&e] : nil;
        if (!pin || !pout) {
            [iface destroy]; [dev destroy];
            seterr(err, errlen, @"open pipes: %@", e.localizedDescription); return NULL;
        }

        usbh_dev *d = calloc(1, sizeof *d);
        d->device = dev; d->interface = iface; d->in = pin; d->out = pout;
        return d;
    }
}

long usbh_bulk(usbh_dev *d, bool in, void *buf, size_t len, double timeout_s,
               bool *stalled, char *err, size_t errlen) {
    @autoreleasepool {
        if (stalled) *stalled = false;
        NSError *e = nil;
        // Plain NSMutableData: its length is the exact transfer size. (Buffers from
        // ioDataWithCapacity: have a fixed length and throw if it is changed.)
        NSMutableData *data = in ? [NSMutableData dataWithLength:len]
                                 : [NSMutableData dataWithBytes:buf length:len];
        if (!data) { seterr(err, errlen, @"out of memory"); return -1; }
        IOUSBHostPipe *p = in ? d->in : d->out;
        NSUInteger n = 0;
        BOOL ok = [p sendIORequestWithData:data bytesTransferred:&n completionTimeout:timeout_s error:&e];
        if (!ok) {
            if ((uint32_t)e.code == (uint32_t)kUSBHostReturnPipeStalled) {
                [p clearStallWithError:nil];
                if (stalled) *stalled = true;
                return (long)n;
            }
            seterr(err, errlen, @"bulk %s %zu: %@ (0x%lx)", in ? "IN" : "OUT", len, e.localizedDescription, (long)e.code);
            return -1;
        }
        if (in && n) memcpy(buf, data.bytes, n);
        return (long)n;
    }
}

bool usbh_bot_reset(usbh_dev *d, uint8_t ifaceNum, char *err, size_t errlen) {
    @autoreleasepool {
        IOUSBDeviceRequest r = {
            .bmRequestType = 0x21, // class, interface, host->device
            .bRequest = 0xFF,      // Bulk-Only Mass Storage Reset
            .wValue = 0, .wIndex = ifaceNum, .wLength = 0,
        };
        NSError *e = nil;
        NSUInteger n = 0;
        if (![d->interface sendDeviceRequest:r data:nil bytesTransferred:&n completionTimeout:5 error:&e]) {
            seterr(err, errlen, @"BOT reset: %@", e.localizedDescription);
            return false;
        }
        [d->in clearStallWithError:nil];
        [d->out clearStallWithError:nil];
        return true;
    }
}

void usbh_close(usbh_dev *d) {
    if (!d) return;
    @autoreleasepool {
        [d->interface destroy];
        [d->device destroy]; // resets the device; macOS re-matches its normal drivers
        d->in = nil; d->out = nil; d->interface = nil; d->device = nil;
    }
    free(d);
}
