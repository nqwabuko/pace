import AppKit
import SwiftUI

/// What a key press on the break card means. Kept as a pure mapping off the two
/// things a key event actually carries, so the self-test can assert the whole
/// keyboard without a window on screen — and so there is exactly one place
/// that decides what ⌘S does.
enum BreakKey {
    case skip, snooze, done

    static let escKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]   // Return, and the keypad's Enter

    static func action(keyCode: UInt16, chars: String?, flags: NSEvent.ModifierFlags) -> BreakKey? {
        // Esc and Return usually never reach here — SwiftUI's cancel/default
        // actions claim them first — but a window that covers the whole screen
        // has to answer to them even if that stops being true.
        if keyCode == escKeyCode { return .skip }   // Esc, whatever is held with it
        if returnKeyCodes.contains(keyCode) { return .done }
        // Command and nothing else that a person chose to hold: ⌘⌥S belongs to
        // whatever the user has bound it to, not to us. Caps lock isn't one of
        // those choices, so it isn't allowed to break the shortcut.
        guard flags.intersection([.command, .shift, .option, .control]) == .command else { return nil }
        switch chars?.lowercased() {
        case "s": return .skip
        case "5": return .snooze
        case "d": return .done
        default: return nil
        }
    }

    static func action(for event: NSEvent) -> BreakKey? {
        action(keyCode: event.keyCode, chars: event.charactersIgnoringModifiers, flags: event.modifierFlags)
    }
}

/// View-model for one break window. The controller ticks `remaining` down; the
/// view just renders it.
final class BreakVM: ObservableObject {
    let kind: BreakKind
    let prompt: Prompt
    let refusals: Int          // times this break has been put off since you last took one
    @Published var remaining: Int
    var onSkip: () -> Void = {}
    var onSnooze: () -> Void = {}
    var onDone: () -> Void = {}
    init(kind: BreakKind, remaining: Int, refusals: Int) {
        self.kind = kind
        self.remaining = remaining
        self.refusals = refusals
        self.prompt = Tips.random(for: kind)
    }

    /// Said once, plainly, when you've put this one off before. Not a scold: the
    /// point is that extending is no longer invisible.
    var debtLine: String? {
        guard refusals > 0 else { return nil }
        return refusals == 1
            ? "You put this one off once already."
            : "You've put this one off \(refusals) times."
    }
}

private struct BreakView: View {
    @ObservedObject var vm: BreakVM

