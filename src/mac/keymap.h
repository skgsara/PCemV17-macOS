/* macOS virtual keycode (NSEvent.keyCode) -> PC set-1 scancode translation.
 *
 * Pure C, no dependencies, so both the ObjC bridge and Swift (via the bridging
 * header) can use it. PC scancode semantics match the rest of PCem:
 * bit 7 set (values >= 0x80) means an E0-extended key, e.g. RCTRL = 0x1d|0x80.
 */
#ifndef PCEM_KEYMAP_H
#define PCEM_KEYMAP_H

/* Returns the PC scancode for a macOS keyCode, or -1 if unmapped. */
int pcem_mac_keycode_to_pc(int mac_keycode);

#endif
