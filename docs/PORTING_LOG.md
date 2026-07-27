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
