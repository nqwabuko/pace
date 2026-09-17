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

// `--make-menuicon <path> [paused] [dark] [nudge] [call] [foot] [cracks <0…3>] [strain <0…2>]`:
// render the menu-bar glyph big for review.
if let i = args.firstIndex(of: "--make-menuicon") {
    let out = i + 1 < args.count ? args[i + 1] : "menuicon.png"
    let strain = args.firstIndex(of: "strain").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
    let cracks = args.firstIndex(of: "cracks").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
    exit(IconMaker.writeMenuIconPreview(to: out, paused: args.contains("paused"), dark: args.contains("dark"), nudge: args.contains("nudge"), strain: CGFloat(strain), cracks: cracks, foot: args.contains("foot"), onCall: args.contains("call")) ? 0 : 1)
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

// `--report-demo <dir>`: render a folder of sample Obsidian notes to preview the
// reporting format, without touching the real log.
if let i = args.firstIndex(of: "--report-demo"), i + 1 < args.count {
    Report.previewVault(at: args[i + 1], now: Date())
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
