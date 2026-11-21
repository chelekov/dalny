/*
 * Keyboard type detection and Mac virtual-key to RDP scancode mapping.
 * The product table and ISO correction follow FreeRDP's Mac client
 * (client/Mac/Keyboard.m, Apache License 2.0, Copyright 2014 Marc-Andre Moreau).
 */

#include "AppleKeyboard.h"

#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

enum
{
	DALNY_KB_ANSI = 0,
	DALNY_KB_ISO = 1,
	DALNY_KB_JIS = 2
};

typedef struct
{
	uint32_t productId;
	int type;
} DalnyKeyboardDesc;

static const DalnyKeyboardDesc kAppleKeyboards[] = {
	{ 0x200, DALNY_KB_ANSI }, { 0x201, DALNY_KB_ANSI }, { 0x202, DALNY_KB_ANSI },
	{ 0x203, DALNY_KB_ANSI }, { 0x204, DALNY_KB_ANSI }, { 0x205, DALNY_KB_ANSI },
	{ 0x206, DALNY_KB_ANSI }, { 0x207, DALNY_KB_ANSI }, { 0x208, DALNY_KB_ANSI },
	{ 0x209, DALNY_KB_ANSI }, { 0x20A, DALNY_KB_ANSI }, { 0x20B, DALNY_KB_ANSI },
	{ 0x20C, DALNY_KB_ANSI }, { 0x20D, DALNY_KB_ANSI }, { 0x20E, DALNY_KB_ANSI },
	{ 0x20F, DALNY_KB_ISO },  { 0x210, DALNY_KB_ANSI }, { 0x211, DALNY_KB_ANSI },
	{ 0x212, DALNY_KB_ANSI }, { 0x213, DALNY_KB_ANSI }, { 0x214, DALNY_KB_ANSI },
	{ 0x215, DALNY_KB_ISO },  { 0x216, DALNY_KB_JIS },  { 0x217, DALNY_KB_ANSI },
	{ 0x218, DALNY_KB_ISO },  { 0x219, DALNY_KB_JIS },  { 0x21A, DALNY_KB_ANSI },
	{ 0x21B, DALNY_KB_ISO },  { 0x21C, DALNY_KB_JIS },  { 0x21D, DALNY_KB_ANSI },
	{ 0x21E, DALNY_KB_ISO },  { 0x21F, DALNY_KB_JIS },  { 0x220, DALNY_KB_ANSI },
	{ 0x221, DALNY_KB_JIS },  { 0x222, DALNY_KB_JIS },  { 0x223, DALNY_KB_ANSI },
	{ 0x224, DALNY_KB_ISO },  { 0x225, DALNY_KB_JIS },  { 0x226, DALNY_KB_ANSI },
	{ 0x227, DALNY_KB_ANSI }, { 0x228, DALNY_KB_ANSI }, { 0x229, DALNY_KB_ANSI },
	{ 0x22A, DALNY_KB_ISO },  { 0x22B, DALNY_KB_JIS },  { 0x22C, DALNY_KB_ANSI },
	{ 0x22D, DALNY_KB_ANSI }, { 0x22E, DALNY_KB_ANSI }, { 0x22F, DALNY_KB_ANSI },
	{ 0x230, DALNY_KB_ANSI }, { 0x231, DALNY_KB_ISO },  { 0x232, DALNY_KB_JIS },
	{ 0x233, DALNY_KB_ANSI }, { 0x234, DALNY_KB_ANSI }, { 0x235, DALNY_KB_ANSI },
	{ 0x236, DALNY_KB_ANSI }, { 0x237, DALNY_KB_ISO },  { 0x238, DALNY_KB_JIS },
	{ 0x239, DALNY_KB_ANSI }, { 0x23A, DALNY_KB_ANSI }, { 0x23B, DALNY_KB_ANSI },
	{ 0x23C, DALNY_KB_ANSI }, { 0x23D, DALNY_KB_ANSI }, { 0x23E, DALNY_KB_ANSI },
	{ 0x23F, DALNY_KB_ANSI }, { 0x240, DALNY_KB_ISO },  { 0x241, DALNY_KB_JIS },
	{ 0x242, DALNY_KB_ANSI }, { 0x243, DALNY_KB_ISO },  { 0x244, DALNY_KB_JIS },
	{ 0x245, DALNY_KB_ANSI }, { 0x246, DALNY_KB_ISO },  { 0x247, DALNY_KB_JIS },
	{ 0x248, DALNY_KB_ANSI }, { 0x249, DALNY_KB_ANSI }, { 0x24A, DALNY_KB_ISO },
	{ 0x24B, DALNY_KB_ANSI }, { 0x24C, DALNY_KB_ANSI }, { 0x24D, DALNY_KB_ISO },
	{ 0x24E, DALNY_KB_ANSI }, { 0x24F, DALNY_KB_ANSI }, { 0x250, DALNY_KB_ISO },
	{ 0x251, DALNY_KB_ANSI }, { 0x252, DALNY_KB_ANSI }, { 0x253, DALNY_KB_ISO },
	{ 0x254, DALNY_KB_JIS },  { 0x255, DALNY_KB_ANSI }, { 0x256, DALNY_KB_ANSI },
	{ 0x257, DALNY_KB_ANSI }, { 0x258, DALNY_KB_ANSI }, { 0x259, DALNY_KB_ANSI },
	{ 0x25A, DALNY_KB_ANSI }, { 0x25B, DALNY_KB_ANSI }, { 0x25C, DALNY_KB_ANSI },
	{ 0x25D, DALNY_KB_ANSI }, { 0x25E, DALNY_KB_ANSI }, { 0x25F, DALNY_KB_ANSI },
	{ 0x260, DALNY_KB_ANSI }, { 0x261, DALNY_KB_ANSI }, { 0x262, DALNY_KB_ANSI },
	{ 0x263, DALNY_KB_ANSI }, { 0x264, DALNY_KB_ANSI }, { 0x265, DALNY_KB_ANSI },
	{ 0x266, DALNY_KB_ANSI }, { 0x267, DALNY_KB_ANSI }, { 0x268, DALNY_KB_ANSI },
	{ 0x269, DALNY_KB_ANSI }, { 0x26A, DALNY_KB_ANSI },
};

