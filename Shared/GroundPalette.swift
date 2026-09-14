import SwiftUI
import UIKit

/// A ground: the hue the whole app sits on, chosen in Settings.
///
/// In `Shared/` because the widgets and the Dynamic Island paint the same
/// ground; the app writes the chosen id into the snapshot they read.
///
/// Each one is a flat, bright, saturated colour, a slightly deeper cut of
/// it for the chrome, and a deep cut that serves as the action colour on
/// the cream sheet, where the ground's own colour would be too bright
/// behind cream type. The lights are what the launch screen drifts through. The cream, the ink and the status colours are the same on every
/// ground; only the ground changes.
struct GroundPalette: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let topUI: UIColor
    let bottomUI: UIColor
    /// The action colour on the sheet. Deep enough to carry cream text.
    let deepUI: UIColor
    /// Washes drawn over the gradient, and the colours the launch screen
    /// drifts through. Two to four.
    let lightsUI: [UIColor]

    var top: Color { Color(topUI) }
    var bottom: Color { Color(bottomUI) }
    var deep: Color { Color(deepUI) }
    var lights: [Color] { lightsUI.map(Color.init) }
    /// The ground itself.
    var flatUI: UIColor { topUI }
    var flat: Color { Color(flatUI) }
    /// The terminal's chrome: the ground's hue, nearly black.
    var chromeUI: UIColor { mix(bottomUI, .black, 0.55) }

    static func == (a: GroundPalette, b: GroundPalette) -> Bool { a.id == b.id }

    // MARK: - The set

    /// Smoke: charcoal with grey wisps drifting over it. The default, and
    /// the one ground whose smoke is always on.
    static let smoke = GroundPalette(
        id: "smoke", name: "Smoke",
        topUI: UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
        bottomUI: UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1),
        deepUI: UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),
        lightsUI: [UIColor(red: 0.62, green: 0.62, blue: 0.68, alpha: 1),
                   UIColor(red: 0.42, green: 0.40, blue: 0.48, alpha: 1),
                   UIColor(red: 0.80, green: 0.78, blue: 0.78, alpha: 1)])

    static let crimson = GroundPalette(
        id: "crimson", name: "Crimson",
        topUI: UIColor(red: 0.93, green: 0.16, blue: 0.24, alpha: 1),
        bottomUI: UIColor(red: 0.86, green: 0.12, blue: 0.20, alpha: 1),
        deepUI: UIColor(red: 0.78, green: 0.08, blue: 0.14, alpha: 1),
        lightsUI: [UIColor(red: 1.00, green: 0.42, blue: 0.34, alpha: 1),
                   UIColor(red: 0.96, green: 0.25, blue: 0.40, alpha: 1),
                   UIColor(red: 1.00, green: 0.22, blue: 0.24, alpha: 1),
                   UIColor(red: 0.80, green: 0.10, blue: 0.16, alpha: 1)])

    static let ember = GroundPalette(
        id: "ember", name: "Ember",
        topUI: UIColor(red: 1.00, green: 0.46, blue: 0.12, alpha: 1),
        bottomUI: UIColor(red: 0.94, green: 0.38, blue: 0.08, alpha: 1),
        deepUI: UIColor(red: 0.82, green: 0.30, blue: 0.05, alpha: 1),
        lightsUI: [UIColor(red: 1.00, green: 0.72, blue: 0.25, alpha: 1),
                   UIColor(red: 1.00, green: 0.45, blue: 0.30, alpha: 1),
                   UIColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1)])

    static let indigo = GroundPalette(
        id: "indigo", name: "Indigo",
        topUI: UIColor(red: 0.19, green: 0.14, blue: 0.96, alpha: 1),
        bottomUI: UIColor(red: 0.16, green: 0.11, blue: 0.88, alpha: 1),
        deepUI: UIColor(red: 0.15, green: 0.10, blue: 0.80, alpha: 1),
        lightsUI: [UIColor(red: 0.48, green: 0.42, blue: 1.00, alpha: 1),
                   UIColor(red: 0.68, green: 0.32, blue: 1.00, alpha: 1),
                   UIColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 1)])

    static let ocean = GroundPalette(
        id: "ocean", name: "Ocean",
        topUI: UIColor(red: 0.05, green: 0.56, blue: 1.00, alpha: 1),
        bottomUI: UIColor(red: 0.03, green: 0.48, blue: 0.92, alpha: 1),
        deepUI: UIColor(red: 0.03, green: 0.40, blue: 0.78, alpha: 1),
        lightsUI: [UIColor(red: 0.30, green: 0.82, blue: 0.95, alpha: 1),
                   UIColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
                   UIColor(red: 0.25, green: 0.90, blue: 0.80, alpha: 1)])

    static let forest = GroundPalette(
        id: "forest", name: "Forest",
        topUI: UIColor(red: 0.07, green: 0.70, blue: 0.44, alpha: 1),
        bottomUI: UIColor(red: 0.05, green: 0.60, blue: 0.37, alpha: 1),
        deepUI: UIColor(red: 0.04, green: 0.50, blue: 0.30, alpha: 1),
        lightsUI: [UIColor(red: 0.45, green: 0.90, blue: 0.55, alpha: 1),
                   UIColor(red: 0.75, green: 0.95, blue: 0.30, alpha: 1),
                   UIColor(red: 0.20, green: 0.80, blue: 0.70, alpha: 1)])

    static let violet = GroundPalette(
        id: "violet", name: "Violet",
        topUI: UIColor(red: 0.56, green: 0.22, blue: 0.96, alpha: 1),
        bottomUI: UIColor(red: 0.49, green: 0.18, blue: 0.88, alpha: 1),
        deepUI: UIColor(red: 0.42, green: 0.14, blue: 0.78, alpha: 1),
        lightsUI: [UIColor(red: 0.85, green: 0.45, blue: 1.00, alpha: 1),
                   UIColor(red: 1.00, green: 0.40, blue: 0.75, alpha: 1),
                   UIColor(red: 0.55, green: 0.40, blue: 1.00, alpha: 1)])

    static let midnight = GroundPalette(
        id: "midnight", name: "Midnight",
        topUI: UIColor(red: 0.17, green: 0.21, blue: 0.58, alpha: 1),
        bottomUI: UIColor(red: 0.13, green: 0.16, blue: 0.48, alpha: 1),
        deepUI: UIColor(red: 0.12, green: 0.15, blue: 0.44, alpha: 1),
        lightsUI: [UIColor(red: 0.30, green: 0.45, blue: 1.00, alpha: 1),
                   UIColor(red: 0.55, green: 0.35, blue: 0.90, alpha: 1),
                   UIColor(red: 0.20, green: 0.70, blue: 0.95, alpha: 1)])

    static let graphite = GroundPalette(
        id: "graphite", name: "Graphite",
        topUI: UIColor(red: 0.23, green: 0.23, blue: 0.26, alpha: 1),
        bottomUI: UIColor(red: 0.17, green: 0.17, blue: 0.20, alpha: 1),
        deepUI: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
        lightsUI: [UIColor(red: 0.50, green: 0.50, blue: 0.56, alpha: 1),
                   UIColor(red: 0.38, green: 0.36, blue: 0.42, alpha: 1)])

    /// In the order they are offered. Smoke first because it is the default.
    static let all: [GroundPalette] = [smoke, crimson, ember, indigo, ocean, forest,
                                       violet, midnight, graphite]

    static func named(_ id: String?) -> GroundPalette {
        all.first { $0.id == id } ?? .smoke
    }

    /// Whether this ground always drifts.
    var alwaysSmokes: Bool { id == "smoke" }
}

/// Linear blend of two colours in sRGB, `t` toward `b`.
func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                   blue: ab + (bb - ab) * t, alpha: aa + (ba - aa) * t)
}
