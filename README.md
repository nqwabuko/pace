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

1. **Two counters** advance each tick, one per break type (eye, move). A counter
   measures **seconds of screen work since that break last actually rested you** —
   that one sentence decides everything else below.
2. **Guards** run first. If the **microphone is in use** (any app, so Zoom /
   Teams / Meet / FaceTime / Slack huddles all count, even muted) and
   *meeting-aware* is on, the loop **holds**, a due break fires the moment the
   call ends. If you've been **locked away** past the reset threshold, both
   counters reset, so you're never ambushed the instant you sit back down.
3. When a counter hits its interval, a **break overlay** appears. Only three
   things ever reset a counter: sitting the break out, telling it you already
   took one, or a long enough locked-away spell. A movement break rests the eyes
   too, so taking one clears both.
4. **Putting a break off costs you nothing but time.** *+5 min* buys five
   minutes of quiet, *Skip* buys ten, and neither credits you a rest — the
   counter keeps climbing straight through, so the break comes back owing more
   than it did before, and the menu-bar eye keeps getting worse. Extend it four
   times in a row and you can see all four on the bar.
5. The overlay always **auto-dismisses** at zero and is always **dismissible**
   (Skip, Esc, a click off the card, or a hard key-monitor fallback), plus an
   independent watchdog timer that closes it even if its own countdown dies. A
   window that covers your whole screen should not be able to outlive its clock.
   If a call starts mid-break, it bows out at once and is logged as
   *interrupted*, not *skipped* — you didn't refuse anything.

The loop reads a **monotonic clock**, not its own tick count. If the run loop is
starved (App Nap, a slow disk) the next tick still counts every second that
passed, so time is never silently lost; and because that clock stops while the
Mac sleeps, sleeping isn't counted as eye strain.

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

## The icon is the gauge

The menu-bar eye shows how long your eyes have been working, and it does not lie
to make you feel better.

- **Just rested** — a light open ring with a small pupil sitting low, loose the
  way a googly eye settles.
- **Working** — the pupil dilates and rises.
- **Break due** — a bold pupil with a ring of white still showing around it.
- **Overdue** — the pupil floods the eye solid, and the whole eye swells and
  settles lower the longer you hold out. **Hollow means you're fine, solid means
  you're behind.**

One rule holds the whole thing together: **the glyph only ever gets heavier.**
Never thinner, never smaller. A hairline reads as "off" at menu-bar size, so an
icon that quietened down as you fell further behind would be worse than no icon.
That's measured, not eyeballed — see `--selftest` below. (An earlier version
squinted the eye shut when overdue, which shrank it by a quarter. Exactly
backwards, and only the measurement caught it.)

Because the counter behind it only resets on a break you actually took, extending
the same break over and over walks the eye further and further into the solid
range instead of snapping it back to rested.

Render the whole sequence to look at it:

```sh
./.build/debug/pace --make-strainstrip strip.png                    # add `dark` for a dark bar
./.build/debug/pace --make-strainstrip strip.png dark stages 0 1 1.5 2
```

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
swift run pace                    # run the app from source
swift run pace --demo             # preview one break overlay (5s) and quit
swift run pace --check            # print mic-in-use / idle / login-item and exit
swift run pace --check ~/vault    # ...and try a real write into that folder
swift run pace --sim              # run the whole loop against a fake clock
```

`--check` is the way to verify detection: run it, start a call, run it again, and
watch `mic-in-use` flip to `true`. Give it a folder and it also tries an actual
vault write and prints what went wrong, which beats guessing why notes stopped
appearing.

### `--selftest`: the mechanical claims

`--sim` shows you the loop and you judge it. `--selftest` asserts the handful of
things the design would quietly break if a constant were nudged, and exits
non-zero, so it works as a gate:

```
glyph — the icon must never look calmer the more rest you owe
  ok   ink only ever increases
  ok   solidity never falls
  ok   hollow when rested   0.57
  ok   white still showing when due   0.82
  ok   solid once overdue (by 1.5)   1.00

