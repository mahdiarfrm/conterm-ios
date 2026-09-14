import SwiftUI
import UIKit

/// Canonical design tokens. Spring presets are listed here once so every
/// animated transition uses the same physical language.
///
/// Visual identity: **one bold ground, one cream sheet.** The app sits on
/// a single hue chosen in Settings (`GroundPalette`; crimson, the brand, by
/// default), deepened at the foot of the screen, and the things you read
/// closely sit on a cream sheet in warm ink. Chrome
/// on the ground is translucent white with a lit rim; chrome on the sheet
/// is white. Every token that has to read on both surfaces is `dynamic`:
/// the ground runs in the dark appearance and the sheet in the light one,
/// so a control moved from one to the other restyles itself.
///
/// The terminal is exempt. It is a black tile on the ground, always, because
/// it is the one surface you read for hours.
enum Theme {
    /// A color that resolves differently in light vs dark appearance.
    /// On macOS this reads the window's `NSAppearance`; on iOS the trait
    /// collection resolves it per view, which is strictly simpler.
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: - Palette — one bold ground, one cream sheet

    /// The flat colour of the ground, for bars and beds that cannot hold the
    /// gradient `BrandGround` draws. Set once at the root; screens below are
    /// transparent, or paint the same ground themselves when pushed.
    static var appBackground: Color { Color(palette.flatUI) }

    /// The gradient the app sits on, from the ground chosen in Settings:
    /// its hue at the top of the screen, deepened at the foot. Every one is
    /// deep enough to carry white type.
    enum Ground {
        static var top: Color { palette.top }
        static var bottom: Color { palette.bottom }
    }

    /// Opaque backing for a terminal surface. Near-black, always: the
    /// terminal is the one surface that does not take the brand.
    static let paneTile = Color(red: 0.05, green: 0.055, blue: 0.075)

    /// Backdrop tint endpoints, shared by the material tints and the app
    /// backdrops so the light/dark washes agree across glass and solid modes.
    static let backdropLightUI = UIColor(red: 0.957, green: 0.949, blue: 0.925, alpha: 1)
    static var backdropDarkUI: UIColor { palette.bottomUI }
    static let backdropLight = Color(backdropLightUI)
    static var backdropDark: Color { Color(backdropDarkUI) }

    /// Bed for chips that float over the terminal (the host/title pill, the
    /// command-result badge). The ground's hue, nearly black: the terminal's
    /// chrome belongs to the app, the terminal's cells do not.
    static var paneTitleBar: Color { Color(palette.chromeUI) }

    /// Bed for the title pill while the session is connected. Pushed cool,
    /// so a live remote session reads as remote at a glance.
    static let paneRemoteBar = Color(red: 0.07, green: 0.13, blue: 0.20)

    /// SSH cyan on the dark terminal bed — the remote-state hue for the
    /// glyph glow, the border, and the one-shot connect sweep. Terminal
    /// chrome only; on the ground and the sheet, `meter` is the live hue.
    static let sshAccent = Color(red: 0.45, green: 0.85, blue: 1.0)
    static let sshAccentDeep = Color(red: 0.10, green: 0.50, blue: 0.95)

    /// The one action colour: cream on the ground, ink on the sheet. A
    /// filled pill is always this, with `onAccent` text. Glyphs, numbers and
    /// controls on a cream surface are monochrome; colour is for beds and
    /// for status, never for a glyph.
    static let accent = dynamic(light: Brand.inkUI, dark: Brand.creamUI)
    /// A soft wash of the accent, for a chip or a secondary pill.
    static let accentSoft = dynamic(
        light: Brand.inkUI.withAlphaComponent(0.08),
        dark: UIColor(white: 1.0, alpha: 0.16))
    /// The bed of an ink panel: a neutral near-black, the same on every
    /// ground, so it never takes a tint the ground does not have.
    static let inkBed = Color(red: 0.07, green: 0.07, blue: 0.09)
    /// Text and glyphs drawn on top of `accent`.
    static let onAccent = dynamic(light: Brand.creamUI, dark: Brand.inkUI)
    static let highlight = Color(red: 1.00, green: 0.93, blue: 0.90)

    /// Non-adaptive accent for chrome that floats over the dark terminal in
    /// BOTH appearances (the session title pill, the key accessory row).
    static let accentOnDark = Brand.cream
    static let warning = Color(red: 1.00, green: 0.80, blue: 0.55)

    /// Meter and chart fill. Ink on the sheet; on the ground it is the
    /// cream, the way the current bar in a chart is the white one.
    static let meter = dynamic(light: Brand.inkUI, dark: Brand.creamUI)

