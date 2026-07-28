# PCem macOS Port — Agent Guide

This file is the project's memory. Every agent session MUST read it first and update it
(along with `docs/PORTING_LOG.md`) before finishing. It exists because the owner works
across many sessions and each session starts with zero context.

## Owner context

The owner is a programming beginner (some C reading, some Swift Playgrounds) doing this as
a personal learning project. Explain what you change and why. Keep commit messages and
comments educational but concise. Never dumb down the code itself.

She takes medication that can cause brain fog and memory lapses. Practical consequences
for every session:
- Start each session by recapping where things stand in 2–3 sentences.
- Never rely on chat as the only record: decisions, how-tos, and next steps go into
  `AGENTS.md`, `docs/PORTING_LOG.md`, or `docs/START_HERE.md`.
- Keep messages short and structured. One idea at a time. No walls of text.
- If she seems confused about something already covered, point to the file that has it
  — kindly, without commenting on the repetition itself.

## Goal

Turn PCem v17 into a native macOS app on Apple Silicon by **gradually replacing the
wxWidgets UI with Swift/AppKit/SwiftUI while keeping the C emulator core untouched as
much as possible**. This is a multi-month effort done in milestones.

## Roadmap

- **M0 — Repo memory**: this file + `docs/PORTING_LOG.md`. ✅ 2026-07-26
- **M1 — Xcode project**: XcodeGen-based project building the existing wx UI code into
  `PCem.app`. ✅ 2026-07-26
- **M2 — Target split**: `PCemCore` static library + `PCem` app target (wx UI). ✅ 2026-07-26
- **M3 — Swift shell**: new AppKit window with a CALayer/CGImage renderer consuming
  `buffer32` (chose CALayer over Metal — simpler, swappable later); AppKit
  keyboard/mouse input. New target `PCemMac` + sources in `src/mac/`. ✅ 2026-07-27
- **M4 — Config UI in SwiftUI**: replace machine manager (`wx-config_sel.c`) and settings
  (`wx-config.c`) dialogs one at a time. 🔶 IN PROGRESS — machine manager ✅ 2026-07-28,
  settings dialog (minus HD slots) ✅ 2026-07-28, HD slots + device sub-dialogs ⬜ NEXT
- **M5 — Remove wx entirely**: drop SDL/wx dependencies; optionally replace OpenAL with
  CoreAudio; CoreMIDI; app icon/signing/notarization. ⬜

## Current status

M0–M3 done (2026-07-27); M4 step 1 done (2026-07-28). New target `PCemMac`: a native
Swift/AppKit shell with **no SDL2 and no wxWidgets**, linking `PCemCore` via the
bridge in `src/mac/`. Verified by the owner (2026-07-28): MS-DOS 5 boots, keyboard
works, mouse capture/release works, and the guest cursor tracks the touchpad in
both DOS and Windows 3.1 (after the tracking-area fix — see `EmulatorView.swift`
bullet below and the 2026-07-28 entry in `docs/PORTING_LOG.md`).
M4 step 1: the wx machine manager is replaced by a SwiftUI sheet (Machine →
Manage Machines…): list/New/Copy/Rename/Delete/Boot via new
`pcem_bridge_config_*` functions; view in `src/mac/MachineManagerView.swift`.
M4 step 2 (same day): the wx settings dialog is replaced by a SwiftUI sheet
(Machine → Settings…, `src/mac/SettingsView.swift`) covering Machine
(model/CPU/FPU/dynarec/memory/waitstates/sync), Video, Sound, floppy types,
CD model/speed, Mouse and Joystick — everything except the 7 hard-disc slot
panels (M4 step 3) and the per-device "Configure…" sub-dialogs (M5). The
bridge (`pcem_settings_t` + begin/get/apply/cancel + model-filtered list
feeders) ports `config_dlgsave` and the `recalc_*_list` filters 1:1; apply
dirty-checks, reboots and saves exactly like wx. Caveat from step 1 stands:
"New" copies the running machine's settings (wx opened the settings editor
first; wiring that up is step 3).
Per-machine *HD slots* and device sub-dialogs still use the wx build (`PCem`
target, kept as reference until M5). Next session: M4 step 3 — see
"How to attack M4" below.

## How to build

Two independent build systems exist. **Both must keep working.**

1. **Autotools** (original, terminal):
   `./configure && make` — produces the `pcem` binary at repo root.
   Dependencies via Homebrew: `sdl2 wxwidgets openal-soft`.
2. **Xcode** (added in M1):
   - `project.yml` is the source of truth; regenerate with `xcodegen` (install:
     `brew install xcodegen`). NEVER edit `PCem.xcodeproj` by hand.
   - Build: `xcodebuild -project PCem.xcodeproj -scheme PCem -configuration Debug build`
   - Schemes/targets: `PCemCore` (static lib, all non-wx sources), `PCem` (wx app),
     `PCemMac` (native Swift shell, added M3 — scheme `PCemMac`).

## Architecture map (as of v17 + Apple Silicon patch)

### Layers
- **Core (platform-independent C)** — everything in `src/` EXCEPT `wx-*` and `mac/`.
  Entry: `initpc()` / `resetpchard()` / `runpc()` / `closepc()` in `src/pc.c`.
