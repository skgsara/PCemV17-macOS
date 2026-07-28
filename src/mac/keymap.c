/* macOS virtual keycode (NSEvent.keyCode) -> PC set-1 scancode table.
 *
 * The PC scancodes are identical to the SDL table in src/wx-sdl2-display.c
 * (SDLScancodeToSystemScancode); only the host side changed from SDL scancodes
 * to macOS keyCodes (the kVK_* constants from Carbon HIToolbox/Events.h,
 * written as hex here so this file needs no framework includes).
 *
 * Bit 7 set = E0-extended key (e.g. 0x9d = E0 1d = right Ctrl).
 * Unmapped entries are -1.
 */
#include "keymap.h"

static const int mac_to_pc[128] = {
        [0x00] = 0x1e,  /* kVK_ANSI_A            */
        [0x01] = 0x1f,  /* kVK_ANSI_S            */
        [0x02] = 0x20,  /* kVK_ANSI_D            */
        [0x03] = 0x21,  /* kVK_ANSI_F            */
        [0x04] = 0x23,  /* kVK_ANSI_H            */
        [0x05] = 0x22,  /* kVK_ANSI_G            */
        [0x06] = 0x2c,  /* kVK_ANSI_Z            */
        [0x07] = 0x2d,  /* kVK_ANSI_X            */
        [0x08] = 0x2e,  /* kVK_ANSI_C            */
        [0x09] = 0x2f,  /* kVK_ANSI_V            */
        [0x0a] = 0x56,  /* kVK_ISO_Section (non-US backslash) */
        [0x0b] = 0x30,  /* kVK_ANSI_B            */
        [0x0c] = 0x10,  /* kVK_ANSI_Q            */
        [0x0d] = 0x11,  /* kVK_ANSI_W            */
        [0x0e] = 0x12,  /* kVK_ANSI_E            */
        [0x0f] = 0x13,  /* kVK_ANSI_R            */
        [0x10] = 0x15,  /* kVK_ANSI_Y            */
        [0x11] = 0x14,  /* kVK_ANSI_T            */
        [0x12] = 0x02,  /* kVK_ANSI_1            */
        [0x13] = 0x03,  /* kVK_ANSI_2            */
        [0x14] = 0x04,  /* kVK_ANSI_3            */
        [0x15] = 0x05,  /* kVK_ANSI_4            */
        [0x16] = 0x07,  /* kVK_ANSI_6            */
        [0x17] = 0x06,  /* kVK_ANSI_5            */
        [0x18] = 0x0d,  /* kVK_ANSI_Equal        */
        [0x19] = 0x0a,  /* kVK_ANSI_9            */
        [0x1a] = 0x08,  /* kVK_ANSI_7            */
        [0x1b] = 0x0c,  /* kVK_ANSI_Minus        */
        [0x1c] = 0x09,  /* kVK_ANSI_8            */
        [0x1d] = 0x0b,  /* kVK_ANSI_0            */
        [0x1e] = 0x1b,  /* kVK_ANSI_RightBracket */
        [0x1f] = 0x18,  /* kVK_ANSI_O            */
        [0x20] = 0x16,  /* kVK_ANSI_U            */
        [0x21] = 0x1a,  /* kVK_ANSI_LeftBracket  */
        [0x22] = 0x17,  /* kVK_ANSI_I            */
        [0x23] = 0x19,  /* kVK_ANSI_P            */
        [0x24] = 0x1c,  /* kVK_Return            */
        [0x25] = 0x26,  /* kVK_ANSI_L            */
        [0x26] = 0x24,  /* kVK_ANSI_J            */
        [0x27] = 0x28,  /* kVK_ANSI_Quote        */
        [0x28] = 0x25,  /* kVK_ANSI_K            */
        [0x29] = 0x27,  /* kVK_ANSI_Semicolon    */
        [0x2a] = 0x2b,  /* kVK_ANSI_Backslash    */
        [0x2b] = 0x33,  /* kVK_ANSI_Comma        */
        [0x2c] = 0x35,  /* kVK_ANSI_Slash        */
        [0x2d] = 0x31,  /* kVK_ANSI_N            */
        [0x2e] = 0x32,  /* kVK_ANSI_M            */
        [0x2f] = 0x34,  /* kVK_ANSI_Period       */
        [0x30] = 0x0f,  /* kVK_Tab               */
        [0x31] = 0x39,  /* kVK_Space             */
        [0x32] = 0x29,  /* kVK_ANSI_Grave        */
        [0x33] = 0x0e,  /* kVK_Delete (backspace)*/
        [0x35] = 0x01,  /* kVK_Escape            */
        [0x36] = 0xdc,  /* kVK_RightCommand (E0 5c = RGUI) */
        [0x37] = 0xdb,  /* kVK_Command (E0 5b = LGUI)      */
        [0x38] = 0x2a,  /* kVK_Shift             */
        [0x39] = 0x3a,  /* kVK_CapsLock          */
        [0x3a] = 0x38,  /* kVK_Option (LALT)     */
        [0x3b] = 0x1d,  /* kVK_Control (LCTRL)   */
        [0x3c] = 0x36,  /* kVK_RightShift        */
        [0x3d] = 0xb8,  /* kVK_RightOption (E0 38 = RALT)  */
        [0x3e] = 0x9d,  /* kVK_RightControl (E0 1d = RCTRL)*/

        [0x41] = 0x53,  /* kVK_ANSI_KeypadDecimal */
        [0x43] = 0x37,  /* kVK_ANSI_KeypadMultiply */
        [0x45] = 0x4e,  /* kVK_ANSI_KeypadPlus   */
        [0x47] = 0x45,  /* kVK_ANSI_KeypadClear (num lock) */
        [0x4b] = 0xb5,  /* kVK_ANSI_KeypadDivide (E0 35)   */
        [0x4c] = 0x9c,  /* kVK_ANSI_KeypadEnter (E0 1c)    */
        [0x4e] = 0x4a,  /* kVK_ANSI_KeypadMinus  */
        [0x52] = 0x52,  /* kVK_ANSI_Keypad0      */
        [0x53] = 0x4f,  /* kVK_ANSI_Keypad1      */
        [0x54] = 0x50,  /* kVK_ANSI_Keypad2      */
        [0x55] = 0x51,  /* kVK_ANSI_Keypad3      */
        [0x56] = 0x4b,  /* kVK_ANSI_Keypad4      */
        [0x57] = 0x4c,  /* kVK_ANSI_Keypad5      */
        [0x58] = 0x4d,  /* kVK_ANSI_Keypad6      */
        [0x59] = 0x47,  /* kVK_ANSI_Keypad7      */
        [0x5b] = 0x48,  /* kVK_ANSI_Keypad8      */
        [0x5c] = 0x49,  /* kVK_ANSI_Keypad9      */

        [0x60] = 0x3f,  /* kVK_F5                */
        [0x61] = 0x40,  /* kVK_F6                */
        [0x62] = 0x41,  /* kVK_F7                */
        [0x63] = 0x3d,  /* kVK_F3                */
        [0x64] = 0x42,  /* kVK_F8                */
        [0x65] = 0x43,  /* kVK_F9                */
        [0x67] = 0x57,  /* kVK_F11               */
        [0x6d] = 0x44,  /* kVK_F10               */
        [0x6f] = 0x58,  /* kVK_F12               */

        [0x72] = 0xd2,  /* kVK_Help (E0 52 = Insert)      */
        [0x73] = 0xc7,  /* kVK_Home (E0 47)               */
        [0x74] = 0xc9,  /* kVK_PageUp (E0 49)             */
        [0x75] = 0xd3,  /* kVK_ForwardDelete (E0 53 = Del)*/
        [0x76] = 0x3e,  /* kVK_F4                         */
        [0x77] = 0xcf,  /* kVK_End (E0 4f)                */
        [0x78] = 0x3c,  /* kVK_F2                         */
        [0x79] = 0xd1,  /* kVK_PageDown (E0 51)           */
        [0x7a] = 0x3b,  /* kVK_F1                         */
        [0x7b] = 0xcb,  /* kVK_LeftArrow (E0 4b)          */
        [0x7c] = 0xcd,  /* kVK_RightArrow (E0 4d)         */
        [0x7d] = 0xd0,  /* kVK_DownArrow (E0 50)          */
        [0x7e] = 0xc8,  /* kVK_UpArrow (E0 48)            */
};

int pcem_mac_keycode_to_pc(int mac_keycode)
{
        if (mac_keycode < 0 || mac_keycode > 127)
                return -1;
        /* Unmapped slots were zero-initialised; 0 is not a valid PC scancode
           for any key here, so map 0 to -1 except where explicitly set. */
        int sc = mac_to_pc[mac_keycode];
        return sc == 0 ? -1 : sc;
}
