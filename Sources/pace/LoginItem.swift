import Foundation
import ServiceManagement

/// "Start at Login", via the modern SMAppService API (macOS 13+). Only works
/// from the built .app bundle; from a raw `swift run` it will report/return
/// false, which is fine for development.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

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
