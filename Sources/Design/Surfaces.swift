import SwiftUI

// MARK: - The two surfaces
//
// The app has exactly two: the crimson ground, and the cream sheet laid on
// it. A screen is on the ground; a document you read closely (a list of
// hosts, a form, settings) is on a sheet. The ground runs in the dark
// appearance and the sheet in the light one, which is how every dynamic
// token knows which surface it is on without being told.

/// The ground: the chosen hue, flat and bright, under everything. No
/// gradient and no clock — it is painted once and redrawn only when the
/// setting changes, which it watches so a new colour lands under every
/// screen at once.
struct BrandGround: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        let palette = GroundPalette.named(prefs.ground)
        ZStack {
            palette.flat
            if prefs.smoke || palette.alwaysSmokes {
                Smoke(palette: palette)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Spring.morph, value: prefs.ground)
        .animation(Theme.crossfade, value: prefs.smoke)
    }
}

/// Smoke: wisps in the ground's own family, lighter and darker than it,
/// drifting and turning slowly under everything, the way smoke moves
/// under a light. Drawn as soft radial gradients on a canvas rather than
/// blurred views, so a frame costs almost nothing, and paused under Reduce
/// Motion, where it holds one still frame.
struct Smoke: View {
    var palette: GroundPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Wisp {
        let speed: Double
        let phase: Double
        let orbit: CGSize
        let anchor: UnitPoint
        let radius: CGFloat
        let light: Bool
        let strength: Double
    }

    private static let wisps: [Wisp] = [
        Wisp(speed: 0.30, phase: 0.0, orbit: CGSize(width: 0.32, height: 0.22),
             anchor: UnitPoint(x: 0.25, y: 0.22), radius: 0.62, light: true, strength: 0.9),
        Wisp(speed: 0.22, phase: 1.9, orbit: CGSize(width: 0.26, height: 0.30),
             anchor: UnitPoint(x: 0.78, y: 0.30), radius: 0.55, light: false, strength: 0.8),
        Wisp(speed: 0.36, phase: 3.7, orbit: CGSize(width: 0.34, height: 0.24),
             anchor: UnitPoint(x: 0.55, y: 0.72), radius: 0.66, light: true, strength: 0.75),
        Wisp(speed: 0.19, phase: 5.1, orbit: CGSize(width: 0.22, height: 0.28),
             anchor: UnitPoint(x: 0.18, y: 0.82), radius: 0.50, light: false, strength: 0.7),
        Wisp(speed: 0.44, phase: 2.6, orbit: CGSize(width: 0.40, height: 0.18),
             anchor: UnitPoint(x: 0.50, y: 0.48), radius: 0.36, light: true, strength: 0.55),
        Wisp(speed: 0.27, phase: 4.4, orbit: CGSize(width: 0.20, height: 0.34),
             anchor: UnitPoint(x: 0.85, y: 0.80), radius: 0.40, light: false, strength: 0.6),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let reach = max(size.width, size.height)
                let lighter = Color(mix(palette.topUI, .white, palette.alwaysSmokes ? 0.42 : 0.34))
                let darker = Color(mix(palette.topUI, .black, 0.48))
                for wisp in Self.wisps {
                    let a = t * wisp.speed + wisp.phase
                    // Two frequencies, so the path never repeats exactly and
                    // the wisp turns rather than swings.
                    let x = (wisp.anchor.x + wisp.orbit.width * CGFloat(sin(a) * 0.7 + sin(a * 0.37) * 0.3)) * size.width
                    let y = (wisp.anchor.y + wisp.orbit.height * CGFloat(cos(a * 0.8) * 0.7 + cos(a * 0.29) * 0.3)) * size.height
                    let breathe = 1 + 0.12 * CGFloat(sin(a * 0.6 + wisp.phase))
                    let r = reach * wisp.radius * breathe
                    let tint = wisp.light ? lighter : darker
                    let peak = wisp.strength * (wisp.light ? 0.85 : 0.7)
                    let shading = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [.init(color: tint.opacity(peak), location: 0),
                                         .init(color: tint.opacity(peak * 0.45), location: 0.45),
                                         .init(color: tint.opacity(0), location: 1)]),
                        center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r)
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: shading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A modal that is a sheet: cream, in the light appearance, with the
/// crimson as its action colour. Used on presentations — the settings, an
/// editor, the key library.
private struct CreamSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Brand.cream.ignoresSafeArea())
            .preferredColorScheme(.light)
            .environment(\.colorScheme, .light)
            .tint(Theme.Brand.ink)
    }
}

/// A card that is a sheet laid on the ground, inline: cream, rounded on
/// every corner, light appearance inside. The home screen's host list sits
/// in one of these under the readouts.
private struct CreamCard: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Theme.Brand.cream)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.colorScheme, .light)
            .tint(Theme.Brand.ink)
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }
}

extension View {
    /// Paint the ground behind this screen.
    func brandGround() -> some View { background(BrandGround().ignoresSafeArea()) }

    /// Make this presentation a cream sheet.
    func creamSheet() -> some View { modifier(CreamSheet()) }

    /// Lay this content on a cream card on the ground.
    func creamCard(cornerRadius: CGFloat = Theme.sheetCorner) -> some View {
        modifier(CreamCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Pills

/// A filled pill: the accent with `onAccent` text. Cream on the ground,
/// crimson on the sheet.
struct FilledPill: ViewModifier {
    var height: CGFloat = Theme.hitTarget

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(Theme.accent))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// A soft pill: a wash of the accent with accent text. The secondary
/// action beside a `FilledPill`.
struct SoftPill: ViewModifier {
    var height: CGFloat = Theme.hitTarget

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(Theme.accentSoft))
    }
}

extension View {
    func filledPill(height: CGFloat = Theme.hitTarget) -> some View {
        modifier(FilledPill(height: height))
    }
    func softPill(height: CGFloat = Theme.hitTarget) -> some View {
        modifier(SoftPill(height: height))
    }
}

/// A small badge in a row: a wash of the tint with the tint as text.
struct BadgePill: ViewModifier {
    var tint: Color = Theme.accent

    func body(content: Content) -> some View {
        content
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
    }
}

extension View {
    func badgePill(tint: Color = Theme.accent) -> some View { modifier(BadgePill(tint: tint)) }
}
