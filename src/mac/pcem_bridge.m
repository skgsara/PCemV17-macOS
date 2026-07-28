/* pcem_bridge.m — native macOS UI layer for the PCem core.
 *
 * This file does two jobs:
 *
 * 1. It satisfies the link-time contract the emulator core expects from a UI
 *    layer (see AGENTS.md "Coupling hazards"): create_bitmap/destroy_bitmap/
 *    hline, startblit/endblit, timer_read/timer_freq, the keyboard/mouse
 *    polling functions, updatewindowsize, set_window_title, warning,
 *    stop_emulation_now, get_pcem_path, dir_exists, plus joystick/MIDI stubs.
 *    It also assigns video_blit_memtoscreen_func so the core's blit thread
 *    can hand frames to us.
 *
 * 2. It exposes the small C API in pcem_bridge.h that the Swift shell
 *    (PCemMacApp.swift / EmulatorView.swift) drives: lifecycle, config
 *    switching, input injection, and frame delivery.
 *
 * The flow mirrors the wx UI (src/wx-sdl2.c pc_main/wx_start/start_emulation)
 * but collapsed into a single pass, with SDL replaced by pthreads/Foundation.
 */
/* NOTE: no Apple system headers beyond libc here on purpose — mach/dispatch
   headers typedef thread_t and unistd.h declares pause(), both colliding with
   PCem core names. Framework calls live in pcem_mac_platform.m. */
#include <time.h>
#include <pthread.h>
#include <sys/stat.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>

#include "ibm.h"
#include "device.h"
#include "config.h"
#include "video.h"
#include "cpu.h"
#include "x86.h"
#include "model.h"
#include "mem.h"
#include "nvr.h"
#include "sound.h"
#include "thread.h"
#include "paths.h"
#include "plat-keyboard.h"
#include "plat-mouse.h"
#include "plat-joystick.h"
#include "plat-midi.h"
#include "disc.h"
#include "disc_img.h"
#include "scsi_zip.h"
#include "cassette.h"
#include "cdrom-image.h"
#include "cdrom-ioctl.h"
#include "ide.h"
#include "ide_atapi.h"

#include "pcem_bridge.h"
#include "pcem_mac_platform.h"

/* Core blit-handshake function, defined in video.c but not in any header
   (the wx UI declares it in wx-sdl2-video.h, which we don't use). */
void video_blit_complete(void);

/* atapi_close() is UI glue in the wx build (wx-sdl2.c:783): close whichever
   CD backend is active. Ported here. */
static void atapi_close(void)
{
        switch (cdrom_drive)
        {
        case CDROM_IMAGE:
                image_close();
                break;
        default:
                ioctl_close();
                break;
        }
}

/* ========================================================================
 * UI-owned globals the core references (defined here, declared extern in
 * core headers)
 * ======================================================================== */

int pause = 0;                          /* read by runpc() pacing (was wx-sdl2.c) */
uint64_t timer_freq;                    /* read by video cards' blitter timing */

int romspresent[ROM_MAX];               /* declared extern in ibm.h, UI-owned */
int gfx_present[GFX_MAX];               /* declared extern in ibm.h, UI-owned */

uint8_t pcem_key[272];                  /* PC scancode state, read by core keyboard.c */
int rawinputkey[272];                   /* host-side shadow, written by the UI thread */
int mouse_buttons;                      /* bit0=L bit1=R bit2=M, read by pc.c */
joystick_t joystick_state[MAX_JOYSTICKS]; /* zeroed = no joysticks attached */

/* ========================================================================
 * Bitmap + blit contract (was wx-sdl2-video.c)
 * ======================================================================== */

void hline(BITMAP *b, int x1, int y, int x2, int col)
{
        if (y < 0 || y >= buffer32->h)
                return;

        for (; x1 < x2; x1++)
                ((uint32_t *)b->line[y])[x1] = col;
}

BITMAP *create_bitmap(int x, int y)
{
        BITMAP *b = malloc(sizeof(BITMAP) + (y * sizeof(uint8_t *)));
        int c;
        b->dat = malloc(x * y * 4);
        for (c = 0; c < y; c++)
                b->line[c] = b->dat + (c * x * 4);
        b->w = x;
        b->h = y;
        return b;
}

void destroy_bitmap(BITMAP *b)
{
        free(b->dat);
        free(b);
}

