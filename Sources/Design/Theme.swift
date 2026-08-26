import SwiftUI
import UIKit

/// Canonical design tokens, carried over from Conterm on macOS so the two
/// apps read as one product. Spring presets are listed here once so every
/// animated transition uses the same physical language.
///
/// Visual identity: **neutral liquid glass**. No saturated tints — the
/// accent is a near-white cool that disappears into the material rather
/// than tinting it. Surfaces are translucent whites/blacks; the system
/// material does the heavy lifting. Colour appears in exactly three places:
/// status (`Status`), the one user-chosen action accent, and the warm-red
/// brand moment on the launch screen.
enum Theme {
    /// A color that resolves differently in light vs dark appearance.
    /// On macOS this reads the window's `NSAppearance`; on iOS the trait
    /// collection resolves it per view, which is strictly simpler.
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: - Palette — neutral, low-saturation

    /// The one ground the whole app sits on.
    ///
    /// Set once at the root; every screen below is transparent. Two
    /// near-blacks a few percent apart do not read as a design choice, they
    /// read as a seam — which is exactly what shipping `paneTile` under one
    /// view and `backdropDark` under the next produced.
    static let appBackground = Color(red: 0.039, green: 0.039, blue: 0.055)

    /// Opaque backing for a terminal surface. The terminal is a solid tile
    /// laid on the app's glass sheet — opaque so the glass shows only in the
    /// chrome and gaps, and so the streaming region never blends against
    /// whatever is behind it. Near-black to frame the cells at the rounded edge.
    static let paneTile = Color(red: 0.05, green: 0.055, blue: 0.075)

