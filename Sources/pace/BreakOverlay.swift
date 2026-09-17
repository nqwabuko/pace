import AppKit
import SwiftUI

/// What the card is showing, as one value the view observes. The model is built
/// by `Card.model`, so the view never derives anything: it draws what it is
/// given, and the thing it is given can be checked without a screen.
final class BreakVM: ObservableObject {
    @Published var model: Card.Model
    var send: (Card.Event) -> Void = { _ in }
    init(model: Card.Model) { self.model = model }
}

private struct BreakView: View {
    @ObservedObject var vm: BreakVM

    var body: some View {
        ZStack {
            // Click anywhere off the card to skip — a permission-free escape
            // hatch that doesn't depend on focus or the countdown timer.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.send(.clickedOff) }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var m: Card.Model { vm.model }

    private var card: some View {
        VStack(spacing: 22) {
            GooglyEyesView(eyeSize: 52)
                .frame(height: 60)
            Text(m.title)
                .font(.system(size: 30, weight: .semibold))
            if m.story {
                VStack(spacing: 12) {
                    ChainView(model: m)
                    if let line = m.line {
                        Text(line)
                            .font(.system(size: 15, weight: .medium))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, -10)
            }

            VStack(spacing: 8) {
                Text(m.prompt.line)
                    .font(.system(size: 17, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(m.prompt.source)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                Text(m.prompt.why)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text(m.clock)
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
                Button("Skip  ⌘S") { vm.send(.key(.skip)) }
                    .keyboardShortcut(.cancelAction)      // draws it as the escape button
                Button("+5 min  ⌘5") { vm.send(.key(.snooze)) }
                Button("\(m.doneLabel)  ⌘D") { vm.send(.key(.done)) }
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

}

/// A borderless window that can take key focus (needed so Esc/Return work).
private final class BreakWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The shell around `Card`: it owns the window, the two clocks, the key monitor
/// and the sounds, and it owns no rules at all. Everything that happens arrives
/// as a `Card.Event`, the machine says what the new state is and what to do, and
/// this performs it.
///
/// The guards that used to be scattered through here — don't stack a second
/// card, don't dismiss one that isn't up, don't credit a rest twice — are not
/// guards any more. They are cases in `Card.next`, which is why they can be
/// checked without a screen.
final class OverlayController {
    private var state = Card.State.idle
    private var window: BreakWindow?
    private var vm: BreakVM?
    private var countdown: Timer?
    private var watchdog: Timer?
    private var keyMonitor: Any?

    /// Called with the reason when a break ends (completed / skipped / snoozed /
    /// interrupted).
    var onEnd: ((BreakKind, BreakEndReason) -> Void)?

    var isShowing: Bool { state.session != nil }

    func show(_ kind: BreakKind, trail: [Loop.Mark] = [], overdueSec: Int = 0) {
        // The impure half of opening a card, and all of it is here: the clock, the
        // preference that sets the length, and the one random draw of the prompt.
        // From this line on the card is a function of that value.
        send(.show(Card.Session(
            kind: kind, trail: trail, overdueSec: overdueSec,
            durationSec: kind.durationSec, startedAt: Date(), prompt: Tips.random(for: kind))))
    }

    /// Close the window immediately (used when a call starts mid-break). Logged as
    /// `interrupted`, not `skipped`: the user didn't refuse anything, so it must
    /// not read as an ignored break in the stats.
    func dismissForMeeting() { send(.callStarted) }

    private func send(_ event: Card.Event) {
        let (next, effects) = Card.next(state, event)
        state = next
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: Card.Effect) {
        switch effect {
        case .startChime:
            if Settings.bool(.soundEnabled) { NSSound(named: "Tink")?.play() }

        case .endChime:
            // Gentle "done" chime so you know the break ended with your eyes closed
            // or mid-stretch. Only on a natural finish, not a skip.
            if Settings.endChime { NSSound(named: "Glass")?.play() }

        case .open(let session):
            open(session)

        case .remaining(let seconds):
            if let s = state.session { vm?.model = Card.model(s, remaining: seconds) }

        case .close:
            countdown?.invalidate(); countdown = nil
            watchdog?.invalidate(); watchdog = nil
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            window?.orderOut(nil)
            window = nil
            vm = nil

        case .ended(let kind, let reason):
            onEnd?(kind, reason)
        }
    }

    private func open(_ session: Card.Session) {
        let vm = BreakVM(model: Card.model(session, remaining: session.durationSec))
        vm.send = { [weak self] event in self?.send(event) }
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

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Every shortcut goes through the monitor, so none of them depend on
        // SwiftUI focus landing where we hoped. Consuming the event also stops a
        // button's own shortcut firing the same action a second time.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = BreakKey.action(for: event) else { return event }
            self?.send(.key(action))
            return nil
        }

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.send(.tick(Date())) }
        RunLoop.main.add(t, forMode: .common)
        countdown = t

        // Independent one-shot backstop. A full-screen window that covers the whole
        // display must never be able to outlive its own countdown, so a second
        // clock ends it even if the first never fires again. It sends `.timeUp`
        // rather than another `.tick`: a tick is a question about the wall clock,
        // and a clock that steps backwards would answer "still a minute to run"
        // and leave the card up. This one is not a question.
        let w = Timer(timeInterval: Double(session.durationSec) + 5, repeats: false) { [weak self] _ in
            self?.send(.timeUp)
        }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w
    }
}

/// `pace --break-preview <path> [marks…]`: render the card offscreen to a PNG.
/// The chain only means anything in the states it moulds to, and the only way to
/// see those on a real machine is to put off four breaks over an hour — or to
/// render them. Offscreen deliberately: judging this must not need a full-screen
/// window landing over whatever you were doing.
enum BreakPreview {
    static func write(to path: String, kind: BreakKind, trail: [Loop.Mark], overdueSec: Int,
                      size: CGSize = CGSize(width: 620, height: 860)) -> Bool {
        _ = NSApplication.shared
        let session = Card.Session(
            kind: kind, trail: trail, overdueSec: overdueSec, durationSec: kind.durationSec,
            startedAt: Date(), prompt: Tips.random(for: kind))
        let vm = BreakVM(model: Card.model(session, remaining: session.durationSec))
        // An opaque desk colour behind the same dim the real window paints, because
        // `cacheDisplay` has no desktop to blend the card's material against.
        let root = ZStack {
            Color(nsColor: .underPageBackgroundColor)
            Color.black.opacity(0.55)
            BreakView(vm: vm)
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
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
