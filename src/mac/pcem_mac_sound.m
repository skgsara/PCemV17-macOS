/* pcem_mac_sound.m — CoreAudio sound backend for the PCem core, replacing
 * src/soundopenal.c (OpenAL, deprecated by Apple) in the native shell.
 *
 * Contract implemented (src/sound.h:25-29 + one global, exactly the symbols
 * soundopenal.c provided):
 *   int SOUNDBUFLEN            — mix block size in stereo frames; the core
 *                                externs AND rewrites it live
 *                                (sound_update_buf_length, sound.c:141)
 *   void initalmain(int, char**) — create the AudioUnits, atexit(closeal)
 *   void inital(void)            — start the units (idempotent)
 *   void givealbuffer(int32_t*)  — main mix: 48 kHz stereo int32, SOUNDBUFLEN
 *                                  frames per call, from the emu thread
 *   void givealbuffer_cd(int16_t*) — CD audio: 44.1 kHz stereo int16,
 *                                  CD_BUFLEN (4410) frames per call, from
 *                                  the CD thread
 * closeal() is internal-only (registered via atexit, like soundopenal.c).
 *
 * Design (per the approved plan):
 * - Two output AudioUnits (default output device), one per stream at its
 *   NATIVE rate — 48 kHz main, 44.1 kHz CD, both stereo int16 interleaved —
 *   so macOS does the mixing and no resampler is needed (mirrors OpenAL's
 *   two sources at two rates).
 * - Each stream has a lock-free SPSC ring buffer (C11 stdatomic head/tail,
 *   65536 frames ≈ 1.4 s). Producers are the emu/CD threads; the consumer
 *   is the AudioUnit render callback on CoreAudio's realtime thread.
 * - Semantics match soundopenal.c exactly: NEVER block on audio — a full
 *   ring silently drops the incoming block, an empty ring makes the render
 *   callback emit silence (recovery is automatic when the producer resumes,
 *   like OpenAL's "restart stopped source" path).
 * - Gain (sound_gain, in dB) is read LIVE and applied as pow(10, dB/20)
 *   per sample in the render callback, with clipping — same formula as the
 *   OpenAL alListenerf path.
 *
 * This is the ONLY mac-shell file with AudioToolbox includes, and it
 * includes NO PCem headers (same rule as pcem_mac_midi.m / pcem_mac_platform.m:
 * framework headers collide with core names). Core constants are duplicated
 * locally with a comment.
 */
#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* Core constants (src/sound.h, src/sound.c) — duplicated because this file
   includes no PCem headers. */
#define MAIN_FREQ   48000            /* sound.c FREQ */
#define CD_FREQ     44100            /* sound.h CD_FREQ */
#define CD_BUFLEN   (CD_FREQ / 10)   /* sound.h CD_BUFLEN — 4410 frames */
#define MAXSOUNDBUFLEN (48000 / 10)  /* sound.h — hard cap the core enforces */

int SOUNDBUFLEN = 48000 / 20;        /* exactly soundopenal.c:26 */

/* Defined by the core (sound.c:132), in dB; read live per render cycle. */
extern int sound_gain;

/* ========================================================================
 * Lock-free SPSC ring buffer (stereo int16 frames).
 *
 * head/tail are ever-increasing frame counters; the power-of-two capacity
 * makes wraparound a mask. One producer thread (tail) + one consumer thread
 * (head) per ring — no locks, no allocation, realtime-safe.
 * ======================================================================== */

#define RING_FRAMES 65536            /* power of two; ~1.4 s at 48 kHz */
#define RING_MASK   (RING_FRAMES - 1)

typedef struct
{
        int16_t data[RING_FRAMES * 2]; /* interleaved L/R */
        _Atomic uint32_t head;         /* next frame to read (consumer) */
        _Atomic uint32_t tail;         /* next frame to write (producer) */
} ring_t;

/* Producer side. Returns 1 if the block was queued, 0 if the ring was full
   (block dropped — the soundopenal.c "no free OpenAL buffer" case). */
static int ring_write(ring_t *r, const int16_t *frames, int count)
{
        uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
        uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
        uint32_t i;

        if (tail - head + (uint32_t)count > RING_FRAMES)
                return 0; /* full — drop, never block the emu/CD thread */

        for (i = 0; i < (uint32_t)count * 2; i++)
                r->data[((tail + (i / 2)) & RING_MASK) * 2 + (i & 1)] = frames[i];
        atomic_store_explicit(&r->tail, tail + (uint32_t)count,
                              memory_order_release);
        return 1;
}

/* Consumer side. Reads up to `count` frames into out, returns how many
   frames were actually available (caller zero-fills the rest). */
static int ring_read(ring_t *r, int16_t *out, int count)
{
        uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
        uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
        uint32_t avail = tail - head;
        uint32_t n = avail < (uint32_t)count ? avail : (uint32_t)count;
        uint32_t i;

        for (i = 0; i < n * 2; i++)
                out[i] = r->data[((head + (i / 2)) & RING_MASK) * 2 + (i & 1)];
        atomic_store_explicit(&r->head, head + n, memory_order_release);
        return (int)n;
}

/* ========================================================================
 * AudioUnits: one per stream, one shared render callback.
 * ======================================================================== */

