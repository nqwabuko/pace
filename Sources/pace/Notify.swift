import Foundation
import UserNotifications

/// What macOS says about notifications for this app, as a value.
///
/// Read at the edge, once, and never asked again from inside a decision. The
/// four cases are the whole of what can be true, so every rule downstream is a
/// total function of one of them rather than a chain of `if authorized` guards
/// that each have to remember the bundle case.
enum Permission: Equatable {
    case noBundle              // not running from an .app: there is no notification client
    case neverAsked            // macOS has not been asked yet
    case denied                // notifications are off for pace
    case allowed(alerts: Bool) // on; `alerts` is whether banners are enabled

    /// Can anything at all leave the app for the desktop?
    var canSend: Bool { if case .allowed = self { return true } else { return false } }

    /// The status line, in the terms the question gets asked in.
    var human: String {
        switch self {
        case .noBundle:            return "unavailable — running outside the app bundle"
        case .neverAsked:          return "never allowed — macOS has not been asked yet"
        case .denied:              return "off for pace — nudges cannot reach your desktop"
        case .allowed(true):       return "on — nudges appear as banners"
        case .allowed(false):      return "allowed, but banners are off — nudges go to Notification Centre only"
        }
    }
}

/// What became of a notification once it left the loop.
///
/// The log used to record that the rules *decided* to nudge, and nothing asked
/// whether macOS put anything on screen. That made "I never saw it" and "it was
/// never sent" the same record, which is the one question an on-call nudge has
/// to be able to answer: you cannot see the menu bar while you are looking at
/// someone's face.
///
/// One honest limit, stated here because the wording downstream depends on it:
/// `banner` means macOS accepted the request with banners enabled for pace. A
/// Focus mode can still hold it back afterwards, and macOS tells apps nothing
/// about that. So `banner` is "sent", never "seen".
enum Delivery: String {
    case banner        // accepted, and banners are on for pace
    case centreOnly    // accepted, but banners are off: Notification Centre only
    case blocked       // notifications are off for pace, or were never allowed
    case failed        // macOS refused the request outright
    case unavailable   // not running from an .app bundle, so there are none

    /// The whole decision, as one total function of what the world said. Pure, so
    /// `--selftest` can assert that a denied permission never records as sent
    /// without a notification centre to deny anything.
    static func of(_ p: Permission, failed: Bool) -> Delivery {
        switch p {
        case .noBundle:              return .unavailable
        case .neverAsked, .denied:   return .blocked
        case .allowed(let alerts):   return failed ? .failed : (alerts ? .banner : .centreOnly)
        }
    }

    /// Did anything at all leave the app for the desktop?
    var sent: Bool { self == .banner || self == .centreOnly }

    /// One line, in the terms the question was asked in.
    var human: String {
        switch self {
        case .banner:      return "banner sent"
        case .centreOnly:  return "sent, but banners are off — Notification Centre only"
        case .blocked:     return "not sent — notifications are off for pace"
        case .failed:      return "not sent — macOS refused it"
        case .unavailable: return "not sent — running outside the app bundle"
        }
    }

    /// A row written before pace recorded any of this. Deliberately not a case:
    /// the absence of a record is not an outcome, and reading it as one would
    /// backdate a claim onto every nudge already in the history.
    static let unrecorded = "not recorded — logged before pace tracked delivery"

    static func describe(_ raw: String?) -> String {
        raw.flatMap(Delivery.init(rawValue:))?.human ?? unrecorded
    }
}

/// The imperative shell around the notification centre: it reads the world,
/// hands it to the rules above as a value, and performs what they decide.
/// Everything worth checking lives in `Permission` and `Delivery.of`, so what is
/// left here is two API calls and a callback.
enum Notify {

    /// No bundle, no notifications: `UNUserNotificationCenter.current()` needs a
    /// registered bundle and a bare `swift run` binary has none.
    static let available = Bundle.main.bundleURL.pathExtension == "app"

    /// Ask once, when on-call nudges are switched on.
    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Post one notification and report what became of it. The completion runs on
    /// the main thread exactly once on every path, including the refusals, because
    /// the caller writes its log line from it.
    static func post(title: String, body: String, id: String, done: @escaping (Delivery) -> Void) {
        func finish(_ d: Delivery) { DispatchQueue.main.async { done(d) } }
        guard available else { return finish(.of(.noBundle, failed: false)) }

        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            let permission = read(settings)
            guard permission.canSend else { return finish(.of(permission, failed: false)) }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            centre.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                finish(.of(permission, failed: error != nil))
            }
        }
    }

    /// Can a nudge reach the desktop at all, right now? What `--check` prints and
    /// what the activity window says at the top, so the answer never has to be
    /// inferred from a run of rows.
    static func permission(_ done: @escaping (Permission) -> Void) {
        func finish(_ p: Permission) { DispatchQueue.main.async { done(p) } }
        guard available else { return finish(.noBundle) }
        UNUserNotificationCenter.current().getNotificationSettings { finish(read($0)) }
    }

    /// The one place macOS's two enums become one value of ours.
    private static func read(_ s: UNNotificationSettings) -> Permission {
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed(alerts: s.alertSetting == .enabled)
        case .denied:                               return .denied
        case .notDetermined:                        return .neverAsked
        @unknown default:                           return .neverAsked
        }
    }
}
