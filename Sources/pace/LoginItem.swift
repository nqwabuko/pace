import Foundation
import ServiceManagement

/// "Start at Login", via the modern SMAppService API (macOS 13+). Only works
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

    /// Flip the state. Returns the resulting enabled-ness (unchanged on error).
    @discardableResult
    static func toggle() -> Bool {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("pace: login-item toggle failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
