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
#include "mouse.h"
#include "gameport.h"
#include "hdd.h"
#include "lpt.h"
#include "fdd.h"
#include "scsi_cd.h"

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

        /* Launcher-first, like the wx app: NO machine is booted here. The
           machine manager appears at startup and pcem_bridge_use_config does
           the first boot. lastMachine only preselects in the manager. */

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

        emu_done_event = thread_create_event();
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
        static int sound_inited = 0;

        if (!started || index < 0 || index >= config_count)
                return;

        /* stop_emulation() equivalent (no-op when nothing is running yet) */
        emu_thread_stop();

        select_config_by_index(index);
        pcem_mac_defaults_set_string("lastMachine", config_names[index]);

        loadconfig(NULL);
        boot_machine();
        if (!sound_inited)
        {
                sound_init();
                sound_inited = 1;
        }

        emu_thread_start();
        updatewindowsize(640, 480);
}

int pcem_bridge_machine_is_running(void)
{
        return emu_running;
}

const char *pcem_bridge_remembered_config_name(void)
{
        static char saved[256];

        if (pcem_mac_defaults_get_string("lastMachine", saved, sizeof(saved)))
                return saved;
        return "";
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

/* ========================================================================
 * Machine settings (M4 step 2) — port of the wx settings dialog
 * (wx-config.c). The list feeders reproduce recalc_*_list (filtered by the
 * SELECTED model); apply reproduces config_dlgsave. HD slots and device
 * "Configure" sub-dialogs are M4 step 3 / M5.
 * ======================================================================== */

/* Edit mode: settings are loaded from a config file without booting it
   (the wx machine manager's Configure flow). Only valid while no machine
   is running; apply saves back to the same file and skips the reboot. */
static char settings_edit_path[512];
static int settings_edit_mode = 0;

void pcem_bridge_settings_begin(void)
{
        settings_edit_mode = 0;
        pause = 1;
}

int pcem_bridge_settings_begin_edit(const char *config_name)
{
        char path[512];

        if (emu_running || !config_name_valid(config_name))
                return 0;
        config_path_for(config_name, path, sizeof(path));
        loadconfig(path); /* fills the globals the settings UI reads */
        strncpy(settings_edit_path, path, sizeof(settings_edit_path) - 1);
        settings_edit_path[sizeof(settings_edit_path) - 1] = 0;
        settings_edit_mode = 1;
        return 1;
}

void pcem_bridge_settings_cancel(void)
{
        settings_edit_mode = 0;
        pause = 0;
}

void pcem_bridge_settings_get(pcem_settings_t *s)
{
        int c;

        memset(s, 0, sizeof(*s));
        s->model = model;
        s->cpu_manufacturer = cpu_manufacturer;
        s->cpu = cpu;
        for (c = 0; fpu_get_name_from_index(model, cpu_manufacturer, cpu, c); c++)
        {
                if (fpu_get_type_from_index(model, cpu_manufacturer, cpu, c) == fpu_type)
                {
                        s->fpu_index = c;
                        break;
                }
        }
        s->cpu_use_dynarec = cpu_use_dynarec;
        s->cpu_waitstates = cpu_waitstates;
        s->mem_size = mem_size;
        s->enable_sync = enable_sync;
        s->gfxcard = gfxcard;
        s->video_speed = video_speed;
        s->voodoo = voodoo_enabled;
        s->sound_card = sound_card_current;
        s->gameblaster = GAMEBLASTER;
        s->gus = GUS;
        s->ssi2001 = SSI2001;
        s->fdd_type[0] = fdd_get_type(0);
        s->fdd_type[1] = fdd_get_type(1);
        s->cd_speed = cd_speed;
        s->mouse_type = mouse_type;
        s->joystick_type = joystick_type;
}

const char *pcem_bridge_settings_hdd_controller(void)
{
        return hdd_controller_name;
}

const char *pcem_bridge_settings_lpt1_device(void)
{
        return lpt1_device_name;
}

const char *pcem_bridge_settings_cd_model(void)
{
        return cd_model ? cd_model : "";
}

/* The wx dialog clamps the spin value in DISPLAY units (MB for AT machines
   with ram_granularity < 128, else KB), then converts to KB. The struct
   always carries KB, so convert both ways. */
static int clamp_mem_size(int m, int mem_kb)
{
        int uses_mb = (models[m].flags & MODEL_AT) && models[m].ram_granularity < 128;
        int mem = uses_mb ? mem_kb / 1024 : mem_kb;

        mem &= ~(models[m].ram_granularity - 1);
        if (mem < models[m].min_ram)
                mem = models[m].min_ram;
        else if (mem > models[m].max_ram)
                mem = models[m].max_ram;
        return uses_mb ? mem * 1024 : mem;
}

/* Dirty check = same field list as config_dlgsave (minus HD slots and
   cdrom/zip channels, which are M4 step 3). */
static int settings_dirty(const pcem_settings_t *s, const char *hdd, const char *lpt)
{
        int mem = clamp_mem_size(s->model, s->mem_size);
        int temp_fpu = fpu_get_type_from_index(s->model, s->cpu_manufacturer,
                                               s->cpu, s->fpu_index);

        return s->model != model || s->gfxcard != gfxcard || mem != mem_size ||
               temp_fpu != fpu_type ||
               s->gameblaster != GAMEBLASTER || s->gus != GUS ||
               s->ssi2001 != SSI2001 || s->sound_card != sound_card_current ||
               s->voodoo != voodoo_enabled || s->cpu_use_dynarec != cpu_use_dynarec ||
               s->fdd_type[0] != fdd_get_type(0) || s->fdd_type[1] != fdd_get_type(1) ||
               s->mouse_type != mouse_type ||
               strncmp(hdd, hdd_controller_name, sizeof(hdd_controller_name) - 1) ||
               strcmp(lpt, lpt1_device_name);
}

int pcem_bridge_settings_would_reboot(const pcem_settings_t *s,
        const char *hdd_controller, const char *lpt1_device)
{
        /* In edit mode (or otherwise with no machine running) nothing
           reboots — apply just saves the file. */
        return emu_running && settings_dirty(s, hdd_controller, lpt1_device);
}

void pcem_bridge_settings_apply(const pcem_settings_t *s,
        const char *hdd_controller, const char *lpt1_device, const char *cd_model_name)
{
        int c;
        int edit_mode = settings_edit_mode;

        if (settings_dirty(s, hdd_controller, lpt1_device))
        {
                /* Same pause/sleep pattern as pcem_bridge_reset: let the emu
                   thread park before we reconfigure under it. */
                if (!edit_mode)
                {
                        pause = 1;
                        thread_sleep(100);
                }

                savenvr();
                model = s->model;
                romset = model_getromset();
                gfxcard = s->gfxcard;
                mem_size = clamp_mem_size(s->model, s->mem_size);
                cpu_manufacturer = s->cpu_manufacturer;
                cpu = s->cpu;
                fpu_type = fpu_get_type_from_index(s->model, s->cpu_manufacturer,
                                                   s->cpu, s->fpu_index);
                GAMEBLASTER = s->gameblaster;
                GUS = s->gus;
                SSI2001 = s->ssi2001;
                sound_card_current = s->sound_card;
                voodoo_enabled = s->voodoo;
                cpu_use_dynarec = s->cpu_use_dynarec;
                mouse_type = s->mouse_type;
                strncpy(lpt1_device_name, lpt1_device, sizeof(lpt1_device_name) - 1);
                lpt1_device_name[sizeof(lpt1_device_name) - 1] = 0;
                fdd_set_type(0, s->fdd_type[0]);
                fdd_set_type(1, s->fdd_type[1]);
                strncpy(hdd_controller_name, hdd_controller, sizeof(hdd_controller_name) - 1);
                hdd_controller_name[sizeof(hdd_controller_name) - 1] = 0;

                if (!edit_mode)
                {
                        mem_alloc();
                        loadbios();
                        resetpchard();
                }
        }

        /* The rest runs even when nothing reboot-worthy changed (wx does the
           same: video_speed, cpu_set, waitstates, CD, joystick). */
        video_speed = s->video_speed;
        cpu_manufacturer = s->cpu_manufacturer;
        cpu = s->cpu;
        cpu_set();
        cpu_waitstates = s->cpu_waitstates;
        cpu_update_waitstates();
        enable_sync = s->enable_sync;

        cd_speed = s->cd_speed;
        cd_set_speed(cd_speed);
        /* Match the display string back to the table entry, as wx does with
           cd_get_model(cursel). */
        for (c = 0; c <= MAX_CD_MODEL; c++)
        {
                if (!strcmp(cd_get_model(c), cd_model_name))
                {
                        cd_model = cd_get_model(c);
                        cd_set_model(cd_model);
                        break;
                }
        }

        saveconfig(edit_mode ? settings_edit_path : NULL);
        speedchanged();

        joystick_type = s->joystick_type;
        gameport_update_joystick_type();

        settings_edit_mode = 0;
        pause = 0;
}

/* ---- List feeders (ports of the recalc_*_list filters) ------------------
   Model-filtered lists are cached per model; the UI re-queries after every
   model change, so a single cached "list_model" is enough (UI thread only). */

static int list_model = -1;

/* models with ROMs present (wx builds modeltolist/listtomodel the same way) */
#define MAX_MODEL_LIST 128
static int model_list[MAX_MODEL_LIST];
static int model_list_count = 0;

static void rebuild_model_list(void)
{
        int c;

        model_list_count = 0;
        for (c = 0; models[c].id != -1 && model_list_count < MAX_MODEL_LIST; c++)
        {
                if (romspresent[models[c].id])
                        model_list[model_list_count++] = c;
        }
}

int pcem_bridge_settings_model_count(void)
{
        if (!model_list_count)
                rebuild_model_list();
        return model_list_count;
}

const char *pcem_bridge_settings_model_name(int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_settings_model_count())
                return "";
        return models[model_list[list_index]].name;
}

