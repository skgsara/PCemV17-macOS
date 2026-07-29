/* pcem_mac_midi.m — CoreMIDI backend for PCem's MIDI out (see the header
 * for the device-list model). This is the ONLY mac-shell file that includes
 * CoreMIDI; like pcem_mac_platform.m it includes no PCem core headers, so
 * the thread_t/pause name collisions can't happen here.
 *
 * Threading (matches the win/alsa backends): mac_midi_send runs on the
 * emulation thread (MIDISend/MIDIReceived are non-blocking and thread-safe),
 * mac_midi_open/close run on the main thread at boot/stop, enumeration runs
 * on the UI thread. No threads or locks are added.
 */
#import <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <string.h>

#include "pcem_mac_midi.h"

/* Name shown for index 0 in the device picker and to synth apps that
   attach to the virtual source. */
#define VIRTUAL_SOURCE_NAME "PCem Virtual Output"

/* Display name of the virtual source as seen by OTHER apps (they see the
   source itself, not PCem's picker label for it). */
#define VIRTUAL_SOURCE_COREMIDI_NAME "PCem"

/* mac_midi_send chunks packets to this many bytes (plan: <= 256). */
#define MIDI_PACKET_CHUNK 256

static MIDIClientRef midi_client = 0;
static MIDIPortRef midi_out_port = 0;      /* for real destinations */
static MIDIEndpointRef midi_source = 0;    /* virtual source (index 0 open) */
static MIDIEndpointRef midi_dest = 0;      /* real destination (index >0 open) */

/* The client is needed for everything except raw enumeration, so create it
   lazily on first use. */
static int mac_midi_ensure_client(void)
{
        if (midi_client)
                return 1;
        return MIDIClientCreate(CFSTR("PCem"), NULL, NULL, &midi_client) == noErr;
}

int mac_midi_num_devs(void)
{
        return 1 + (int)MIDIGetNumberOfDestinations();
}

void mac_midi_dev_name(int idx, char *buf, int size)
{
        if (size <= 0)
                return;
        buf[0] = 0;

        if (idx == 0)
        {
                strncpy(buf, VIRTUAL_SOURCE_NAME, size - 1);
                buf[size - 1] = 0;
                return;
        }

        MIDIEndpointRef dest = MIDIGetDestination(idx - 1);
        CFStringRef name = NULL;
        if (dest && MIDIObjectGetStringProperty(dest, kMIDIPropertyName,
                                                &name) == noErr && name)
        {
                CFStringGetCString(name, buf, size, kCFStringEncodingUTF8);
                CFRelease(name);
        }
        else
        {
                snprintf(buf, size, "MIDI Destination %d", idx);
        }
}

/* Closes whichever device is open WITHOUT tearing down the client (shared
   by mac_midi_open's re-open path and mac_midi_close). */
static void mac_midi_close_device(void)
{
        if (midi_source)
        {
                MIDIEndpointDispose(midi_source);
                midi_source = 0;
        }
        if (midi_out_port)
        {
                MIDIPortDispose(midi_out_port);
                midi_out_port = 0;
        }
        midi_dest = 0; /* destinations are owned by CoreMIDI — just forget it */
}

int mac_midi_open(int idx)
{
        if (!mac_midi_ensure_client())
                return 0;

        mac_midi_close_device();

        if (idx == 0)
        {
                return MIDISourceCreate(midi_client,
                                        CFSTR(VIRTUAL_SOURCE_COREMIDI_NAME),
                                        &midi_source) == noErr;
        }

        if (idx < 0 || idx >= mac_midi_num_devs())
                return 0;

        midi_dest = MIDIGetDestination(idx - 1);
        if (!midi_dest)
                return 0;
        if (MIDIOutputPortCreate(midi_client, CFSTR("PCem MIDI out"),
                                 &midi_out_port) != noErr)
        {
                midi_dest = 0;
                return 0;
        }
        return 1;
}

void mac_midi_close(void)
{
        mac_midi_close_device();
}

void mac_midi_send(const uint8_t *bytes, int len)
{
        /* Guard the win/alsa backends lack: never send with nothing open. */
        if (!midi_source && !(midi_out_port && midi_dest))
                return;
        if (!bytes || len <= 0)
                return;

        /* A MIDIPacketList grows by ~16 bytes of header per packet; the
           largest message the core produces is a 1026-byte sysex, i.e. at
           most 5 chunks — 2 KB covers data + headers with room to spare. */
        uint8_t storage[2048];
        MIDIPacketList *list = (MIDIPacketList *)storage;
        MIDIPacket *packet = MIDIPacketListInit(list);

        while (len > 0)
        {
                int chunk = len > MIDI_PACKET_CHUNK ? MIDI_PACKET_CHUNK : len;
                /* Timestamp 0 = "send now". */
                packet = MIDIPacketListAdd(list, sizeof(storage), packet,
                                           0, chunk, bytes);
                if (!packet)
                        return; /* buffer exhausted — drop rather than crash */
                bytes += chunk;
                len -= chunk;
        }

        if (midi_source)
                MIDIReceived(midi_source, list);
        else
                MIDISend(midi_out_port, midi_dest, list);
}
