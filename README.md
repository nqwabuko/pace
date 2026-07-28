# pace

A calm macOS menu-bar break reminder, in Swift. Pomodoro-inspired: it nudges you
to **rest your eyes** (the 20-20-20 rule) and **move your body**, and it gets out
of the way when you're on a call or away from the keyboard.

Same self-contained-`.app` pattern as [netty](../netty): menu-bar only
(`LSUIElement`, no Dock icon), the launcher is named `pace` so Activity Monitor
and Login Items show "pace", and it's ad-hoc signed so it runs after being moved.

```
menu bar:  👁  ->  click for the menu
break:     a soft full-screen card, a countdown, Skip / +5 min (Esc always skips)
```

## How it works

A one-second feedback loop, like netty's sampler:

1. **Two counters** advance each tick, one per break type (eye, move).
2. **Guards** run first. If the **microphone is in use** (any app, so Zoom /
   Teams / Meet / FaceTime / Slack huddles all count, even muted) and
   *meeting-aware* is on, the loop **holds**, a due break fires the moment the
   call ends. If you've been **idle** past the reset threshold, both counters
   **reset**, so you're never ambushed the instant you sit back down.
3. When a counter hits its interval, a **break overlay** appears. A movement
   break rests the eyes too, so it resets both.
4. The overlay always **auto-dismisses** at zero and is always **dismissible**
   (Skip, Esc, or a hard key-monitor fallback), so it can never trap you. If a
   call starts mid-break, it bows out at once.

Meeting detection is deliberately **app-agnostic**: it reads the default input
device's `kAudioDevicePropertyDeviceIsRunningSomewhere` (CoreAudio) rather than
matching app names, so new tools work with no changes. Idle time is read from
IOHIDSystem's `HIDIdleTime` (IOKit). Both are permission-free reads. **No
network, nothing leaves your Mac.**

## Install

```sh
./make-app.sh --install     # build pace.app, copy to /Applications, launch
./make-app.sh               # just build ./pace.app
```

Then open the menu and turn on **Start at login**.

## Quick entry (Horo-style)

**Left-click** the menu-bar icon for a small popover: the next-break status and a
text field you just type times into, the way [Horo](https://matthewpalmer.net/horo-free-timer-mac/)
and [Hourglass](https://chris.dziemborowicz.com/apps/hourglass/) do.

- `20m`, `1h 15m`, `1.5h`, `90s`, `1:30` — schedule a break after that long
- `@10am`, `at 2:30pm`, `noon` — schedule a break at the next such time
- `pause 1h`, `pause until 2pm`, `snooze 20m` — suppress all breaks until then
- `eye break in 20m` / `move in 45m` — pick which kind

The rule (from Hourglass): am/pm, noon/midnight, or a leading `@` means an
absolute time; a bare number or duration units mean a countdown. See exactly how
any phrase resolves with `swift run pace --parse "break @10am"`.

## Menu (right-click)

- **Next break in m:ss** + a per-timer detail line (Eyes / Move / Scheduled).
- Take an eye / move break now.
- Toggle each break type; set its interval and length.
- **Pause during calls** (default on), **Reset when I step away** (default on),
  optional sound.
- **Pause** for 30 min / 1 h / 2 h / until tomorrow; Resume.
- Start at login.

## Stats at a glance

Left-click → **Stats** (or right-click → Reporting → Show stats) opens a small
native window: today / 7-day-average / streak tiles, a stacked per-day bar chart
(eye vs move), and an eye-vs-move donut. Built with Swift Charts, so it matches
the system look. This is the quick daily glance; the Obsidian export below is for
long-range tracking.

## Reporting (Obsidian)

Right-click → **Reporting** → **Log to Obsidian vault…** and pick your vault (or
any folder). pace writes into a `pace/` subfolder:

- **Daily notes** (`2026-07-21.md`) with Dataview-friendly YAML frontmatter
  (`pace_eye`, `pace_move`, `pace_skipped`, `pace_break_minutes`) plus a table of
  the day's breaks. The frontmatter folds straight into an existing self-mastery
  vault, so your own Dataview / Charts queries can pick it up.
- **`pace-dashboard.md`**: 7- and 30-day averages (breaks/day, resting minutes,
  % taken), a current streak, a 14-day bar chart, and an eye-vs-move split. Built
  with a monospace bar chart and a native mermaid pie, so it renders with **no
  plugins**.

The source of truth is a local JSONL log in `~/Library/Application Support/pace/`;
the notes are a rendered view of it and can be rebuilt any time
(**Rebuild dashboard now**). Nothing leaves your Mac. Preview the format without
committing: `swift run pace --report-demo /tmp/vault`.

## Log a bug or idea

Left-click → **Bug / idea**, or right-click → **Log a bug or idea…**. Pick Bug or
Improvement, type a note. It appends to `feedback.md` in Application Support (and
mirrors into your vault's `pace/` folder if one is set). Also scriptable:
`pace --feedback idea "your note"`.

## Break prompts

Each break card shows a short principle with a real attribution, then a one-line
technical/medical "why". Movement principles follow named sources (Katy Bowman's
*Move Your DNA*, Kelly Starrett's *Deskbound*, James Levine on NEAT, activity-break
research); eye principles follow the 20-20-20 rule (Dr. Jeffrey Anshel). The "why"
lines are grounded in the sitting-physiology and eye-strain literature (e.g. leg
lipoprotein-lipase drop, ciliary-muscle fatigue). Principles are faithful
statements of each source's position, not verbatim quotations. Edit them in
`Sources/pace/Tips.swift`.

Defaults: eye break every 20 min for 20 s; move break every 50 min for 60 s;
5 min idle counts as a rest.

## Run / test from source

```sh
swift run pace              # run the app from source
swift run pace --demo       # preview one break overlay (5s) and quit
swift run pace --check      # print mic-in-use / idle / login-item and exit
```

`--check` is the way to verify detection: run it, start a call, run it again, and
watch `mic-in-use` flip to `true`.

## Files

- `Sources/pace/Settings.swift` — one typed store over UserDefaults.
- `Sources/pace/Signals.swift` — mic-in-use (CoreAudio) + idle (IOKit).
- `Sources/pace/Scheduler.swift` — the 1-second loop, guards, counters.
- `Sources/pace/BreakOverlay.swift` — the dismissible overlay window.
- `Sources/pace/AppDelegate.swift` — status item + menu.
- `Sources/pace/IconMaker.swift` — menu-bar glyph + app icon.
- `make-app.sh` — build the self-contained bundle.

## Known edge

If an app fully releases the microphone while you're muted *and* your camera is
off, pace can't tell you're in a call (mic is the only signal). Rare in practice;
mute keeps the device stream open in every mainstream tool. You can always Pause.