/* The core's blit thread (video.c) calls video_blit_memtoscreen_func with a
   dirty row range of buffer32; we copy it into our staging buffer and then
   MUST call video_blit_complete() so the core's emulation thread can reuse
   buffer32. framebuf/ frame_dirty are re-read by a ~60 Hz UI timer via
   pcem_bridge_copy_frame(). Pixels are 32-bit BGRX. */
#define FB_W 2048
#define FB_H 2048

static uint8_t *framebuf = NULL;
static pthread_mutex_t frame_mutex = PTHREAD_MUTEX_INITIALIZER;
static int frame_dirty = 0;
static int frame_w = 0, frame_h = 0;

static void mac_blit_memtoscreen(int x, int y, int y1, int y2, int w, int h)
{
        if (y1 == y2 || !buffer32)
        {
                video_blit_complete();
                return;
        }

        pthread_mutex_lock(&frame_mutex);
        for (int yy = y1; yy < y2; yy++)
        {
                if ((y + yy) >= 0 && (y + yy) < buffer32->h)
                        memcpy(framebuf + yy * FB_W * 4,
                               &(((uint32_t *)buffer32->line[y + yy])[x]), w * 4);
        }
        frame_w = w;
        frame_h = h;
        frame_dirty = 1;
        pthread_mutex_unlock(&frame_mutex);
        video_blit_complete();
}

int pcem_bridge_frame_max_bytes(void)
{
        return FB_W * FB_H * 4;
}

int pcem_bridge_copy_frame(uint8_t *dst, int *w, int *h)
{
        int copied = 0;
        pthread_mutex_lock(&frame_mutex);
        if (frame_dirty && framebuf)
        {
                for (int yy = 0; yy < frame_h; yy++)
                        memcpy(dst + yy * frame_w * 4,
                               framebuf + yy * FB_W * 4, frame_w * 4);
                *w = frame_w;
                *h = frame_h;
                frame_dirty = 0;
                copied = 1;
        }
        pthread_mutex_unlock(&frame_mutex);
        return copied;
}

/* ========================================================================
 * Blit locking (was ghMutex in wx-sdl2.c — a self-lock around runpc())
 * ======================================================================== */

static pthread_mutex_t blit_mutex = PTHREAD_MUTEX_INITIALIZER;

void startblit(void)
{
        pthread_mutex_lock(&blit_mutex);
}

void endblit(void)
{
        pthread_mutex_unlock(&blit_mutex);
}

/* ========================================================================
 * Timing (was SDL_GetPerformanceCounter in wx-sdl2.c). We use nanoseconds
 * since boot; timer_freq tells the core the ticks-per-second to match.
 * ======================================================================== */

