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
/* The per-user data dir (~/.pcem/, trailing slash) — for "Open Data Folder". */
void pcem_bridge_get_data_path(char *s, int size);
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
/* 1 while a machine is booted, 0 in the launcher state (nothing running). */
int         pcem_bridge_machine_is_running(void);
/* The NSUserDefaults "lastMachine" value ("" when unset): used to preselect
   in the machine manager, NOT to auto-boot (launcher-first, like wx). */
const char *pcem_bridge_remembered_config_name(void);

/* ---- Machine manager (M4): file ops on configs/*.cfg ---------------------
   All return 0 = ok, 1 = name already exists, 2 = invalid name,
   3 = file error. Names are without the .cfg extension. */
int  pcem_bridge_config_create(const char *name); /* save current settings as name.cfg */
int  pcem_bridge_config_rename(const char *old_name, const char *new_name);
int  pcem_bridge_config_copy(const char *old_name, const char *new_name);
int  pcem_bridge_config_delete(const char *name);
/* Re-list the configs/ dir after file ops (updates count/name accessors). */
void pcem_bridge_config_rescan(void);

/* ---- Machine settings (M4 step 2) -----------------------------------------
   Snapshot/apply API mirroring the wx settings dialog (wx-config.c): the UI
   calls _begin (pauses emulation), reads current values with _get, edits
   locally, then _apply (dirty-check -> reboot -> save, same sequence as
   config_dlgsave) or _cancel. String settings (hdd controller / lpt device /
   cd model) travel as separate const char* params so the struct stays
   all-int and Swift-friendly. The list feeders below reproduce the wx
   dialog's recalc_*_list filters for the SELECTED model, so the UI
   re-queries them whenever the model selection changes. */
typedef struct
{
        int model;                  /* core index into models[] */
        int cpu_manufacturer, cpu;  /* indices within the model */
        int fpu_index;              /* index into the CPU's FPU list */
        int cpu_use_dynarec;
        int cpu_waitstates;         /* 0..8, 0 = system default */
        int mem_size;               /* KB (convert for display via model_uses_mb) */
        int enable_sync;
        int gfxcard;                /* old-style numbering; GFX_BUILTIN = -1 */
        int video_speed;            /* -1..5 (-1 = default) */
        int voodoo;
        int sound_card;             /* index into sound_cards[] */
        int gameblaster, gus, ssi2001;
        int fdd_type[2];            /* 0..7 (None .. 3.5" 2.88M) */
        int cd_speed;               /* 1..72 */
        int mouse_type;
        int joystick_type;
} pcem_settings_t;

void pcem_bridge_settings_begin(void);
/* Edit mode: load config_name's settings WITHOUT booting it (the wx machine
   manager's Configure flow: loadconfig(cfg); config_open; saveconfig(cfg)).
   Only valid while no machine is running. Returns 1 on success. */
int  pcem_bridge_settings_begin_edit(const char *config_name);
void pcem_bridge_settings_get(pcem_settings_t *s);
const char *pcem_bridge_settings_hdd_controller(void); /* internal name */
const char *pcem_bridge_settings_lpt1_device(void);    /* internal name */
const char *pcem_bridge_settings_cd_model(void);       /* display string */
int  pcem_bridge_settings_would_reboot(const pcem_settings_t *s,
        const char *hdd_controller, const char *lpt1_device);
void pcem_bridge_settings_apply(const pcem_settings_t *s,
        const char *hdd_controller, const char *lpt1_device,
        const char *cd_model);
void pcem_bridge_settings_cancel(void);

/* Models (only those with ROMs present). */
int         pcem_bridge_settings_model_count(void);
const char *pcem_bridge_settings_model_name(int list_index);
int         pcem_bridge_settings_model_index(int list_index); /* core index */
/* Per-core-model info. */
int pcem_bridge_model_min_ram(int model);
int pcem_bridge_model_max_ram(int model);
int pcem_bridge_model_ram_granularity(int model);
int pcem_bridge_model_uses_mb(int model); /* display memory in MB, not KB */
int pcem_bridge_model_has_pci(int model);
int pcem_bridge_model_has_fixed_gfx(int model);
int pcem_bridge_model_has_optional_gfx(int model);