loop — extending a break must never credit a rest
  ok   counter keeps climbing through 4 extensions   1.00 → 2.00 → 3.00 → 4.00
  ok   four extensions are all counted   refusals=4
  ok   taking it finally rests you   0.00

vault health — a broken vault must read as broken, then heal
  ok   three failures count as three   3
  ok   a success clears it
```

Add `verbose` to print the measured ink/solidity curve, which is what you want
when tuning any of the glyph constants.

### `--sim`: the loop's test harness

The loop is the product, and every bug in it is a bug about *time* — a counter
that resets when it shouldn't, a deferral that comes back too soon. Waiting
twenty real minutes to see one is no way to check anything, so both clocks, the
mic and the idle sensor are injected, and a whole scenario runs in milliseconds
against the real `Scheduler`.

```sh
swift run pace --sim                                  # the default: extend one break four times
swift run pace --sim "eye 5m, moveoff, work 5m, skip, work 9m, work 2m"
swift run pace --sim "eye 3m, nudges, work 2m, call 13m, work 1m"
swift run pace --sim "eye 5m, work 1m, lostunlock 20m, work 1m"
```

It prints the counter, the strain, a gauge and the refusal count on every event:

```
   time   worked / due   strain  [ rested ---- due ---- overdue ]   off   what happened
   5:00    5:00 / 5:00     1.00  [##########|..........]    1   +5 min (eye)
  10:00   10:00 / 5:00     2.00  [##########|!!!!!!!!!!]    1   BREAK DUE (eye)
  10:00   10:00 / 5:00     2.00  [##########|!!!!!!!!!!]    2   +5 min (eye)
  15:00   15:00 / 5:00     3.00  [##########|!!!!!!!!!!]    2   BREAK DUE (eye)
```

A bad script is refused outright rather than skipped over — a typo like `snoze`
would otherwise run a different scenario and print a trace that looks fine.

Ops: `eye`/`move <dur>` set an interval, `eyeoff`/`moveoff` turn one off, `nudges`
turns on-call nudges on, `work`/`call`/`lock`/`pause <dur>` pass time,
`lostunlock <dur>` drops the unlock notification to test the watchdog, and
`snooze`/`skip`/`done`/`interrupt` answer the break that's on screen. It runs
against a throwaway settings domain, so a simulation can never change your real
configuration.

## Files

- `Sources/pace/Settings.swift` — one typed store over UserDefaults.
- `Sources/pace/Signals.swift` — mic-in-use (CoreAudio) + idle (IOKit).
- `Sources/pace/Scheduler.swift` — the 1-second loop, guards, counters.
- `Sources/pace/BreakOverlay.swift` — the dismissible overlay window.
- `Sources/pace/AppDelegate.swift` — status item + menu.
- `Sources/pace/IconMaker.swift` — menu-bar glyph + app icon.
- `Sources/pace/Sim.swift` — the fake-clock harness behind `--sim`.
- `Sources/pace/SelfTest.swift` — the asserted invariants behind `--selftest`.
- `make-app.sh` — build the self-contained bundle.

## When something goes wrong

Failures are visible and temporary, never silent and never fatal:

- **Vault writes** happen off the main thread, so a folder on an unmounted
  network volume can't stall the break timer. If a write fails, *Reporting* in
  the menu says so and why, and the next break tries again — a volume that comes
  back heals itself with no intervention.
- **A dropped screen-unlock notification** used to wedge the app in "away"
  forever. Now, if it thinks the screen is locked while human input is arriving,
  it concludes you're back and carries on.
- **The break window** has an independent watchdog on top of its countdown, so it
  cannot outlive its own clock and sit over your screen.

## What it's allowed to do

Not sandboxed, and worth saying out loud rather than leaving implied. pace reads
audio-device and camera *state* (never a stream), the system idle counter, and
whatever folder you point it at for Obsidian notes. It writes its log under
Application Support and that one folder. **It opens no network connections at
all**, so nothing it reads can leave the machine.

## Known edge

If an app fully releases the microphone while you're muted *and* your camera is
off, pace can't tell you're in a call (mic is the only signal). Rare in practice;
mute keeps the device stream open in every mainstream tool. You can always Pause.
