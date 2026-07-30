import Foundation

/// Typed, defaulted access to the app's settings. UserDefaults is the single
/// store; the values here are the source of truth for the whole app, read live
/// by the scheduler each tick. Keeping this in one place means the menu and the
/// loop can never disagree about a setting.
enum Settings {
    private static let d = UserDefaults.standard

    // Keys + their defaults, registered once at launch.
    enum Key: String {
        case eyeEnabled, eyeIntervalMin, eyeDurationSec
        case moveEnabled, moveIntervalMin, moveDurationSec
        case meetingAware, idleAware, awayResetMin, callBreaks
        case soundEnabled, endChime
        case vaultPath
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.eyeEnabled.rawValue:      true,
            Key.eyeIntervalMin.rawValue:  20,   // 20-20-20 cadence
            Key.eyeDurationSec.rawValue:  30,   // 30s for fuller focus recovery
            Key.moveEnabled.rawValue:     true,
            Key.moveIntervalMin.rawValue: 30,   // 30 min: the metabolic sweet spot
            Key.moveDurationSec.rawValue: 120,  // 2 min: solid microbreak
            Key.meetingAware.rawValue:    true, // hold/adjust breaks during calls
            Key.callBreaks.rawValue:      false, // on-call: gentle nudges instead of holding (opt-in)
            Key.idleAware.rawValue:       true, // a break away from the keys counts
            Key.awayResetMin.rawValue:    15,   // away this long counts as a real rest (then reset on return)
            Key.soundEnabled.rawValue:    false, // soft sound when a break starts
            Key.endChime.rawValue:        true,  // chime when a break ends (eyes closed / stretching)
            Key.vaultPath.rawValue:       "",   // empty = no Obsidian logging
        ])
    }

    /// One-time bump of an existing install to the evidence-based break lengths
    /// (30s eyes, 30-min / 2-min move). Runs once, then never touches these
    /// again, so later manual changes in the menu stick.
    static func migrateBreakLengths() {
        let flag = "migratedBreakLengthsV2"
        guard !d.bool(forKey: flag) else { return }
        set(.eyeDurationSec, 30)
        set(.moveIntervalMin, 30)
        set(.moveDurationSec, 120)
        d.set(true, forKey: flag)
    }

    static func bool(_ k: Key) -> Bool { d.bool(forKey: k.rawValue) }
    static func int(_ k: Key) -> Int { d.integer(forKey: k.rawValue) }
    static func set(_ k: Key, _ v: Bool) { d.set(v, forKey: k.rawValue) }
    static func set(_ k: Key, _ v: Int) { d.set(v, forKey: k.rawValue) }
    static func toggle(_ k: Key) { set(k, !bool(k)) }

    // Convenience.
    static var eyeEnabled: Bool { bool(.eyeEnabled) }
    static var moveEnabled: Bool { bool(.moveEnabled) }
    static var meetingAware: Bool { bool(.meetingAware) }
    static var callBreaks: Bool { bool(.callBreaks) }
    static var idleAware: Bool { bool(.idleAware) }
    static var eyeIntervalSec: Int { max(60, int(.eyeIntervalMin) * 60) }
    static var moveIntervalSec: Int { max(60, int(.moveIntervalMin) * 60) }
    static var eyeDurationSec: Int { max(5, int(.eyeDurationSec)) }
    static var moveDurationSec: Int { max(5, int(.moveDurationSec)) }
    static var awayResetSec: Int { max(120, int(.awayResetMin) * 60) }
    static var endChime: Bool { bool(.endChime) }
    static var vaultPath: String {
        get { d.string(forKey: Key.vaultPath.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.vaultPath.rawValue) }
    }
}
