import SwiftUI
import UIKit

/// The design language for everything Conterm draws outside its own window.
///
/// Taken from the Mac app's own `Theme.swift` and `LiquidGlass.swift` rather
/// than invented here, because two apps called Conterm should not look like
/// two products. Ported by value: a widget extension cannot import the app's
/// design layer, so the tokens are copied and the file says where from.
///
/// **What it looks like.** A near-black bed with one soft wash of the brand
/// red in a corner — the same crimson/signature-red/coral family the launch
/// overlay uses, at a fraction of the opacity, so it reads as warmth rather
/// than as decoration. Chrome is flat glass: a black fill with a hairline
/// top-lit rim in `.plusLighter`, which is the house signature and is on
/// nearly every surface in the Mac app. Rounded SF for names, monospaced
/// digits for anything that changes, amber for the one thing that wants you.
///
/// **What it replaced, twice.** First a rounded card with a grey stroke and a
/// rainbow hairline — every developer-tool widget ever made, and against the
/// project's own written rules. Then a literal terminal, `~ %` prompt and
/// all, which was distinctive but was a costume: Conterm's chrome has never
/// looked like a terminal, and a widget that does belongs to a different app.
enum CT {

    // MARK: - Beds  (Theme.paneTile, Theme.paneTitleBar)

    static let bed = Color(red: 0.050, green: 0.055, blue: 0.075)
    static let bedLift = Color(red: 0.090, green: 0.098, blue: 0.125)

    // MARK: - Brand  (LaunchOverlay's red family)

    static let crimson = Color(red: 0.80, green: 0.10, blue: 0.16)
    static let signature = Color(red: 1.00, green: 0.22, blue: 0.24)
    static let coral = Color(red: 1.00, green: 0.42, blue: 0.34)

    // MARK: - Ink  (Theme.accentOnDark, textSecondary)

    static let text = Color(red: 0.92, green: 0.96, blue: 1.00)
    static let dim = Color(red: 0.62, green: 0.68, blue: 0.78)
    static let faint = Color(red: 0.42, green: 0.48, blue: 0.58)

    // MARK: - Status  (AgentCenterOverlay's AgentColor)

