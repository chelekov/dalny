#ifndef DALNY_APPLE_KEYBOARD_H
#define DALNY_APPLE_KEYBOARD_H

#include <stdint.h>

int dalny_mac_keyboard_is_iso(void);
uint32_t dalny_scancode_for_mac_key(uint32_t macKeyCode, int isoKeyboard);

#endif
