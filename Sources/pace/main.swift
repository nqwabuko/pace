import AppKit

// Entry point. Two headless modes for the build script and for a quick
// self-test; otherwise launch the menu-bar app.
let args = CommandLine.arguments

// `--make-icon <path>`: render the 1024px app icon and exit (used by make-app.sh).
if let i = args.firstIndex(of: "--make-icon") {
    let out = i + 1 < args.count ? args[i + 1] : "pace-icon.png"
    exit(IconMaker.writeAppIcon(to: out) ? 0 : 1)
}

// `--parse "<text>"`: show how the natural-language entry resolves, and exit.
// The parser's test harness (and a way to see exactly what any phrase does).
if let i = args.firstIndex(of: "--parse") {
    Settings.registerDefaults()
    let text = args[(i + 1)...].joined(separator: " ")
    if let cmd = TimeParser.parse(text, now: Date(), calendar: .current) { print(cmd.human) } else { print("(couldn't parse)") }
    exit(0)
}

// `--make-menuicon <path> [paused] [dark] [nudge] [call] [cracks <0…3>] [strain <0…2>] [move <0…2>]`:
// render the menu-bar glyph big for review. `move` is the movement gauge: leave it
// out and movement is not tracked, which is its own reading and draws no figure.
// (It replaces the old `foot` keyword, which could only say missed / not missed.)
if let i = args.firstIndex(of: "--make-menuicon") {
    let out = i + 1 < args.count ? args[i + 1] : "menuicon.png"
    let strain = args.firstIndex(of: "strain").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
    let move = args.firstIndex(of: "move").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    let missed = args.firstIndex(of: "missed").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
    let state = IconMaker.GlyphState(eye: CGFloat(strain), move: move.map { CGFloat($0) }, missed: missed,
                                     onCall: args.contains("call"), paused: args.contains("paused"),
                                     nudge: args.contains("nudge"))
    exit(IconMaker.writeMenuIconPreview(to: out, state: state, dark: args.contains("dark")) ? 0 : 1)
}

// `--make-damagestrip <path> [dark]`: render every damage state against every
// strain as one grid, to judge what still reads at true bar size.
if let i = args.firstIndex(of: "--make-damagestrip") {
    let out = i + 1 < args.count ? args[i + 1] : "damagestrip.png"
    exit(IconMaker.writeDamageStrip(to: out, dark: args.contains("dark")) ? 0 : 1)
}

// `--make-strainstrip <path> [dark]`: render the pupil-dilation sequence as one
// strip, big plus actual size, to judge how it reads in the bar.
if let i = args.firstIndex(of: "--make-strainstrip") {
    let out = i + 1 < args.count ? args[i + 1] : "strainstrip.png"
    let stages = args.firstIndex(of: "stages").map { i in
        args[(i + 1)...].compactMap { Double($0) }.map { CGFloat($0) }
    }.flatMap { $0.isEmpty ? nil : $0 }
    exit((stages.map { IconMaker.writeStrainStrip(to: out, dark: args.contains("dark"), stages: $0) }
          ?? IconMaker.writeStrainStrip(to: out, dark: args.contains("dark"))) ? 0 : 1)
}

// `--feedback <bug|idea> <note…>`: log a bug/idea from the terminal.
if let i = args.firstIndex(of: "--feedback"), i + 2 < args.count, let kind = FeedbackKind(rawValue: args[i + 1]) {
    Settings.registerDefaults()
    Feedback.log(kind: kind, note: args[(i + 2)...].joined(separator: " "), mirrorVault: Settings.vaultPath)
    print("logged to \(Feedback.fileURL.path)")
    exit(0)
}

// `--report-demo <dir> [yyyy-mm-dd]`: render a folder of sample Obsidian notes to
// preview the reporting format, without touching the real log.
//
// The sample fortnight is generated backwards from `now`, so with no date the whole
// tree renames itself every midnight. That is right for a human previewing the format
// and useless for `check.sh`, which has to diff this against a stored baseline. The
// optional date pins it. Noon, so a clock going forward or back an hour can't tip the
// day either way.
if let i = args.firstIndex(of: "--report-demo"), i + 1 < args.count {
    var when = Date()
    if i + 2 < args.count {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: args[i + 2]) else {
            FileHandle.standardError.write(Data("report-demo: '\(args[i + 2])' is not yyyy-mm-dd\n".utf8))
            exit(2)
        }
        when = day.addingTimeInterval(12 * 3600)
    }
    Report.previewVault(at: args[i + 1], now: when)
    print("wrote sample vault to \(args[i + 1])/pace/")
    exit(0)
}

// `--stats-preview <path>`: render the stats window to a PNG off sample data, so
// the reporting can be reviewed without opening a window over your work.
if let i = args.firstIndex(of: "--stats-preview"), i + 1 < args.count {
    Settings.registerDefaults()
    // Height is optional so the whole scroll (now that "Held by calls" has been
    // added below the fold) can be captured in one shot for review.
    let h = i + 2 < args.count ? (Int(args[i + 2]) ?? 900) : 900
    // `--real` renders the actual log instead, which is how you reproduce a stats
    // window that looks wrong on this machine without opening it over the desktop.
    let now = Date()
    let evs = args.contains("--real") ? Report.events() : Report.sampleEvents(now: now)
    let ok = StatsPreview.write(to: args[i + 1], s: Report.summary(from: evs, now: now), height: h)
    print(ok ? "wrote \(args[i + 1])" : "failed to render")
    exit(ok ? 0 : 1)
}