static AudioUnit main_unit = NULL;
static AudioUnit cd_unit = NULL;
static ring_t main_ring;
static ring_t cd_ring;

/* Pulls from the ring (inRefCon), applies live gain with clipping, and
   zero-fills when the ring runs dry (underrun = silence, automatic recovery
   once the producer resumes). Runs on CoreAudio's realtime thread — no
   locks, no allocation, no logging here. */
static OSStatus sound_render(void *inRefCon,
                             AudioUnitRenderActionFlags *actionFlags,
                             const AudioTimeStamp *timeStamp,
                             UInt32 busNumber, UInt32 numFrames,
                             AudioBufferList *bufferList)
{
        ring_t *ring = (ring_t *)inRefCon;
        double gain = pow(10.0, (double)sound_gain / 20.0);
        UInt32 b;

        (void)actionFlags; (void)timeStamp; (void)busNumber;

        for (b = 0; b < bufferList->mNumberBuffers; b++)
        {
                int16_t *out = (int16_t *)bufferList->mBuffers[b].mData;
                UInt32 frames = bufferList->mBuffers[b].mDataByteSize / 4;
                UInt32 got, i;

                (void)numFrames; /* byte size is authoritative per buffer */
                got = (UInt32)ring_read(ring, out, (int)frames);

                if (gain != 1.0) /* bit-exact passthrough at the default 0 dB */
                {
                        for (i = 0; i < got * 2; i++)
                        {
                                double s = out[i] * gain;
                                out[i] = s > 32767.0 ? 32767 :
                                         s < -32768.0 ? -32768 : (int16_t)s;
                        }
                }
                if (got < frames)
                        memset(out + got * 2, 0,
                               (frames - got) * 2 * sizeof(int16_t));
        }
        return noErr;
}

static int create_output_unit(double rate, ring_t *ring, AudioUnit *unit_out)
{
        AudioComponentDescription desc;
        AudioComponent comp;
        AudioUnit unit;
        AudioStreamBasicDescription fmt;
        AURenderCallbackStruct cb;

        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr)
                return 0;

        /* Stereo int16 interleaved packed at the stream's native rate. */
        memset(&fmt, 0, sizeof(fmt));
        fmt.mSampleRate = rate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger |
                           kAudioFormatFlagIsPacked;
        fmt.mBitsPerChannel = 16;
        fmt.mChannelsPerFrame = 2;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerFrame = 4;
        fmt.mBytesPerPacket = 4;
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0,
                                 &fmt, sizeof(fmt)) != noErr)
        {
                AudioComponentInstanceDispose(unit);
                return 0;
        }

        cb.inputProc = sound_render;
        cb.inputProcRefCon = ring;
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Input, 0,
                                 &cb, sizeof(cb)) != noErr)
        {
                AudioComponentInstanceDispose(unit);
                return 0;
        }

        if (AudioUnitInitialize(unit) != noErr)
        {
                AudioComponentInstanceDispose(unit);
                return 0;
        }

        *unit_out = unit;
        return 1;
}

void closeal(void);

void initalmain(int argc, char *argv[])
{
        (void)argc; (void)argv;

        if (!create_output_unit(MAIN_FREQ, &main_ring, &main_unit))
                fprintf(stderr, "PCem: failed to create main audio output unit\n");
        if (!create_output_unit(CD_FREQ, &cd_ring, &cd_unit))
                fprintf(stderr, "PCem: failed to create CD audio output unit\n");
        atexit(closeal);
}

void inital(void)
{
        /* Called once from sound_init at first boot; start is idempotent. */
        if (main_unit)
                AudioOutputUnitStart(main_unit);
        if (cd_unit)
                AudioOutputUnitStart(cd_unit);
}

void closeal(void)
{
        if (main_unit)
        {
                AudioOutputUnitStop(main_unit);
                AudioUnitUninitialize(main_unit);
                AudioComponentInstanceDispose(main_unit);
                main_unit = NULL;
        }
        if (cd_unit)
        {
                AudioOutputUnitStop(cd_unit);
                AudioUnitUninitialize(cd_unit);
                AudioComponentInstanceDispose(cd_unit);
                cd_unit = NULL;
        }
}

void givealbuffer(int32_t *buf)
{
        /* SOUNDBUFLEN is rewritten live by the core (Sound menu buffer
           length); the core caps it at MAXSOUNDBUFLEN (sound.c:138-141). */
        int len = SOUNDBUFLEN;
        int16_t buf16[MAXSOUNDBUFLEN * 2];
        int c;

        if (!main_unit || len <= 0 || len > MAXSOUNDBUFLEN)
                return;

        for (c = 0; c < len * 2; c++)
                buf16[c] = buf[c] < -32768 ? -32768 :
                           buf[c] > 32767 ? 32767 : (int16_t)buf[c];

        ring_write(&main_ring, buf16, len); /* drop-on-full, like OpenAL */
}

void givealbuffer_cd(int16_t *buf)
{
        /* Always exactly CD_BUFLEN frames per call (sound.c:205). */
        if (!cd_unit)
                return;
        ring_write(&cd_ring, buf, CD_BUFLEN);
}