int pcem_bridge_settings_model_index(int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_settings_model_count())
                return -1;
        return model_list[list_index];
}

int pcem_bridge_model_min_ram(int m)          { return models[m].min_ram; }
int pcem_bridge_model_max_ram(int m)          { return models[m].max_ram; }
int pcem_bridge_model_ram_granularity(int m)  { return models[m].ram_granularity; }
int pcem_bridge_model_uses_mb(int m)
{
        return (models[m].flags & MODEL_AT) && models[m].ram_granularity < 128;
}
int pcem_bridge_model_has_pci(int m)          { return models[m].flags & MODEL_PCI; }
int pcem_bridge_model_has_fixed_gfx(int m)    { return model_has_fixed_gfx(m); }
int pcem_bridge_model_has_optional_gfx(int m) { return model_has_optional_gfx(m); }

int pcem_bridge_cpu_manu_count(int m)
{
        int c = 0;
        while (models[m].cpu[c].cpus != NULL && c < 4)
                c++;
        return c;
}

const char *pcem_bridge_cpu_manu_name(int m, int manu)
{
        if (manu < 0 || manu >= pcem_bridge_cpu_manu_count(m))
                return "";
        return models[m].cpu[manu].name;
}

int pcem_bridge_cpu_count(int m, int manu)
{
        int c = 0;
        if (manu < 0 || manu >= pcem_bridge_cpu_manu_count(m))
                return 0;
        while (models[m].cpu[manu].cpus[c].cpu_type != -1)
                c++;
        return c;
}

