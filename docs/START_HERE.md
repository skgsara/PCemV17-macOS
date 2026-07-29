# START HERE (read this first, any day you feel lost)

*Written 2026-07-26, updated 2026-07-28. This file is for you, Sara — plain language,
no memory required. If a future session changes things, that session must update
this file.*

## Where the project stands

You have **two working Mac apps** from the same project:

- **PCemMac** (new, 2026-07-27) — the first all-Swift interface. No wxWidgets, no
  SDL. It boots the emulator, shows the screen, and handles keyboard and mouse.
  Verified by you on 2026-07-28: MS-DOS 5 boots, and the mouse follows your
  finger in both DOS and Windows 3.1.
- **PCem** (original) — the wxWidgets interface. Only still needed for the
  small per-device "Configure…" dialogs in machine settings; keep it until M5.

The big goal: slowly replace PCem's old interface (wxWidgets) with a native Mac
interface written in Swift. The plan lives in `AGENTS.md` (milestones M0–M5).
Done so far: M0, M1, M2, M3, and almost all of M4.

## How to run the apps

1. Open `PCem.xcodeproj` (double-click it).
2. At the top of the Xcode window, next to the Run button, pick the scheme:
   - **PCemMac** = your new native app
   - **PCem** = the old wx app (only needed for per-device "Configure…" dialogs)
3. Press **⌘R** (Run).

In PCemMac: the app opens the **machine manager first**, just like the original
PCem. Pick a machine and press **Boot** (or double-click it) to start. Your
last-used machine is preselected for you. **Configure…** changes a machine's
settings *before* it runs; **Machine → Settings…** changes the machine that's
currently running (it warns before rebooting). When a machine shuts down,
you're back at the machine manager.
Click the emulated screen to capture the mouse. **Ctrl+Option+M** releases it
(or View → Release Mouse; middle-click / Ctrl+End also work on external
keyboards). The menu bar mirrors the old app's right-click menu: **System**
(Reset/Pause/Shutdown), **Disc** (mount/eject floppies + ZIP), **CD-ROM**
(load/eject images), **Cassette**, **Sound** (buffer length, volume), **View**
(window size 1×/2×/3×), and **Machine** (switch between your saved machines).

If the project file ever gets messed up: open Terminal in this folder and type
`xcodegen` — it rebuilds `PCem.xcodeproj` from `project.yml`. Never edit the
.xcodeproj by hand.

The old way still works too: type `make` in Terminal, then run `./pcem`.
All three builds share the same ROMs and machine configs.

## How to continue after a break (new chat session)

Open a new chat in this folder and say exactly this:

> **Read AGENTS.md and docs/PORTING_LOG.md, then let's continue with M5.**

The agent will know everything: what's done, what's next, and every trap we've
already fallen into. You do not need to remember or explain anything.

When you feel up to it (no rush): run the **PCemMac** scheme and play with the
new menus — mount a floppy from the **Disc** menu, switch window size in
**View**, and release the mouse with **Ctrl+Option+M**.

## What M4 is (the current fun part)

Changing a machine's settings used to open the old wxWidgets dialogs. In M4 we
rebuild those dialogs in SwiftUI, one at a time.

- **Done (2026-07-28): the machine manager.** In PCemMac, open **Machine →
  Manage Machines…** to create, copy, rename, delete and boot your saved
  machines.
- **Done (2026-07-28): the settings window.** **Machine → Settings…** now
  changes CPU, memory, video card, sound, drives, mouse and joystick — all
  native. If your change needs a reboot, it asks first, just like the old app.
  One caveat: a *new* machine still starts as a copy of the one currently
  running.
- **Done (2026-07-28): the hard-disc panels.** The settings window has a
  **Hard Discs** tab: attach or eject disk images on 7 slots, mark a slot as
  CD-ROM or ZIP, and **create brand-new disk images** (.img and .vhd) from
  the New… button.
- **Next (M5):** the small per-device "Configure…" dialogs, then removing
  wxWidgets entirely.

## What happened on 2026-07-28 (the short version)

- You test-drove PCemMac: MS-DOS 5 boots, keyboard works, and the new
  **Ctrl+Option+M** mouse-release shortcut works.
- One bug found and fixed: in Windows 3.1 the cursor only moved while you
  *pressed* the touchpad. Cause: Mac apps must explicitly ask for mouse-move
  events (a "tracking area"); without it only presses/drags come through.
  One small addition to `EmulatorView.swift` fixed it.
- You confirmed the fix: the cursor now follows your finger — no pressing —
  in both DOS and Windows 3.1. The old wx app was our control experiment:
  its mouse worked all along, which proved the bug was in our new shell,
  not in the emulator engine.
- Evening: the first M4 dialog landed. **Machine → Manage Machines…** in
  PCemMac now creates, copies, renames, deletes and boots machines — all
  native SwiftUI, no wxWidgets.
- Night: the settings window followed. **Machine → Settings…** changes the
  running machine's CPU, memory, video, sound, drives, mouse and joystick,
  with the same "this will reset PCem" warning as the old app.
- Late night, your call: PCemMac now starts the way the original does — the
  machine manager opens first and nothing runs until you press **Boot**. The
  manager also has **Configure…** to change a machine *before* it runs, and
  shutting a machine down brings you back to the manager.
- Later still: the **Hard Discs** tab landed — the last big settings page.
  You tested it by creating a 32 MB disk image and FDISK saw it in DOS.
  Your testing caught two real bugs: one where picking a drive "Type"
  zeroed the geometry (fields were updating each other in a loop), and one
  where **Boot did nothing after a shutdown** (a leftover from the launcher
  change). Both fixed, committed as `a43cd42`.
- Mystery of the night, solved: the "Foreign Hard Disk" in the XTIDE boot
  menu is **not a second disk** — it's your one 152 MB disk seen twice (once
  by the AMIBIOS through its old CMOS setting, once by the XTIDE card). The
  wx app shows the same thing, so it's a machine-config quirk, not a bug.

## What happened on 2026-07-27 (the short version)

- Built the native shell (M3): new files in `src/mac/` — a C "bridge" that plugs
  the emulator engine into macOS, plus two Swift files for the window and input.
- Trickiest bug: Apple's own headers use the same names as PCem internals
  (`thread_create`, `pause`), so the bridge file is kept C-only and all Apple
  framework calls live in one small separate file.
- Two fixes after your feedback: the app now boots your last-used machine
  automatically (the old app just *looked* like it remembered — it actually
  asked you every time via the machine manager), and the window defaults to 1×
  with a View menu for 2×/3×.
- Then the full menu bar arrived: everything the old app's right-click menu
  could do (mount/eject floppies, CD images, ZIP, cassette, sound settings,
  reset/shutdown) now lives in proper menus. Mouse release is Ctrl+Option+M.
- Committed as `92efebb` ("M3: native Swift/AppKit shell") and pushed to GitHub.

## What happened on 2026-07-26 (the short version)

- Created the project memory: `AGENTS.md` + `docs/PORTING_LOG.md`.
- Created the Xcode project (two parts: `PCemCore` = the emulator engine,
  `PCem` = the current interface).
- Fixed 6 build problems; the coolest one: macOS caught a real bug where the
  code copied a filename onto itself (`src/disc.c`).
- Three git commits: `d429455` (memory), `ee03746` (Xcode project),
  `e60a27c` (disc.c fix).

## House rules we agreed on

- Important things get **written into the repo**, not just said in chat.
- Every session ends by updating `AGENTS.md` + `docs/PORTING_LOG.md` +
  this file.
- Small commits, one milestone at a time.
- The emulator's C engine does not get rewritten — only the interface layer.
