import Foundation
import ServiceManagement

/// pace's login item, via the modern SMAppService API (macOS 13+). Only works
/// from the built .app bundle; from a raw `swift run` it will report/return
/// false, which is fine for development.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Whether the question can be answered here at all. `SMAppService` registers
    /// an .app bundle, so from a bare binary (`swift run`, `.build/debug/pace`) the
    /// status isn't "off", it's unknowable.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Registered, not registered, or `nil` for "can't tell from here". `--check`
    /// prints this rather than `isEnabled`, because a diagnostic that reports a
    /// definite `false` where it has no way to know is worse than one that says
    /// nothing: it sent a debugging session after a setting that was never unset.
    static var enabled: Bool? { isAvailable ? isEnabled : nil }

    /// Register pace's login item if it isn't already. Called at each launch while
    /// on; switching off in dials never unregisters it, so macOS still launches pace
    /// at login and pace quits itself there. A failure is logged, not fatal.
    static func ensureRegistered() {
        guard isAvailable, !isEnabled else { return }
        do { try SMAppService.mainApp.register() }
        catch { NSLog("pace: login-item register failed: \(error.localizedDescription)") }
    }
}
