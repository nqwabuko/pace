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
    if let cmd = TimeParser.parse(text) { print(cmd.human) } else { print("(couldn't parse)") }
    exit(0)
}

// `--make-menuicon <path> [paused] [dark]`: render the menu-bar glyph big for review.
if let i = args.firstIndex(of: "--make-menuicon") {
    let out = i + 1 < args.count ? args[i + 1] : "menuicon.png"
    exit(IconMaker.writeMenuIconPreview(to: out, paused: args.contains("paused"), dark: args.contains("dark"), nudge: args.contains("nudge")) ? 0 : 1)
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
    Report.previewVault(at: args[i + 1])
    print("wrote sample vault to \(args[i + 1])/pace/")
    exit(0)
}

// `--check`: print the environmental signals and exit. Lets you verify meeting
// and idle detection without the GUI (start a call, run it, see mic-in-use flip).
if args.contains("--check") {
    Settings.registerDefaults()
    print("in a call  : \(Signals.inCall())   (mic: \(Signals.micInUse()))")
    print("idle (s)   : \(String(format: "%.1f", Signals.idleSeconds()))")
    print("login item : \(LoginItem.isEnabled)")
    exit(0)
}

// `--demo`: preview one break overlay (5s) and quit. Handy to see it, and the
// overlay smoke-test.
if args.contains("--demo") {
    Settings.registerDefaults()
    UserDefaults.standard.set(5, forKey: Settings.Key.eyeDurationSec.rawValue)
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
