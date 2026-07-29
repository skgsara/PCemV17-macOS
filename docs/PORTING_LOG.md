# PCem macOS Porting Log

Newest entries at the bottom. Each entry: date, what changed, what broke, next step.
Future agents: append an entry before ending every session, and update `AGENTS.md`.

---

## 2026-07-26 — Session 2: repo memory + Xcode project (M0–M2)

**Before this session**: the repo was a single squashed commit `5bb3bb4`
("PCem v17 patched for Apple Silicon macOS") by a previous agent. It made the Linux
autotools build work on macOS 26 Tahoe / Apple Silicon:

- `configure.ac`: recognize Apple Silicon arm host CPU as arm64
- `src/Makefile.am`: SDL2 include path via sdl2-config, off64_t fallbacks
- `codegen_allocator.c`: MAP_JIT + `pthread_jit_write_protect_np` for the dynarec
- `386_dynarec.c`: toggle JIT memory permissions around block execution
- `wx-sdl2-display.c`: marshal window title updates to the main thread
- `wx-thread.c`: add missing `sys/time.h` include

**Owner's decision this session**: long-term goal is replacing the wxWidgets UI with a
native Swift/AppKit UI (multi-month learning project). Established the M0–M5 roadmap
(see AGENTS.md). Owner's main concern was session continuity — solved with AGENTS.md +
this log + per-milestone commits.

**Done**:
- M0: wrote `AGENTS.md` (architecture map, roadmap, session rules) and this log.
- M1+M2: `project.yml` (XcodeGen, `brew install xcodegen`) → `PCem.xcodeproj` with TWO
  targets: `PCemCore` (static lib, all non-wx sources + `wx-thread.c`) and `PCem`
  (wx app, links PCemCore). Entitlements `macos/PCem.entitlements` with
  `com.apple.security.cs.allow-jit` (required for the MAP_JIT dynarec).
  `.gitignore` now excludes the generated `PCem.xcodeproj/` and `macos/Info.plist`.

**What broke along the way** (all fixed, in order):
1. `xcodebuild` itself failed to load a plugin → fixed with `xcodebuild -runFirstLaunch`.
2. `wx-thread.c`: `thread_create` collided with mach's `thread_create` because Xcode
   enables Clang modules → `CLANG_ENABLE_MODULES: NO`.
3. 54 duplicate symbols (`void *menu;` etc. defined in multiple .c files) → the
   autotools build passes `-fcommon`; Xcode equivalent is `GCC_NO_COMMON_BLOCKS: NO`.
4. XcodeGen `framework:` deps resolved to local paths → SDK frameworks must use `sdk:`.
5. Crash at startup (`fputs` on NULL FILE*): SDL_GetBasePath() returns
   `Contents/Resources/` for bundled apps (exe dir for plain binaries), and Xcode
   doesn't create Resources/ for apps without resources, so `pcem.log` fopen failed.
   Fix: post-build script mkdir -p Resources + symlinks roms/nvr/configs/screenshots/
   pcem.cfg there.
6. EXC_BREAKPOINT `__chk_fail_overlap` in `disc_load` (disc.c:92): `resetpchard` calls
   `disc_load(0, discfns[0])` → `strcpy(discfns[0], discfns[0])` — overlapping strcpy
   is UB and macOS fortified libc traps it. Fixed with an `if (fn != discfns[drive])`
   guard (same fix pattern `cdrom-image.cc` already had for OSX). cassette.c:101 has a
   similar strcpy but is only called from the UI with dialog paths — left alone.

**Verification**: Debug build launches, stays running, prints same messages as the
autotools binary; user confirmed the machine manager appears and MS-DOS 5 boots. Release
build compiles. Autotools build untouched and still works.

**Next (M3)**: Swift shell target + renderer consuming `buffer32` — see
"How to attack M3" in AGENTS.md.

---

## 2026-07-27 — Session 3: native Swift shell (M3)

**Before this session**: M0–M2 done; wx UI running in `PCem.app` from Xcode.
M3 = replace display + input with a native Swift/AppKit shell.

**Owner's decision**: renderer = CALayer + CGImage (simpler than Metal; the pixel
layout is already CGImage-native). Plan first, then implementation.

**Done** — new target `PCemMac`, no SDL2/wx, links `PCemCore`:
- `src/mac/pcem_bridge.{h,m}`: implements the whole core→UI link contract
  (`create_bitmap`/`destroy_bitmap`/`hline`, `startblit`/`endblit`, `timer_read`/
  `timer_freq` via `clock_gettime_nsec_np`, keyboard/mouse polls, `updatewindowsize`,
  `set_window_title`, `warning`, `stop_emulation_now`, `get_pcem_path`, `dir_exists`,
  joystick/MIDI stubs), assigns `video_blit_memtoscreen_func` → staging buffer,
  runs the emulation thread (port of `mainthread()`), lifecycle = `pc_main` +
  `wx_start` + `start_emulation` collapsed into one pass, config list/switch,
  frame copy API, main-queue callbacks for Swift.