- **UI layer (wx, legacy reference)** — all `src/wx-*` files: wxWidgets dialogs + SDL2
  display/input/audio glue. `main()` lives in `src/wx-main.cc` → `pc_main()` in
  `src/wx-sdl2.c`.
- **UI layer (native, M3+)** — `src/mac/`: Swift/AppKit shell, no SDL2/wx:
  - `pcem_bridge.h` — the ONLY header Swift sees (bridging header). Plain C API:
    lifecycle, config list/switch, input injection, frame copy, UI callbacks.
  - `pcem_bridge.m` — satisfies the core's UI link contract (see "Coupling hazards")
    + emulation thread (port of `mainthread()`, paced with
    `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`, `timer_freq = 1e9`) + 2048×2048
    BGRX staging framebuffer behind a mutex (port of `sdl_blit_memtoscreen`).
    **Includes NO Apple system headers beyond libc** (see hazard below).
  - `pcem_mac_platform.m/.h` — the ONLY file mixing frameworks with the shell:
    NSBundle resource path, config dir listing, NSLog, `dispatch_async_f` to main.
  - `keymap.c/.h` — macOS `NSEvent.keyCode` → PC set-1 scancode table (ported from
    `SDLScancodeToSystemScancode` in `wx-sdl2-display.c`).
  - `PCemMacApp.swift` — app/window/menus. Full menu bar mirroring the wx
    context menu (`src/pc.xrc`): System / Disc / CD-ROM / Cassette / Sound,
    plus native Machine picker and View (1×/2×/3× scale, Release Mouse).
    Drive/sound actions go through bridge functions that mirror the wx-sdl2.c
    handlers 1:1 (incl. `atapi_close()`, which is UI glue, not core).
    Bridge callbacks (title, video-size → window resize, guest power-off).
    **Launcher-first, like upstream**: the machine manager opens at startup and
    nothing boots until a machine is picked (`lastMachine` in NSUserDefaults
    only *preselects*); guest power-off returns to the manager. The manager's
    Configure… edits a config without booting it (bridge
    `pcem_bridge_settings_begin_edit` — loadconfig → edit → saveconfig on the
    file), enabled only while no machine is running.
    Mouse release: Ctrl+Option+M (MacBook-friendly) / middle-click / Ctrl+End.
  - `EmulatorView.swift` — 60 Hz `Timer` pulls frames via `pcem_bridge_copy_frame`
    into a CGImage (`noneSkipFirst|byteOrder32Little` = BGRX, zero conversion) set
    as `layer.contents`; keyboard via `keyDown/keyUp/flagsChanged`; mouse capture
    on click (`CGAssociateMouseAndMouseCursorPosition(false)` + hidden cursor),
    release via middle-click / Ctrl+End / focus loss. **Requires the
    `NSTrackingArea`** installed in `updateTrackingAreas()` — without it AppKit
    only delivers *drag* events and plain hover movement never reaches the view
    (bit us on 2026-07-28: cursor moved only while pressing the touchpad).

### Threading (native shell)
1. Emulation thread: `emu_thread_proc` in `pcem_bridge.m` (core `thread_create`),
   self-paced, `runpc()` every ~10 ms; `onesec()` called from it each second.
2. Blit thread: created by core `video.c` (`blit_thread`), calls bridge's
   `mac_blit_memtoscreen` → staging buffer → `video_blit_complete()` (mandatory,
   or the core deadlocks).
3. Render: 60 Hz `Timer` on the main run loop (`EmulatorView`) — no render thread.
   The old wx "render inside a wx timer callback" hack does not exist here.

### Coupling hazards (read before touching the UI/core boundary)
- UI↔core coupling is through **globals** in `src/ibm.h` (`model`, `cpu`, `mem_size`,
  `gfxcard`, `discfns`, `emulation_state`, `pause`, …), not an API. The Swift UI will
  manipulate the same globals through a small C shim.
- `create_bitmap`/`destroy_bitmap` are DEFINED in UI code (`wx-sdl2-video.c`) but USED by
  core `video.c`. Any new renderer must provide them (or they must move into core).
- `runpc()` directly calls `keyboard_poll_host()`, `mouse_poll_host()`,
  `joystick_poll()` — these symbols must always exist at link time.
- `startblit()`/`endblit()` (SDL mutex `ghMutex`) protect `buffer32` against the renderer.
  A new renderer must respect equivalent locking.
- Sound backend contract (`soundopenal.c`, replaceable): `initalmain()`, `inital()`,
  `closeal()`, `givealbuffer(int32_t*)`, `givealbuffer_cd(int16_t*)`.
- Video backend contract: implement `video_blit_memtoscreen_func` consuming `buffer32`
  (2048×2048 BITMAP, `video.h`), then call `video_blit_complete()`.
- MIDI: `plat-midi.h`; the macOS build uses the stub `wx-sdl2-midi.c`.
- Threading primitives (`thread.h`) come from the pthread half of `wx-thread.c` —
  this file is a CORE dependency despite its name.
