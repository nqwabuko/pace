import Foundation

/// An on-call nudge, timed. One banner used to say "glance away" and then nothing,
/// so on a call you had no way to know when the 30 seconds were up without
/// watching a clock, which is the screen you were meant to be looking away from.
/// Now the nudge is a short script of banners: one to start, one to say when the
/// break's time is up, and on a longer break one at halfway.
///
/// The script is a value, worked out from the break's kind and length and the cues
/// picked for it. No clock, no notification centre, no randomness: the shell picks
/// the cues, hands them in, and posts what comes back at the offsets it says. So
/// `--selftest` can check the timing without waiting it out.
///
/// What it cannot do is know whether you looked away. The closing beat says "if
/// you did", and nothing here credits a rest: a banner is not a break taken.
enum Coach {

    struct Beat: Equatable {
        let at: TimeInterval   // seconds after the nudge
        let title: String
        let body: String
    }

    /// A break this long or longer gets a halfway beat. Shorter, and the middle
    /// banner would land on top of the first one still showing.
    static let halfwayFrom = 60

    /// The whole script. `cue` is what to do, `swap` an optional second thing for
    /// the halfway beat (a long move break is easier as two small moves).
    static func script(_ kind: BreakKind, seconds: Int, cue: String, swap: String?) -> [Beat] {
        let s = max(5, seconds)
        let length = spoken(s)
        var beats = [Beat(at: 0, title: "\(kind == .eye ? "Glance away" : "Shift your body"), \(length)",
                          body: cue)]
        if s >= halfwayFrom {
            beats.append(Beat(at: TimeInterval(s / 2), title: "Halfway",
                              body: swap ?? (kind == .eye ? "Keep looking far away." : "Keep going.")))
        }
        beats.append(Beat(at: TimeInterval(s), title: "That's \(length)",
                          body: kind == .eye ? "If you glanced away, well done. Back to it."
                                             : "If you moved, well done. Settle back in."))
        return beats
    }

    /// How long the script runs, which is also how long the menu-bar figure keeps
    /// its glance-away pose.
    static func span(_ beats: [Beat]) -> TimeInterval { beats.last?.at ?? 0 }

    /// "30 seconds", "2 minutes", "90 seconds": what a person would say.
    static func spoken(_ s: Int) -> String {
        if s >= 60, s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return "\(s) seconds"
    }
}
