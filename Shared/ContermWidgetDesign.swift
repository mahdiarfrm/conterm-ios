import SwiftUI
import UIKit

/// The design language for everything Conterm draws outside its own window:
/// the home screen widgets, the lock screen, the Dynamic Island.
///
/// The app's own language, ported by value — a widget extension cannot
/// import the app's design layer, so the tokens are copied and the file
/// says where each comes from. One bold ground, the one chosen in Settings
/// and carried in the snapshot; translucent white tiles and capsules with a
/// lit rim on it; the number first and large with a glyph and a word
/// beneath; Manrope for everything that is read. Colour means state and
/// nothing else, in the light cuts the ground can carry.
enum CT {

    // MARK: - Ground  (Theme.Ground, BrandGround)

    static func palette(_ id: String?) -> GroundPalette { GroundPalette.named(id) }

    // MARK: - Ink  (Theme.textPrimary, textSecondary, Brand)

    static let text = Color.white.opacity(0.97)
    static let dim = Color.white.opacity(0.70)
    static let faint = Color.white.opacity(0.48)
    static let cream = Color(red: 0.957, green: 0.949, blue: 0.925)
    static let ink = Color(red: 0.12, green: 0.05, blue: 0.07)

    // MARK: - Status  (Theme.Status, the light cuts)

    static let ready = Color(red: 0.50, green: 0.94, blue: 0.62)
    static let working = Color(red: 0.60, green: 0.88, blue: 1.00)
    static let attention = Color(red: 1.00, green: 0.75, blue: 0.40)
    static let idle = Color(red: 0.95, green: 0.80, blue: 0.84)
    static let danger = Color(red: 1.00, green: 0.62, blue: 0.62)

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

    // MARK: - Type  (TextFace)

    /// Manrope where the bundle has it, the rounded system face otherwise.
    /// Both targets bundle the file and list it in their Info.plist.
    private static let hasFace: Bool = UIFont(name: "Manrope-Regular", size: 12) != nil

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        guard hasFace else { return .system(size: size, weight: weight, design: .rounded) }
        let name: String
        switch weight {
        case .ultraLight, .thin: name = "Manrope-ExtraLight"
        case .light: name = "Manrope-Light"
        case .medium: name = "Manrope-Medium"
        case .semibold: name = "Manrope-SemiBold"
        case .bold: name = "Manrope-Bold"
        case .heavy, .black: name = "Manrope-ExtraBold"
        default: name = "Manrope-Regular"
        }
        return .custom(name, fixedSize: size)
    }

    // MARK: - Surfaces

    /// The ground: the chosen hue, flat. A widget is small and sits among
    /// others; a gradient on it reads as a picture rather than a surface.
    struct Ground: View {
        var palette: GroundPalette = .crimson

        var body: some View {
            palette.flat
        }
    }

    /// The flat lens: a translucent white fill and a hairline top-lit rim.
    /// `glassTile`, by value.
    struct Tile<Content: View>: View {
        var cornerRadius: CGFloat = 18
        var padding: CGFloat = 12
        var lit: Bool = false
        @ViewBuilder var content: Content

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .padding(padding)
                .background(shape.fill(Color.white.opacity(lit ? 0.24 : 0.14)))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                    .blendMode(.plusLighter))
        }
    }

    /// The same lens on a capsule. `glassPill`.
    struct Chip<Content: View>: View {
        var tint: Color?
        var lit: Bool = false
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(tint?.opacity(0.22) ?? Color.white.opacity(lit ? 0.26 : 0.15))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                }
        }
    }

    /// The status mark: a lit dot.
    struct Gem: View {
        var color: Color
        var size: CGFloat = 7

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }

    /// The number first and large, the meaning beneath it as a glyph and a
    /// word. `Readout`, by value.
    struct Readout: View {
        var value: String
        var label: String
        var symbol: String?
        var size: CGFloat = 28
        var tint: Color = CT.text

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(CT.ui(size, .bold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.34, weight: .semibold))
                    }
                    Text(label)
                        .font(CT.ui(size * 0.4, .semibold))
                }
                .foregroundStyle(CT.dim)
                .lineLimit(1)
            }
        }
    }

    /// A short history as small capsules, the newest lit. Static — a widget
    /// cannot animate — but the shape the app's charts take.
    struct Bars: View {
        var values: [Double]
        var slots: Int = 12
        var height: CGFloat = 22
        var tint: Color = CT.cream

        var body: some View {
            GeometryReader { geo in
                let padding = max(slots - values.count, 0)
                let all = Array(repeating: -1.0, count: padding) + values
                // Thin capsules spread across the width, never fat ones: a
                // bar wider than it is tall is a dot, not a bar.
                let width = min(max((geo.size.width - 3 * CGFloat(slots - 1)) / CGFloat(slots), 2), 7)
                let gap = max((geo.size.width - width * CGFloat(slots)) / CGFloat(max(slots - 1, 1)), 2)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(all.enumerated()), id: \.offset) { index, v in
                        let empty = v < 0
                        let last = index == all.count - 1
                        Capsule(style: .continuous)
                            .fill(empty ? Color.white.opacity(0.10)
                                  : tint.opacity(last ? 1 : 0.55))
                            .frame(width: width,
                                   height: empty ? width : max(width, height * CGFloat(min(max(v, 0), 1))))
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .bottomLeading)
            }
            .frame(height: height)
        }
    }

    /// One session as a row: the gem, the name, the shell number when it
    /// means something, and a clock that ticks itself.
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
                        .foregroundStyle(CT.dim)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                Spacer(minLength: 6)
                Text(session.startedAt, style: .timer)
                    .font(CT.ui(size * 0.9, .semibold))
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

    /// The wordmark, as a template image in the cream. The same
    /// `text-logo.png` the app's bar carries.
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
                    .foregroundStyle(CT.cream)
            } else {
                // Decorative; a missing asset must not leave a hole.
                Text("Conterm")
                    .font(CT.ui(height * 0.8, .bold))
                    .foregroundStyle(CT.cream)
            }
        }
    }

    // MARK: - Helpers

    static func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }

    /// The elapsed time as a short word: "2h 15m", "48s".
    static func elapsed(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }
}
