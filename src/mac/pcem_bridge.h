/* pcem_bridge.h — the ONLY PCem header imported by Swift (bridging header).
 *
 * Everything the Swift shell needs from the emulator core is exposed here as
 * plain C. The implementation (pcem_bridge.m) also satisfies the link-time
 * contract the core expects from a UI layer (create_bitmap, startblit,
 * keyboard_poll_host, ... — see AGENTS.md).
 */
#ifndef PCEM_BRIDGE_H
#define PCEM_BRIDGE_H

#include <stdint.h>

#include "keymap.h" /* pcem_mac_keycode_to_pc(): NSEvent.keyCode -> PC scancode */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- UI callbacks (invoked on the MAIN queue) ---------------------------
   Set these before pcem_bridge_start(). ctx is passed back untouched. */
typedef void (*pcem_title_cb)(void *ctx, const char *title);
typedef void (*pcem_video_size_cb)(void *ctx, int w, int h);
typedef void (*pcem_stop_cb)(void *ctx); /* guest asked to power off */

void pcem_bridge_set_title_callback(pcem_title_cb cb, void *ctx);
void pcem_bridge_set_video_size_callback(pcem_video_size_cb cb, void *ctx);
void pcem_bridge_set_stop_callback(pcem_stop_cb cb, void *ctx);

/* ---- Lifecycle -----------------------------------------------------------
   pcem_bridge_start boots the machine named by pcem.cfg / the current
   config. Returns 1 on success, 0 if no ROMs are usable. */
int  pcem_bridge_start(void);
void pcem_bridge_stop(void);      /* stop the emulation thread (app keeps running) */
void pcem_bridge_quit(void);      /* stop + full core shutdown, call before exit */
void pcem_bridge_pause(int paused);
int  pcem_bridge_is_paused(void);
/* kind: 0 = soft reset, 1 = hard reset, 2 = ctrl+alt+del */
void pcem_bridge_reset(int kind);

/* ---- Machine configs (list = *.cfg files in the configs/ dir) ------------ */
int         pcem_bridge_config_count(void);
const char *pcem_bridge_config_name(int index); /* name without .cfg */
const char *pcem_bridge_current_config_name(void);
/* Switch machine: stops, loads that config, cold-boots it. */
void        pcem_bridge_use_config(int index);
/* Same, by config name (safe against list rescans shifting indices). */
void        pcem_bridge_use_config_named(const char *name);

/* ---- Machine manager (M4): file ops on configs/*.cfg ---------------------
   All return 0 = ok, 1 = name already exists, 2 = invalid name,
   3 = file error. Names are without the .cfg extension. */
int  pcem_bridge_config_create(const char *name); /* save current settings as name.cfg */
int  pcem_bridge_config_rename(const char *old_name, const char *new_name);
int  pcem_bridge_config_copy(const char *old_name, const char *new_name);
int  pcem_bridge_config_delete(const char *name);
/* Re-list the configs/ dir after file ops (updates count/name accessors). */
void pcem_bridge_config_rescan(void);

/* ---- Drives & sound (mirror the wx context-menu handlers) -----------------
   All of these are safe to call from the UI thread while emulation runs
   (the wx menu handlers do exactly the same). */
void        pcem_bridge_mount_floppy(int drive, const char *path); /* 0=A: 1=B: */
void        pcem_bridge_eject_floppy(int drive);
const char *pcem_bridge_floppy_path(int drive); /* "" when empty */
void        pcem_bridge_mount_cd_image(const char *path);
void        pcem_bridge_eject_cd(void);
int         pcem_bridge_cd_is_empty(void);
void        pcem_bridge_zip_load(const char *path);
void        pcem_bridge_zip_eject(void);
void        pcem_bridge_cassette_load(const char *path);
void        pcem_bridge_cassette_eject(void);
int         pcem_bridge_get_bpb_disable(void);
void        pcem_bridge_set_bpb_disable(int disabled);
int         pcem_bridge_get_sound_buf_len(void);
void        pcem_bridge_set_sound_buf_len(int ms);   /* 50/100/200/400 */
int         pcem_bridge_get_sound_gain(void);
void        pcem_bridge_set_sound_gain(int db);      /* 0..18 in steps of 2 */

/* ---- Input (call from the UI thread) -------------------------------------
   pc_scancode: PC set-1 scancode, bit 7 = E0-extended (use keymap.c). */
void pcem_bridge_key_event(int pc_scancode, int down);
void pcem_bridge_mouse_move(int dx, int dy, int dz);
void pcem_bridge_mouse_button(int button, int down); /* 0=left 1=right 2=middle */
void pcem_bridge_mouse_capture(int captured);

/* ---- Framebuffer ---------------------------------------------------------
   The core's video thread writes into a staging buffer (32-bit BGRX).
   Call pcem_bridge_copy_frame from a ~60 Hz timer; it returns 1 and fills
   dst (contiguous, w*h*4 bytes) + w/h when a new frame is ready, else 0.
   dst must be at least pcem_bridge_frame_max_bytes() — 2048*2048*4. */
int pcem_bridge_frame_max_bytes(void);
int pcem_bridge_copy_frame(uint8_t *dst, int *w, int *h);

#ifdef __cplusplus
}
#endif

#endif
