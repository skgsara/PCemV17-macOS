# START HERE (read this first, any day you feel lost)

*Written 2026-07-26, updated 2026-07-27. This file is for you, Sara — plain language,
no memory required. If a future session changes things, that session must update
this file.*

## Where the project stands

You have **two working Mac apps** from the same project:

- **PCemMac** (new, 2026-07-27) — the first all-Swift interface. No wxWidgets, no
  SDL. It boots the emulator, shows the screen, and handles keyboard and mouse.
  Verified booting the AMI 486 BIOS at 100% speed.
- **PCem** (original) — the wxWidgets interface. Still needed to *configure*
  machines; keep it until M5.

The big goal: slowly replace PCem's old interface (wxWidgets) with a native Mac
interface written in Swift. The plan lives in `AGENTS.md` (milestones M0–M5).
Done so far: M0, M1, M2, M3.

## How to run the apps

1. Open `PCem.xcodeproj` (double-click it).
2. At the top of the Xcode window, next to the Run button, pick the scheme:
   - **PCemMac** = your new native app
   - **PCem** = the old wx app (use this one to change machine settings)
3. Press **⌘R** (Run).

In PCemMac: the app boots straight into your last-used machine (it remembers).
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

> **Read AGENTS.md and docs/PORTING_LOG.md, then let's continue with M4.**

The agent will know everything: what's done, what's next, and every trap we've
already fallen into. You do not need to remember or explain anything.

## What M4 is (the next fun part)

Right now, changing a machine's settings (CPU, memory, video card…) still opens
the old wxWidgets dialogs. In M4 we rebuild those dialogs in SwiftUI, one at a
time — first the machine picker, then the settings window.

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
- Not committed to git yet — commit happens when you say so.

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