- `src/mac/pcem_mac_platform.{h,m}`: the only framework file (NSBundle path,
  config dir scan, NSLog, `dispatch_async_f`).
- `src/mac/keymap.{c,h}`: macOS keyCode → PC scancode table (from the SDL table).
- `src/mac/PCemMacApp.swift` + `EmulatorView.swift`: window, menus (Machine picker,
  Reset/Hard Reset/Ctrl+Alt+Del/Pause), 60 Hz Timer → CGImage → `layer.contents`,
  keyboard (`flagsChanged` handles modifiers), mouse capture (click to grab,
  middle-click / Ctrl+End / focus loss to release).
- `project.yml`: `mac/**` excluded from `PCemCore`, new `PCemMac` target + scheme,
  generated `macos/PCemMac-Info.plist` (added to `.gitignore`). Same Resources
  symlink script, same entitlements (JIT). `OTHER_LDFLAGS: -lc++` needed because
  PCemCore contains C++ (`cdrom-image.cc`) and this target has no .cc files.
- Autotools untouched; `src/mac/` deliberately not in `src/Makefile.am`.

**What broke along the way** (all fixed, in order):
1. Foundation in the bridge: mach/task.h declares `thread_create` (collides with
   PCem's `thread.h`) and unistd.h declares `pause()` (collides with `int pause`).
   Also mach/dispatch headers typedef `thread_t`. Fix: `pcem_bridge.m` is libc-only;
   ALL framework calls moved to `pcem_mac_platform.m`. This is now a documented
   rule in AGENTS.md.
2. `video_blit_complete()` has no header declaration — declared locally in the bridge.
3. Swift: `Int32` vs `Int` on `pcem_bridge_frame_max_bytes()`; keymap.h not visible
   to Swift → included from `pcem_bridge.h` (the bridging header).
4. Link: missing C++ runtime → `-lc++` (see above).

**Verification**: `PCemMac` and `PCem` (wx) schemes both build; autotools `make`
still links. Smoke run: paths resolve to bundle Resources, config loads, romset
scan completes, BIOS writes chipset registers, `onesec` fires, and the first frame
(656×208 VGA text mode) reached the view (verified with a temporary NSLog, since
removed). NOT yet verified: visual boot, keyboard, mouse — owner to confirm by
running scheme `PCemMac`. (Screenshot verification wasn't possible: the terminal
has no Screen Recording permission.)

**Known leftovers**: no screenshots/shaders/joystick/MIDI; stuck keys possible if
focus is lost mid-keypress (mouse capture IS released on focus loss).

**Next (M4)**: SwiftUI config UI — machine manager first, then settings; see
"How to attack M4" in AGENTS.md.

---

## 2026-07-27 (later) — Session 3b: auto-boot + window scale

**Owner feedback**: (1) PCemMac booted a default machine; she had to pick
ms-dos-5 from the Machine menu every time. (2) The 2× window felt too big.

**Root cause of (1)**: upstream PCem never stores the last machine —
`config_file_default` starts empty and is only set by `--config` or the wx
machine-manager dialog (`wx-config_sel.c:84`). The wx app hides this by always
showing the dialog; the new shell just booted built-in defaults.

**Fixes**:
- Bridge remembers the last-used machine in NSUserDefaults (`lastMachine`, via
  new `pcem_mac_defaults_*` helpers in `pcem_mac_platform.m`). On start with no
  machine loaded it boots the remembered one, else the first config in the list.
  Choosing a machine from the Machine menu updates it.
- Window scale is now 1× by default (matches the wx app) with a **View →
  Window Size 1×/2×/3×** menu (`windowScale` in `PCemMacApp.swift`).

**Verification**: screenshot (Screen Recording permission granted) shows MS-DOS 5
booting straight into DOSSHELL at 1× size, at 100% speed. Keyboard/mouse still
to be confirmed by owner.

**Next (M4)**: SwiftUI config UI — see "How to attack M4" in AGENTS.md.

---

## 2026-07-27 (evening) — Session 3c: full menu bar + MacBook mouse release

**Owner requests**: (1) MacBook has no middle-click or End key — need an easier
mouse-release shortcut. (2) The wx right-click context menu (System/Disc/CD-ROM/
Cassette/Video/Sound/Misc per `src/pc.xrc`) should exist in the menu bar.

**Done**:
- Release shortcut: **Ctrl+Option+M** (also still middle-click and Ctrl+End for
  external keyboards), plus a View → Release Mouse menu item with the shortcut.
- Full menu bar mirroring the wx context menu, all wired through new bridge
  functions (`pcem_bridge_mount/eject_floppy`, `_mount_cd_image`, `_eject_cd`,
  `_zip_load/eject`, `_cassette_load/eject`, `_get/set_bpb_disable`,
  `_get/set_sound_buf_len`, `_get/set_sound_gain`), each mirroring the exact
  wx handler in `wx-sdl2.c` (disc_close+disc_load, atapi->exit+atapi_close+
  image_open, etc.):
  - **System**: Reset / Hard Reset / Ctrl+Alt+Del / Pause / Shut Down Machine
  - **Disc**: Change A:/B:…, Eject A:/B:, Disable BPB checking, Load/Eject ZIP
  - **CD-ROM**: Load image… / Empty
  - **Cassette**: Load tapefile… / Eject tape
  - **Sound**: Buffer length 50–400 ms, Output level Normal–+18 dB (radios)
  - **View**: 1×/2×/3× + Release Mouse (native replacement for the wx Video menu)
  - Eject items auto-enable only when something is mounted; radios/checkmarks
  sync via `validateMenuItem`.
- Gotcha fixed en route: `atapi_close()` is UI glue (defined in `wx-sdl2.c:783`,
  dispatches to `image_close()`/`ioctl_close()`), not core — ported into the bridge.

**Deliberately deferred** (wx dialogs or renderer-specific, see AGENTS.md M4/M5):
Create blank disc image…, host CD drive selection (no optical drives on modern
Macs), Video menu renderer options (VSync/shaders/stretch — N/A for the CALayer
renderer), Screenshot, Machine status window.

**Verification**: builds; screenshot shows all menus in the menu bar and the
machine booting at 100%. Menu actions themselves to be exercised by owner.

**Next (M4)**: SwiftUI config UI — see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 — Smoke-test `PCemMac`

**Done**: built the `PCemMac` scheme with `xcodebuild -scheme PCemMac -configuration Debug build`
(clean success; one alignment warning from the linker, harmless). Launched the binary for 15 s
and confirmed from `pcem.log` that the remembered machine (`ms-dos-5`) initializes, video starts,
`onesec` fires, and the floppy boot begins (disk seeks on drive 0). Then launched the app bundle
with `open` for interactive testing.

**What to check**: window appears at 1× scale, MS-DOS 5 finishes booting, keyboard typing works,
mouse capture/releases with **Ctrl+Option+M** (or middle-click / Ctrl+End), menu items respond.

**Next (M4)**: SwiftUI config UI — see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 (later) — Session 4: mouse hover fix (Windows 3.1)

**Owner report**: PCemMac boots MS-DOS 5 fine and capture/release works, but in
Windows 3.1 the guest cursor only moved *while pressing a finger on the
touchpad* — never on plain finger movement. A/B test (agent launched both apps,
owner drove the mouse): the wx build's mouse worked perfectly, so the bug was
in the native shell, not the shared core.

**Root cause**: AppKit only delivers `mouseMoved` events to a view that opts in
— via an `NSTrackingArea` (or `window.acceptsMouseMovedEvents = true`).
`EmulatorView` had neither, so only *drag* events ever arrived; a finger press
counts as left-button-down, turning movement into `mouseDragged`, which the
view DID receive. (The earlier "DOS works" report was keyboard-only — hover
mouse had in fact never worked.)

**Fix**: `src/mac/EmulatorView.swift` — added `updateTrackingAreas()` that
installs an `NSTrackingArea` with `.mouseMoved + .activeAlways + .inVisibleRect`.

**Verification**: owner confirmed the cursor follows the finger (no press) in
both DOS and Windows 3.1.

**Next (M4)**: SwiftUI config UI — see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 (evening) — Session 5: machine manager in SwiftUI (M4 step 1)

**Done** — the wx machine-manager dialog (`wx-config_sel.c`) is replaced in the
`PCemMac` target:
- Bridge (`pcem_bridge.h/.m`): new `pcem_bridge_config_create/rename/copy/delete`
  (plain libc file ops on `configs/*.cfg`; return codes 0 ok / 1 exists /
  2 invalid name / 3 file error), `pcem_bridge_config_rescan`, and
  `pcem_bridge_use_config_named` (boot by name — index-based boot would drift
  after rescans). Rename of the booted machine follows it (`config_name`,
  `config_file_default`); rename/delete keeps the `lastMachine` default
  consistent (new `pcem_mac_defaults_remove` in `pcem_mac_platform.m`).
- SwiftUI: `src/mac/MachineManagerView.swift` — list with "running" marker,
  New / Copy / Rename / Delete / Boot / Done, double-click boots, `.alert` with
  TextField for name entry, confirmation on delete, "already exists" error
  (same wording as wx).
- `PCemMacApp.swift`: Machine menu gains "Manage Machines…" (added in
  `rebuildMachineMenu`), presented as a sheet via `NSHostingController`;
  boot dismisses, releases the mouse and calls `use_config_named`; the menu is
  rebuilt on dismiss.

**Design note**: wx "New" opened the settings dialog before saving. Our
settings dialog doesn't exist yet (M4 step 2), so **New** saves the *current*
machine's settings under the new name (comment in `pcem_bridge_config_create`,
hint text in the sheet). Revisit when step 2 lands.

