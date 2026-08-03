import AppKit
import SwiftUI

/// View-model for one break window. The controller ticks `remaining` down; the
/// view just renders it.
final class BreakVM: ObservableObject {
    let kind: BreakKind
    let prompt: Prompt
    @Published var remaining: Int
    var onSkip: () -> Void = {}
    var onSnooze: () -> Void = {}
    var onDone: () -> Void = {}
    init(kind: BreakKind, remaining: Int) {
        self.kind = kind
        self.remaining = remaining
        self.prompt = Tips.random(for: kind)
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
            HStack(spacing: 12) {
                Button("Skip") { vm.onSkip() }
                    .keyboardShortcut(.cancelAction)      // Esc
                Button("+5 min") { vm.onSnooze() }
                Button(vm.kind.doneLabel) { vm.onDone() }
                    .keyboardShortcut(.defaultAction)     // Return — already did it, credit the break
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
/// (Skip button, Esc, or a local key monitor as a hard fallback) and always
/// auto-closes when the countdown ends, so it can never trap the user. It also
/// bows out if a call starts while it's up.
final class OverlayController {
    private var window: BreakWindow?
    private var vm: BreakVM?
    private var countdown: Timer?
    private var escMonitor: Any?
    private var currentKind: BreakKind?
    private(set) var isShowing = false

    /// Called with the reason when a break ends (completed / skipped / snoozed).
    var onEnd: ((BreakKind, BreakEndReason) -> Void)?

    func show(_ kind: BreakKind) {
        guard !isShowing else { return }
        isShowing = true
        currentKind = kind

        let vm = BreakVM(kind: kind, remaining: kind.durationSec)
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

        // Hard fallback so Esc always works regardless of SwiftUI focus.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(.skipped); return nil }   // 53 == Esc
            return event
        }

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        countdown = t
    }

    /// Close the window immediately (used when a call starts mid-break).
    func dismissForMeeting() {
        guard isShowing else { return }
        dismiss(.skipped)
    }

    private func step() {
        guard let vm else { return }
        vm.remaining -= 1
        if vm.remaining <= 0 { dismiss(.completed) }
    }

    private func dismiss(_ reason: BreakEndReason) {
        guard isShowing, let kind = currentKind else { return }
        isShowing = false
        countdown?.invalidate(); countdown = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        // Gentle "done" chime so you know the break ended with your eyes closed
        // or mid-stretch. Only on a natural finish, not a skip.
        if reason == .completed, Settings.endChime { NSSound(named: "Glass")?.play() }
        window?.orderOut(nil)
        window = nil
        vm = nil
        currentKind = nil
        onEnd?(kind, reason)
    }
}

/// Minimal delegate behind `pace --demo`: pops one break overlay so you can see
/// (and dismiss) it without waiting out an interval, then quits. Also serves as
/// the overlay smoke-test.
final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.onEnd = { _, _ in NSApp.terminate(nil) }
        overlay.show(.eye)
    }
}