    /// Backdrop tint endpoints, shared by the material tints and the app
    /// backdrops so the light/dark washes agree across glass and solid modes.
    /// Alphas are applied per surface.
    static let backdropLightUI = UIColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1)
    static let backdropDarkUI = UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
    static let backdropLight = Color(backdropLightUI)
    static let backdropDark = Color(backdropDarkUI)

    /// Solid bed for chips that float over the terminal (the host/title pill,
    /// the command-result badge). Opaque so they read as solid chips, a step
    /// lighter than `paneTile` for separation.
    static let paneTitleBar = Color(red: 0.12, green: 0.13, blue: 0.16)

    /// Bed for the title pill while the session is connected. Same lightness
    /// as `paneTitleBar` but pushed cool, so a live remote session reads as
    /// remote at a glance with no per-frame cost.
    static let paneRemoteBar = Color(red: 0.07, green: 0.13, blue: 0.20)

    /// SSH cyan on the dark pill bed — the remote-state hue for the glyph
    /// glow, the border, and the one-shot connect sweep.
    static let sshAccent = Color(red: 0.45, green: 0.85, blue: 1.0)
    /// SSH blue for a light bed, where the bright cyan would wash out.
    static let sshAccentDeep = Color(red: 0.10, green: 0.50, blue: 0.95)

    /// Accent: near-white cool on dark, near-black cool on light. Stays
    /// neutral (not a saturated blue) so it doesn't tint the whole UI.
    static let accent = dynamic(
        light: UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0),
        dark: UIColor(red: 0.92, green: 0.96, blue: 1.00, alpha: 1.0))
    static let accentSoft = dynamic(
        light: UIColor(white: 0.0, alpha: 0.10),
        dark: UIColor(white: 1.0, alpha: 0.14))
    static let highlight = Color(red: 0.85, green: 0.95, blue: 1.00)

    /// Non-adaptive accent for chrome that floats over the dark terminal in
    /// BOTH appearances (the session title pill, the key accessory row). The
    /// regular `accent` flips near-black in light mode and would vanish
    /// against that bed — this stays the cool near-white.
    static let accentOnDark = Color(red: 0.92, green: 0.96, blue: 1.00)
    static let warning = Color(red: 1.00, green: 0.80, blue: 0.55)

    static let textPrimary = dynamic(
        light: UIColor(white: 0.0, alpha: 0.88),
        dark: UIColor(white: 1.0, alpha: 0.96))
    static let textSecondary = dynamic(
        light: UIColor(white: 0.0, alpha: 0.55),
        dark: UIColor(white: 1.0, alpha: 0.55))

    static let stroke = dynamic(
        light: UIColor(white: 0.0, alpha: 0.10),
        dark: UIColor(white: 1.0, alpha: 0.08))
    static let strokeStrong = dynamic(
        light: UIColor(white: 0.0, alpha: 0.16),
        dark: UIColor(white: 1.0, alpha: 0.18))

    /// Opaque bed for floating chrome when glass is off — a clean near-white
    /// on light (kept bright so a darkening wash on top doesn't turn it muddy
    /// grey), near-black on dark.
    static let panelBed = dynamic(
        light: UIColor(red: 0.975, green: 0.978, blue: 0.985, alpha: 1.0),
        dark: UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0))
    /// Opaque bed for a small raised chip. Near-black on dark to match the
    /// panels — the hairline rim defines the disc — near-white on light.
    /// Opaque so it neither samples the backdrop nor needs a shadow.
    static let chipBed = dynamic(
        light: UIColor(white: 0.88, alpha: 1.0),
        dark: UIColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1.0))
    /// Opaque bed for a row in a long list. A list is a wide expanse where
    /// translucent rows over a backdrop read as noise, so the row goes opaque.
    static let rowBed = dynamic(
        light: UIColor(white: 0.97, alpha: 1.0),
        dark: UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0))
    /// Pressed/selected row wash.
    static let selectionFill = dynamic(
        light: UIColor(white: 0.0, alpha: 0.06),
        dark: UIColor(white: 1.0, alpha: 0.08))
    /// Translucent recessed wash for a heavier chrome bar — a veil that sinks
    /// the bar a step below the glass around it. Lighter in light mode so it
    /// reads as a subtle recess instead of a muddy black slab.
    static let recessedWash = dynamic(
        light: UIColor(white: 0.0, alpha: 0.06),
        dark: UIColor(white: 0.0, alpha: 0.18))

    /// Spectrum for iridescent rims — light caught in a glass edge. Shared by
    /// the Host Overview card and the affordance that opens it, so the button
    /// visually promises the surface it leads to.
    ///
    /// Always an `AngularGradient` centred, at -40°, stroked 1–1.2pt, in
    /// `.plusLighter` on dark and `.normal` on light (additive light vanishes
    /// against white).
    static let iridescent: [Color] = [
        Color(red: 0.55, green: 0.85, blue: 1.00).opacity(0.55),
        Color(red: 0.72, green: 0.58, blue: 1.00).opacity(0.35),
        Color(red: 1.00, green: 0.62, blue: 0.78).opacity(0.42),
        Color(red: 1.00, green: 0.85, blue: 0.55).opacity(0.30),
        Color(red: 0.58, green: 0.95, blue: 0.80).opacity(0.38),
        Color(red: 0.55, green: 0.85, blue: 1.00).opacity(0.55),
    ]

    /// Status hues. The only colours in the app that carry meaning on their
    /// own — everything else in the chrome is monochrome, which is what makes
    /// these legible at a glance in a long list of hosts.
    enum Status {
        static let neutral = Color(red: 0.46, green: 0.56, blue: 0.74)
        static let working = Color(red: 0.42, green: 0.82, blue: 1.00)
        static let attention = Color(red: 0.97, green: 0.58, blue: 0.28)
        static let ready = Color(red: 0.40, green: 0.86, blue: 0.56)
        static let danger = Color(red: 1.00, green: 0.36, blue: 0.36)
    }

    /// Backgrounds for swipe actions and other places a system control paints
    /// **white text on our colour**.
    ///
    /// The `Status` palette above is tuned for coloured text on a dark bed,
    /// which is the opposite problem: `Status.danger` and `Status.working`
    /// are light enough that white on top of them barely reads. These are the
    /// same hues taken deep enough to sit behind white — the crimson is the
    /// brand's own, so destructive still looks like Conterm rather than like
    /// the system red.
    enum Action {
        static let destructive = Color(red: 0.72, green: 0.11, blue: 0.16)
        static let neutral     = Color(red: 0.16, green: 0.18, blue: 0.23)
        static let accent      = Color(red: 0.10, green: 0.42, blue: 0.80)
        static let caution     = Color(red: 0.72, green: 0.40, blue: 0.10)
    }

    /// The marketing identity, deliberately distinct from the running app's
    /// cool neutral chrome: a warm red family on warm cream. Used on the
    /// launch screen and nowhere else.
    enum Brand {
        static let crimson = Color(red: 0.80, green: 0.10, blue: 0.16)
        /// The signature red (#FF383C).
        static let red = Color(red: 1.00, green: 0.22, blue: 0.24)
        static let coral = Color(red: 1.00, green: 0.42, blue: 0.34)
        static let raspberry = Color(red: 0.96, green: 0.25, blue: 0.40)
        /// Warm cream (#F4F2EC) — explicitly not a cold white.
        static let cream = Color(red: 0.957, green: 0.949, blue: 0.925)
    }

    // MARK: - Geometry

    /// Generously rounded — the chrome's shapes read as soft glass, never
    /// boxes. Every rounded rect in the app uses `style: .continuous`.
    static let cardCorner: CGFloat = 22
    static let panelCorner: CGFloat = 16
    static let briefingCorner: CGFloat = 18
    static let bubbleCorner: CGFloat = 26
    static let sheetCorner: CGFloat = 20
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
    }

    /// The standard crossfade. Used where a spring would be wrong — swapping
    /// content in place, especially over a Metal layer.
    static let crossfade = Animation.easeOut(duration: 0.12)
    /// Dismissals: things leave faster than they arrive, and without bounce.
    static let dismiss = Animation.easeIn(duration: 0.18)
}