- **Apple system headers collide with core names**: mach/dispatch headers typedef
  `thread_t` and declare `thread_create()` (both in `thread.h`), unistd.h declares
  `pause()` (core's `int pause`), and `video_blit_complete()` has no header decl
  (declare it locally). Rule: files including core headers stay libc-only; put all
  framework calls in a separate file (pattern: `pcem_bridge.m` vs
  `pcem_mac_platform.m`).
- `libPCemCore.a` contains C++ (`cdrom-image.cc`): targets without their own .cc
  files must link `-lc++` explicitly (see `PCemMac` in project.yml).

### Apple Silicon patches already in the tree (from commit 5bb3bb4)
- `codegen_allocator.c`: JIT arena via `mmap(MAP_JIT)` + `pthread_jit_write_protect_np`.
- `386_dynarec.c`: toggles W^X around dynarec block execution.
- ARM64 dynarec backend selected at compile time (`__aarch64__` → `codegen_backend_arm64*`).
- macOS file list in `src/Makefile.am`: `cdrom-ioctl-osx.c`, `wx-sdl2-display.c`,
  defines `PCEM_RENDER_WITH_TIMER` / `PCEM_RENDER_TIMER_LOOP`, off64 fallbacks.

### Build flags that matter (both build systems)
- Defines: `PCEM_RENDER_WITH_TIMER`, `PCEM_RENDER_TIMER_LOOP`, `off64_t=off_t`,
  `fopen64=fopen`, `fseeko64=fseek`, `ftello64=ftell`.
- Networking is OFF (no `USE_NETWORKING`, no slirp). Don't enable casually.
- Links: SDL2, wx 3.3 (Homebrew, dynamic — the .app is NOT redistributable as-is),
  OpenAL, OpenGL, IOKit, Carbon, Cocoa, QuartzCore, AudioToolbox, pthread.

## How to attack M4 (next session)

Replace the wx config dialogs with SwiftUI, one at a time, in the `PCemMac` target:

1. ~~**Machine manager first** (`wx-config_sel.c`)~~ ✅ 2026-07-28 — bridge file ops
   (`pcem_bridge_config_create/rename/copy/delete/rescan`,
   `pcem_bridge_use_config_named`) + SwiftUI sheet
   `src/mac/MachineManagerView.swift`, presented from Machine → Manage Machines….
   Caveat: "New" copies the running machine's settings until step 3 wires it to
   the settings sheet.
2. ~~**Settings dialog** (`wx-config.c`, the big one)~~ ✅ 2026-07-28 (minus HD slots) —
   `pcem_settings_t` + `pcem_bridge_settings_begin/get/apply/cancel` (apply =
   port of `config_dlgsave`: dirty-check → `savenvr` → write globals →
   `mem_alloc/loadbios/resetpchard` → `cpu_set`/`cpu_update_waitstates`/
   `cd_set_*`/`saveconfig`/`speedchanged`/`gameport_update_joystick_type`),
   model-filtered list feeders (ports of `recalc_*_list`), SwiftUI sheet
   `src/mac/SettingsView.swift` (Machine → Settings…, edits the running
   machine). Units gotcha: `mem_size` is always KB but model
   min/max/granularity are in DISPLAY units (MB when `MODEL_AT &&
   ram_granularity < 128`) — see `clamp_mem_size()` in the bridge.
3. **HD slots** (the rest of the Drives page) ⬜ NEXT: 7 slots `hdc[]`/`ide_fn[]`
   + geometry + cdrom/zip channel exclusivity + `.img`/`.vhd` image creation
   (`hdnew_dlgproc`/`hdsize_dlgproc` in wx-config.c, minivhd).
   (The manager's Configure… already works: `pcem_bridge_settings_begin_edit`
   loads a config without booting it — safe because the launcher flow means
   Configure is only enabled while nothing is running.)
4. Device config dialogs (`wx-deviceconfig.cc`) come last; some devices have custom
   UIs — stub or defer to M5.
5. Keep the wx `PCem` target building until M5 removes it.

Known M3 leftovers to fix when they bite: no screenshots/shaders, no joystick UI,
MIDI stubbed, windowed-only (standard macOS fullscreen works via the green button),
stuck keys possible if the app loses focus mid-keypress (mouse is released, keys
are not), no "create blank disc image" or machine-status windows (wx dialogs —
M4/M5), no host-CD-drive menu item (no optical drives on modern Macs).

## Rules for every session

1. Read this file + the latest entries in `docs/PORTING_LOG.md` first. If the owner
   seems lost, point her to `docs/START_HERE.md` (her personal quick-reference).
2. Before finishing: update this file's status/roadmap and append a dated log entry
   describing what changed, what broke, and the exact next step.
3. Commit per milestone (ask the owner before git mutations). Small, clear commits.
4. Minimal changes. Never refactor the emulator core "while you're in there".
5. Keep BOTH build systems working. If you add/remove/rename a source file, update
   `project.yml` AND `src/Makefile.am` if applicable. (`src/mac/` is deliberately
   NOT in `Makefile.am` — it's the macOS-only shell.)
6. `wx-resources.cpp` is generated from `pc.xrc` by `wxrc` — don't hand-edit.
