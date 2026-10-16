#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

typedef struct TDTransport TDTransport;
CFDictionaryRef TDDisplayInfo(CGDirectDisplayID display) CF_RETURNS_RETAINED;
CFStringRef TDDisplayEDIDUUID(CGDirectDisplayID display) CF_RETURNS_RETAINED;
TDTransport *TDOpenTransport(CGDirectDisplayID display);
void TDCloseTransport(TDTransport *transport);
uint32_t TDTransportChip(TDTransport *transport);
IOReturn TDReadCapabilities(TDTransport *transport, char *buffer, uint32_t capacity);
IOReturn TDReadVCP(TDTransport *transport, uint8_t code, uint16_t *current, uint16_t *maximum);
IOReturn TDWriteVCP(TDTransport *transport, uint8_t code, uint16_t value);
int TDBrightnessGet(CGDirectDisplayID display, float *value);
int TDBrightnessSet(CGDirectDisplayID display, float value);
