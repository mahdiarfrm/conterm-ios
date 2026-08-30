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

    /// Build a synthetic key press for a named key.
    ///
    /// This exists because `ghostty_surface_text` is **paste**, not typing:
    /// `Surface.textCallback` routes into `completeClipboardPaste`, and
    /// `input/paste.zig` replaces NUL, BS, ENQ, EOT, ESC, DEL and the tty
    /// control characters (Ctrl-C, Ctrl-Z, Ctrl-U, Ctrl-W, Ctrl-R…) with
    /// **spaces**, exactly as xterm does, as a paste-injection defence. So
    /// every key that matters to a terminal — escape, backspace, the arrows,
    /// any Ctrl chord — has to arrive as a key event with a keycode, never as
    /// text. Sending them as text is how backspace types a space.
    static func press(_ usage: UIKeyboardHIDUsage,
                      mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
                      text: String? = nil) -> ghostty_input_key_s? {
        guard let keycode = virtualKeyCode(for: usage) else { return nil }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = mods
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(keycode)
        key.composing = false
        key.unshifted_codepoint = text?.unicodeScalars.first?.value ?? 0
        key.text = nil
        return key
    }

    /// The key that produces a character on a US layout, and whether Shift
    /// is held to get it.
    ///
    /// This exists so that **typing goes through the key path**. The software
    /// keyboard hands us text, and sending text to libghostty is
    /// `ghostty_surface_text`, which is paste — wrapped in bracketed-paste
    /// markers when the far program has them on. A program that understands
    /// bracketed paste treats what arrives as *pasted content*, not as
    /// keystrokes: vim inserts `:wq` into the buffer instead of running it,
    /// and a shell puts a newline in its line editor instead of submitting.
    /// So a phone keyboard could not drive vim at all, which for a terminal
    /// is not a rough edge but a missing floor.
    struct Keystroke {
        let usage: UIKeyboardHIDUsage
        let shift: Bool
        /// What the same physical key produces without Shift. libghostty uses
        /// it to identify the key itself, independently of the character.
        let unshifted: UnicodeScalar
    }

    static func keystroke(for scalar: UnicodeScalar) -> Keystroke? {
        // Letters. Shift is what separates the two cases, and the unshifted
        // codepoint is always the lowercase.
        if scalar.isASCII {
            let ascii = UInt8(scalar.value)
            if ascii >= 97, ascii <= 122, let usage = letterUsage(ascii) {
                return Keystroke(usage: usage, shift: false, unshifted: scalar)
            }
            if ascii >= 65, ascii <= 90, let usage = letterUsage(ascii + 32) {
                return Keystroke(usage: usage, shift: true,
                                 unshifted: UnicodeScalar(ascii + 32))
            }
        }

        switch scalar {
        case "1": return .init(usage: .keyboard1, shift: false, unshifted: "1")
        case "2": return .init(usage: .keyboard2, shift: false, unshifted: "2")
        case "3": return .init(usage: .keyboard3, shift: false, unshifted: "3")
        case "4": return .init(usage: .keyboard4, shift: false, unshifted: "4")
        case "5": return .init(usage: .keyboard5, shift: false, unshifted: "5")
        case "6": return .init(usage: .keyboard6, shift: false, unshifted: "6")
        case "7": return .init(usage: .keyboard7, shift: false, unshifted: "7")
        case "8": return .init(usage: .keyboard8, shift: false, unshifted: "8")
        case "9": return .init(usage: .keyboard9, shift: false, unshifted: "9")
        case "0": return .init(usage: .keyboard0, shift: false, unshifted: "0")

        case "!": return .init(usage: .keyboard1, shift: true, unshifted: "1")
        case "@": return .init(usage: .keyboard2, shift: true, unshifted: "2")
        case "#": return .init(usage: .keyboard3, shift: true, unshifted: "3")
        case "$": return .init(usage: .keyboard4, shift: true, unshifted: "4")
        case "%": return .init(usage: .keyboard5, shift: true, unshifted: "5")
        case "^": return .init(usage: .keyboard6, shift: true, unshifted: "6")
        case "&": return .init(usage: .keyboard7, shift: true, unshifted: "7")
        case "*": return .init(usage: .keyboard8, shift: true, unshifted: "8")
        case "(": return .init(usage: .keyboard9, shift: true, unshifted: "9")
        case ")": return .init(usage: .keyboard0, shift: true, unshifted: "0")

        case "-": return .init(usage: .keyboardHyphen, shift: false, unshifted: "-")
        case "_": return .init(usage: .keyboardHyphen, shift: true, unshifted: "-")
        case "=": return .init(usage: .keyboardEqualSign, shift: false, unshifted: "=")
        case "+": return .init(usage: .keyboardEqualSign, shift: true, unshifted: "=")
        case "[": return .init(usage: .keyboardOpenBracket, shift: false, unshifted: "[")
        case "{": return .init(usage: .keyboardOpenBracket, shift: true, unshifted: "[")
        case "]": return .init(usage: .keyboardCloseBracket, shift: false, unshifted: "]")
        case "}": return .init(usage: .keyboardCloseBracket, shift: true, unshifted: "]")
        case "\\": return .init(usage: .keyboardBackslash, shift: false, unshifted: "\\")
        case "|": return .init(usage: .keyboardBackslash, shift: true, unshifted: "\\")
        case ";": return .init(usage: .keyboardSemicolon, shift: false, unshifted: ";")
        case ":": return .init(usage: .keyboardSemicolon, shift: true, unshifted: ";")
        case "'": return .init(usage: .keyboardQuote, shift: false, unshifted: "'")
        case "\"": return .init(usage: .keyboardQuote, shift: true, unshifted: "'")
        case "`": return .init(usage: .keyboardGraveAccentAndTilde, shift: false, unshifted: "`")
        case "~": return .init(usage: .keyboardGraveAccentAndTilde, shift: true, unshifted: "`")
        case ",": return .init(usage: .keyboardComma, shift: false, unshifted: ",")
        case "<": return .init(usage: .keyboardComma, shift: true, unshifted: ",")
        case ".": return .init(usage: .keyboardPeriod, shift: false, unshifted: ".")
        case ">": return .init(usage: .keyboardPeriod, shift: true, unshifted: ".")
        case "/": return .init(usage: .keyboardSlash, shift: false, unshifted: "/")
        case "?": return .init(usage: .keyboardSlash, shift: true, unshifted: "/")
        case " ": return .init(usage: .keyboardSpacebar, shift: false, unshifted: " ")
        case "\t": return .init(usage: .keyboardTab, shift: false, unshifted: "\t")
        // UIKit reports Return as a newline; the terminal wants the key.
        case "\n", "\r": return .init(usage: .keyboardReturnOrEnter, shift: false, unshifted: "\r")
        default: return nil
        }
    }

    private static func letterUsage(_ lowercaseASCII: UInt8) -> UIKeyboardHIDUsage? {
        let all: [UIKeyboardHIDUsage] = [
            .keyboardA, .keyboardB, .keyboardC, .keyboardD, .keyboardE, .keyboardF,
            .keyboardG, .keyboardH, .keyboardI, .keyboardJ, .keyboardK, .keyboardL,
            .keyboardM, .keyboardN, .keyboardO, .keyboardP, .keyboardQ, .keyboardR,
            .keyboardS, .keyboardT, .keyboardU, .keyboardV, .keyboardW, .keyboardX,
            .keyboardY, .keyboardZ,
        ]
        let index = Int(lowercaseASCII) - 97
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }

    /// The HID usage for a printable character, so a Ctrl chord can be sent
    /// as a real key event rather than as a raw control byte.
    static func usage(for scalar: UnicodeScalar) -> UIKeyboardHIDUsage? {
        if let stroke = keystroke(for: scalar) { return stroke.usage }
        return legacyUsage(for: scalar)
    }

    private static func legacyUsage(for scalar: UnicodeScalar) -> UIKeyboardHIDUsage? {
        switch scalar {
        case "a", "A": return .keyboardA
        case "b", "B": return .keyboardB
        case "c", "C": return .keyboardC
        case "d", "D": return .keyboardD
        case "e", "E": return .keyboardE
        case "f", "F": return .keyboardF
        case "g", "G": return .keyboardG
        case "h", "H": return .keyboardH
        case "i", "I": return .keyboardI
        case "j", "J": return .keyboardJ
        case "k", "K": return .keyboardK
        case "l", "L": return .keyboardL
        case "m", "M": return .keyboardM
        case "n", "N": return .keyboardN
        case "o", "O": return .keyboardO
        case "p", "P": return .keyboardP
        case "q", "Q": return .keyboardQ
        case "r", "R": return .keyboardR
        case "s", "S": return .keyboardS
        case "t", "T": return .keyboardT
        case "u", "U": return .keyboardU
        case "v", "V": return .keyboardV
        case "w", "W": return .keyboardW
        case "x", "X": return .keyboardX
        case "y", "Y": return .keyboardY
        case "z", "Z": return .keyboardZ
        case "[": return .keyboardOpenBracket
        case "]": return .keyboardCloseBracket
        case "\\": return .keyboardBackslash
        case "-", "_": return .keyboardHyphen
        case "/", "?": return .keyboardSlash
        case " ": return .keyboardSpacebar
        default: return nil
        }
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
