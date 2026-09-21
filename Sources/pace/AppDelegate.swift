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
    private var activityWindow: NSWindow?
    private var nudgeUntil: Date?
    private var lastAppearance: IconMaker.Appearance?
    private var lastGlyph: IconMaker.GlyphState?   // last-drawn glyph state, so the 1s tick redraws only on a visible change
    private var lastStatus: Scheduler.Status?   // latest tick, so a closing break can log what it owed
    private let notificationsAvailable = Notify.available

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
            button.image = IconMaker.statusImage(.rested)
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
        add(rs, "What pace has done…", #selector(showActivity))
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
        // Both gauges go on the bar, and both come straight from the scheduler's
        // counters (seconds since that break was actually taken), which is why
        // extending no longer snaps the icon back to rested. Posture is the movement
        // gauge and the head's colour is the eye gauge. Movement used to be one bool
        // here (`missed > 0`) and `move.strain` was computed every tick and thrown
        // away — half the app invisible on the bar.
        //
        // The step sizes are not taste. They are the finest steps that are actually
        // VISIBLE at 36px, measured: half an interval for the eye (a ~10px disc
        // cannot resolve a hue ramp finer than that) and a quarter for movement,
        // where the lean has the whole glyph to work in. Quantising finer would
        // repaint the bar to show the user nothing, which is the exact failure the
        // gauge before this one shipped with. `--selftest` gates both.
        let st = IconMaker.GlyphState(
            eye: IconMaker.quantised(s.eye.strain, steps: 2),
            move: s.move.enabled ? IconMaker.quantised(s.move.strain, steps: 4) : nil,
            // Eye rests owed that didn't happen. They push the head further along
            // the same ramp as the time itself rather than getting a mark of their
            // own, because a refusal is time you still owe. It outlives the call
            // that held it, so a call ending doesn't wipe the debt off the icon.
            missed: min(IconMaker.maxMissed, s.eye.missed),
            onCall: s.meeting, paused: s.paused, nudge: nudging)
        // The redraw key is the pair of values the image is a function of, compared
        // by struct equality. It used to be a hand-built string, which meant adding
        // a field and forgetting this line was a silent stop-repainting bug.
        let ap = IconMaker.Appearance.current(statusItem.button)
        if st != lastGlyph || ap != lastAppearance {
            lastGlyph = st
            lastAppearance = ap
            statusItem.button?.image = IconMaker.statusImage(st, ap)
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
        // The row is written from the delivery callback, not before it. A nudge
        // during a call is the one break pace can't show you, so the only fact
        // worth recording about it is whether it left the app — and a row saying
        // "nudged" that was written whatever macOS did made "I never saw it" and
        // "it was never sent" the same record. `Notify.post` calls back exactly
        // once on every path, including the refusals, so there is still one row
        // per nudge.
        Notify.post(title: kind == .eye ? "Rest your eyes" : "Shift your body",
                    body: Tips.callCue(for: kind),
                    id: "pace-nudge-\(kind.label)") { delivery in
            Report.log(kind: kind.label, outcome: "nudged", seconds: 0,
                       overdueSec: owed?.overdue, refusals: owed?.refusals,
                       callSec: owed?.callHeldSec, delivery: delivery, now: now)
            if !Settings.vaultPath.isEmpty { Report.updateVault(Settings.vaultPath, now: now) }
        }
    }

    private func ensureNotifPermission() { Notify.requestPermission() }

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

    /// The action log. The notification status is asked for first and the window
    /// opens on the answer: "can a nudge reach this desktop" is the headline fact
    /// on it, and a window that opens saying "checking…" is a window you read
    /// before it knows anything.
    @objc private func showActivity() {
        Notify.permission { [weak self] permission in
            guard let self else { return }
            let view = ActivityView(log: Activity.log(Report.events(), now: Date(), permission: permission))
            let host = NSHostingController(rootView: view)
            if let w = self.activityWindow {
                w.contentViewController = host
                w.setContentSize(self.activitySize)
            } else {
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: self.activitySize),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                w.title = "pace activity"
                w.isReleasedWhenClosed = false
                w.contentViewController = host
                // Same trap as the stats window: a scrolling root view reports a
                // preferred size of zero, and the window adopts it as a bare title bar.
                w.setContentSize(self.activitySize)
                w.center()
                self.activityWindow = w
            }
            NSApp.activate(ignoringOtherApps: true)
            self.activityWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var activitySize: NSSize { NSSize(width: 520, height: 640) }

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