/* CPUs within a model. */
int         pcem_bridge_cpu_manu_count(int model);
const char *pcem_bridge_cpu_manu_name(int model, int manu);
int         pcem_bridge_cpu_count(int model, int manu);
const char *pcem_bridge_cpu_name(int model, int manu, int cpu);
/* bit0 = supports dynarec, bit1 = requires dynarec */
int pcem_bridge_cpu_dynarec_flags(int model, int manu, int cpu);
int pcem_bridge_cpu_waitstates_supported(int model, int manu, int cpu);

/* FPUs for a CPU. */
int         pcem_bridge_fpu_count(int model, int manu, int cpu);
const char *pcem_bridge_fpu_name(int model, int manu, int cpu, int index);

/* Video cards filtered for the model; gfxcard value = old-style or -1. */
int         pcem_bridge_video_count(int model);
const char *pcem_bridge_video_name(int model, int list_index);
int         pcem_bridge_video_gfxcard(int model, int list_index);

/* Sound cards filtered for the model. */
int         pcem_bridge_sound_count(int model);
const char *pcem_bridge_sound_name(int model, int list_index);
int         pcem_bridge_sound_card(int model, int list_index);

/* HDD controllers filtered for the model. */
int         pcem_bridge_hdd_count(int model);
const char *pcem_bridge_hdd_name(int model, int list_index);
const char *pcem_bridge_hdd_internal_name(int model, int list_index);

/* LPT devices (unfiltered). */
int         pcem_bridge_lpt_count(void);
const char *pcem_bridge_lpt_name(int index);
const char *pcem_bridge_lpt_internal_name(int index);

/* Mice filtered for the model. */
int         pcem_bridge_mouse_count(int model);
const char *pcem_bridge_mouse_name(int model, int list_index);
int         pcem_bridge_mouse_type(int model, int list_index);

/* Joysticks (unfiltered; mapping buttons deferred to M5). */
int         pcem_bridge_joystick_count(void);
const char *pcem_bridge_joystick_name(int index);

/* CD models filtered by the selected HDD controller's interface
   (hdd_internal_name = e.g. "ide", "none", "aha1542c"). */
int         pcem_bridge_cd_model_count(const char *hdd_internal_name);
const char *pcem_bridge_cd_model_name(const char *hdd_internal_name, int list_index);
/* Fixed speed for a CD model, or -1 if user-selectable. */
int pcem_bridge_cd_model_fixed_speed(const char *cd_model_name);
/* CD speeds (1..72, 17 entries). */
int pcem_bridge_cd_speed_count(void);
int pcem_bridge_cd_speed_value(int list_index);

/* ---- Hard-disc slots (M4 step 3) ------------------------------------------
   Port of the wx settings dialog's HD page (hdconf_dlgproc & friends in
   wx-config.c). The bridge keeps a PENDING copy of the 7 slots (geometry +
   image path) and the cdrom/zip channels, snapshotted from the globals by
   pcem_bridge_settings_begin/_begin_edit; pcem_bridge_settings_apply
   dirty-checks and writes them back like config_dlgsave, cancel drops them.
   All slot accessors below are only valid inside a settings session. */
#define PCEM_HD_SLOTS 7
#define PCEM_HD_MAX_CYLINDERS 265264 /* wx-config.c:26 (Award 430VX POST limit) */

void        pcem_bridge_hd_slot_get(int slot, int *spt, int *hpc, int *cyl);
const char *pcem_bridge_hd_slot_path(int slot); /* "" when empty */
void        pcem_bridge_hd_slot_set(int slot, int spt, int hpc, int cyl,
                                    const char *path);
int  pcem_bridge_hd_cdrom_channel(void); /* -1 = none */
int  pcem_bridge_hd_zip_channel(void);
void pcem_bridge_hd_set_channels(int cdrom, int zip);

/* 1 when the named HDD controller (internal name) is MFM — the UI then
   disables the per-slot type pickers, like hdconf_update. */
int pcem_bridge_hdd_is_mfm(const char *internal_name);

/* The 46-entry AT BIOS drive-type table (wx hd_types). */
int  pcem_bridge_hd_type_count(void);
void pcem_bridge_hd_type_get(int index, int *cylinders, int *heads);

