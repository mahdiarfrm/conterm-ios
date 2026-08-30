import SwiftUI

/// The design language for everything Conterm draws outside its own window.
///
/// **The idea.** A terminal has exactly one iconic mark: the block cursor.
/// Every surface here is built around it — it is the bullet before a host
/// name, the unit of the fleet rail, and the thing that blinks when something
/// is live. Next to it sits one hairline of the house iridescence along the
/// top edge, and nothing else is allowed to be colourful. Status is the only
/// colour, so colour always means something.
///
/// **Why it is a system rather than three layouts.** Widgets accumulate
/// features, and the usual result is five sizes that each grew their own
/// idea of a row. So the pieces are defined once here — `Plate`, `Cursor`,
/// `Gem`, `Rail`, `Readout`, `SignalRow` — and every size is assembled from
/// them. A new feature emits a `ContermSnapshot.Signal` and appears in all of
/// them, in the right rank, without a single layout being touched.
///
/// Compiled into both the app and the widget extension: the app renders the
/// same views in a gallery so the design can be looked at and changed without
/// installing a widget to see it.
enum CT {

    // MARK: - Palette
    //
    // Ported from the app's Theme, deliberately by value rather than by
    // import: a widget extension cannot see the app's design layer, and a
    // handful of constants is not worth a third target to share them.

    static let bed = Color(red: 0.051, green: 0.055, blue: 0.075)      // #0D0E13
    static let bedTop = Color(red: 0.078, green: 0.086, blue: 0.114)   // lifted edge
    static let text = Color(red: 0.922, green: 0.961, blue: 1.0)       // #EBF5FF
    static let dim = Color(red: 0.46, green: 0.56, blue: 0.74)         // #758FBD
    static let ssh = Color(red: 0.451, green: 0.851, blue: 1.0)        // #73D9FF