const char *pcem_bridge_cpu_name(int m, int manu, int cpu)
{
        if (cpu < 0 || cpu >= pcem_bridge_cpu_count(m, manu))
                return "";
        return models[m].cpu[manu].cpus[cpu].name;
}

int pcem_bridge_cpu_dynarec_flags(int m, int manu, int cpu)
{
        if (cpu < 0 || cpu >= pcem_bridge_cpu_count(m, manu))
                return 0;
        return models[m].cpu[manu].cpus[cpu].cpu_flags;
}

int pcem_bridge_cpu_waitstates_supported(int m, int manu, int cpu)
{
        int type;
        if (cpu < 0 || cpu >= pcem_bridge_cpu_count(m, manu))
                return 0;
        type = models[m].cpu[manu].cpus[cpu].cpu_type;
        return type >= CPU_286 && type <= CPU_386DX;
}

int pcem_bridge_fpu_count(int m, int manu, int cpu)
{
        int c = 0;
        while (fpu_get_name_from_index(m, manu, cpu, c))
                c++;
        return c;
}

const char *pcem_bridge_fpu_name(int m, int manu, int cpu, int index)
{
        const char *name = fpu_get_name_from_index(m, manu, cpu, index);
        return name ? name : "";
}

/* video: list entries are old-style gfxcard values (GFX_BUILTIN = -1) */
#define MAX_VID_LIST 64
static int vid_list[MAX_VID_LIST];
static int vid_count = 0;

