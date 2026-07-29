/* pcem_mac_midi.h — CoreMIDI wrapper for pcem_bridge.m.
 *
 * Same split as pcem_mac_platform.h/.m: pcem_bridge.m deliberately includes
 * no Apple system headers (they collide with PCem core names), so ALL
 * CoreMIDI types and calls live in pcem_mac_midi.m. This header is plain C.
 *
 * Device list model (matches the win/alsa "index into a device list" API):
 *   index 0    = "PCem Virtual Output" — a CoreMIDI virtual SOURCE named
 *                "PCem". Any Mac synth app (Munt, a DAW, ...) can listen to
 *                it, so MIDI out works on a fresh Mac with zero MIDI hardware.
 *   index 1..N = real CoreMIDI destinations (MIDIGetDestination) — USB
 *                interfaces and apps that publish their own destinations.
 */
#ifndef PCEM_MAC_MIDI_H
#define PCEM_MAC_MIDI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 (virtual source) + number of real CoreMIDI destinations. Always >= 1. */
int  mac_midi_num_devs(void);

/* Copies device `idx`'s display name into buf, ALWAYS truncated to size-1
   chars + NUL. The core-side midi_get_dev_name() (plat-midi.h) strcpy's into
   caller buffers with no size, so callers of this wrapper must pass a small
   fixed bound (the bridge uses 64) — keep names short by contract. */
void mac_midi_dev_name(int idx, char *buf, int size);

/* Opens device `idx` for output (0 = virtual source, >0 = destination).
   Returns 1 on success, 0 if idx is out of range or creation failed.
   Re-opening while open closes the previous device first. */
int  mac_midi_open(int idx);

/* Closes the open device, if any. Safe to call when nothing is open. */
void mac_midi_close(void);

/* Sends one complete MIDI message (len 1-3 for channel/system messages,
   up to 1026 for a sysex block). No-op when no device is open — callers
   never have to guard. Builds a MIDIPacketList (timestamp 0 = "now",
   chunks longer than 256 bytes split into multiple packets) and hands it
   to MIDIReceived (virtual source) or MIDISend (destination). Both are
   non-blocking and thread-safe, so this is safe on the emulation thread. */
void mac_midi_send(const uint8_t *bytes, int len);

#ifdef __cplusplus
}
#endif

#endif
