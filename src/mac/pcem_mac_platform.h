/* pcem_mac_platform.h — Cocoa/system-framework helpers for pcem_bridge.m.
 *
 * pcem_bridge.m deliberately includes no Apple system headers beyond libc:
 * mach and dispatch headers typedef thread_t (collides with PCem's own
 * thread_t in thread.h) and unistd.h declares pause() (collides with PCem's
 * `int pause`). Framework files like this one (also pcem_mac_midi.m and
 * pcem_mac_sound.m) include no core headers, so there is no collision here.
 */
#ifndef PCEM_MAC_PLATFORM_H
#define PCEM_MAC_PLATFORM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Per-user data directory (~/.pcem/, matching the upstream Linux wx build),
   with trailing slash. roms/ nvr/ configs/ screenshots/ live under it. */
void pcem_mac_data_path(char *s, int size);

/* Create the data dir and its roms/ nvr/ configs/ screenshots/ subdirs if
   they don't exist yet (first run). No-op afterwards. */
void pcem_mac_ensure_data_dirs(void);

/* Lists *.cfg files in dir (names without extension, sorted).
   Returns the count and hands the caller a malloc'd array of strdup'd
   strings via names_out (free each string + the array). */
int pcem_mac_list_configs(const char *dir, char ***names_out);

/* NSLog a message (warnings also go to pcem.log via pclog). */
void pcem_mac_log(const char *msg);

/* Run fn(ctx) asynchronously on the main queue (dispatch_async_f wrapper). */
void pcem_mac_run_on_main(void (*fn)(void *), void *ctx);

/* NSUserDefaults string access (used to remember the last-booted machine). */
void pcem_mac_defaults_set_string(const char *key, const char *value);
/* Returns 1 and fills buf if the key exists, else 0. */
int  pcem_mac_defaults_get_string(const char *key, char *buf, int size);
/* Remove a key (used to keep lastMachine consistent on delete/rename). */
void pcem_mac_defaults_remove(const char *key);

#ifdef __cplusplus
}
#endif

#endif

