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
  (`wx-config.c`) dialogs one at a time. ✅ 2026-07-28 — machine manager, settings
  dialog, HD slots all done (device sub-dialogs moved to M5, done there).
- **M5 — Remove wx entirely**: drop SDL/wx dependencies; optionally replace OpenAL with
  CoreAudio; CoreMIDI; app icon/signing/notarization. 🔶 IN PROGRESS — device
  "Configure…" sub-dialogs ✅ 2026-07-28, wx target + SDL/wx deps removed from
  Xcode ✅ 2026-07-28, CoreMIDI ✅ 2026-07-29; remaining: joystick mapping +
  GameController (deferred — needs a controller to test), optional
  OpenAL→CoreAudio, app icon/signing (owner wants those LAST).

## Current status

M0–M4 done; M5 in progress — device "Configure…" sub-dialogs done and the wx
target removed from Xcode (2026-07-28). New target `PCemMac`: a native
Swift/AppKit shell with **no SDL2 and no wxWidgets**, linking `PCemCore` via
the bridge in `src/mac/`. Verified by the owner (2026-07-28): MS-DOS 5 boots,
keyboard works, mouse capture/release works, and the guest cursor tracks the
touchpad in both DOS and Windows 3.1 (after the tracking-area fix — see
`EmulatorView.swift` bullet below and the 2026-07-28 entry in
`docs/PORTING_LOG.md`).
M4 step 1: the wx machine manager is replaced by a SwiftUI sheet (Machine →
Manage Machines…): list/New/Copy/Rename/Delete/Boot via new
`pcem_bridge_config_*` functions; view in `src/mac/MachineManagerView.swift`.
M4 step 2 (same day): the wx settings dialog is replaced by a SwiftUI sheet
(Machine → Settings…, `src/mac/SettingsView.swift`) covering Machine
(model/CPU/FPU/dynarec/memory/waitstates/sync), Video, Sound, floppy types,
CD model/speed, Mouse and Joystick. The
bridge (`pcem_settings_t` + begin/get/apply/cancel + model-filtered list
feeders) ports `config_dlgsave` and the `recalc_*_list` filters 1:1; apply
dirty-checks, reboots and saves exactly like wx. Caveat from step 1 stands:
"New" copies the running machine's settings (wx opened the settings editor
first; wiring that up is a later cleanup).
M4 step 3 (same day): the settings dialog's HD page is replaced by a
"Hard Discs" tab — 7 slots with type picker (Hard drive/CD-ROM/ZIP with
channel exclusivity), geometry fields, Choose…/New…/Eject, .img/.vhd
creation (raw/fixed/dynamic/differencing, `src/mac/HardDiscSheets.swift`).
The bridge keeps a PENDING slot snapshot per settings session
(`pcem_bridge_hd_slot_*`, `pcem_bridge_hd_set_channels`), dirty-checks it
against the globals (`hd_pending_dirty` = wx's `hd_changed` + channel
compares) and writes it back in apply; image probe/create
(`pcem_bridge_hd_image_probe/_create`, minivhd) port `hd_file`/`hdnew_dlgproc`.
M5 slice 1 (2026-07-28): the generic wx device-config dialog
(`wx-deviceconfig.cc`) is replaced by `src/mac/DeviceConfigView.swift` +
`pcem_bridge_devcfg_*` (all-int bridge API over `device_t.config`;
CONFIG_BINARY → Toggle, CONFIG_SELECTION → Picker; CONFIG_MIDI filtered out
until slice 3 landed CoreMIDI). Five "Configure…" buttons in the settings sheet
(Machine/Video/Voodoo/Sound/HD Controller) resolve their device from the
PENDING selection exactly like `wx-config.c:1220-1290`; Apply dirty-checks,
confirms "This will reset PCem!" when a machine runs, then writes +
`saveconfig` + `resetpchard` immediately, independent of the parent sheet's
Cancel (wx's `has_been_inited` path).
M5 slice 2 (2026-07-28): **the wx `PCem` target is gone from the Xcode
project** — `project.yml` has only `PCemCore` + `PCemMac`, and the shared
build settings no longer carry wx/SDL defines or header paths. The wx
sources stay in the tree and **autotools still builds the wx `pcem` binary**
(`./configure && make`) as the fallback for the one remaining wx-only
feature: joystick axis/button mapping (`wx-joystickconfig.cc` — deferred
until the owner has a controller to test with, then it lands as a
GameController port + SwiftUI sheet).
M5 slice 3 (2026-07-29): **CoreMIDI backend** replaces the MIDI stub.
`src/mac/pcem_mac_midi.m` (the only file with CoreMIDI includes, no PCem
headers) wraps client/virtual-source/destination/send behind a plain-C API;
`pcem_bridge.m` implements the five `plat-midi.h` functions on top,
including the win/alsa byte-stream reassembler (with two deliberate fixes:
no-op when no device is open, and proper running-status handling — upstream
has a latent buffer overflow there). Device list: index 0 = "PCem Virtual
Output" (CoreMIDI virtual source, works out of the box with any Mac synth
app), 1..N = real CoreMIDI destinations. Selection travels via config key
`midi` in the NULL section, re-read by `midi_init` at every boot
(`boot_machine`, mirrors wx-sdl2.c:673/725). The "MIDI out device" picker
now appears in the SB16/AWE32/Aztech Configure sheets — CONFIG_MIDI items
are synthesized as generic Picker options in the devcfg bridge, so
`DeviceConfigView.swift` needed no changes. Switching device applies
immediately (`midi_close`+`midi_init` after the reset — wx made you
reboot).