    static let textPrimary = dynamic(
        light: Brand.inkUI.withAlphaComponent(0.94),
        dark: UIColor(white: 1.0, alpha: 0.97))
    static let textSecondary = dynamic(
        light: Brand.inkUI.withAlphaComponent(0.56),
        dark: UIColor(white: 1.0, alpha: 0.68))

    static let stroke = dynamic(
        light: UIColor(white: 0.0, alpha: 0.09),
        dark: UIColor(white: 1.0, alpha: 0.16))
    static let strokeStrong = dynamic(
        light: UIColor(white: 0.0, alpha: 0.16),
        dark: UIColor(white: 1.0, alpha: 0.28))

    /// Opaque bed for floating chrome when glass is off — white on the
    /// sheet, the ground's foot on the ground.
    static var panelBed: Color { dynamic(light: UIColor.white, dark: backdropDarkUI) }
    /// Opaque bed for a small raised chip.
    static var chipBed: Color { dynamic(light: UIColor.white, dark: backdropDarkUI) }
    /// Bed for a row in a long list: white on the sheet, a translucent
    /// white tile on the ground.
    static let rowBed = dynamic(
        light: UIColor.white,
        dark: UIColor(white: 1.0, alpha: 0.12))
    /// Pressed/selected row wash.
    static let selectionFill = dynamic(
        light: Brand.inkUI.withAlphaComponent(0.06),
        dark: UIColor(white: 1.0, alpha: 0.12))
    /// Translucent recessed wash for a heavier chrome bar.
    static let recessedWash = dynamic(
        light: UIColor(white: 0.0, alpha: 0.05),
        dark: UIColor(white: 0.0, alpha: 0.16))

