import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let scheduler = Scheduler()
    private let overlay = OverlayController()
    private let popover = NSPopover()
    private let popModel = PopoverModel()
    private var menu: NSMenu!
    private var statsWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var nudgeUntil: Date?
    private var iconKey: String?   // last-drawn glyph state, so the 1s tick redraws only on a visible change
    private var lastStatus: Scheduler.Status?   // latest tick, so a closing break can log what it owed
    private let notificationsAvailable = Bundle.main.bundleURL.pathExtension == "app"

    // Menu items we update live / on open.
    private let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let eyeItem = NSMenuItem(title: "Eye breaks", action: #selector(toggleEye), keyEquivalent: "")
    private let moveItem = NSMenuItem(title: "Move breaks", action: #selector(toggleMove), keyEquivalent: "")
    private let meetingItem = NSMenuItem(title: "Pause during calls", action: #selector(toggleMeeting), keyEquivalent: "")
    private let callBreaksItem = NSMenuItem(title: "On-call nudges (keep breaks during calls)", action: #selector(toggleCallBreaks), keyEquivalent: "")
    private let idleItem = NSMenuItem(title: "Reset after a long break away", action: #selector(toggleIdle), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "Sound when a break starts", action: #selector(toggleSound), keyEquivalent: "")
    private let endChimeItem = NSMenuItem(title: "Chime when a break ends", action: #selector(toggleEndChime), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")
    private let vaultItem = NSMenuItem(title: "", action: #selector(rebuildReport), keyEquivalent: "")
    private var eyeEvery: NSMenuItem!
    private var eyeLen: NSMenuItem!
    private var moveEvery: NSMenuItem!
    private var moveLen: NSMenuItem!
    private var awayReset: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = IconMaker.statusImage(paused: false)
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu = buildMenu()   // built, shown on right-click (not assigned to statusItem.menu)

        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(model: popModel))
        host.sizingOptions = [.preferredContentSize]   // size the popover to the SwiftUI content (else it defaults to 320x320 and floats off-anchor)
        popover.contentViewController = host
        popModel.onSubmit = { [weak self] in self?.handleCommand($0) }
        popModel.onEyeNow = { [weak self] in self?.scheduler.triggerNow(.eye); self?.popover.performClose(nil) }
        popModel.onMoveNow = { [weak self] in self?.scheduler.triggerNow(.move); self?.popover.performClose(nil) }
        popModel.onPauseHour = { [weak self] in self?.scheduler.pause(for: 3600) }
        popModel.onResume = { [weak self] in self?.scheduler.resume() }
        popModel.onStats = { [weak self] in self?.popover.performClose(nil); self?.showStats() }
        popModel.onFeedback = { [weak self] in self?.popover.performClose(nil); self?.showFeedback() }

        overlay.onEnd = { [weak self] kind, reason in
            guard let self else { return }
            self.scheduler.overlayShowing = false
            // Read the debt before resolving, not after: `breakFinished` either
            // clears it or adds to it, and what belongs on the record is how far
            // past due you were at the moment you decided what to do about it.
            let owed = self.lastStatus?.gauge(kind)
            self.scheduler.breakFinished(kind, reason)
            let now = Date()
            Report.log(kind: kind.label, outcome: reason.logName,
                       seconds: reason == .completed ? kind.durationSec : 0,
                       overdueSec: owed?.overdue, refusals: owed?.refusals,
                       callSec: owed?.callHeldSec, now: now)
            let vault = Settings.vaultPath
            if !vault.isEmpty { Report.updateVault(vault, now: now) }
        }
        scheduler.onAwayRest = { credits, awaySec in
            let now = Date()
            for g in credits {
                Report.log(kind: g.kind.label, outcome: "rested", seconds: awaySec,
                           overdueSec: g.overdue, refusals: g.refusals,
                           callSec: g.callHeldSec, now: now)
            }
            if !Settings.vaultPath.isEmpty { Report.updateVault(Settings.vaultPath, now: now) }
        }
        scheduler.onBreakDue = { [weak self] kind, trail in
            guard let self else { return }
            self.scheduler.overlayShowing = true
            // The debt reading is the previous tick's: the break fires before this
            // tick's status goes out, so a second is the worst it can be behind.
            self.overlay.show(kind, trail: trail, overdueSec: self.lastStatus?.gauge(kind).overdue ?? 0)
        }
        scheduler.onMeetingDuringBreak = { [weak self] in self?.overlay.dismissForMeeting() }
        scheduler.onCallNudge = { [weak self] kind in self?.deliverCallNudge(kind) }
        scheduler.onTick = { [weak self] status in self?.render(status) }

        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            if Settings.callBreaks { ensureNotifPermission() }
        }

        // Screen lock / unlock drive the away/reset logic (safer than idle time).
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)

        scheduler.start()
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        // The two status lines below carry the numbers that matter, including how
        // far overdue you are. AppKit greys a disabled item, and greyed-out is not
        // an option for those, so nothing here is auto-disabled: they stay full
        // contrast with no action, rather than borrowing a no-op one.
        m.autoenablesItems = false

        m.addItem(headerItem)
        m.addItem(detailItem)
        m.addItem(.separator())

        add(m, "Take an eye break now", #selector(takeEyeNow))
        add(m, "Take a move break now", #selector(takeMoveNow))
        m.addItem(.separator())

        eyeItem.target = self
        m.addItem(eyeItem)
        eyeEvery = intervalSubmenu("Eye break: every", [15, 20, 25, 30], "min", #selector(setEyeEvery))
        eyeLen = intervalSubmenu("Eye break: for", [20, 30, 45], "sec", #selector(setEyeLen))
        m.addItem(eyeEvery); m.addItem(eyeLen)

        moveItem.target = self
        m.addItem(moveItem)
        moveEvery = intervalSubmenu("Move break: every", [30, 45, 50, 60, 90], "min", #selector(setMoveEvery))
        moveLen = intervalSubmenu("Move break: for", [30, 60, 120], "sec", #selector(setMoveLen))
        m.addItem(moveEvery); m.addItem(moveLen)
        m.addItem(.separator())

        for it in [meetingItem, callBreaksItem, idleItem, soundItem, endChimeItem] { it.target = self; m.addItem(it) }
        awayReset = intervalSubmenu("Reset if locked for", [10, 15, 20, 30, 45], "min", #selector(setAwayReset))
        m.addItem(awayReset)
        m.addItem(.separator())

        let reporting = NSMenuItem(title: "Reporting", action: nil, keyEquivalent: "")
        let rs = NSMenu()
        add(rs, "Show stats…", #selector(showStats))
        rs.addItem(.separator())
        vaultItem.target = self   // clicking it retries the write, which is what you'd want anyway
        rs.addItem(vaultItem)
        add(rs, "Log to Obsidian vault…", #selector(chooseVault))
        add(rs, "Open today's note", #selector(openToday))
        add(rs, "Open dashboard", #selector(openDashboard))
        add(rs, "Rebuild dashboard now", #selector(rebuildReport))
        rs.addItem(.separator())
        add(rs, "Stop logging to vault", #selector(stopLogging))
        reporting.submenu = rs
        m.addItem(reporting)
        m.addItem(.separator())

        let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
        let ps = NSMenu()
        pauseItem(ps, "For 30 minutes", 30 * 60)
        pauseItem(ps, "For 1 hour", 60 * 60)
        pauseItem(ps, "For 2 hours", 120 * 60)
        let tom = NSMenuItem(title: "Until tomorrow", action: #selector(pauseTomorrow), keyEquivalent: "")
        tom.target = self; ps.addItem(tom)
        pause.submenu = ps
        m.addItem(pause)
        resumeItem.target = self
        m.addItem(resumeItem)
        m.addItem(.separator())

        loginItem.target = self
        m.addItem(loginItem)
        m.addItem(.separator())
        add(m, "Log a bug or idea…", #selector(showFeedback))
        add(m, "About pace", #selector(about))
        add(m, "Quit pace", #selector(quit))
        return m
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    private func intervalSubmenu(_ title: String, _ values: [Int], _ unit: String, _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in values {
            let it = NSMenuItem(title: "\(v) \(unit)", action: sel, keyEquivalent: "")
            it.tag = v; it.target = self
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    private func pauseItem(_ menu: NSMenu, _ title: String, _ seconds: Int) {
        let it = NSMenuItem(title: title, action: #selector(pauseFor), keyEquivalent: "")
        it.tag = seconds; it.target = self
        menu.addItem(it)
    }

    // Refresh every checkmark/label when the menu opens.
    func menuWillOpen(_ menu: NSMenu) { refreshChecks() }

    private func refreshChecks() {
        eyeItem.state = Settings.eyeEnabled ? .on : .off
        moveItem.state = Settings.moveEnabled ? .on : .off
        meetingItem.state = Settings.meetingAware ? .on : .off
        callBreaksItem.state = Settings.callBreaks ? .on : .off
        idleItem.state = Settings.idleAware ? .on : .off
        soundItem.state = Settings.bool(.soundEnabled) ? .on : .off
        endChimeItem.state = Settings.endChime ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
        resumeItem.isEnabled = scheduler.isPaused
        vaultItem.title = vaultStatusLine()
        tick(eyeEvery, Settings.int(.eyeIntervalMin))
        tick(eyeLen, Settings.int(.eyeDurationSec))
        tick(moveEvery, Settings.int(.moveIntervalMin))
        tick(moveLen, Settings.int(.moveDurationSec))
        tick(awayReset, Settings.int(.awayResetMin))
    }

    /// Say plainly whether vault logging is working. A silent no-op for weeks is
    /// the failure mode this line exists to prevent.
    private func vaultStatusLine() -> String {
        guard !Settings.vaultPath.isEmpty else { return "Vault: not logging" }
        let h = Report.vaultHealth      // read when the menu opens; no second copy to keep in step
        if h.isFailing {
            let n = h.consecutiveFailures
            return "Vault: can't write (\(n) attempt\(n == 1 ? "" : "s")) — \(h.lastError ?? "unknown")"
        }
        return "Vault: OK\(h.lastSuccess.map { ", last write \(hm($0))" } ?? "")"
    }

    private func tick(_ parent: NSMenuItem, _ current: Int) {
        parent.submenu?.items.forEach { $0.state = ($0.tag == current) ? .on : .off }
    }

    // MARK: click routing

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if wantsMenu {
            if popover.isShown { popover.performClose(nil) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popModel.feedback = ""
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleCommand(_ text: String) {
        guard let cmd = TimeParser.parse(text, now: Date(), calendar: .current) else {
            popModel.feedback = "Couldn't read that. Try 20m, 1h 15m, @10am, pause 1h."
            return
        }
        scheduler.dispatch(cmd)
        popModel.feedback = "OK, \(cmd.human)."
    }

    // MARK: live status

    private func render(_ s: Scheduler.Status) {
        lastStatus = s
        let nudging = (nudgeUntil.map { $0 > Date() } ?? false) && !s.paused
        // The pupil widens over the eye interval, and past due the lid keeps
        // closing and the eye sags — so putting a break off again and again is
        // visible on the bar instead of free. The strain comes straight from the
        // scheduler's counter (seconds since your eyes actually rested), which is
        // why extending no longer snaps the icon back to rested.
        let strain = min(2.0, max(0, s.eye.strain))
        let step = Int((strain * 12).rounded())   // 24 steps over 0…2: a 1s tick only redraws on a visible change
        // Damage: what was owed and didn't happen. The eye's misses crack the rim,
        // a missed movement break presses a foot into the pupil — the one thing the
        // move gauge has ever had on the bar. Both outlive the call that held them,
        // so a call ending doesn't quietly wipe the debt off the icon.
        let cracks = min(IconMaker.maxCracks, s.eye.missed)
        let foot = s.move.enabled && s.move.missed > 0
        let key = "\(s.paused)-\(nudging)-\(step)-\(cracks)-\(foot)-\(s.meeting)"
        if key != iconKey {
            iconKey = key
            statusItem.button?.image = IconMaker.statusImage(
                paused: s.paused, nudge: nudging, strain: CGFloat(step) / 12,
                cracks: cracks, foot: foot, onCall: s.meeting)
        }

        let summary: String
        if s.paused {
            summary = s.pausedUntil.map { "Paused until \(hm($0))" } ?? "Paused"
        } else if s.meeting {
            summary = Settings.callBreaks ? "In a call, nudging gently" : "In a call, holding"
        } else if s.away {
            summary = "Away, break waiting for you"
        } else if s.inDebt {
            summary = overdueSummary(s)
        } else if let at = s.scheduledAt, isSooner(at, than: s) {
            summary = "Break at \(hm(at))"
        } else {
            summary = s.nextIn.map { "Next break in \(clock($0))" } ?? "No breaks enabled"
        }

        var bits: [String] = s.enabled.map { "\($0.name) \(reading($0))" }
        if let at = s.scheduledAt { bits.append("Scheduled \(hm(at))") }
        let detail = bits.isEmpty ? "All breaks off" : bits.joined(separator: "   ·   ")

        headerItem.title = summary
        detailItem.title = detail
        statusItem.button?.toolTip = "pace, \(summary)"
        popModel.statusText = summary
        popModel.detailText = detail
    }

    /// The header line when a break is owed. Says how far behind you are and, if
    /// you've been extending, how many times — the number the old build threw away
    /// every time it reset the counter.
    /// The header line when a break is owed. Says how far behind you are and, if
    /// you've been extending, how many times — the number the old build threw away
    /// every time it reset the counter. Which gauge is "worst" is the scheduler's
    /// call, not re-decided here.
    private func overdueSummary(_ s: Scheduler.Status) -> String {
        guard let g = s.worst else { return "No breaks enabled" }
        let late = "\(g.name) break \(clock(g.overdue)) overdue"
        return g.refusals > 0 ? "\(late), put off \(g.refusals)×" : late
    }

    /// One gauge as text: the countdown, or how far past due it has run. Overdue is
    /// shown as a plain "+m:ss over", never hidden or clamped to zero.
    private func reading(_ g: Scheduler.Gauge) -> String {
        g.overdue > 0 ? "+\(clock(g.overdue)) over" : clock(g.remaining)
    }

    private func isSooner(_ date: Date, than s: Scheduler.Status) -> Bool {
        guard let r = s.nextIn else { return true }
        return date.timeIntervalSinceNow < Double(r)
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: actions

    @objc private func takeEyeNow() { scheduler.triggerNow(.eye) }
    @objc private func takeMoveNow() { scheduler.triggerNow(.move) }
    @objc private func toggleEye() { Settings.toggle(.eyeEnabled) }
    @objc private func toggleMove() { Settings.toggle(.moveEnabled) }
    @objc private func toggleMeeting() { Settings.toggle(.meetingAware) }
    @objc private func toggleIdle() { Settings.toggle(.idleAware) }
    @objc private func toggleSound() { Settings.toggle(.soundEnabled) }
    @objc private func toggleEndChime() { Settings.toggle(.endChime) }
    @objc private func toggleCallBreaks() {
        Settings.toggle(.callBreaks)
        if Settings.callBreaks { ensureNotifPermission() }
    }

    // MARK: on-call nudges

    /// A due break arrived while on a call (on-call nudges on): flip the menu-bar
    /// eye to "look away" for ~30s and post a quiet, call-friendly notification.
    /// No sound (your mic would catch it); the icon is the private cue.
    private func deliverCallNudge(_ kind: BreakKind) {
        nudgeUntil = Date().addingTimeInterval(30)
        let owed = lastStatus?.gauge(kind)
        let now = Date()
        Report.log(kind: kind.label, outcome: "nudged", seconds: 0,
                   overdueSec: owed?.overdue, refusals: owed?.refusals,
                   callSec: owed?.callHeldSec, now: now)
        if !Settings.vaultPath.isEmpty { Report.updateVault(Settings.vaultPath, now: now) }

        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = kind == .eye ? "Rest your eyes" : "Shift your body"
        content.body = Tips.callCue(for: kind)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "pace-nudge-\(kind.label)", content: content, trigger: nil))
    }

    private func ensureNotifPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    // Show the nudge banner even though pace is a background (menu-bar) app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func setEyeEvery(_ s: NSMenuItem) { Settings.set(.eyeIntervalMin, s.tag) }
    @objc private func setEyeLen(_ s: NSMenuItem) { Settings.set(.eyeDurationSec, s.tag) }
    @objc private func setMoveEvery(_ s: NSMenuItem) { Settings.set(.moveIntervalMin, s.tag) }
    @objc private func setMoveLen(_ s: NSMenuItem) { Settings.set(.moveDurationSec, s.tag) }
    @objc private func setAwayReset(_ s: NSMenuItem) { Settings.set(.awayResetMin, s.tag) }
    @objc private func screenDidLock() { scheduler.setScreenLocked(true) }
    @objc private func screenDidUnlock() { scheduler.setScreenLocked(false) }
    @objc private func pauseFor(_ s: NSMenuItem) { scheduler.pause(for: TimeInterval(s.tag)) }
    @objc private func pauseTomorrow() { scheduler.pauseUntilTomorrow() }
    @objc private func resume() { scheduler.resume() }
    @objc private func quit() { NSApp.terminate(nil) }


    // MARK: reporting

    @objc private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Pick your Obsidian vault (or any folder). pace writes into a 'pace' subfolder."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.vaultPath = url.path
            Report.updateVault(url.path, rebuildAll: true, now: Date())
            NSWorkspace.shared.open(Report.dashboardURL(url.path))
        }
    }

    @objc private func openToday() { openVaultFile(Report.dailyURL(Settings.vaultPath, now: Date())) }
    @objc private func openDashboard() { openVaultFile(Report.dashboardURL(Settings.vaultPath)) }

    @objc private func rebuildReport() {
        guard !Settings.vaultPath.isEmpty else { return needVaultAlert() }
        Report.updateVault(Settings.vaultPath, rebuildAll: true, now: Date())
    }

    @objc private func stopLogging() { Settings.vaultPath = "" }

    private func openVaultFile(_ url: URL) {
        guard !Settings.vaultPath.isEmpty else { return needVaultAlert() }
        if !FileManager.default.fileExists(atPath: url.path) { Report.updateVault(Settings.vaultPath, now: Date()) }
        NSWorkspace.shared.open(url)
    }

    private func needVaultAlert() {
        let a = NSAlert()
        a.messageText = "No vault chosen"
        a.informativeText = "Pick a folder first with 'Log to Obsidian vault…'."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: stats + feedback windows

    @objc private func showStats() {
        // The open stretch comes from the live loop, not the log: a call holding a
        // break off right now hasn't been written anywhere yet, and that is exactly
        // when you'd open this window.
        let open = (eye: lastStatus?.eye.callHeldSec ?? 0, move: lastStatus?.move.callHeldSec ?? 0)
        let host = NSHostingController(rootView: StatsView(s: Report.summary(now: Date(), openCall: open)))
        if let w = statsWindow {
            w.contentViewController = host
            w.setContentSize(statsSize)
        } else {
            // Resizable, because the report grows: a panel added to the view must not
            // be a panel you can only reach by scrolling a window you can't enlarge.
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: statsSize),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "pace stats"
            w.isReleasedWhenClosed = false
            w.contentViewController = host
            w.setContentSize(statsSize)
            w.center()
            statsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The stats window's size, and the `setContentSize` calls above that impose it.
    ///
    /// Assigning a `contentViewController` makes the window adopt that controller's
    /// `preferredContentSize`, and a hosting controller whose root view scrolls
    /// reports that as **zero** — a scroll view has no height of its own to offer.
    /// So the window opened at 420×32: a title bar with nothing under it, no way to
    /// resize it and no way to know why. The window owns its own size here, and the
    /// scroll view gets whatever is left, which is the right way round.
    ///
    /// Only this window scrolls, so only this one collapsed; the feedback window's
    /// view has a real intrinsic height and sizes itself correctly.
    private var statsSize: NSSize { NSSize(width: 460, height: 720) }

    @objc private func showFeedback() {
        let view = FeedbackView(
            onSubmit: { kind, note in Feedback.log(kind: kind, note: note, mirrorVault: Settings.vaultPath) },
            onClose: { [weak self] in self?.feedbackWindow?.close() })
        let host = NSHostingController(rootView: view)
        if let w = feedbackWindow {
            w.contentViewController = host
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Feedback"
            w.isReleasedWhenClosed = false
            w.contentViewController = host
            w.center()
            feedbackWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "pace"
        a.informativeText = """
        A calm break reminder. Pomodoro-inspired eye and movement breaks that \
        step aside during calls (it watches the mic, not any one app) and reset \
        when you step away.

        Everything runs locally. No network, no data leaves your Mac.
        """
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