    static let working = Color(red: 0.42, green: 0.82, blue: 1.00)
    static let attention = Color(red: 0.969, green: 0.580, blue: 0.278)
    static let ready = Color(red: 0.40, green: 0.859, blue: 0.561)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.36)
    static let neutral = Color(red: 0.46, green: 0.56, blue: 0.74)

    static func tint(_ phase: ContermSnapshot.Phase) -> Color {
        switch phase {
        case .connecting: return working
        case .connected: return ready
        case .closed: return neutral
        case .failed: return danger
        }
    }

    static func tint(_ kind: ContermSnapshot.Signal.Kind) -> Color {
        switch kind {
        case .agentWaiting: return attention
        case .hostDown: return danger
        case .sessionLost: return working
        case .note: return neutral
        }
    }

    /// The house iridescence: cyan → violet → pink → amber → mint. Used as a
    /// single hairline and never as a fill — a saturated wash reads as neon
    /// paint, which is the note this palette is built to avoid.
    static let iridescent = LinearGradient(
        colors: [
            Color(red: 0.45, green: 0.90, blue: 1.00),
            Color(red: 0.62, green: 0.60, blue: 1.00),
            Color(red: 1.00, green: 0.60, blue: 0.85),
            Color(red: 1.00, green: 0.78, blue: 0.45),
            Color(red: 0.55, green: 0.95, blue: 0.75),
        ],
        startPoint: .leading, endPoint: .trailing)

    // MARK: - The plate

    /// The bed every surface sits on: a barely-there vertical lift, a
    /// top-lit rim, and one iridescent hairline along the top edge.
    ///
    /// The hairline is the signature. It appears exactly once per surface,
    /// at the top, at low opacity — enough that two Conterm widgets on a home
    /// screen full of other apps read as a pair, and not so much that it
    /// becomes decoration.
    struct Plate<Content: View>: View {
        var corner: CGFloat = 22
        var padding: CGFloat = 14
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    LinearGradient(colors: [CT.bedTop, CT.bed],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .top) {
                    CT.iridescent
                        .frame(height: 1)
                        .opacity(0.55)
                        .blendMode(.plusLighter)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }

    // MARK: - Marks

    /// The block cursor. The one mark this product owns.
    struct Cursor: View {
        var height: CGFloat = 14
        var color: Color = CT.ssh
        /// A hollow cursor is the terminal convention for "not focused" —
        /// used here for a session that is no longer live.
        var filled = true

        var body: some View {
            RoundedRectangle(cornerRadius: height * 0.14, style: .continuous)
                .fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(Color.clear))
                .overlay {
                    if !filled {
                        RoundedRectangle(cornerRadius: height * 0.14, style: .continuous)
                            .strokeBorder(color.opacity(0.7), lineWidth: 1)
                    }
                }
                .frame(width: height * 0.55, height: height)
                .shadow(color: color.opacity(filled ? 0.55 : 0), radius: height * 0.35)
        }
    }

    /// A status dot with a halo, so it reads as lit rather than printed.
    struct Gem: View {
        var color: Color
        var size: CGFloat = 7

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(color.opacity(0.30), lineWidth: size * 0.55))
                .shadow(color: color.opacity(0.65), radius: size * 0.5)
        }
    }

    /// A fleet at a glance: one segment per session, stacked.
    ///
    /// This is what makes a small widget say something a number can't — six
    /// green bars and one red is a shape you read without counting.
    struct Rail: View {
        var colors: [Color]
        var thickness: CGFloat = 3
        var length: CGFloat = 34
        var axis: Axis = .vertical

        var body: some View {
            let stack = Group {
                if axis == .vertical {
                    VStack(spacing: 3) { segments }
                } else {
                    HStack(spacing: 3) { segments }
                }
            }
            return stack
        }

        @ViewBuilder private var segments: some View {
            ForEach(Array(colors.prefix(8).enumerated()), id: \.offset) { _, color in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: axis == .vertical ? thickness : length,
                           height: axis == .vertical ? length : thickness)
                    .shadow(color: color.opacity(0.5), radius: 3)
            }
        }
    }

    // MARK: - Type

    /// A small tracked label. The only place capitals are used.
    struct Label: View {
        var text: String
        var size: CGFloat = 8.5

        var body: some View {
            Text(text.uppercased())
                .font(.system(size: size, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(CT.dim.opacity(0.8))
                .lineLimit(1)
        }
    }

    /// A labelled number. Monospaced digits and a settled width, so a value
    /// that changes cannot resize the thing around it.
    struct Readout<Value: View>: View {
        var label: String
        @ViewBuilder var value: Value

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                CT.Label(text: label)
                value
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(CT.text)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Rows

    /// One session, as a line. The cursor is the bullet.
    struct SessionRow: View {
        var session: ContermSnapshot.Session
        var showTime = true
        var size: CGFloat = 13

        var body: some View {
            HStack(spacing: 7) {
                CT.Cursor(height: size,
                          color: CT.tint(session.phase),
                          filled: session.phase == .connected)
                Text(session.alias)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if session.ordinal > 1 {
                    Text("#\(session.ordinal)")
                        .font(.system(size: size * 0.72, weight: .bold, design: .monospaced))
                        .foregroundStyle(CT.dim)
                }
                Spacer(minLength: 4)
                if showTime {
                    Text(session.startedAt, style: .timer)
                        .font(.system(size: size * 0.85, weight: .medium, design: .rounded))
                        .foregroundStyle(CT.dim)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: size * 2.9, alignment: .trailing)
                }
            }
        }
    }

    /// One signal, as a line. Everything a future feature wants to say on a
    /// widget comes through here.
    struct SignalRow: View {
        var signal: ContermSnapshot.Signal
        var size: CGFloat = 12

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: signal.kind.symbol)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(CT.tint(signal.kind))
                    .frame(width: size)
                Text(signal.title)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if let detail = signal.detail {
                    Text(detail)
                        .font(.system(size: size * 0.85, weight: .medium, design: .monospaced))
                        .foregroundStyle(CT.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    static func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1fMB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0fkB", Double(n) / 1024) }
        return "\(n)B"
    }

    static func railColors(_ snapshot: ContermSnapshot) -> [Color] {
        let live = snapshot.live.map { tint($0.phase) }
        return live.isEmpty ? [neutral.opacity(0.35)] : live
    }
}
