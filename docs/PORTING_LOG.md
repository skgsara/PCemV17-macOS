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