    static let ready = Color(red: 0.30, green: 0.82, blue: 0.46)
    static let working = Color(red: 0.22, green: 0.56, blue: 1.00)
    static let attention = Color(red: 1.00, green: 0.62, blue: 0.12)
    static let idle = Color(red: 0.66, green: 0.69, blue: 0.76)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.34)

    static func tint(_ phase: ContermSnapshot.Phase) -> Color {
        switch phase {
        case .connected: return ready
        case .connecting: return working
        case .closed: return idle
        case .failed: return danger
        }
    }

    static func tint(_ kind: ContermSnapshot.Signal.Kind) -> Color {
        switch kind {
        case .agentWaiting: return attention
        case .hostDown: return danger
        case .sessionLost: return working
        case .note: return idle
        }
    }

    static func symbol(_ kind: ContermSnapshot.Signal.Kind) -> String {
        switch kind {
        case .agentWaiting: return "sparkles"
        case .hostDown: return "exclamationmark.triangle.fill"
        case .sessionLost: return "bolt.horizontal.fill"
        case .note: return "circle.fill"
        }
    }

    // MARK: - Type
    //
    // Rounded for chrome, monospaced digits for anything that changes —
    // the Mac app's rule, and the reason a column of times lines up.

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: - Surfaces

    /// The bed, with one soft wash of brand red.
    ///
    /// A radial, off the top-right corner, at a few percent. It is the only
    /// colour on the surface that does not mean something, and it is kept
    /// below the threshold where it would read as a tint — the Mac app files
    /// coloured ambient backdrops under dead ends, and this stays on the
    /// right side of that by a wide margin.
    struct Ground: View {
        var body: some View {
            GeometryReader { geo in
                // The radius has to scale with the surface. Fixed at 260pt it
                // was a soft corner glow on a large widget and a wash over the
                // entire card on a small one, which read as a maroon tint
                // rather than as warmth.
                let reach = max(geo.size.width, geo.size.height)
                ZStack {
                    LinearGradient(colors: [bedLift, bed],
                                   startPoint: .top, endPoint: .bottom)
                    RadialGradient(
                        colors: [signature.opacity(0.13), crimson.opacity(0.05), .clear],
                        center: UnitPoint(x: 0.95, y: -0.05),
                        startRadius: 0, endRadius: reach * 0.78)
                    RadialGradient(
                        colors: [coral.opacity(0.04), .clear],
                        center: UnitPoint(x: 0.02, y: 1.05),
                        startRadius: 0, endRadius: reach * 0.55)
                }
            }
        }
    }

    /// The flat glass capsule: a black fill and a hairline top-lit rim in
    /// `.plusLighter`. Straight out of `LiquidGlass.swift` — `chromeFill` is
    /// black at 0.20, `chromeEdge` runs white 0.30 to white 0.06.
    struct Chip<Content: View>: View {
        var tint: Color?
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(tint?.opacity(0.16) ?? Color.black.opacity(0.20))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                }
        }
    }

    /// The status mark: a lit dot. The Mac app's gem, unchanged.
    struct Gem: View {
        var color: Color
        var size: CGFloat = 7

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.75), radius: size * 0.62)
        }
    }

    /// One session: gem, name, and a right-aligned clock that ticks itself.
    struct SessionRow: View {
        var session: ContermSnapshot.Session
        var size: CGFloat = 14

        var body: some View {
            HStack(spacing: 8) {
                Gem(color: CT.tint(session.phase), size: size * 0.5)
                Text(session.alias)
                    .font(CT.ui(size, .semibold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if session.ordinal > 1 {
                    Text("\(session.ordinal)")
                        .font(CT.ui(size * 0.68, .bold))
                        .foregroundStyle(CT.faint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                Spacer(minLength: 6)
                Text(session.startedAt, style: .timer)
                    .font(CT.ui(size * 0.88, .medium))
                    .foregroundStyle(CT.dim)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: size * 3.9, alignment: .trailing)
            }
        }
    }

    /// One signal. The single amber thing on a surface, so it is the thing
    /// your eye lands on.
    struct SignalRow: View {
        var signal: ContermSnapshot.Signal
        var size: CGFloat = 13

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: CT.symbol(signal.kind))
                    .font(.system(size: size * 0.82, weight: .bold))
                    .foregroundStyle(CT.tint(signal.kind))
                Text(signal.title)
                    .font(CT.ui(size, .semibold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if let detail = signal.detail {
                    Text(detail)
                        .font(CT.ui(size * 0.82, .medium))
                        .foregroundStyle(CT.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The real wordmark, as a template image, lit.
    ///
    /// The same `text-logo.png` the app's header uses — it is now in the
    /// extension's bundle too, so the two never drift. Filled with a gradient
    /// that runs from near-white to coral and given a soft red bloom, which
    /// is as close to the Mac app's lit chrome as a static snapshot can get.
    struct Logo: View {
        var height: CGFloat = 15

        private static let image: UIImage? = {
            if let named = UIImage(named: "text-logo") {
                return named.withRenderingMode(.alwaysTemplate)
            }
            if let url = Bundle.main.url(forResource: "text-logo", withExtension: "png"),
               let data = try? Data(contentsOf: url),
               let loaded = UIImage(data: data) {
                return loaded.withRenderingMode(.alwaysTemplate)
            }
            return nil
        }()

        var body: some View {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .foregroundStyle(
                        LinearGradient(colors: [CT.text, CT.text, CT.coral],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing))
                    .shadow(color: CT.signature.opacity(0.45), radius: height * 0.42)
            } else {
                // Decorative; a missing asset must not leave a hole.
                Text("CONTERM")
                    .font(.system(size: height * 0.72, weight: .black, design: .rounded)
                        .width(.expanded))
                    .foregroundStyle(CT.text)
            }
        }
    }

    /// The wordmark, with the brand dot. Small, and only where there is room.
    struct Mark: View {
        var size: CGFloat = 13

        var body: some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(colors: [CT.signature, CT.crimson],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .shadow(color: CT.signature.opacity(0.6), radius: size * 0.35)
                Text("Conterm")
                    .font(CT.ui(size, .bold))
                    .foregroundStyle(CT.text)
            }
        }
    }

    // MARK: - Helpers

    static func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f kB", Double(n) / 1024) }
        return "\(n) B"
    }
}
