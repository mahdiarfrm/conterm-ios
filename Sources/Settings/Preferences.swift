import Foundation
import Observation
import UIKit

/// Everything the user can change, in one place.
///
/// Deliberately small. A setting earns its place by changing something the
/// user can point at — there are no toggles here that only rename a value in
/// a plist. Defaults are chosen so the app is right without ever opening
/// this screen.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private init() {
        terminalColumns = Self.read(defaults, "conterm.terminalColumns", 52)
        chromeScale = Self.read(defaults, "conterm.uiScale", 1.0)
        soundEffects = Self.read(defaults, "conterm.soundEffects", true)
        haptics = Self.read(defaults, "conterm.haptics", true)
        typingHaptics = Self.read(defaults, "conterm.typingHaptics", false)
        launchAnimation = Self.read(defaults, "conterm.launchAnimation", true)
        keepScreenAwake = Self.read(defaults, "conterm.keepScreenAwake", false)
    }

    private static func read<T>(_ d: UserDefaults, _ key: String, _ fallback: T) -> T {
        d.object(forKey: key) as? T ?? fallback
    }

    /// How many columns a new terminal aims for. The font size is derived
    /// from this and the screen width, because a fixed point size cannot
    /// promise a usable line on both a 5.4" phone and a 13" iPad.
    var terminalColumns: Int {
        didSet { defaults.set(terminalColumns, forKey: "conterm.terminalColumns") }
    }

    /// Size multiplier for the chrome around the terminal — never the
    /// terminal itself, which has `terminalColumns`.
    var chromeScale: Double {
        didSet {
            defaults.set(chromeScale, forKey: "conterm.uiScale")
            Theme.reloadUIScale()
        }
    }

    var soundEffects: Bool {
        didSet { defaults.set(soundEffects, forKey: "conterm.soundEffects") }
    }

    var haptics: Bool {
        didSet { defaults.set(haptics, forKey: "conterm.haptics") }
    }

    /// A tap for every character typed into a terminal.
    ///
    /// Separate from `haptics`, which covers deliberate acts — connecting,
    /// failing, toggling. Typing is different in kind: it fires dozens of
    /// times a sentence, and whether that reads as a keyboard with weight or
    /// as a buzzing phone is genuinely a matter of taste. Off by default, so
    /// nobody has to discover a setting to make their phone stop.
    var typingHaptics: Bool {
        didSet { defaults.set(typingHaptics, forKey: "conterm.typingHaptics") }
    }

    var launchAnimation: Bool {
        didSet { defaults.set(launchAnimation, forKey: "conterm.launchAnimation") }
    }

    /// Hold the screen on while a terminal is open. Off by default: it is a
    /// battery decision, and most sessions are a glance rather than a watch.
    var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: "conterm.keepScreenAwake")
            IdleTimer.apply()
        }
    }
}

/// Whether the screen may sleep. Driven by the preference and by whether a
/// terminal is actually on screen, so the setting can't quietly pin the
/// display awake from the host list.
@MainActor
enum IdleTimer {
    private(set) static var terminalVisible = false

    static func terminalAppeared() {
        terminalVisible = true
        apply()
    }

    static func terminalDisappeared() {
        terminalVisible = false
        apply()
    }

    static func apply() {
        UIApplication.shared.isIdleTimerDisabled =
            terminalVisible && Preferences.shared.keepScreenAwake
    }
}
