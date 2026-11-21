#include "AppleKeyboard.h"

#include <winpr/input.h>
#include <freerdp/scancode.h>

uint32_t dalny_scancode_for_mac_key(uint32_t macKeyCode, int isoKeyboard)
{
	if (isoKeyboard)
	{
		if (macKeyCode == APPLE_VK_ANSI_Grave)
			macKeyCode = APPLE_VK_ISO_Section;
		else if (macKeyCode == APPLE_VK_ISO_Section)
			macKeyCode = APPLE_VK_ANSI_Grave;
	}

	DWORD virtualKey = GetVirtualKeyCodeFromKeycode(macKeyCode, WINPR_KEYCODE_TYPE_APPLE);
	return GetVirtualScanCodeFromVirtualKeyCode(virtualKey, 4);
}