    var body: some View {
        ZStack {
            // Click anywhere off the card to skip — a permission-free escape
            // hatch that doesn't depend on focus or the countdown timer.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.onSkip() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(spacing: 22) {
            GooglyEyesView(eyeSize: 52)
                .frame(height: 60)
            Text(vm.kind.title)
                .font(.system(size: 30, weight: .semibold))
            if let debt = vm.debtLine {
                Text(debt)
                    .font(.system(size: 15, weight: .medium))
                    .padding(.top, -12)
            }

            VStack(spacing: 8) {
                Text(vm.prompt.line)
                    .font(.system(size: 17, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(vm.prompt.source)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                Text(vm.prompt.why)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text(clock(vm.remaining))
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
                .padding(.top, 4)
            // The shortcut sits in the label rather than in a legend under the
            // buttons: one glance, full size, nothing greyed out. The two
            // modifiers below are load-bearing, not decoration: driving a real
            // card with synthetic keys shows SwiftUI swallowing Esc before the
            // key monitor is ever offered it, so deleting `.cancelAction` would
            // quietly delete Esc.
            HStack(spacing: 12) {
                Button("Skip  ⌘S") { vm.onSkip() }
                    .keyboardShortcut(.cancelAction)      // draws it as the escape button
                Button("+5 min  ⌘5") { vm.onSnooze() }
                Button("\(vm.kind.doneLabel)  ⌘D") { vm.onDone() }
                    .keyboardShortcut(.defaultAction)     // draws it as the default button
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(52)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .shadow(radius: 40)
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

/// A borderless window that can take key focus (needed so Esc/Return work).
private final class BreakWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows exactly one break window at a time. The window is always dismissible
/// (the buttons, Esc, ⌘S, or a click off the card — the ⌘ keys read by a
/// monitor, so they don't depend on where focus landed) and always
/// auto-closes when the countdown ends, so it can never trap the user. It also
/// bows out if a call starts while it's up.
final class OverlayController {
    private var window: BreakWindow?
    private var vm: BreakVM?
    private var countdown: Timer?
    private var watchdog: Timer?
    private var keyMonitor: Any?
    private var currentKind: BreakKind?
    private var startedAt: Date?
    private var durationSec = 0
    private(set) var isShowing = false

    /// Called with the reason when a break ends (completed / skipped / snoozed /
    /// interrupted).
    var onEnd: ((BreakKind, BreakEndReason) -> Void)?

    func show(_ kind: BreakKind, refusals: Int = 0) {
        guard !isShowing else { return }
        isShowing = true
        currentKind = kind
        durationSec = kind.durationSec
        startedAt = Date()

        let vm = BreakVM(kind: kind, remaining: durationSec, refusals: refusals)
        vm.onSkip = { [weak self] in self?.dismiss(.skipped) }
        vm.onSnooze = { [weak self] in self?.dismiss(.snoozed) }
        vm.onDone = { [weak self] in self?.dismiss(.completed) }   // already did it: credit + chime
        self.vm = vm

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let win = BreakWindow(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.contentView = NSHostingView(rootView: BreakView(vm: vm))
        win.setFrame(screen.frame, display: true)
        window = win

        if Settings.bool(.soundEnabled) { NSSound(named: "Tink")?.play() }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Every shortcut goes through the monitor, so none of them depend on
        // SwiftUI focus landing where we hoped. Consuming the event also stops a
        // button's own shortcut firing the same action a second time.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = BreakKey.action(for: event) else { return event }
            switch action {
            case .skip:   self?.dismiss(.skipped)
            case .snooze: self?.dismiss(.snoozed)
            case .done:   self?.dismiss(.completed)
            }
            return nil
        }

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        countdown = t

        // Independent one-shot backstop. A full-screen window that covers the
        // whole display must never be able to outlive its own countdown, so a
        // second timer closes it even if the first never fires again.
        let w = Timer(timeInterval: Double(durationSec) + 5, repeats: false) { [weak self] _ in
            self?.dismiss(.completed)
        }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w
    }

    /// Close the window immediately (used when a call starts mid-break). Logged as
    /// `interrupted`, not `skipped`: the user didn't refuse anything, so it must
    /// not read as an ignored break in the stats.
    func dismissForMeeting() {
        guard isShowing else { return }
        dismiss(.interrupted)
    }

    /// Recompute what's left from the clock rather than counting ticks, so a
    /// starved run loop or a slept machine can't leave the countdown wrong (or
    /// stuck) — it just catches up on the next fire.
    private func step() {
        guard let vm, let startedAt else { return }
        let left = Double(durationSec) - Date().timeIntervalSince(startedAt)
        let whole = Int(left.rounded(.up))
        if whole != vm.remaining { vm.remaining = max(0, whole) }
        if left <= 0 { dismiss(.completed) }
    }

    private func dismiss(_ reason: BreakEndReason) {
        guard isShowing, let kind = currentKind else { return }
        isShowing = false
        countdown?.invalidate(); countdown = nil
        watchdog?.invalidate(); watchdog = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        // Gentle "done" chime so you know the break ended with your eyes closed
        // or mid-stretch. Only on a natural finish, not a skip.
        if reason == .completed, Settings.endChime { NSSound(named: "Glass")?.play() }
        window?.orderOut(nil)
        window = nil
        vm = nil
        currentKind = nil
        startedAt = nil
        onEnd?(kind, reason)
    }
}

/// Minimal delegate behind `pace --demo`: pops one break overlay so you can see
/// (and dismiss) it without waiting out an interval, then quits. Also serves as
/// the overlay smoke-test — it prints how the break ended, so a keypress driven
/// from the outside can be checked against what the card actually did rather
/// than against the fact that a window went away.
final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.onEnd = { kind, reason in
            print("\(kind.label) break ended: \(reason.logName)")
            NSApp.terminate(nil)
        }
        overlay.show(.eye)
    }
}