uint64_t timer_read(void)
{
        return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static uint64_t host_ms(void)
{
        return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000;
}

/* ========================================================================
 * Keyboard / mouse / joystick / MIDI (was wx-sdl2-keyboard.c etc.)
 * ======================================================================== */

void keyboard_poll_host(void)
{
        for (int c = 0; c < 272; c++)
                pcem_key[c] = rawinputkey[c] > 0;
}

static int mouse_x = 0, mouse_y = 0, mouse_z = 0;
static int pending_dx = 0, pending_dy = 0, pending_dz = 0;
static int host_buttons = 0;

void mouse_poll_host(void)
{
        if (mousecapture) /* global owned by core (pc.c) */
        {
                mouse_buttons = host_buttons;
                mouse_x += pending_dx; pending_dx = 0;
                mouse_y += pending_dy; pending_dy = 0;
                mouse_z += pending_dz; pending_dz = 0;
        }
        else
        {
                mouse_x = mouse_y = mouse_z = mouse_buttons = 0;
                pending_dx = pending_dy = pending_dz = 0;
        }
}

void mouse_get_mickeys(int *x, int *y, int *z)
{
        *x = mouse_x;
        *y = mouse_y;
        *z = mouse_z;
        mouse_x = mouse_y = mouse_z = 0;
}

void joystick_poll(void) { }
void midi_write(uint8_t val) { (void)val; }

/* ========================================================================
 * Misc core callbacks
 * ======================================================================== */

void warning(const char *format, ...)
{
        char buf[1024];
        va_list ap;
        va_start(ap, format);
        vsnprintf(buf, sizeof(buf), format, ap);
        va_end(ap);
        pclog("WARNING: %s\n", buf);
        pcem_mac_log(buf);
}

void get_pcem_path(char *s, int size)
{
        /* The post-build script symlinks roms/ nvr/ configs/ screenshots/ and
           pcem.cfg into Contents/Resources/, exactly like the wx build. */
        pcem_mac_resource_path(s, size);
}

int dir_exists(char *path)
{
        struct stat st;
        return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* ========================================================================
 * Callbacks into the Swift shell (always invoked on the main queue)
 * ======================================================================== */

static pcem_title_cb title_cb = NULL;
static void *title_ctx = NULL;
static pcem_video_size_cb video_size_cb = NULL;
static void *video_size_ctx = NULL;
static pcem_stop_cb stop_cb = NULL;
static void *stop_ctx = NULL;

void pcem_bridge_set_title_callback(pcem_title_cb cb, void *ctx)
{
        title_cb = cb; title_ctx = ctx;
}

void pcem_bridge_set_video_size_callback(pcem_video_size_cb cb, void *ctx)
{
        video_size_cb = cb; video_size_ctx = ctx;
}

void pcem_bridge_set_stop_callback(pcem_stop_cb cb, void *ctx)
{
        stop_cb = cb; stop_ctx = ctx;
}

/* The three functions below are called from the emulation thread; marshal
   them to the main queue via pcem_mac_run_on_main (dispatch_async_f). */

typedef struct
{
        pcem_title_cb cb;
        void *ctx;
        char *title;
} title_msg_t;

static void title_trampoline(void *arg)
{
        title_msg_t *m = arg;
        m->cb(m->ctx, m->title);
        free(m->title);
        free(m);
}

/* Called from the emulation thread ~1 Hz (pc.c) with the FPS status line. */
void set_window_title(const char *s)
{
        if (!title_cb)
                return;
        title_msg_t *m = malloc(sizeof(*m));
        m->cb = title_cb;
        m->ctx = title_ctx;
        m->title = strdup(s);
        pcem_mac_run_on_main(title_trampoline, m);
}

typedef struct
{
        pcem_video_size_cb cb;
        void *ctx;
        int w, h;
} video_size_msg_t;

static void video_size_trampoline(void *arg)
{
        video_size_msg_t *m = arg;
        m->cb(m->ctx, m->w, m->h);
        free(m);
}

/* Called from the emulation thread whenever the guest changes resolution. */
void updatewindowsize(int x, int y)
{
        if (!video_size_cb)
                return;
        video_size_msg_t *m = malloc(sizeof(*m));
        m->cb = video_size_cb;
        m->ctx = video_size_ctx;
        m->w = x;
        m->h = y;
        pcem_mac_run_on_main(video_size_trampoline, m);
}

static void stop_trampoline(void *arg)
{
        (void)arg;
        stop_cb(stop_ctx);
}

/* Called by the core when the guest powers off (ACPI shutdown etc.). */
void stop_emulation_now(void)
{
        /* Deduct enough cycles that runpc() returns immediately. */
        cycles -= 99999999;
        if (stop_cb)
                pcem_mac_run_on_main(stop_trampoline, NULL);
}

/* ========================================================================
 * Emulation thread (port of mainthread() in wx-sdl2.c)
 * ======================================================================== */

static volatile int emu_running = 0;
static event_t *emu_done_event = NULL;
static int started = 0;

static void emu_thread_proc(void *param)
{
        (void)param;
        int frames = 0;
        int drawits = 0;
        uint64_t old_time = host_ms();
        uint64_t last_sec = old_time;
        uint64_t new_time;

        while (emu_running)
        {
                new_time = host_ms();
                drawits += (int)(new_time - old_time);
                old_time = new_time;

                if (new_time - last_sec >= 1000)
                {
                        onesec(); /* core: updates fps counters (pc.c) */
                        last_sec = new_time;
                }

                if (drawits > 0 && !pause)
                {
                        drawits -= 10;
                        if (drawits > 50)
                                drawits = 0;
                        runpc();
                        frames++;
                        if (frames >= 200 && nvr_dosave)
                        {
                                frames = 0;
                                nvr_dosave = 0;
                                savenvr();
                        }
                }
                else
                {
                        thread_sleep(1);
                }
        }

        thread_set_event(emu_done_event);
}

static void emu_thread_start(void)
{
        emu_running = 1;
        thread_create(emu_thread_proc, NULL);
}

/* Mirror of wx stop_emulation(): join the thread, flush state to disk. */
static void emu_thread_stop(void)
{
        if (!emu_running)
                return;
        emu_running = 0;
        thread_wait_event(emu_done_event, 10000);
        savenvr();
        saveconfig(NULL);
        device_close_all();
}

/* ========================================================================
 * Machine config list (the *.cfg files in configs/)
 * ======================================================================== */

static char **config_names = NULL;
static int config_count = 0;

static void scan_configs(void)
{
        for (int i = 0; i < config_count; i++)
                free(config_names[i]);
        free(config_names);
        config_names = NULL;
        config_count = pcem_mac_list_configs(configs_path, &config_names);
}

int pcem_bridge_config_count(void)
{
        return config_count;
}

const char *pcem_bridge_config_name(int index)
{
        if (index < 0 || index >= config_count)
                return NULL;
        return config_names[index];
}

const char *pcem_bridge_current_config_name(void)
{
        return config_name; /* core global (config.c) */
}

/* Point the core at config #index, same as the wx config picker does. */
static void select_config_by_index(int index)
{
        char cfg[512];
        snprintf(cfg, sizeof(cfg), "%s%s%s.cfg", configs_path,
                 configs_path[strlen(configs_path) - 1] == '/' ? "" : "/",
                 config_names[index]);
        strcpy(config_file_default, cfg);
        strcpy(config_name, config_names[index]);
}

/* ========================================================================
 * Lifecycle (pc_main + wx_start + start_emulation collapsed into one pass)
 * ======================================================================== */

/* Shared tail of start/use_config: pick a bootable romset/gfxcard if the
   configured one is missing, then cold-boot. Mirrors start_emulation(). */
static void boot_machine(void)
{
        int c;

        if (!loadbios())
        {
                for (c = 0; c < ROM_MAX; c++)
                {
                        if (romspresent[c])
                        {
                                romset = c;
                                model = model_getmodel(romset);
                                break;
                        }
                }
        }

        if (!video_card_available(video_old_to_new(gfxcard)))
        {
                for (c = GFX_MAX - 1; c >= 0; c--)
                {
                        if (gfx_present[c])
                        {
                                gfxcard = c;
                                break;
                        }
                }
        }

        loadbios();
        resetpchard();
}

int pcem_bridge_start(void)
{
        if (started)
                return 1;

        /* timer_read() counts nanoseconds; tell the core. */
        timer_freq = 1000000000;

        framebuf = malloc(FB_W * FB_H * 4);
        video_blit_memtoscreen_func = mac_blit_memtoscreen;

        paths_init();

        char *argv0 = (char *)"PCemMac";
        initpc(1, &argv0); /* parses args + loads pcem.cfg and the machine cfg */

        scan_configs();

        /* Upstream PCem leaves config_file_default empty at startup and shows
           the wx machine manager instead. We have no startup dialog, so boot
           the last-used machine (NSUserDefaults), else the first in the list. */
        if (config_name[0] == 0 && config_count > 0)
        {
                int index = 0;
                char saved[256];
                if (pcem_mac_defaults_get_string("lastMachine", saved, sizeof(saved)))
                {
                        for (int i = 0; i < config_count; i++)
                        {
                                if (!strcmp(config_names[i], saved))
                                {
                                        index = i;
                                        break;
                                }
                        }
                }
                select_config_by_index(index);
                loadconfig(NULL); /* reload with the machine cfg in place */
        }

        /* Availability scan, mirrors wx_start(). */
        int c, d = romset;
        for (c = 0; c < ROM_MAX; c++)
        {
                romset = c;
                romspresent[c] = loadbios();
        }
        romset = d;
        for (c = 0; c < ROM_MAX; c++)
        {
                if (romspresent[c])
                        break;
        }
        if (c == ROM_MAX)
        {
                pclog("No ROMs present!\n");
                return 0;
        }
        for (c = 0; c < GFX_MAX; c++)
                gfx_present[c] = video_card_available(video_old_to_new(c));

        boot_machine();
        sound_init();

        emu_done_event = thread_create_event();
        emu_thread_start();

        updatewindowsize(640, 480);
        started = 1;
        return 1;
}

void pcem_bridge_stop(void)
{
        if (!started)
                return;
        emu_thread_stop();
        started = 0;
}

void pcem_bridge_quit(void)
{
        pcem_bridge_stop();
        closepc();
}

void pcem_bridge_pause(int paused)
{
        pause = paused ? 1 : 0;
}

int pcem_bridge_is_paused(void)
{
        return pause;
}

/* kind: 0 = soft reset, 1 = hard reset, 2 = ctrl+alt+del.
   Mirrors the wx reset handlers (wx-sdl2.c reset_emulation etc.). */
void pcem_bridge_reset(int kind)
{
        if (!started)
                return;
        pause = 1;
        thread_sleep(100);
        savenvr();
        if (kind == 2)
                resetpc_cad();
        else if (kind == 1)
                resetpchard();
        else
                resetpc();
        pause = 0;
}

void pcem_bridge_use_config(int index)
{
        if (!started || index < 0 || index >= config_count)
                return;

        /* stop_emulation() equivalent */
        emu_thread_stop();

        select_config_by_index(index);
        pcem_mac_defaults_set_string("lastMachine", config_names[index]);

        loadconfig(NULL);
        boot_machine();

        emu_thread_start();
        updatewindowsize(640, 480);
}

/* ========================================================================
 * Machine manager (M4): file ops on configs/*.cfg
 * (replaces the wx machine-manager dialog, wx-config_sel.c)
 * ======================================================================== */

static int config_name_valid(const char *name)
{
        size_t len;
        if (!name)
                return 0;
        len = strlen(name);
        if (len == 0 || len >= 200)
                return 0;
        if (name[0] == '.')
                return 0;
        if (strchr(name, '/') || strchr(name, '\\'))
                return 0;
        return 1;
}

static void config_path_for(const char *name, char *out, int size)
{
        snprintf(out, size, "%s%s%s.cfg", configs_path,
                 configs_path[strlen(configs_path) - 1] == '/' ? "" : "/",
                 name);
}

/* If lastMachine still points at old_name, move it to new_name (or remove it
   when new_name is NULL). Keeps the auto-boot memory consistent after
   rename/delete. */
static void lastmachine_fixup(const char *old_name, const char *new_name)
{
        char saved[256];
        if (pcem_mac_defaults_get_string("lastMachine", saved, sizeof(saved)) &&
            !strcmp(saved, old_name))
        {
                if (new_name)
                        pcem_mac_defaults_set_string("lastMachine", new_name);
                else
                        pcem_mac_defaults_remove("lastMachine");
        }
}

int pcem_bridge_config_create(const char *name)
{
        char path[512];

        if (!config_name_valid(name))
                return 2;
        config_path_for(name, path, sizeof(path));
        {
                struct stat st;
                if (stat(path, &st) == 0)
                        return 1; /* already exists */
        }
        /* wx opens its settings dialog before saving (wx-config_sel.c IDC_NEW).
           Our settings dialog doesn't exist yet (M4 step 2), so the new config
           starts as a copy of the current machine's settings. */
        saveconfig(path);
        return 0;
}

int pcem_bridge_config_rename(const char *old_name, const char *new_name)
{
        char old_path[512], new_path[512];
        struct stat st;

        if (!config_name_valid(new_name))
                return 2;
        config_path_for(old_name, old_path, sizeof(old_path));
        config_path_for(new_name, new_path, sizeof(new_path));
        if (stat(new_path, &st) == 0)
                return 1;
        if (rename(old_path, new_path) != 0)
                return 3;
        if (!strcmp(config_name, old_name))
        {
                /* The renamed config is the booted machine: follow it. */
                strcpy(config_name, new_name);
                strcpy(config_file_default, new_path);
        }
        lastmachine_fixup(old_name, new_name);
        return 0;
}

int pcem_bridge_config_copy(const char *old_name, const char *new_name)
{
        char old_path[512], new_path[512];
        char buf[4096];
        FILE *in, *out;
        size_t n;
        struct stat st;

        if (!config_name_valid(new_name))
                return 2;
        config_path_for(old_name, old_path, sizeof(old_path));
        config_path_for(new_name, new_path, sizeof(new_path));
        if (stat(new_path, &st) == 0)
                return 1;
        in = fopen(old_path, "rb");
        if (!in)
                return 3;
        out = fopen(new_path, "wb");
        if (!out)
        {
                fclose(in);
                return 3;
        }
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        {
                if (fwrite(buf, 1, n, out) != n)
                {
                        fclose(in);
                        fclose(out);
                        remove(new_path);
                        return 3;
                }
        }
        fclose(in);
        fclose(out);
        return 0;
}

int pcem_bridge_config_delete(const char *name)
{
        char path[512];

        if (!config_name_valid(name))
                return 2;
        config_path_for(name, path, sizeof(path));
        if (remove(path) != 0)
                return 3;
        lastmachine_fixup(name, NULL);
        return 0;
}

void pcem_bridge_config_rescan(void)
{
        scan_configs();
}

void pcem_bridge_use_config_named(const char *name)
{
        int i;
        for (i = 0; i < config_count; i++)
        {
                if (!strcmp(config_names[i], name))
                {
                        pcem_bridge_use_config(i);
                        return;
                }
        }
}

/* ========================================================================
 * Input injection (called from the UI thread)
 * ======================================================================== */

void pcem_bridge_key_event(int pc_scancode, int down)
{
        if (pc_scancode < 0 || pc_scancode >= 272)
                return;
        rawinputkey[pc_scancode] = down ? 1 : 0;
}

void pcem_bridge_mouse_move(int dx, int dy, int dz)
{
        pending_dx += dx;
        pending_dy += dy;
        pending_dz += dz;
}

void pcem_bridge_mouse_button(int button, int down)
{
        int bit;
        switch (button)
        {
                case 0: bit = 1; break; /* left   */
                case 1: bit = 2; break; /* right  */
                case 2: bit = 4; break; /* middle */
                default: return;
        }
        if (down)
                host_buttons |= bit;
        else
                host_buttons &= ~bit;
}

void pcem_bridge_mouse_capture(int captured)
{
        mousecapture = captured ? 1 : 0;
        if (!captured)
        {
                /* Drop held buttons/deltas so the guest doesn't see stuck input. */
                host_buttons = 0;
                pending_dx = pending_dy = pending_dz = 0;
        }
}

/* ========================================================================
 * Drives & sound (each mirrors the corresponding wx-sdl2.c menu handler)
 * ======================================================================== */

void pcem_bridge_mount_floppy(int drive, const char *path)
{
        if (drive < 0 || drive > 1 || !path || !path[0])
                return;
        disc_close(drive);
        disc_load(drive, (char *)path);
        saveconfig(NULL);
}

void pcem_bridge_eject_floppy(int drive)
{
        if (drive < 0 || drive > 1)
                return;
        disc_close(drive);
        saveconfig(NULL);
}

const char *pcem_bridge_floppy_path(int drive)
{
        if (drive < 0 || drive > 1)
                return "";
        return discfns[drive];
}

void pcem_bridge_mount_cd_image(const char *path)
{
        if (!path || !path[0])
                return;
        if (!strcmp(image_path, path) && cdrom_drive == CDROM_IMAGE)
                return; /* same image already mounted */
        atapi->exit();
        atapi_close();
        image_open((char *)path);
        old_cdrom_drive = cdrom_drive;
        cdrom_drive = CDROM_IMAGE;
        saveconfig(NULL);
}

void pcem_bridge_eject_cd(void)
{
        if (cdrom_drive == 0)
                return;
        atapi->exit();
        atapi_close();
        ioctl_set_drive(0);
        old_cdrom_drive = cdrom_drive;
        cdrom_drive = 0;
        saveconfig(NULL);
}

int pcem_bridge_cd_is_empty(void)
{
        return cdrom_drive == 0;
}

void pcem_bridge_zip_load(const char *path)
{
        if (!path || !path[0])
                return;
        zip_load((char *)path);
}

void pcem_bridge_zip_eject(void)
{
        zip_eject();
}

void pcem_bridge_cassette_load(const char *path)
{
        if (!path || !path[0])
                return;
        cassette_eject();
        cassette_load(path);
        saveconfig(NULL);
}

void pcem_bridge_cassette_eject(void)
{
        cassette_eject();
        saveconfig(NULL);
}

int pcem_bridge_get_bpb_disable(void)
{
        return bpb_disable;
}

void pcem_bridge_set_bpb_disable(int disabled)
{
        bpb_disable = disabled ? 1 : 0;
        saveconfig(NULL);
}

int pcem_bridge_get_sound_buf_len(void)
{
        return sound_buf_len;
}

void pcem_bridge_set_sound_buf_len(int ms)
{
        sound_buf_len = ms;
        saveconfig(NULL);
}

int pcem_bridge_get_sound_gain(void)
{
        return sound_gain;
}

void pcem_bridge_set_sound_gain(int db)
{
        sound_gain = db;
        saveconfig(NULL);
}