static void rebuild_video_list(int m)
{
        int c;
        int rs = model_getromset_from_model(m);

        vid_count = 0;
        if (model_has_fixed_gfx(m))
        {
                vid_list[vid_count++] = GFX_BUILTIN;
        }
        else
        {
                if (model_has_optional_gfx(m))
                        vid_list[vid_count++] = GFX_BUILTIN;
                for (c = 0; vid_count < MAX_VID_LIST; c++)
                {
                        char *name = video_card_getname(c);
                        device_t *dev;

                        if (!name[0])
                                break;
                        dev = video_card_getdevice(c, rs);
                        if (video_card_available(c) && gfx_present[video_new_to_old(c)] &&
                            ((models[m].flags & MODEL_PCI) || !(dev->flags & DEVICE_PCI)) &&
                            ((models[m].flags & MODEL_MCA) || !(dev->flags & DEVICE_MCA)) &&
                            (!(models[m].flags & MODEL_MCA) || (dev->flags & DEVICE_MCA)))
                                vid_list[vid_count++] = video_new_to_old(c);
                }
        }
        list_model = m;
}

int pcem_bridge_video_count(int m)
{
        if (list_model != m)
                rebuild_video_list(m);
        return vid_count;
}

const char *pcem_bridge_video_name(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_video_count(m))
                return "";
        if (vid_list[list_index] == GFX_BUILTIN)
                return "Built-in video";
        return video_card_getname(video_old_to_new(vid_list[list_index]));
}

int pcem_bridge_video_gfxcard(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_video_count(m))
                return 0;
        return vid_list[list_index];
}

/* sound: list entries are sound_cards[] indices */
#define MAX_SND_LIST 20
static int snd_list[MAX_SND_LIST];
static int snd_count = 0;
static int snd_list_model = -1;

static void rebuild_sound_list(int m)
{
        int c;

        snd_count = 0;
        for (c = 0; snd_count < MAX_SND_LIST; c++)
        {
                char *name = sound_card_getname(c);
                device_t *dev;

                if (!name[0])
                        break;
                if (!sound_card_available(c))
                        continue;
                dev = sound_card_getdevice(c);
                if (!dev || (dev->flags & DEVICE_MCA) == (models[m].flags & MODEL_MCA))
                        snd_list[snd_count++] = c;
        }
        snd_list_model = m;
}

int pcem_bridge_sound_count(int m)
{
        if (snd_list_model != m)
                rebuild_sound_list(m);
        return snd_count;
}

const char *pcem_bridge_sound_name(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_sound_count(m))
                return "";
        return sound_card_getname(snd_list[list_index]);
}

int pcem_bridge_sound_card(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_sound_count(m))
                return 0;
        return snd_list[list_index];
}

/* hdd controllers: list entries are controller indices */
#define MAX_HDD_LIST 16
static int hdd_list[MAX_HDD_LIST];
static int hdd_list_count = 0;
static int hdd_list_model = -1;

static void rebuild_hdd_list(int m)
{
        int c;

        hdd_list_count = 0;
        for (c = 0; hdd_list_count < MAX_HDD_LIST; c++)
        {
                char *name = hdd_controller_get_name(c);
                int flags;

                if (!name[0])
                        break;
                flags = hdd_controller_get_flags(c);
                if ((((flags & DEVICE_AT) && !(models[m].flags & MODEL_AT)) ||
                     (flags & DEVICE_MCA) != (models[m].flags & MODEL_MCA)) && c)
                        continue;
                if ((((flags & DEVICE_PS1) && models[m].id != ROM_IBMPS1_2011) ||
                     (!(flags & DEVICE_PS1) && models[m].id == ROM_IBMPS1_2011)) && c)
                        continue;
                if (!hdd_controller_available(c))
                        continue;
                hdd_list[hdd_list_count++] = c;
        }
        hdd_list_model = m;
}

int pcem_bridge_hdd_count(int m)
{
        if (hdd_list_model != m)
                rebuild_hdd_list(m);
        return hdd_list_count;
}

const char *pcem_bridge_hdd_name(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_hdd_count(m))
                return "";
        return hdd_controller_get_name(hdd_list[list_index]);
}

const char *pcem_bridge_hdd_internal_name(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_hdd_count(m))
                return "";
        return hdd_controller_get_internal_name(hdd_list[list_index]);
}

int pcem_bridge_lpt_count(void)
{
        int c = 0;
        while (lpt_device_get_name(c))
                c++;
        return c;
}

const char *pcem_bridge_lpt_name(int index)
{
        const char *name = lpt_device_get_name(index);
        return name ? name : "";
}

const char *pcem_bridge_lpt_internal_name(int index)
{
        const char *name = lpt_device_get_internal_name(index);
        return name ? name : "";
}

