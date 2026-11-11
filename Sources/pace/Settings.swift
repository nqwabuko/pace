import Foundation

/// Typed, defaulted access to the app's settings, read live by the scheduler each
/// tick. Keeping this in one place means the menu and the loop can never disagree
/// about a setting.
///
/// Two stores, never both: when dials is installed the running app reads the
/// snapshot it last got from `dials get pace` and writes through `dials set`;
/// otherwise (dials not installed, or any headless mode) UserDefaults, as before.
enum Settings {
    /// The backing store when dials is not in charge. A `var` for exactly one
    /// reason: `--sim` points it at a throwaway suite so a simulation can never
    /// touch your real settings.
    static var store = UserDefaults.standard
    private static var d: UserDefaults { store }

    /// dials' values, when dials is the store. Set only by the app's own launch
    /// (`useDials`); nil everywhere else, so `--sim` and `--selftest` never see it.
    static var snapshot: DialsSnapshot?
    /// Why the snapshot may be out of date (a get or set that failed), in words for
    /// pace's report to dials. nil when the last call worked.
    private(set) static var problem: String?

    // Keys + their defaults, registered once at launch.
    enum Key: String {
        case eyeEnabled, eyeIntervalMin, eyeDurationSec
        case moveEnabled, moveIntervalMin, moveDurationSec
        case meetingAware, idleAware, awayResetMin, callBreaks
        case soundEnabled, endChime
        case vaultPath
    }

    /// The built-in defaults. dials' registry carries the same values for pace.
    static let defaults: [Key: JSONValue] = [
        .eyeEnabled:      .bool(true),
        .eyeIntervalMin:  .number(20),   // 20-20-20 cadence
        .eyeDurationSec:  .number(30),   // 30s for fuller focus recovery
        .moveEnabled:     .bool(true),
        .moveIntervalMin: .number(30),   // 30 min: the metabolic sweet spot
        .moveDurationSec: .number(120),  // 2 min: solid microbreak
        .meetingAware:    .bool(true),   // hold/adjust breaks during calls
        .callBreaks:      .bool(false),  // on-call: gentle nudges instead of holding (opt-in)
        .idleAware:       .bool(true),   // a break away from the keys counts
        .awayResetMin:    .number(15),   // away this long counts as a real rest (then reset on return)
        .soundEnabled:    .bool(false),  // soft sound when a break starts
        .endChime:        .bool(true),   // chime when a break ends (eyes closed / stretching)
        .vaultPath:       .string(""),   // empty = no Obsidian logging
    ]

    static func registerDefaults() {
        var plist: [String: Any] = [:]
        for (k, v) in defaults {
            switch v {
            case .bool(let b): plist[k.rawValue] = b
            case .number(let n): plist[k.rawValue] = Int(n)
            case .string(let s): plist[k.rawValue] = s
            default: break
            }
        }
        d.register(defaults: plist)
    }

    /// Make dials the store: read pace's values now, and again whenever they change
    /// (`refresh`). A first read that fails leaves an empty snapshot, which reads as
    /// the built-in defaults (the same values `dials get` gives before anything is
    /// set) and is said in the report.
    static func useDials() {
        snapshot = DialsSnapshot(rev: 0, values: [:])
        refresh()
    }

    /// Re-read the snapshot from dials. A failed read keeps the last one.
    static func refresh() {
        do { snapshot = try DialsClient.get("pace"); problem = nil }
        catch { problem = "could not read settings from dials: \(error)" }
    }

    /// Every value pace is applying, for its report to dials.
    static var using: [String: JSONValue] {
        var u: [String: JSONValue] = [:]
        for k in defaults.keys {
            switch defaults[k] {
            case .bool?: u[k.rawValue] = .bool(bool(k))
            case .number?: u[k.rawValue] = .number(Double(int(k)))
            case .string?: u[k.rawValue] = .string(vaultPath)
            default: break
            }
        }
        return u
    }

    /// A change from the menu: through dials when it is the store, then re-read so
    /// the menu shows what dials holds; a refused or failed set leaves the value as
    /// it was and is said in the report.
    private static func write(_ k: Key, _ v: JSONValue, local: () -> Void) {
        guard snapshot != nil else { return local() }
        do {
            try DialsClient.set("pace", k.rawValue, DialsArgs.json(v))
            refresh()
        } catch {
            problem = "could not set \(k.rawValue) in dials: \(error)"
        }
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

    // From dials, a key the snapshot lacks or holds as the wrong type reads as its
    // built-in default.
    static func bool(_ k: Key) -> Bool {
        guard let snap = snapshot else { return d.bool(forKey: k.rawValue) }
        if case .bool(let b)? = snap.values[k.rawValue] { return b }
        if case .bool(let b)? = defaults[k] { return b }
        return false
    }
    static func int(_ k: Key) -> Int {
        guard let snap = snapshot else { return d.integer(forKey: k.rawValue) }
        if case .number(let n)? = snap.values[k.rawValue], n.isFinite, abs(n) < 1e9 { return Int(n) }
        if case .number(let n)? = defaults[k] { return Int(n) }
        return 0
    }
    static func set(_ k: Key, _ v: Bool) { write(k, .bool(v)) { d.set(v, forKey: k.rawValue) } }
    static func set(_ k: Key, _ v: Int) { write(k, .number(Double(v))) { d.set(v, forKey: k.rawValue) } }
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
        get {
            guard let snap = snapshot else { return d.string(forKey: Key.vaultPath.rawValue) ?? "" }
            if case .string(let s)? = snap.values[Key.vaultPath.rawValue] { return s }
            return ""
        }
        set { write(.vaultPath, .string(newValue)) { d.set(newValue, forKey: Key.vaultPath.rawValue) } }
    }
}
