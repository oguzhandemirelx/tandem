#include "Native.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>

// Private display APIs are resolved at runtime so missing symbols fail gracefully.
// Protocol/discovery references and their licenses are recorded in THIRD_PARTY.md.
typedef CFTypeRef (*CreateAV)(CFAllocatorRef, io_service_t);
typedef IOReturn (*I2C)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef CFDictionaryRef (*DisplayInfo)(CGDirectDisplayID);
typedef int (*BrightnessGet)(CGDirectDisplayID, float *);
typedef int (*BrightnessSet)(CGDirectDisplayID, float);
static CreateAV createAV;
static I2C readI2C, writeI2C;
static DisplayInfo displayInfo;
static BrightnessGet brightnessGet;
static BrightnessSet brightnessSet;
static pthread_once_t loaded = PTHREAD_ONCE_INIT;
struct TDTransport { CFTypeRef service; uint32_t chip; };

static void loadSymbols(void) {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    void *cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
    void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (io) {
        createAV = (CreateAV)dlsym(io, "IOAVServiceCreateWithService");
        readI2C = (I2C)dlsym(io, "IOAVServiceReadI2C");
        writeI2C = (I2C)dlsym(io, "IOAVServiceWriteI2C");
    }
    if (cd) displayInfo = (DisplayInfo)dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary");
    if (ds) {
        brightnessGet = (BrightnessGet)dlsym(ds, "DisplayServicesGetBrightness");
        brightnessSet = (BrightnessSet)dlsym(ds, "DisplayServicesSetBrightness");
    }
}
CFDictionaryRef TDDisplayInfo(CGDirectDisplayID display) {
    pthread_once(&loaded, loadSymbols);
    return displayInfo ? displayInfo(display) : NULL;
}
CFStringRef TDDisplayEDIDUUID(CGDirectDisplayID display) {
    CFDictionaryRef info = TDDisplayInfo(display);
    if (!info) return NULL;
    CFStringRef path = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    io_registry_entry_t adapter = path && CFGetTypeID(path) == CFStringGetTypeID()
        ? IORegistryEntryCopyFromPath(kIOMainPortDefault, path) : 0;
    CFRelease(info);
    if (!adapter) return NULL;
    CFTypeRef uuid = IORegistryEntrySearchCFProperty(adapter, kIOServicePlane, CFSTR("EDID UUID"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    IOObjectRelease(adapter);
    if (uuid && CFGetTypeID(uuid) != CFStringGetTypeID()) { CFRelease(uuid); return NULL; }
    return uuid;
}
static CFTypeRef property(io_registry_entry_t entry, CFStringRef key) {
    return IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
}
TDTransport *TDOpenTransport(CGDirectDisplayID display) {
    pthread_once(&loaded, loadSymbols);
    if (!createAV || !readI2C || !writeI2C || CGDisplayIsBuiltin(display)) return NULL;
    CFDictionaryRef info = TDDisplayInfo(display);
    if (!info) return NULL;
    CFStringRef path = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    io_registry_entry_t adapter = path && CFGetTypeID(path) == CFStringGetTypeID()
        ? IORegistryEntryCopyFromPath(kIOMainPortDefault, path) : 0;
    CFRelease(info);
    if (!adapter) return NULL;
    uint64_t target = 0;
    IOReturn result = IORegistryEntryGetRegistryEntryID(adapter, &target);
    IOObjectRelease(adapter);
    if (result != KERN_SUCCESS) return NULL;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iterator = 0;
    result = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(root);
    if (result != KERN_SUCCESS) return NULL;
    bool selected = false;
    TDTransport *transport = NULL;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
            uint64_t identifier = 0;
            selected = IORegistryEntryGetRegistryEntryID(entry, &identifier) == KERN_SUCCESS && identifier == target;
        } else if (selected && IOObjectConformsTo(entry, "DCPAVServiceProxy")) {
            CFTypeRef location = property(entry, CFSTR("Location"));
            bool external = location && CFEqual(location, CFSTR("External"));
            if (location) CFRelease(location);
            if (external) {
                CFTypeRef av = createAV(kCFAllocatorDefault, entry);
                if (av) {
                    transport = calloc(1, sizeof(TDTransport));
                    if (transport) {
                        transport->service = av;
                        transport->chip = 0x37;
                        io_registry_entry_t parent = 0;
                        if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS) {
                            CFTypeRef provider = property(parent, CFSTR("EPICProviderClass"));
                            if (provider && CFEqual(provider, CFSTR("AppleDCPMCDP29XX"))) transport->chip = 0xB7;
                            if (provider) CFRelease(provider);
                            IOObjectRelease(parent);
                        }
                    } else CFRelease(av);
                }
            }
        }
        IOObjectRelease(entry);
        if (transport) break;
    }
    IOObjectRelease(iterator);
    return transport;
}
void TDCloseTransport(TDTransport *t) { if (t) { CFRelease(t->service); free(t); } }
uint32_t TDTransportChip(TDTransport *t) { return t ? t->chip : 0; }
// Capability reply: source, length, 0xe3, offset high/low, data, checksum.
// Read bounded fragments, validate every packet, and require the echoed offset.
IOReturn TDReadCapabilities(TDTransport *t, char *buffer, uint32_t capacity) {
    if (!t || !buffer || capacity < 2) return kIOReturnNotOpen;
    buffer[0] = 0;
    uint32_t offset = 0;
    while (offset < capacity - 1 && offset < 4096) {
        bool accepted = false;
        for (int attempt = 0; attempt < 3; ++attempt) {
            uint8_t request[5] = {0x83, 0xf3, offset >> 8, offset & 0xff, 0};
            request[4] = 0x6e ^ 0x51;
            for (int i = 0; i < 4; ++i) request[4] ^= request[i];
            usleep(10000);
            IOReturn result = writeI2C(t->service, t->chip, 0x51, request, sizeof(request));
            if (result) return result;
            usleep(60000);
            uint8_t reply[64] = {0};
            result = readI2C(t->service, t->chip, 0x51, reply, sizeof(reply));
            if (result) continue;
            unsigned length = reply[1] & 0x7f;
            if (reply[0] != 0x6e || !(reply[1] & 0x80) || length < 3 || length + 3 > sizeof(reply) || reply[2] != 0xe3 ||
                (((unsigned)reply[3] << 8) | reply[4]) != offset) continue;
            uint8_t checksum = 0x50;
            for (unsigned i = 0; i < length + 3; ++i) checksum ^= reply[i];
            if (checksum && t->chip == 0xb7 && length + 3 > 32 && length + 4 <= sizeof(reply) && reply[32] == reply[0]) {
                // MCDP reads insert the source address at the 32-byte transfer
                // boundary. Accept normalization only if the full checksum passes.
                memmove(reply + 32, reply + 33, length + 3 - 32);
                checksum = 0x50;
                for (unsigned i = 0; i < length + 3; ++i) checksum ^= reply[i];
            }
            if (checksum) continue;
            unsigned count = length - 3;
            if (!count) return offset ? kIOReturnSuccess : kIOReturnUnsupported;
            if (offset + count >= capacity) return kIOReturnNoSpace;
            for (unsigned i = 0; i < count; ++i) {
                if (!reply[5 + i]) { buffer[offset + i] = 0; return kIOReturnSuccess; }
                buffer[offset + i] = reply[5 + i];
            }
            offset += count; buffer[offset] = 0; accepted = true; break;
        }
        if (!accepted) { buffer[0] = 0; return kIOReturnIOError; }
    }
    buffer[0] = 0;
    return kIOReturnNoSpace;
}
IOReturn TDReadVCP(TDTransport *t, uint8_t code, uint16_t *current, uint16_t *maximum) {
    if (!t) return kIOReturnNotOpen;
    for (int attempt = 0; attempt < 3; ++attempt) {
        // Standard DDC checksum includes the host address 0x51.
        // Verified with real replies; omitting 0x51 returns stale capability bytes.
        uint8_t request[4] = { 0x82, 0x01, code, (uint8_t)(0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ code) };
        usleep(10000);
        IOReturn result = writeI2C(t->service, t->chip, 0x51, request, sizeof(request));
        if (result != kIOReturnSuccess) return result;
        usleep(t->chip == 0xB7 ? 50000 : 40000);
        uint8_t reply[12] = {0};
        result = readI2C(t->service, t->chip, 0x51, reply, sizeof(reply));
        if (getenv("TANDEM_DDC_DEBUG")) {
            fprintf(stderr, "VCP %02x attempt %d result %x:", code, attempt, result);
            for (int i = 0; i < 12; ++i) fprintf(stderr, " %02x", reply[i]);
            fprintf(stderr, "\n");
        }
        if (result != kIOReturnSuccess) continue;
        uint8_t checksum = 0x50;
        for (int i = 0; i < 11; ++i) checksum ^= reply[i];
        if (reply[0] != 0x6E || reply[1] != 0x88 || reply[2] != 0x02 || reply[4] != code || checksum != 0) continue;
        if (reply[3] != 0) return kIOReturnUnsupported;
        *maximum = ((uint16_t)reply[6] << 8) | reply[7];
        *current = ((uint16_t)reply[8] << 8) | reply[9];
        return *maximum && *current <= *maximum ? kIOReturnSuccess : kIOReturnBadArgument;
    }
    return kIOReturnIOError;
}
IOReturn TDWriteVCP(TDTransport *t, uint8_t code, uint16_t value) {
    if (!t) return kIOReturnNotOpen;
    uint8_t packet[6] = { 0x84, 0x03, code, value >> 8, value & 0xff, 0 };
    packet[5] = 0x6E ^ 0x51;
    for (int i = 0; i < 5; ++i) packet[5] ^= packet[i];
    usleep(50000);
    return writeI2C(t->service, t->chip, 0x51, packet, sizeof(packet));
}
int TDBrightnessGet(CGDirectDisplayID id, float *value) {
    pthread_once(&loaded, loadSymbols);
    return brightnessGet ? brightnessGet(id, value) : kIOReturnUnsupported;
}
int TDBrightnessSet(CGDirectDisplayID id, float value) {
    pthread_once(&loaded, loadSymbols);
    return brightnessSet ? brightnessSet(id, value) : kIOReturnUnsupported;
}