/* mice: port of mouse_valid() in wx-config.c (static there) */
static int mouse_valid_for_model(int type, int m)
{
        if (((type & MOUSE_TYPE_IF_MASK) == MOUSE_TYPE_PS2) &&
            !(models[m].flags & MODEL_PS2))
                return 0;
        if (((type & MOUSE_TYPE_IF_MASK) == MOUSE_TYPE_AMSTRAD) &&
            !(models[m].flags & MODEL_AMSTRAD))
                return 0;
        if (((type & MOUSE_TYPE_IF_MASK) == MOUSE_TYPE_OLIM24) &&
            !(models[m].flags & MODEL_OLIM24))
                return 0;
        return 1;
}

#define MAX_MOUSE_LIST 20
static int mouse_list_map[MAX_MOUSE_LIST];
static int mouse_list_count = 0;
static int mouse_list_model = -1;

static void rebuild_mouse_list(int m)
{
        int c;

        mouse_list_count = 0;
        for (c = 0; mouse_list_count < MAX_MOUSE_LIST; c++)
        {
                char *name = mouse_get_name(c);
                if (!name)
                        break;
                if (mouse_valid_for_model(mouse_get_type(c), m))
                        mouse_list_map[mouse_list_count++] = c;
        }
        mouse_list_model = m;
}

int pcem_bridge_mouse_count(int m)
{
        if (mouse_list_model != m)
                rebuild_mouse_list(m);
        return mouse_list_count;
}

const char *pcem_bridge_mouse_name(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_mouse_count(m))
                return "";
        return mouse_get_name(mouse_list_map[list_index]);
}

int pcem_bridge_mouse_type(int m, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_mouse_count(m))
                return 0;
        return mouse_list_map[list_index];
}

int pcem_bridge_joystick_count(void)
{
        int c = 0;
        while (joystick_get_name(c))
                c++;
        return c;
}

const char *pcem_bridge_joystick_name(int index)
{
        const char *name = joystick_get_name(index);
        return name ? name : "";
}

/* CD models filtered by the selected HDD controller's interface
   (port of recalc_cd_list). List entries are cd table indices. */
#define MAX_CD_LIST 8
static int cd_list_map[MAX_CD_LIST];
static int cd_list_count = 0;
static char cd_list_hdd[16] = "";

static void rebuild_cd_list(const char *hdd_internal_name)
{
        int c;
        int is_ide = hdd_controller_is_ide((char *)hdd_internal_name);
        int is_scsi = hdd_controller_is_scsi((char *)hdd_internal_name);

        cd_list_count = 0;
        for (c = 0; c <= MAX_CD_MODEL && cd_list_count < MAX_CD_LIST; c++)
        {
                int iface = cd_get_model_interfaces(c);
                if (iface == CD_MODEL_INTERFACE_ALL ||
                    (iface == CD_MODEL_INTERFACE_IDE && is_ide) ||
                    (iface == CD_MODEL_INTERFACE_SCSI && is_scsi))
                        cd_list_map[cd_list_count++] = c;
        }
        strncpy(cd_list_hdd, hdd_internal_name, sizeof(cd_list_hdd) - 1);
        cd_list_hdd[sizeof(cd_list_hdd) - 1] = 0;
}

int pcem_bridge_cd_model_count(const char *hdd_internal_name)
{
        if (strcmp(cd_list_hdd, hdd_internal_name))
                rebuild_cd_list(hdd_internal_name);
        return cd_list_count;
}

const char *pcem_bridge_cd_model_name(const char *hdd_internal_name, int list_index)
{
        if (list_index < 0 || list_index >= pcem_bridge_cd_model_count(hdd_internal_name))
                return "";
        return cd_get_model(cd_list_map[list_index]);
}

int pcem_bridge_cd_model_fixed_speed(const char *cd_model_name)
{
        int c;
        for (c = 0; c <= MAX_CD_MODEL; c++)
        {
                if (!strcmp(cd_get_model(c), cd_model_name))
                        return cd_get_model_speed(c);
        }
        return -1;
}

int pcem_bridge_cd_speed_count(void)
{
        int c = 0;
        while (cd_get_speed(c) < MAX_CD_SPEED)
                c++;
        return c + 1; /* include the MAX_CD_SPEED entry, as wx does */
}

int pcem_bridge_cd_speed_value(int list_index)
{
        return cd_get_speed(list_index);
}
