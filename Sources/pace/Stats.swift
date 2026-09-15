import Foundation

struct DayCount: Identifiable {
    let id = UUID()
    let day: Date
    let eye: Int
    let move: Int
    let overdueSec: Int   // eye time worked past due, from the breaks that cleared it
    let putOffs: Int      // times a break was extended or skipped
    let callEyeSec: Int   // of the time without an eye rest, how much was on a call
    let callMoveSec: Int  // ditto for moving. Overlaps callEyeSec in real time: never add them
    var total: Int { eye + move }
    var overdueMin: Int { overdueSec / 60 }
    var callEyeMin: Int { callEyeSec / 60 }
    var callMoveMin: Int { callMoveSec / 60 }
}

/// How many extensions the breaks you took needed before you took them. Rows
/// logged before `refusals` existed aren't in here at all, so `total` is the
/// number of takes we actually know about, not every take on record.
struct TakeSplit {
    let first: Int
    let once: Int
    let more: Int
    var total: Int { first + once + more }
    var firstPct: Int { total > 0 ? Int(round(Double(first) / Double(total) * 100)) : 0 }
}

struct StatsSummary {
    let days: [DayCount]
    let todayTotal: Int
    let avg7: Double
    let streak: Int
    let eye30: Int
    let move30: Int
    let overdueToday: Int
    let putOffsToday: Int
    let overdueWeek: Int
    let putOffsWeek: Int
    let overduePrevWeek: Int
    let putOffsPrevWeek: Int
    let callEyeToday: Int
    let callMoveToday: Int
    let callEyeWeek: Int
    let callMoveWeek: Int
    let callDaysWeek: Int     // days in the last 7 with any call-held time, so the
                              // average is per call day and not diluted by days off
    let split: TakeSplit
}
