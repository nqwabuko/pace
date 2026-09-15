import AppKit

/// What a key press on the break card means. Kept as a pure mapping off the two
/// things a key event actually carries, so the self-test can assert the whole
/// keyboard without a window on screen — and so there is exactly one place
/// that decides what ⌘S does.
enum BreakKey {
    case skip, snooze, done

    static let escKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]   // Return, and the keypad's Enter

    static func action(keyCode: UInt16, chars: String?, flags: NSEvent.ModifierFlags) -> BreakKey? {
        // Esc and Return usually never reach here — SwiftUI's cancel/default
        // actions claim them first — but a window that covers the whole screen
        // has to answer to them even if that stops being true.
        if keyCode == escKeyCode { return .skip }   // Esc, whatever is held with it
        if returnKeyCodes.contains(keyCode) { return .done }
        // Command and nothing else that a person chose to hold: ⌘⌥S belongs to
        // whatever the user has bound it to, not to us. Caps lock isn't one of
        // those choices, so it isn't allowed to break the shortcut.
        guard flags.intersection([.command, .shift, .option, .control]) == .command else { return nil }
        switch chars?.lowercased() {
        case "s": return .skip
        case "5": return .snooze
        case "d": return .done
        default: return nil
        }
    }

    static func action(for event: NSEvent) -> BreakKey? {
        action(keyCode: event.keyCode, chars: event.charactersIgnoringModifiers, flags: event.modifierFlags)
    }
}
