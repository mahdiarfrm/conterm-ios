import SwiftUI

// MARK: - The glass model
//
// Conterm's `docs/GLASS-REDESIGN.md` settled this on macOS and it holds here:
// the app shows **one sheet of real glass** and everything on top of it is a
// **flat lens** — a plain translucent fill with a lit rim. Never nest glass
// inside glass. A second real glass view pays a per-frame re-lens and, on
// AppKit, draws black-line artifacts where the two stack; on iOS it reads as
// muddy rather than broken, which is worse because you ship it.
//
// The other rule from that doc, restated because it is easy to lose: glass
// only looks like glass when there is *varied content behind it*. Over a flat
// dark screen "translucent" has nothing to be translucent to and reads as a
// tinted panel. Whatever hosts these surfaces needs a real backdrop.

/// Whether the chrome is drawn light-on-dark or dark-on-light. Threaded
/// explicitly rather than read from the environment so a surface floating
/// over the terminal (always dark) can opt out of the app's appearance.
enum ChromeTone {
    case dark
    case light

    static func resolve(_ scheme: ColorScheme) -> ChromeTone {
        scheme == .dark ? .dark : .light
    }

    /// Additive light disappears against white, so the rim highlights blend
    /// normally on a light chrome and additively on a dark one.
    var rimBlend: BlendMode { self == .dark ? .plusLighter : .normal }
}

/// Translucent fill for a chrome control. `selected` lifts it a touch so an
/// active control reads as more present without changing the material.
func chromeFill(_ tone: ChromeTone, selected: Bool = false) -> Color {
    switch tone {
    case .light: return Color.white.opacity(selected ? 0.58 : 0.40)
    case .dark: return Color.black.opacity(selected ? 0.32 : 0.20)
    }
}

/// Hairline top-edge highlight for a chrome capsule — the "wet" light that
/// catches the rim. Pair with `tone.rimBlend`.
func chromeEdge(_ tone: ChromeTone) -> [Color] {
    switch tone {
    case .light: return [Color.white.opacity(0.85), Color.white.opacity(0.20)]
    case .dark: return [Color.white.opacity(0.30), Color.white.opacity(0.06)]
    }
}

// MARK: - Flat lens

/// The workhorse. Every pill, chip, tag, badge and cluster in the app is
/// this: a flat fill plus a 0.5pt top-lit gradient stroke. It costs nothing
/// per frame and it is the single most recognisable thing about the chrome.
struct GlassPill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var tone: ChromeTone?
    var selected: Bool = false

    private var resolved: ChromeTone { tone ?? .resolve(scheme) }

    func body(content: Content) -> some View {
        content
            .background(Capsule(style: .continuous).fill(chromeFill(resolved, selected: selected)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: chromeEdge(resolved),
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                    .blendMode(resolved.rimBlend)
                    .allowsHitTesting(false)
            )
    }
}

/// The same lens on a rounded rect, for anything too big to be a capsule.
struct GlassTile: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat
    var tone: ChromeTone?
    var selected: Bool = false

    private var resolved: ChromeTone { tone ?? .resolve(scheme) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(chromeFill(resolved, selected: selected)))
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(colors: chromeEdge(resolved),
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                    .blendMode(resolved.rimBlend)
                    .allowsHitTesting(false)
            )
    }
}

/// A floating control that gets *real* Liquid Glass where the OS has it.
///
/// Reserved for chrome that floats over content on its own — the palette bar,
/// a docked action. Anything sitting inside a `glassPanel` keeps the flat
/// lens, because glass over glass pays a second lensing pass and reads muddy.
struct FloatingGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            content.modifier(GlassPill(tone: .resolve(scheme)))
        }
    }
}

extension View {
    /// Wrap a pill-shaped control in the flat chrome lens.
    func glassPill(tone: ChromeTone? = nil, selected: Bool = false) -> some View {
        modifier(GlassPill(tone: tone, selected: selected))
    }

    /// Floating chrome: real glass on iOS 26, flat lens below.
    func floatingGlass() -> some View { modifier(FloatingGlass()) }

    /// Conditionally wrap — when `enabled` is false the view is returned
    /// bare. Used by clusters that supply one shared surface for a row of
    /// controls instead of one lens per control, which is the right call
    /// whenever the controls belong together.
    @ViewBuilder
    func glassPill(enabled: Bool, tone: ChromeTone? = nil) -> some View {
        if enabled { glassPill(tone: tone) } else { self }
    }

    func glassTile(cornerRadius: CGFloat,
                   tone: ChromeTone? = nil,
                   selected: Bool = false) -> some View {
        modifier(GlassTile(cornerRadius: cornerRadius, tone: tone, selected: selected))
    }
}

// MARK: - Panels

/// The four-layer panel recipe: a material bed, a hairline that defines the
/// edge, a top-lit rim that makes it read as glass rather than frost, and a
/// large soft shadow that lifts it off whatever is behind.
///
/// On iOS 26 the bed can be real Liquid Glass; below that it falls back to
/// `.ultraThinMaterial`, which is what Conterm does on macOS 14–15 and what
/// the whole flat-lens system above was designed around. The fallback is not
/// a degraded mode — it is the design.
struct GlassPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat
    var shadowRadius: CGFloat = 30
    var shadowY: CGFloat = 12
    /// Adds the iridescent angular rim between the hairline and the sheen.
    /// Reserved for briefing surfaces — a card that opens onto real detail
    /// about a machine. Using it everywhere would spend the signal.
    var iridescent: Bool = false

    private var tone: ChromeTone { .resolve(scheme) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(bed(shape))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .overlay(iridescentRim(shape))
            .overlay(
                shape
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.32), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                    .blendMode(tone.rimBlend)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.45), radius: shadowRadius, x: 0, y: shadowY)
    }

    @ViewBuilder
    private func bed(_ shape: RoundedRectangle) -> some View {
        if #available(iOS 26, *) {
            shape.fill(.ultraThinMaterial).glassEffect(in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func iridescentRim(_ shape: RoundedRectangle) -> some View {
        if iridescent {
            shape
                .stroke(
                    AngularGradient(colors: Theme.iridescent,
                                    center: .center,
                                    angle: .degrees(-40)),
                    lineWidth: 1.2)
                .blendMode(tone.rimBlend)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.panelCorner,
                    shadowRadius: CGFloat = 30,
                    shadowY: CGFloat = 12,
                    iridescent: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius,
                            shadowRadius: shadowRadius,
                            shadowY: shadowY,
                            iridescent: iridescent))
    }

    /// A briefing surface — the Host Overview card and its kin. Slightly
    /// tighter shadow than a modal, plus the iridescent rim.
    func briefingCard() -> some View {
        glassPanel(cornerRadius: Theme.briefingCorner,
                   shadowRadius: 26,
                   shadowY: 12,
                   iridescent: true)
    }
}

// MARK: - Refraction

/// The three overlays that make a blurred surface read as *glass* rather
/// than flat frost: a crisp specular top edge, a soft diagonal sheen, and a
/// bottom inner shadow. Layer over a material, never over a solid colour.
struct GlassRefraction: View {
    @Environment(\.colorScheme) private var scheme
    private var tone: ChromeTone { .resolve(scheme) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .blendMode(tone.rimBlend)

            LinearGradient(colors: [.white.opacity(0.10), .clear],
                           startPoint: .topLeading, endPoint: .center)
                .blendMode(tone.rimBlend)

            VStack {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 54)
                    .blendMode(.multiply)
            }
        }
        .allowsHitTesting(false)
    }
}
