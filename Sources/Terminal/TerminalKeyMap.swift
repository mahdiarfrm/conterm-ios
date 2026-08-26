import UIKit

/// Translation between UIKit's keyboard vocabulary and libghostty's.
///
/// The trap here is not obvious and costs an afternoon if you hit it blind:
/// libghostty's `src/input/keycodes.zig` maps **iOS to the macOS table**
/// (`.ios, .macos => mac`), so `ghostty_input_key_s.keycode` wants a *macOS
/// virtual keycode* — the Carbon `kVK_*` numbers. But `UIKey.keyCode` is a
/// `UIKeyboardHIDUsage`, a completely different numbering. Passing the HID
/// value through unchanged produces a terminal where the arrow keys type
/// letters.
enum TerminalKeyMap {

    /// HID usage → macOS virtual keycode.
    ///
    /// Only keys a terminal cares about are listed. Anything absent returns
    /// nil and falls through to `insertText`, which is the right outcome for
    /// keys whose meaning is their character.
    static func virtualKeyCode(for usage: UIKeyboardHIDUsage) -> Int? {
        switch usage {
        // Letters — note the macOS table is emphatically not alphabetical.
        case .keyboardA: return 0
        case .keyboardB: return 11
        case .keyboardC: return 8
        case .keyboardD: return 2
        case .keyboardE: return 14
        case .keyboardF: return 3
        case .keyboardG: return 5
        case .keyboardH: return 4
        case .keyboardI: return 34
        case .keyboardJ: return 38
        case .keyboardK: return 40
        case .keyboardL: return 37
        case .keyboardM: return 46
        case .keyboardN: return 45
        case .keyboardO: return 31
        case .keyboardP: return 35
        case .keyboardQ: return 12
        case .keyboardR: return 15
        case .keyboardS: return 1
        case .keyboardT: return 17
        case .keyboardU: return 32
        case .keyboardV: return 9
        case .keyboardW: return 13
        case .keyboardX: return 7
        case .keyboardY: return 16
        case .keyboardZ: return 6

        // Digits.
        case .keyboard1: return 18
        case .keyboard2: return 19
        case .keyboard3: return 20
        case .keyboard4: return 21
        case .keyboard5: return 23
        case .keyboard6: return 22
        case .keyboard7: return 26
        case .keyboard8: return 28
        case .keyboard9: return 25
        case .keyboard0: return 29

        // Punctuation.
        case .keyboardHyphen: return 27
        case .keyboardEqualSign: return 24
        case .keyboardOpenBracket: return 33
        case .keyboardCloseBracket: return 30
        case .keyboardBackslash: return 42
        case .keyboardSemicolon: return 41
        case .keyboardQuote: return 39
        case .keyboardGraveAccentAndTilde: return 50
        case .keyboardComma: return 43
        case .keyboardPeriod: return 47
        case .keyboardSlash: return 44

        // Editing and control.
        case .keyboardReturnOrEnter: return 36
        case .keyboardEscape: return 53
        case .keyboardDeleteOrBackspace: return 51
        case .keyboardDeleteForward: return 117
        case .keyboardTab: return 48
        case .keyboardSpacebar: return 49
        case .keyboardCapsLock: return 57

        // Navigation.
        case .keyboardLeftArrow: return 123
        case .keyboardRightArrow: return 124
        case .keyboardDownArrow: return 125
        case .keyboardUpArrow: return 126
        case .keyboardHome: return 115
        case .keyboardEnd: return 119
        case .keyboardPageUp: return 116
        case .keyboardPageDown: return 121

        // Function keys — again not contiguous on macOS.
        case .keyboardF1: return 122
        case .keyboardF2: return 120
        case .keyboardF3: return 99
        case .keyboardF4: return 118
        case .keyboardF5: return 96
        case .keyboardF6: return 97
        case .keyboardF7: return 98
        case .keyboardF8: return 100
        case .keyboardF9: return 101
        case .keyboardF10: return 109
        case .keyboardF11: return 103
        case .keyboardF12: return 111

        default: return nil
        }
    }

    /// UIKit modifier flags → libghostty's mods, plus whatever the accessory
    /// bar has latched.
    static func mods(from flags: UIKeyModifierFlags,
                     plus sticky: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> ghostty_input_mods_e {
        var raw = sticky.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    /// Translate text on its way to the terminal.
    ///
    /// UIKit hands back "\n" when Return is pressed. A terminal wants
    /// **CR** — a shell reading its line discipline ignores a bare LF, which
    /// is why Return appeared to do nothing whatsoever.
    static func forTerminal(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\r")
                   .replacingOccurrences(of: "\n", with: "\r")
    }

    /// The C0 control code a character produces when Ctrl is held.
    ///
    /// `Ctrl-A`..`Ctrl-Z` are 0x01..0x1A, and the handful of punctuation
    /// controls below them are the ones people actually reach for: `Ctrl-[`
    /// is Escape, `Ctrl-\` quits, `Ctrl-_` undoes in readline.
    static func controlCode(for scalar: UnicodeScalar) -> UInt8? {
        switch scalar {
        case "a"..."z":
            return UInt8(scalar.value - 0x60)
        case "A"..."Z":
            return UInt8(scalar.value - 0x40)
        case "@", " ": return 0x00
        case "[": return 0x1b
        case "\\": return 0x1c
        case "]": return 0x1d
        case "^": return 0x1e
        case "_", "?": return 0x1f
        default: return nil
        }
    }
}