**Verification**: `xcodegen` regen + `xcodebuild` PCemMac and PCem (wx) schemes
both clean; autotools `make` untouched and still links. 15 s smoke run: app
boots the remembered machine (floppy seeks in `pcem.log`). Owner confirmed the
same day: the sheet works (create/copy/rename/delete/boot).

**Next (M4 step 2)**: the settings dialog (`wx-config.c`) in SwiftUI — typed
bridge API per section, see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 (night) — Session 6: settings dialog in SwiftUI (M4 step 2)

**Done** — the wx settings dialog (`wx-config.c`) is replaced in the `PCemMac`
target (except HD slots + device sub-dialogs, deferred):
- Bridge (`pcem_bridge.h/.m`): `pcem_settings_t` (all-int struct; the three
  string settings — hdd controller / lpt device / cd model — travel as
  separate `const char*` params so Swift never wrestles C arrays) +
  `settings_begin` (pause) / `settings_get` / `settings_would_reboot` /
  `settings_apply` / `settings_cancel`. Apply is a 1:1 port of
  `config_dlgsave` (wx-config.c:496-695): dirty-check on the same field list →
  `savenvr()` → write globals → `mem_alloc(); loadbios(); resetpchard();` →
  the always-run tail (`cpu_set`, `cpu_update_waitstates`, `cd_set_speed/
  model`, `saveconfig(NULL)`, `speedchanged`, `gameport_update_joystick_type`).