    /// Spectrum for iridescent rims — light caught in a glass edge.
    ///
    /// Always an `AngularGradient` centred, at -40°, stroked 1–1.2pt, in
    /// `.plusLighter` on dark and `.normal` on light (additive light vanishes
    /// against white).
    static let iridescent: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.80).opacity(0.55),
        Color(red: 1.00, green: 0.62, blue: 0.70).opacity(0.35),
        Color(red: 1.00, green: 0.90, blue: 0.60).opacity(0.42),
        Color(red: 0.95, green: 0.75, blue: 1.00).opacity(0.30),
        Color(red: 1.00, green: 0.95, blue: 0.90).opacity(0.38),
        Color(red: 1.00, green: 0.85, blue: 0.80).opacity(0.55),
    ]

    /// Status hues. The only colours in the app that carry meaning on their
    /// own. Each has a deep cut for the cream sheet and a light cut for the
    /// crimson ground, because a red gem on a red ground says nothing.
    enum Status {
        static let neutral = dynamic(
            light: UIColor(red: 0.50, green: 0.42, blue: 0.46, alpha: 1),
            dark: UIColor(red: 0.95, green: 0.80, blue: 0.84, alpha: 1))
        static let working = dynamic(
            light: UIColor(red: 0.05, green: 0.48, blue: 0.85, alpha: 1),
            dark: UIColor(red: 0.60, green: 0.88, blue: 1.00, alpha: 1))
        static let attention = dynamic(
            light: UIColor(red: 0.85, green: 0.45, blue: 0.08, alpha: 1),
            dark: UIColor(red: 1.00, green: 0.75, blue: 0.40, alpha: 1))
        static let ready = dynamic(
            light: UIColor(red: 0.08, green: 0.58, blue: 0.32, alpha: 1),
            dark: UIColor(red: 0.50, green: 0.94, blue: 0.62, alpha: 1))
        static let danger = dynamic(
            light: UIColor(red: 0.78, green: 0.08, blue: 0.14, alpha: 1),
            dark: UIColor(red: 1.00, green: 0.62, blue: 0.62, alpha: 1))
    }

    /// Backgrounds for swipe actions and other places a system control paints
    /// **white text on our colour**. Taken deep enough to sit behind white.
    enum Action {
        static let destructive = Color(red: 0.72, green: 0.11, blue: 0.16)
        static let neutral     = Color(red: 0.30, green: 0.22, blue: 0.25)
        static let accent      = Color(red: 0.10, green: 0.42, blue: 0.80)
        static let caution     = Color(red: 0.72, green: 0.40, blue: 0.10)
    }

    /// The brand family: a warm red on warm cream, with a warm ink for type
    /// on the cream. This is the ground of the running app and the launch
    /// screen alike.
    enum Brand {
        static let crimsonUI = UIColor(red: 0.80, green: 0.10, blue: 0.16, alpha: 1)
        static let creamUI = UIColor(red: 0.957, green: 0.949, blue: 0.925, alpha: 1)
        static let inkUI = UIColor(red: 0.12, green: 0.05, blue: 0.07, alpha: 1)

        static let crimson = Color(crimsonUI)
        /// The signature red (#FF383C).
        static let red = Color(red: 1.00, green: 0.22, blue: 0.24)
        static let coral = Color(red: 1.00, green: 0.42, blue: 0.34)
        static let raspberry = Color(red: 0.96, green: 0.25, blue: 0.40)
        /// Warm cream (#F4F2EC) — explicitly not a cold white.
        static let cream = Color(creamUI)
        /// Type on the cream: a warm near-black, never a cold grey.
        static let ink = Color(inkUI)
    }

    // MARK: - Geometry

    /// Generously rounded — the chrome's shapes read as soft objects, never
    /// boxes. Every rounded rect in the app uses `style: .continuous`.
    static let cardCorner: CGFloat = 32
    static let panelCorner: CGFloat = 20
    static let briefingCorner: CGFloat = 24
    static let bubbleCorner: CGFloat = 30
    /// The cream sheet, and any modal that is one.
    static let sheetCorner: CGFloat = 34
    /// A stat tile on the ground.
    static let tileCorner: CGFloat = 24
    /// Gap between a terminal tile and the safe-area edge.
    static let paneInset: CGFloat = 12

    // MARK: - Chrome scale

    /// How large the chrome is drawn, as a multiple. The terminal has its own
    /// font size and is deliberately not touched by this — only the surfaces
    /// around it.
    ///
    /// Cached: `ui(_:)` is called once per text run per render, far too hot
    /// for a defaults lookup each time.
    nonisolated(unsafe) private static var uiScaleCache: CGFloat?
    static var uiScale: CGFloat {
        if let s = uiScaleCache { return s }
        let s = loadUIScale()
        uiScaleCache = s
        return s
    }
    static func reloadUIScale() { uiScaleCache = loadUIScale() }
    private static func loadUIScale() -> CGFloat {
        guard let v = UserDefaults.standard.object(forKey: "conterm.uiScale") as? Double
        else { return 1 }
        // Clamped hard: chrome sizes are tuned against fixed hit targets and
        // fixed bar heights, and a scale far outside this range doesn't shrink
        // the UI so much as break it.
        return CGFloat(min(max(v, 0.85), 1.25))
    }

    /// A chrome dimension at the user's scale. Every size in the chrome —
    /// font sizes, paddings, frame heights, icon sizes — routes through this,
    /// which is what makes the setting possible: there is no single view to
    /// scale, because the chrome is hundreds of hardcoded points.
    ///
    /// Rounded to a half point so text doesn't land on a fractional baseline
    /// and blur, which is the usual way a naive UI scale ends up looking cheap.
    static func ui(_ size: CGFloat) -> CGFloat {
        (size * uiScale * 2).rounded() / 2
    }

    /// The minimum comfortable touch target. Conterm's Mac chrome is built on
    /// an 8–13pt type scale against a pointer; a finger needs 44pt of target
    /// regardless of what is drawn inside it.
    static let hitTarget: CGFloat = 44

    // MARK: - Motion

    /// Four springs, reused everywhere. In Conterm's 47k lines `snappy` is
    /// used 225 times and `soft` 60 — treat those two as the defaults and the
    /// other two as special cases.
    enum Spring {
        /// The app's motion. Anything that appears, moves, or highlights.
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.85)
        /// Layout and mode changes, and staggered list reveals.
        static let soft = Animation.spring(response: 0.45, dampingFraction: 0.78)
        static let bouncy = Animation.spring(response: 0.50, dampingFraction: 0.62)
        /// Shorter, slightly damped — for changes where a long animation feels
        /// laggy because a whole subtree rebuilds underneath.
        static let crisp = Animation.spring(response: 0.22, dampingFraction: 0.88)
        /// The morph (`View.morph(on:)`): a changed value goes out of focus
        /// and the new one comes into focus in its place. About half a
        /// second and no overshoot — a blur that bounces reads as a glitch.
        static let morph = Animation.spring(response: 0.5, dampingFraction: 0.86)
        /// The release of a press. A control springs back under the finger
        /// with visible give — quicker than `bouncy`, same character.
        static let pop = Animation.spring(response: 0.36, dampingFraction: 0.58)
    }

    /// The standard crossfade. Used where a spring would be wrong — swapping
    /// content in place, especially over a Metal layer.
    static let crossfade = Animation.easeOut(duration: 0.12)
    /// Dismissals: things leave faster than they arrive, and without bounce.
    static let dismiss = Animation.easeIn(duration: 0.18)
}