// `--nudge-test`: post one real on-call nudge and print what became of it.
// `--check` says what macOS *allows*; this proves the whole path, which is the
// only way to tell a banner you missed from one that was never drawn. It writes
// nothing to the log, because nothing about it is a break you owed.
if args.contains("--nudge-test") {
    Settings.registerDefaults()
    var result: Delivery?
    Notify.post(title: "Rest your eyes", body: Tips.callCue(for: .eye), id: "pace-nudge-test") { result = $0 }
    let deadline = Date().addingTimeInterval(5)
    while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print(result?.human ?? "no answer in 5s — the notification centre never called back")
    exit(result?.sent == true ? 0 : 1)
}

// `--activity [days]`: print the action log — what pace did, in order, and what
// became of each on-call nudge. The same rows the window shows, from the same
// pure builder, so the terminal and the window can't tell you different stories.
if let i = args.firstIndex(of: "--activity") {
    Settings.registerDefaults()
    let days = i + 1 < args.count ? (Int(args[i + 1]) ?? 7) : 7
    // Asking macOS needs a bundle and a run loop; from a bare binary the honest
    // answer is `.noBundle`, which is what `Notify.permission` gives back at once.
    var permission: Permission?
    Notify.permission { permission = $0 }
    let deadline = Date().addingTimeInterval(2)
    while permission == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let log = Activity.log(Report.events(), now: Date(), daysBack: days, permission: permission ?? .noBundle)
    print(Activity.plainText(log))
    exit(0)
}

// `--activity-preview <path> [height]`: render the activity window offscreen.
if let i = args.firstIndex(of: "--activity-preview"), i + 1 < args.count {
    Settings.registerDefaults()
    let h = i + 2 < args.count ? (Int(args[i + 2]) ?? 900) : 900
    let log = Activity.log(Report.events(), now: Date(), permission: .allowed(alerts: true))
    let ok = ActivityPreview.write(to: args[i + 1], view: ActivityView(log: log), height: h)
    print(ok ? "wrote \(args[i + 1])" : "failed to render")
    exit(ok ? 0 : 1)
}

// `--break-preview <path> [move] [dark] [overdue <min>] [snoozed|skipped|held|interrupted …]`:
// render the break card offscreen with a given trail, to judge how the chain
// reads in each state it moulds to.
if let i = args.firstIndex(of: "--break-preview"), i + 1 < args.count {
    Settings.registerDefaults()
    let rest = Array(args[(i + 2)...])
    let overdue = rest.firstIndex(of: "overdue").flatMap { $0 + 1 < rest.count ? Int(rest[$0 + 1]) : nil } ?? 0
    let trail = rest.compactMap { Loop.Mark(rawValue: $0) }
    if rest.contains("dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
    let ok = BreakPreview.write(to: args[i + 1], kind: rest.contains("move") ? .move : .eye,
                                trail: trail, overdueSec: overdue * 60)
    print(ok ? "wrote \(args[i + 1])" : "failed to render")
    exit(ok ? 0 : 1)
}

// `--sim ["<script>"]`: drive the scheduler off a fake clock and print the trace.
// The loop's test harness — see Sim.swift for the script language.
if let i = args.firstIndex(of: "--sim") {
    let script = args[(i + 1)...].joined(separator: " ")
    exit(Sim.run(script.isEmpty ? Sim.defaultScript : script))
}

// `--selftest`: assert the mechanical invariants (glyph weight, the extend-a-break
// loop, vault-health folding) and exit non-zero on failure.
if args.contains("--selftest") {
    SelfTest.dumpCurve = args.contains("verbose")
    exit(SelfTest.run())
}

// `--check [<vault-path>]`: print the environmental signals and exit. Lets you
// verify meeting and idle detection without the GUI (start a call, run it, see
// mic-in-use flip), and check whether a folder actually works as a vault.
if let ci = args.firstIndex(of: "--check") {
    Settings.registerDefaults()
    print("in a call  : \(Signals.inCall())   (mic: \(Signals.micInUse()))")
    print("idle (s)   : \(String(format: "%.1f", Signals.idleSeconds()))")
    print("login item : \(LoginItem.enabled.map(String.init) ?? "n/a — ask the installed app, not this binary")")
    // Whether an on-call nudge can reach the desktop at all. Asked of macOS, not
    // assumed: this is the difference between a nudge you missed and one that was
    // never shown, and from a bare binary there is no bundle to ask about.
    var permission: Permission?
    Notify.permission { permission = $0 }
    let deadline = Date().addingTimeInterval(2)
    while permission == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print("notifs     : \(permission?.human ?? "no answer in 2s")")
    let vault = ci + 1 < args.count ? args[ci + 1] : Settings.vaultPath
    print("vault      : \(vault.isEmpty ? "not logging" : vault)")
    if !vault.isEmpty { print("vault write: \(Report.probeVault(vault, now: Date()) ?? "OK")") }
    exit(0)
}

// `--demo`: preview one break overlay (5s) and quit. Handy to see it, and the
// overlay smoke-test.
if args.contains("--demo") {
    // A scratch settings domain, so previewing the overlay can't leave your real
    // break length set to five seconds.
    UserDefaults.standard.removePersistentDomain(forName: "global.ampeco.pace.demo")
    Settings.store = UserDefaults(suiteName: "global.ampeco.pace.demo") ?? .standard
    Settings.registerDefaults()
    Settings.set(.eyeDurationSec, 5)
    let app = NSApplication.shared
    let demo = DemoDelegate()
    app.delegate = demo
    app.setActivationPolicy(.accessory)
    app.run()
}

Settings.registerDefaults()
Settings.migrateBreakLengths()   // one-time bump of an existing install to the new lengths
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