/* Probe an existing image (port of hd_file + check_hd_type +
   adjust_vhd_geometry_for_pcem). Fills geometry + is_vhd +
   timestamp_mismatch. Returns 0 ok / 1 can't open / 2 VHD error
   (errbuf carries mvhd_strerr). */
int pcem_bridge_hd_image_probe(const char *path, int is_mfm,
        int *spt, int *hpc, int *cyl, int *is_vhd, int *timestamp_mismatch,
        char *errbuf, int errbuf_size);
/* Fix a differencing VHD's parent timestamp (wx's YES branch). 0 = ok. */
int pcem_bridge_hd_vhd_fix_timestamp(const char *path);

/* Create an image (port of the hdnew_dlgproc OK handler; the UI validates
   geometry first). format: 0 raw .img, 1 fixed VHD, 2 dynamic VHD,
   3 differencing VHD (parent_path required). block_large: 1 = 2 MB blocks,
   0 = 512 KB (dynamic/diff only). Returns 0 ok / 1 can't open file /
   2 VHD create failed. For format 3 the out-params return the
   parent-derived geometry; for the others they echo the inputs. */
int pcem_bridge_hd_image_create(const char *path, int spt, int hpc, int cyl,
        int format, int block_large, const char *parent_path,
        int *out_spt, int *out_hpc, int *out_cyl);
/* 0..100 while a create runs (port of create_drive_pos); -1 when idle. */
int pcem_bridge_hd_create_progress(void);

/* ---- Device configuration (M5 slice 1) ------------------------------------
   Port of the generic wx device-config dialog (wx-deviceconfig.cc): a device
   exposes an array of config items (checkboxes / comboboxes) stored per
   config file via config_get_int/config_set_int. All five "Configure…"
   buttons of the wx settings dialog (wx-config.c:1220-1290) resolve their
   device from the dialog's PENDING selection, which is what the callers pass
   here. */
typedef struct
{
        char name[256];         /* config key */
        char description[256];  /* UI label */
        int type;               /* CONFIG_BINARY / CONFIG_SELECTION / CONFIG_MIDI */
        int value;              /* current value */
        int num_options;        /* SELECTION (static list) / MIDI (device count) */
} pcem_devcfg_item_t;

#define PCEM_DEVCFG_MACHINE 0
#define PCEM_DEVCFG_VIDEO   1
#define PCEM_DEVCFG_SOUND   2
#define PCEM_DEVCFG_VOODOO  3
#define PCEM_DEVCFG_HDD     4

/* Resolve the device for `which` from the caller's PENDING selection
   (model index / old-style gfxcard number / sound_cards[] index / hdd
   internal name). Returns 1 if it has a non-empty config (drives button
   enablement), 0 otherwise. */
int pcem_bridge_devcfg_has_config(int which, int primary, int model,
                                  const char *hdd_internal);

/* Begin a device-config session: resolves the device, snapshots item values
   via config_get_int(CFG_MACHINE, ...). Returns the item count (0 = no
   config), -1 = no device. `title_out` (optional) receives device->name.
   CONFIG_MIDI items are included whenever midi_get_num_devs() > 0 (wx hides
   them only when no MIDI out devices exist); their values live in the NULL
   config section, unlike all other item types. */
int pcem_bridge_devcfg_begin(int which, int primary, int model,
                             const char *hdd_internal, char *title_out,
                             int title_sz);

int  pcem_bridge_devcfg_count(void);
int  pcem_bridge_devcfg_item(int idx, pcem_devcfg_item_t *out);      /* 0 ok / -1 range */
int  pcem_bridge_devcfg_option(int idx, int opt, char *desc, int desc_sz); /* returns value, -1 range */
void pcem_bridge_devcfg_set(int idx, int value);                     /* stage a new value */

/* Dirty-check vs config_get_int; if dirty: config_set_int each staged value,
   then — only if a machine is running — saveconfig(NULL) + pause +
   resetpchard() (the wx dialog's has_been_inited path). In edit mode
   (nothing running) just write the in-memory config; the parent settings
   apply's saveconfig() persists it. Returns 1 if values were dirty, 0 if
   unchanged. */
int pcem_bridge_devcfg_apply(void);

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