- List feeders (same file): ports of `recalc_vid/snd/hdd/cd_list` and the
  model/CPU/FPU/mouse/joystick/LPT enumerations, all filtered by the
  SELECTED model and cached per model; the UI re-queries on model change.
- SwiftUI `src/mac/SettingsView.swift`: Form with Machine/Video/Sound/Drives/
  Input sections, presented from Machine → Settings… (edits the running
  machine, like wx's IDM_CONFIG). Model change clamps dependent selections
  (port of `on_model_changed`); Apply shows wx's "This will reset PCem!"
  confirmation only when the dirty set is non-empty.

**Gotchas hit**:
- Owner's screenshot: the sheet rendered EMPTY (just Cancel/Apply). Cause: a
  bare `Form` in a VStack collapses to zero size when the hosting window sizes
  to fit content. Fix: the sheet now uses a `TabView` (Machine/Video/Sound/
  Drives/Input — mirrors the wx dialog's notebook in pc.xrc) with an explicit
  `.frame(width: 520, height: 460)`. Verified via headless screenshot
  (temporary auto-open + `screencapture`; debug line removed afterwards).
- Memory units: `mem_size` is always KB, but model `min_ram`/`max_ram`/
  `ram_granularity` are in DISPLAY units (MB when `MODEL_AT &&
  ram_granularity < 128` — confirmed by pc.c:753). Bridge clamps in display
  units then converts (`clamp_mem_size`), same as wx.
- C `int fdd_type[2]` imports into Swift as a TUPLE — `$s.fdd_type.0` doesn't
  compile; needs an explicit get/set Binding.
- SwiftUI `Toggle("x", binding)` needs `isOn:`; Stepper `step:` for Int32
  needs `Int(...)` (Stride is Int).

**Verification**: PCemMac + PCem (wx) schemes build clean; autotools `make`
untouched; 15 s smoke run boots ms-dos-5. Sheet behavior (change memory/CPU/
video card, Apply → reboot, persistence in the .cfg) to be exercised by the
owner.

**Next (M4 step 3)**: HD slots (7 × `hdc[]`/`ide_fn[]`, geometry, cdrom/zip
channel exclusivity, .img/.vhd creation) + "Configure…" in the machine
manager — see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 (late night) — Session 7: launcher-first + Configure before boot

**Owner feedback**: the original PCem opens its machine manager first and
machines are configured *before* they run; PCemMac auto-booting a machine and
editing settings live felt wrong. She picked **launcher-first** (over keeping
auto-boot or a hybrid).

**Done**:
- `pcem_bridge_start` no longer boots a machine — it only inits the core +
  ROM/gfx availability scan. First boot happens in `pcem_bridge_use_config`
  (which now also owns the one-time `sound_init`).
- App opens the machine manager sheet at launch; Boot (or double-click) starts
  the machine. `lastMachine` now only *preselects* in the manager
  (`pcem_bridge_remembered_config_name`). Guest power-off / Shut Down Machine
  returns to the manager.
- Machine manager gains **Configure…**: edits a config WITHOUT booting it via
  new bridge edit mode `pcem_bridge_settings_begin_edit(name)`
  (loadconfig(cfg) → same Settings sheet → apply saves back to the same file,
  skipping the reboot calls — mirroring wx's `has_been_inited == 0` path).
  Enabled only while no machine is running; Machine → Settings… (live edit of
  the running machine) is disabled while nothing runs (`validateMenuItem`).
- `settings_would_reboot` now returns dirty && running, so edit-mode Apply
  saves without the "This will reset PCem!" alert.
- New bridge: `pcem_bridge_machine_is_running()`.

**Bugs fixed en route**: `#selector(openSettings)` went ambiguous after
overloading — renamed the private one to `presentSettings`. Machine-manager
button row truncated with 7 buttons → widened the sheet to 560 pt. "New
machines…" caption reworded (no machine is running at launcher time).

**Verification**: PCemMac builds; headless screenshots confirm the manager
opens at launch with ms-dos-5 preselected and all buttons visible, and nothing
boots until Boot is pressed. Interactive flow (Configure before boot, live
Settings…, shutdown → back to manager) to be exercised by the owner.

**Next (M4 step 3)**: HD slots — unchanged, see "How to attack M4" in AGENTS.md.

---

## 2026-07-28 (late night) — Session 8: HD slots in SwiftUI (M4 step 3)

**Done** — the last missing page of the wx settings dialog is replaced in the
`PCemMac` target; the settings sheet is now feature-complete (device
"Configure…" sub-dialogs stay deferred to M5):
- Bridge (`pcem_bridge.h/.m`): a PENDING HD snapshot per settings session —
  `pending_hdc[7]` / `pending_fn[7]` / pending cdrom+zip channels, taken by
  both `settings_begin` and `settings_begin_edit`. Slot accessors
  (`pcem_bridge_hd_slot_get/set/_path`, `_hd_set_channels`,
  `_hdd_is_mfm`), the 46-entry `hd_types` table, and image I/O:
  `pcem_bridge_hd_image_probe` (port of `hd_file` + `check_hd_type` +
  `adjust_vhd_geometry_for_pcem`, minivhd; reports VHD timestamp mismatch),
  `_hd_vhd_fix_timestamp`, `_hd_image_create` (port of `hdnew_dlgproc`'s OK
  handler: raw/fixed/dynamic/differencing, `adjust_pcem_geometry_for_vhd`
  for >65535-cylinder geometries) + `_hd_create_progress` (wx
  `create_drive_pos`). `settings_dirty` gained `hd_pending_dirty()` (pending
  vs globals = wx's `hd_changed` + channel compares); apply writes the
  pending state into `hdc[]`/`ide_fn[]`/channels inside the reboot block
  (wx-config.c:631-653). Persistence needed nothing new — `saveconfig` in
  pc.c already stores those globals.
- `src/mac/SettingsView.swift`: new "Hard Discs" tab — scrollable list of 7
  slots, segmented type picker (Hard drive/CD-ROM/ZIP, exclusivity ported
  from `hd_combodrivetype`), geometry fields + live MB label, editable path,
  Choose…/New…/Eject. Type pickers disabled for MFM controllers (wx
  `hdconf_update`); CD-ROM/ZIP slots show a caption (media mounts live in
  the menu bar). Local state syncs to the bridge pending snapshot in
  `applyTapped()` before `would_reboot`, so HD-only changes also trigger
  the "This will reset PCem!" prompt.
- `src/mac/HardDiscSheets.swift` (new): `NewHardDiscSheet` (port of HdNewDlg —
  NSSavePanel, format/block-size pickers, type table, geometry↔size↔type
  cross-updates, wx validation messages, background create with polled
  ProgressView, "remember to partition and format" / differencing-parent
  warnings) and `ConfirmGeometrySheet` (port of HdSizeDlg after probing an
  existing image). Timestamp-mismatch alert offers Fix, like wx.

**Verification**: `xcodegen` regen; PCemMac + PCem (wx) schemes build clean;
autotools `make` untouched. Headless screenshot (temporary auto-open +
tab reorder, both reverted) confirms the tab renders and loads ms-dos-5's
real slot (17/15/1224, 152 MB, image path). 15 s smoke run: no crash at
the launcher. Interactive flow (create an image, Apply → reboot, values in
the .cfg, FDISK sees the drive) to be exercised by the owner.

**Next**: M4 is done except device "Configure…" sub-dialogs
(`wx-deviceconfig.cc`, some with custom UIs) — deferred to M5 (remove wx).

**Owner testing (same night) — two bugs found, both fixed**:
1. New-image sheet: picking a drive Type snapped back to "Custom" and zeroed
   the geometry. Cause: stored `sizeMB`/`typeIndex` + `onChange` both ways
   made a feedback loop (geometry → size → re-rounded geometry → …) that
   decayed to 0; wx avoids it because programmatic SETTEXT doesn't re-fire
   its edit handlers. Fix: size and type are now COMPUTED Bindings over the
   geometry (no stored copies) in both sheets (`HardDiscSheets.swift`).
2. Boot after System → Shut Down Machine did nothing (window stuck at
   "PCem (stopped)"). Cause: `pcem_bridge_stop()` cleared `started`, and
   `pcem_bridge_use_config()` refuses to run when `!started`. `started`
   means "initpc() ran", not "thread is up" — stop no longer clears it.
   (Pre-existing from session 7's launcher-first change; the shutdown path
   had never been exercised.)
Verified by owner: FDISK sees the created 32 MB image as Disk 3;
shutdown → Machines window → Boot works. `configs/ms-dos-5.cfg` gained a
second HD from the test (63/16/65, `hdd_fn=…/harddisktest.img`) — left
uncommitted, it's a local machine config.

**Not a bug (confirmed by owner against the wx build)**: ms-dos-5 shows a
"Foreign Hard Disk" (127.5 MiB) in the XTIDE boot menu and a phantom 128 MB
disk in FDISK. It's the SAME 152 MB image seen twice — AMIBIOS via the CMOS
setting (Hard Disk C: Type 46, CHS-clamped to 1024 cylinders) and the
xtide_at controller via LBA (full 152.4 MiB). Guest-side config quirk, not
a port bug. Fix if desired: AMIBIOS setup → Hard Disk C: = Not installed.

---

## 2026-07-28 (night) — Session 9: device "Configure…" dialogs in SwiftUI (M5 slice 1)

**Done** — the generic wx device-config dialog (`wx-deviceconfig.cc`) is replaced in
the `PCemMac` target; this was the last deferred M4 leftover and the final
user-visible settings feature that still needed the wx build (joystick axis/button
mapping aside — separate custom dialog, still M5):
- Bridge (`pcem_bridge.h/.m`, +233 lines): `pcem_devcfg_item_t` +
  `pcem_bridge_devcfg_has_config/_begin/_count/_item/_option/_set/_apply`.
  Device resolution ports the five wx invocation points (`wx-config.c:1220-1290`)
  driven by the settings sheet's PENDING selection: machine → `model_getdevice`,
  video → `video_card_getdevice(video_old_to_new(gfx),
  model_getromset_from_model(model))` (romset matters for built-in-video machines),
  sound → `sound_card_getdevice`, voodoo → `&voodoo_device`, HDD →
  `hdd_controller_get_device`. Empty config arrays (`pgc_config`) count as
  no-config; `CONFIG_MIDI` items are filtered out (wx hides them when
  `midi_get_num_devs()==0`; the stub always returns 0 — un-filter when CoreMIDI
  lands). Apply ports the wx OK handler 1:1: dirty-check vs `config_get_int` →
  `config_set_int` → if a machine is running, `saveconfig(NULL)` + pause +
  `resetpchard()` IMMEDIATELY, independent of the parent settings sheet's Cancel.
  In edit mode (manager Configure…, nothing running) the writes ride the parent
  apply's `saveconfig()` — wx's `has_been_inited == 0` path.
- `src/mac/DeviceConfigView.swift` (new): fully generic — Toggle per CONFIG_BINARY,
  Picker per CONFIG_SELECTION (values that match no option get a "Custom (0x…)"
  placeholder; upstream has such quirks, e.g. `s3_bahamas64` default 4). wx's
  "This will reset PCem!" confirmation shows BEFORE any write when dirty + running.
- `src/mac/SettingsView.swift`: five "Configure…" buttons (Machine tab after the
  Machine picker; Video tab next to the Device picker and the Voodoo toggle;
  Sound tab next to the Device picker; Drives tab next to the HD Controller
  picker), disabled via `devcfg_has_config` on the pending selection, presented
  as a nested `.sheet`. Voodoo button gated on `model_has_pci` like wx's
  `IDC_CONFIGUREVOODOO`.

**Bugs fixed en route**:
1. The device sheet rendered EMPTY (title + buttons only) — the same collapsed-Form
   gotcha as the settings sheet (Session 6): a bare `Form` in a VStack sizes to
   zero. Fix: explicit `.frame(width: 420, height: 120 + count*44)`.
2. NOT a bug: the Voodoo sheet shows 7 items, not 8 — `recompiler` is behind
   `#ifndef NO_CODEGEN` and `vid_voodoo_render.h:2` defines `NO_CODEGEN`
   unconditionally in this tree.

**Verification**: headless screenshot (temporary auto-open in
`applicationDidFinishLaunching`, removed after) shows the Voodoo config fully
rendered with correct defaults over ms-dos-5's loaded config. `xcodegen` regen;
PCemMac + PCem (wx) schemes both build clean; autotools untouched; 12 s smoke run
alive at the launcher. Interactive flow (change e.g. a Sound Blaster IRQ, Apply →
reset prompt → reboot, value persisted under `[Sound Blaster …]` in the .cfg) to
be exercised by the owner.

**Next (M5)**: joystick axis/button mapping (`wx-joystickconfig.cc`) — the last
wx-only UI; then removing the wx `PCem` target, CoreMIDI, optional CoreAudio,
icon/signing. See "How to attack the rest of M5" in AGENTS.md.

---

## 2026-07-28 (night) — Session 10: wx target removed from Xcode (M5 slice 2)

**Owner decision**: she has no game controller, so the joystick slice
(mapping dialog + GameController host support) is DEFERRED until she has
hardware — and with that the last reason to keep the wx target in Xcode is
gone. Remove wx now; joystick comes back later as a native port.

**Done**:
- `project.yml`: deleted the entire `PCem` (wx) app target and its scheme.
  The Xcode project now has exactly two targets (`PCemCore`, `PCemMac`) and
  one scheme (`PCemMac`). Also stripped the wx/SDL-derived defines
  (`wxDEBUG_LEVEL`, `WXUSINGDLL`, `__WXMAC__`, `__WXOSX__`,
  `__WXOSX_COCOA__`, `_THREAD_SAFE`) and the SDL2/wx header search paths
  from the SHARED settings block — verified first that no PCemCore source
  references them (the only "SDL" hits in core are commented-out includes
  and excluded slirp). `_FILE_OFFSET_BITS=64` and `/opt/homebrew` paths
  stay.
- The wx sources (`src/wx-*`) stay in the tree, and **autotools is
  untouched**: `./configure && make` still produces the wx `pcem` binary,
  which remains the fallback for joystick mapping until the native port.

**Verification**: `xcodegen` regen; `xcodebuild -list` shows only PCemCore +
PCemMac (it prints the PCemMac scheme twice — cosmetic xcodebuild quirk,
only one .xcscheme exists on disk); clean build succeeds; autotools `make`
"Nothing to be done" (unaffected); 12 s smoke run alive at the launcher.

**Next (M5)**: CoreMIDI or app icon/signing — owner's pick. Joystick port
when hardware exists (full how-to in AGENTS.md "How to attack the rest of
M5", incl. the POV_X/POV_Y encoding and the `wx-sdl2-joystick.c` poll loop
to copy).

---

## 2026-07-29 — Session 11: CoreMIDI backend (M5 slice 3)

**Owner decision**: do CoreMIDI + CoreAudio now; app icon/signing LAST.

**Done** — the MIDI stub is replaced by a real CoreMIDI backend, and the
"MIDI out device" picker now appears in the SB16/AWE32/Aztech Configure
sheets:
- `src/mac/pcem_mac_midi.m/.h` (new): the ONLY file with CoreMIDI includes
  (no PCem headers — same rule as `pcem_mac_platform.m`). Plain-C wrapper:
  lazy `MIDIClientCreate`, index 0 = "PCem Virtual Output" (`MIDISourceCreate`
  — a virtual source any Mac synth app can listen to, works out of the box),
  indices 1..N = real CoreMIDI destinations (`MIDIGetDestination` +
  `MIDIOutputPortCreate`). Send builds a `MIDIPacketList` (timestamp 0,
  ≤256-byte packets) → `MIDIReceived` (virtual) / `MIDISend` (destination),
  and no-ops when nothing is open (the guard the alsa backend lacks).
- `pcem_bridge.m`: the five `plat-midi.h` functions replace the stub.
  `midi_init` reads config key `midi` from the NULL section (wx precedent —
  NOT the device-name section) and falls back to index 0 when the configured
  device vanished (like win-midi); hooked into `boot_machine` /
  `emu_thread_stop` (mirrors `wx-sdl2.c:673/725`). `midi_write` is the
  win/alsa byte-stream reassembler with TWO deliberate fixes:
  1. no-op when no device is open (alsa segfaults),
  2. running status handled correctly — upstream (both win-midi.c and
     midi_alsa.c) has a LATENT UNBOUNDED OVERFLOW: after a complete message,
     running-status data bytes keep writing past `midi_command[4]` because
     `midi_pos` is never reset. Fix: when `midi_pos >= midi_len`, restart at
     index 1 (the stored status byte stays at index 0).
- Devcfg bridge: CONFIG_MIDI items un-filtered (`devcfg_begin` includes them
  when `midi_get_num_devs() > 0`, reads/writes the NULL section); options
  synthesized from the backend's device list in `devcfg_item`/`devcfg_option`
  — so `DeviceConfigView.swift` renders the picker with ZERO Swift changes.
  Switching the device while running now applies immediately
  (`midi_close`+`midi_init` after the reset; wx made you reboot).
- `project.yml`: `CoreMIDI.framework` added to `PCemMac`. Autotools
  untouched (wx binary keeps its alsa/stub MIDI).

**Verification**: standalone wrapper test (coder): enumeration = 1 device
("PCem Virtual Output"), open/reopen/bad-index/send/sysex all sane. Headless
screenshot (temporary auto-open, removed after): SB16 Configure sheet shows
"MIDI out device: PCem Virtual Output". 15 s boot smoke run of ms-dos-5
(exercises `midi_init` → virtual source creation): alive, no log errors.
NOT verified: actual MIDI music into a synth app — needs e.g. Munt
installed; owner can try later (pick the device in Settings → Sound →
SB16 Configure…, play a game with GM music).

**Next (M5)**: CoreAudio (replace OpenAL; sound backend contract in
AGENTS.md "Coupling hazards"). Then app icon/signing as the finale.

---

## 2026-07-29 — Session 12: CoreAudio sound backend (M5 slice 4)

**Done** — the deprecated OpenAL backend is replaced by CoreAudio in the
native shell; OpenAL is gone from the Xcode build entirely:
- `src/mac/pcem_mac_sound.m` (new): the only file with AudioToolbox
  includes, no PCem headers (same rule as the MIDI wrapper). Implements
  the full `sound.h` backend contract — `initalmain`/`inital`/
  `givealbuffer(int32_t*)`/`givealbuffer_cd(int16_t*)` + the global
  `SOUNDBUFLEN` (core rewrites it live from the Sound menu);
  `closeal` internal via `atexit`, like soundopenal.c.
- Design: TWO output AudioUnits (default output), one per stream at its
  NATIVE rate — 48 kHz main, 44.1 kHz CD, stereo int16 — so macOS mixes
  and no resampler exists (mirrors OpenAL's two sources at two rates).
  Each stream has a lock-free SPSC ring (65536 frames ≈ 1.4 s, C11
  stdatomic head/tail, power-of-two mask): producer = emu thread (main)
  / CD thread (CD), consumer = the render callback on CoreAudio's
  realtime thread. Semantics match soundopenal.c 1:1: NEVER block,
  drop the block when full, silence on underrun with automatic recovery,
  `sound_gain` (dB → pow(10, dB/20)) read live and applied per sample
  with clipping (bit-exact passthrough at 0 dB).
- `project.yml`: `soundopenal.c` excluded from PCemCore,
  `OpenAL.framework` removed from PCemMac (AudioToolbox provides the
  AudioUnit API). Autotools untouched — the wx binary keeps OpenAL.

**Verification**: ring logic standalone test (coder: fill/drop/wrap/
clip/empty-read all pass); `otool -L` on the debug dylib: AudioToolbox +
CoreMIDI linked, OpenAL absent; OpenAL deprecation warnings gone from
the build log. End-to-end pipeline check with TEMPORARY frame counters
(removed after): 19 s of ms-dos-5 boot, pushed ≈ pulled at 48000
frames/s with a stable ~2000-frame (≈40 ms) lag — no underruns, no
drift. 12 s launcher smoke run alive. NOT verified: actual audible
sound — owner listening test (Windows 3.1 startup sound or a DOS game;
also try Sound menu buffer length 50–400 ms and gain changes live).

**Next (M5 finale)**: app icon + signing/notarization. Joystick +
GameController whenever a controller is available.

---

## 2026-07-29 — Session 12b: quit-crash fix (pre-existing, NOT audio-related)

**Owner's audio test**: BIOS beep ✅, Windows 3.1 startup/exit sounds ✅
(CoreAudio backend works). Playing a MIDI file in Windows 3.1: crackling,
then "Windows crashed" — actually the **PCemMac app itself** was gone.

**Diagnosis**: crash report `PCemMac-2026-07-29-090345.ips` shows the crash
was in the QUIT path, not MIDI/audio: `windowWillClose` → `terminate` →
`pcem_bridge_quit` → `closepc` → `dumpregs` → `readmembl` → SIGSEGV at
0xB8000. And three crash reports from 2026-07-28 have the IDENTICAL stack —
this bug existed since the native shell was born; every quit after a session
(especially with Windows 3.1's paging enabled) died in upstream's debug
memory dump (`closepc` in `src/pc.c` unconditionally calls `dumpregs`,
which walks 16 MB of guest memory via `readmemb` and hits a wild pointer
under paging; it also wrote ~40 MB of ram.dmp/rram.dmp per quit).

**Fix** (minimal core patch, same spirit as the Apple Silicon patches):
`src/pc.c` `closepc()` — skip `dumppic()`/`dumpregs()` under
`#ifndef __APPLE__`, with a comment. Real teardown (codegen/atapi/disc/
video/device close) unchanged. Both build systems rebuilt.

**Verification**: boot ms-dos-5 12 s → graceful quit via AppleScript →
clean exit, NO new crash report. (Before the fix this path produced the
4 reports above.)

**Still open**: the MIDI-playback crackling itself. Likely the emulated
machine dropping below 100% speed under Windows 3.1 + OPL FM load (the
window title shows the %) — owner to retest and report the speed reading;
if it stays at 100% and still crackles, the backend needs another look.