static int identify(uint32_t vendor, uint32_t product)
{
	if (vendor != 0x05AC)
		return DALNY_KB_ANSI;
	if (product < 0x200 || product > 0x26A)
		return DALNY_KB_ANSI;
	return kAppleKeyboards[product - 0x200].type;
}

int dalny_mac_keyboard_is_iso(void)
{
	IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	if (!manager)
		return 0;
	IOHIDManagerSetDeviceMatching(manager, NULL);
	if (IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
	{
		CFRelease(manager);
		return 0;
	}

	CFSetRef devices = IOHIDManagerCopyDevices(manager);
	int iso = 0;
	if (devices)
	{
		CFIndex count = CFSetGetCount(devices);
		IOHIDDeviceRef* refs = (IOHIDDeviceRef*)calloc((size_t)count, sizeof(IOHIDDeviceRef));
		if (refs)
		{
			CFSetGetValues(devices, (const void**)refs);
			for (CFIndex i = 0; i < count; i++)
			{
				uint32_t vendor = 0;
				uint32_t product = 0;
				CFTypeRef value = IOHIDDeviceGetProperty(refs[i], CFSTR(kIOHIDVendorIDKey));
				if (value)
					CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &vendor);
				value = IOHIDDeviceGetProperty(refs[i], CFSTR(kIOHIDProductIDKey));
				if (value)
					CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &product);
				if (identify(vendor, product) == DALNY_KB_ISO)
				{
					iso = 1;
					break;
				}
			}
			free(refs);
		}
		CFRelease(devices);
	}
	CFRelease(manager);
	return iso;
}
