import Foundation

/// One break-card prompt: a short principle with a real attribution, plus a
/// one-line technical/medical "why". The principles are faithful statements of
/// each named source's well-documented position (not verbatim quotations), and
/// the "why" lines are grounded in the eye-strain and sitting-physiology
/// literature. Movement framing follows Katy Bowman's *Move Your DNA* idea that
/// the body needs a variety of movement, not one more fixed posture.
struct Prompt {
    let line: String        // the principle
    let source: String      // attribution
    let why: String         // the technical / medical sub-line
}

enum Tips {
    static let move: [Prompt] = [
        Prompt(line: "Movement is a nutrient your body needs, not a luxury.",
               source: "Katy Bowman, Move Your DNA",
               why: "Idle leg muscles drop lipoprotein-lipase activity by up to 90% within hours, so fats and sugar clear from your blood more slowly."),
        Prompt(line: "Your body wants a variety of positions, not one more good posture.",
               source: "Katy Bowman, Move Your DNA",
               why: "Kneeling, standing, or sitting on the floor loads different tissues and keeps joints nourished."),
        Prompt(line: "Break up sitting often; the dose beats one big workout.",
               source: "Activity-break research, Dunstan et al.",
               why: "Short walking breaks every 30 minutes measurably lower post-meal glucose and insulin."),
        Prompt(line: "Stand and move for about five minutes every hour.",
               source: "Columbia University sitting study, 2023",
               why: "Roughly five minutes of walking per hour offsets much of the harm of prolonged sitting."),
        Prompt(line: "Small, frequent movement adds up more than you think.",
               source: "Dr. James Levine, on NEAT",
               why: "Non-exercise activity like standing and pacing burns energy and steadies blood sugar through the day."),
        Prompt(line: "Stand up to a sitting world: get out of the chair shape.",
               source: "Kelly Starrett, Deskbound",
               why: "Hours of hip and spine flexion stiffen tissues; standing and hinging restores range."),
        Prompt(line: "Hang, squat, or reach overhead for a few slow breaths.",
               source: "Katy Bowman, Move Your DNA",
               why: "Loaded hangs and deep squats take joints through ranges a desk never asks for."),
        Prompt(line: "Move well, then move often.",
               source: "Gray Cook, Functional Movement Systems",
               why: "Frequent, good-quality movement keeps tissues supple better than one hard session."),
        Prompt(line: "Frequent posture changes matter more than one workout.",
               source: "Dr. Joan Vernikos, Sitting Kills, Moving Heals",
               why: "Standing up resets your body against gravity; doing it often is the stimulus sitting removes."),
        Prompt(line: "Stand and take a few steps to get the blood moving.",
               source: "The calf 'second heart'",
               why: "Calf contractions pump blood back up your legs; sitting still lets it pool."),
        Prompt(line: "The best posture is your next one.",
               source: "Ergonomics adage",
               why: "Static load is the strain; changing position spreads it and keeps joints fed."),
        Prompt(line: "Get more of your day's movement incidentally, not just at the gym.",
               source: "Katy Bowman, Move Your DNA",
               why: "Walking to fetch water or taking the stairs adds up to far more than a single workout."),
    ]

    static let eye: [Prompt] = [
        Prompt(line: "Every 20 minutes, look about 20 feet away for 20 seconds.",
               source: "Dr. Jeffrey Anshel, who coined the 20-20-20 rule",
               why: "Sustained near-focus holds the ciliary muscle contracted; distance lets it relax toward optical infinity."),
        Prompt(line: "Look up and out at the horizon and let your focus soften.",
               source: "20-20-20 rule",
               why: "Far focus releases the near-work strain that builds through screen time."),
        Prompt(line: "Blink slowly and fully a few times.",
               source: "Dry-eye guidance",
               why: "Screens cut your blink rate sharply, drying the eye surface; deliberate blinks rewet it."),
        Prompt(line: "Rest your eyes on something distant, not another screen.",
               source: "Dr. Jeffrey Anshel, 20-20-20 rule",
               why: "The pause only helps if the new target is far; a nearby screen keeps the muscle working."),
        Prompt(line: "Close your eyes fully for a few seconds.",
               source: "Eye-rest basics",
               why: "Lid closure rehydrates the surface and gives the focusing muscle a complete rest."),
        Prompt(line: "Cup your palms gently over closed eyes for a few breaths.",
               source: "Vision-rest practice",
               why: "Darkness and a little warmth let the focusing muscle and the retina settle."),
        Prompt(line: "Shift your focus from near to far and back a few times.",
               source: "Accommodative flexibility",
               why: "Moving through the focal range beats holding one fixed distance for hours."),
        Prompt(line: "Rest your gaze on greenery or the sky if you can.",
               source: "Attention Restoration Theory, the Kaplans",
               why: "Distant, softly interesting scenes relax both the eyes and tired attention."),
    ]

    static func random(for kind: BreakKind) -> Prompt {
        let pool = kind == .eye ? eye : move
        return pool.randomElement() ?? move[0]
    }
}
