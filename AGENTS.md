# PCem macOS Port — Agent Guide

This file is the project's memory. Every agent session MUST read it first and update it
(along with `docs/PORTING_LOG.md`) before finishing. It exists because the owner works
across many sessions and each session starts with zero context.

## Owner context

The owner is a programming beginner (some C reading, some Swift Playgrounds) doing this as
a personal learning project. Explain what you change and why. Keep commit messages and
comments educational but concise. Never dumb down the code itself.

## Goal

Turn PCem v17 into a native macOS app on Apple Silicon by **gradually replacing the
wxWidgets UI with Swift/AppKit/SwiftUI while keeping the C emulator core untouched as
much as possible**. This is a multi-month effort done in milestones.

## Roadmap

- **M0 — Repo memory**: this file + `docs/PORTING_LOG.md`. ✅ 2026-07-26
- **M1 — Xcode project**: XcodeGen-based project building the existing wx UI code into
  `PCem.app`. ✅ 2026-07-26
- **M2 — Target split**: `PCemCore` static library + `PCem` app target (wx UI). ✅ 2026-07-26
- **M3 — Swift shell**: new AppKit window with a Metal/CALayer renderer consuming
  `buffer32`, replacing `wx-sdl2-display.c` / `wx-sdl2-video*.c`; AppKit keyboard/mouse
  input replacing `wx-sdl2-keyboard.c` / `wx-sdl2-mouse.c`. Keep wx dialogs for config
  during transition. ⬜ NEXT
- **M4 — Config UI in SwiftUI**: replace machine manager (`wx-config_sel.c`) and settings
  (`wx-config.c`) dialogs one at a time. ⬜
- **M5 — Remove wx entirely**: drop SDL/wx dependencies; optionally replace OpenAL with
  CoreAudio; CoreMIDI; app icon/signing/notarization. ⬜

## Current status

M0–M2 done (2026-07-26). The Xcode project builds the unmodified wxWidgets UI into
`PCem.app`; verified booting MS-DOS 5 to DOSSHELL with working keyboard input.
Next session should start M3 (see "How to attack M3" below).

## How to build

Two independent build systems exist. **Both must keep working.**

1. **Autotools** (original, terminal):
   `./configure && make` — produces the `pcem` binary at repo root.
   Dependencies via Homebrew: `sdl2 wxwidgets openal-soft`.
2. **Xcode** (added in M1):
   - `project.yml` is the source of truth; regenerate with `xcodegen` (install:
     `brew install xcodegen`). NEVER edit `PCem.xcodeproj` by hand.
   - Build: `xcodebuild -project PCem.xcodeproj -scheme PCem -configuration Debug build`
   - The app target links `libPCemCore.a` (target `PCemCore`, all non-wx sources).

## Architecture map (as of v17 + Apple Silicon patch)

### Layers
- **Core (platform-independent C)** — everything in `src/` EXCEPT `wx-*` files.
  Entry: `initpc()` / `resetpchard()` / `runpc()` / `closepc()` in `src/pc.c`.
- **UI layer** — all `src/wx-*` files: wxWidgets dialogs + SDL2 display/input/audio glue.
  `main()` lives in `src/wx-main.cc` → `pc_main()` in `src/wx-sdl2.c`.

### Threading (3 threads)
1. Emulation thread: SDL thread `mainthread()` (`src/wx-sdl2.c:181`), self-paced via
   `SDL_GetTicks`, calls `runpc()` every ~10 ms.
2. Blit thread: created by core `video.c` (`blit_thread`), copies emulated framebuffer
   `buffer32` → `screen` via function pointer `video_blit_memtoscreen_func`.
3. Render: on macOS driven by a wx timer (`PCEM_RENDER_WITH_TIMER`,
   `PCEM_RENDER_TIMER_LOOP` defined in build flags), NOT a separate thread.
   This is a known hack ("works on OSX... no idea why") — redesign in M3.

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

## How to attack M3 (next session)

1. Add a third target `PCemMac` (Swift AppKit app) linking `PCemCore`.
2. Write a small ObjC/C bridge (`PCemBridge`) exposing: init, load config by name,
   start/pause/reset/stop emulation, and a frame callback.
3. Replace the render path: new `*-display` + `*-video` implementation that hands
   `buffer32` contents to a Metal texture (or CALayer/CGImage first — simpler).
   Provide `create_bitmap`/`destroy_bitmap`, `video_blit_memtoscreen_func`, blit locking.
4. Replace input: AppKit `keyDown/keyUp` → PC scancodes into `pcem_key[272]`;
   mouse via `CGAssociateMouseAndMouseCursorPosition` / delta tracking like
   `wx-sdl2-mouse.c` does with SDL.
5. Keep `soundopenal.c` (OpenAL works fine on macOS).
6. Keep the wx-based `PCem` target working as a reference until M4/M5.

## Rules for every session

1. Read this file + the latest entries in `docs/PORTING_LOG.md` first.
2. Before finishing: update this file's status/roadmap and append a dated log entry
   describing what changed, what broke, and the exact next step.
3. Commit per milestone (ask the owner before git mutations). Small, clear commits.
4. Minimal changes. Never refactor the emulator core "while you're in there".
5. Keep BOTH build systems working. If you add/remove/rename a source file, update
   `project.yml` AND `src/Makefile.am` if applicable.
6. `wx-resources.cpp` is generated from `pc.xrc` by `wxrc` — don't hand-edit.
