# START HERE (read this first, any day you feel lost)

*Written 2026-07-26. This file is for you, Sara — plain language, no memory required.
If a future session changes things, that session must update this file.*

## Where the project stands

You have a **working native Mac app**. PCem builds in Xcode and boots MS-DOS 5 to
DOSSHELL with working keyboard. You verified this yourself on 2026-07-26.

The big goal: slowly replace PCem's old interface (wxWidgets) with a native Mac
interface written in Swift. This is a months-long project and that's fine.
The plan lives in `AGENTS.md` (milestones M0–M5). Done so far: M0, M1, M2.

## How to run the app

1. Open `PCem.xcodeproj` (double-click it).
2. Press **⌘R** (Run). That's it.

If the project file ever gets messed up: open Terminal in this folder and type
`xcodegen` — it rebuilds `PCem.xcodeproj` from `project.yml`. Never edit the
.xcodeproj by hand.

The old way still works too: type `make` in Terminal, then run `./pcem`.
Both builds share the same ROMs and machine configs, so use whichever you like.

## How to continue after a break (new chat session)

Open a new chat in this folder and say exactly this:

> **Read AGENTS.md and docs/PORTING_LOG.md, then let's continue with M3.**

The agent will know everything: what's done, what's next, and every trap we've
already fallen into. You do not need to remember or explain anything.

## What M3 is (the next fun part)

Right now the app draws its window using wxWidgets. In M3 we make the first
Swift window that shows the emulated PC's screen without wxWidgets. That's the
first piece that is truly *yours*.

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
- Every session ends by updating `AGENTS.md` + `docs/PORTING_LOG.md`.
- Small commits, one milestone at a time.
- The emulator's C engine does not get rewritten — only the interface layer.