## How to build

Two independent build systems exist. **Both must keep working.**

1. **Autotools** (original, terminal — now the ONLY way to build the wx UI):
   `./configure && make` — produces the wx `pcem` binary at repo root.
   Dependencies via Homebrew: `sdl2 wxwidgets openal-soft`.
2. **Xcode** (added in M1; **native shell only since M5 slice 2** — no wx/SDL
   target, no wx/SDL defines or header paths):
   - `project.yml` is the source of truth; regenerate with `xcodegen` (install:
     `brew install xcodegen`). NEVER edit `PCem.xcodeproj` by hand.
   - Build: `xcodebuild -project PCem.xcodeproj -scheme PCemMac -configuration Debug build`
   - Targets: `PCemCore` (static lib, all non-wx sources incl. `wx-thread.c`),
     `PCemMac` (native Swift shell, the only app + scheme).

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
  - `pcem_mac_platform.m/.h` — one of the TWO files mixing frameworks with the
    shell: NSBundle resource path, config dir listing, NSLog,
    `dispatch_async_f` to main. The other is `pcem_mac_midi.m/.h` — CoreMIDI
    backend behind a plain-C API (added M5 slice 3; see "Current status").
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
- MIDI: `plat-midi.h`; the native shell implements it over CoreMIDI
  (`pcem_mac_midi.m` + the reassembler in `pcem_bridge.m`, M5 slice 3). The
  autotools wx build still uses `midi_alsa.c` (Linux) / `wx-sdl2-midi.c` (stub).
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
- Links (Xcode): OpenAL, IOKit, Carbon, Cocoa, QuartzCore, AudioToolbox,
  CoreMIDI (M5 slice 3), pthread — no SDL2/wx since M5 slice 2. The
  autotools wx build still links SDL2 + wx 3.3 (Homebrew, dynamic).

## How M4 was attacked (kept as a record; M4 is DONE)

The wx config dialogs were replaced with SwiftUI, one at a time, in the `PCemMac` target:

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
3. ~~**HD slots** (the rest of the Drives page)~~ ✅ 2026-07-28 — "Hard Discs"
   tab in the settings sheet: 7 slots `hdc[]`/`ide_fn[]` via a pending
   snapshot in the bridge, cdrom/zip channel exclusivity, `.img`/`.vhd`
   probe + creation (`hdnew_dlgproc`/`hdsize_dlgproc`/`hd_file` ports,
   minivhd) in `src/mac/HardDiscSheets.swift`.
4. ~~Device config dialogs (`wx-deviceconfig.cc`)~~ ✅ 2026-07-28 (as M5 slice 1) —
   generic, no custom UIs needed: `pcem_bridge_devcfg_*` + `DeviceConfigView.swift`;
   five "Configure…" buttons in the settings sheet (see "Current status").
5. ~~Keep the wx `PCem` target building until M5 removes it.~~ Removed 2026-07-28
   (M5 slice 2); autotools still builds the wx binary as a fallback.

## How to attack the rest of M5

- ~~**Remove the wx `PCem` target**~~ ✅ 2026-07-28 (slice 2) — dropped from
  `project.yml` along with the wx/SDL defines and header paths. Autotools keeps
  building the wx binary; removing wx THERE is a separate owner decision (it
  would end all wx dialog access).
- **Joystick axis/button mapping** (`wx-joystickconfig.cc`) — the last wx-only
  settings UI. DEFERRED until the owner has a game controller to test with
  (2026-07-28 decision). When it lands: GameController-based `joystick_init`/
  `joystick_poll` replacing the stubs (raw state via a mutex-protected snapshot
  in `pcem_mac_platform.m`-style code — the bridge stays framework-free; port
  the mapping/atan2 half of `wx-sdl2-joystick.c:104-165` verbatim), define
  `plat_joystick_state[]`/`joysticks_present`, add GameController.framework in
  `project.yml`, and a mapping sheet on the Input tab (wx dialog shape: Device
  combo + one combo per emulated axis/button/POV-X/Y, POV_X=0x80000000 /
  POV_Y=0x40000000 encoding, writes straight to `joystick_state[]`, no reset
  needed). Mappings persist in the `[Joysticks]` cfg section — `loadconfig`/
  `saveconfig` in `pc.c` already handle them.
- ~~**CoreMIDI**~~ ✅ 2026-07-29 (slice 3, see "Current status").
- **Optional**: OpenAL→CoreAudio (sound backend contract in "Coupling
  hazards"). **App icon, signing/notarization come LAST** (owner decision
  2026-07-29), after all functional work.

Known M3 leftovers to fix when they bite: no screenshots/shaders, no joystick UI,
windowed-only (standard macOS fullscreen works via the green button),
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
