import SwiftUI

/// The design language for everything Conterm draws outside its own window.
///
/// **The idea: it is a terminal.** Not a card about a terminal — a terminal.
/// Everything on these surfaces is a character on a monospaced grid, status
/// included: `●` for up, `◌` for connecting, `○` for closed, `✕` for failed,
/// sitting in the text flow rather than beside it as a decoration. The first
/// line is a prompt. The last thing is a block cursor. It reads like you
/// `cat`'d a status file, which is a thing no other widget on a home screen
/// looks like.
///
/// **What this replaces, and why.** The first attempt was a rounded card with
/// a grey stroke, a rainbow hairline, and rounded-sans type — which is every
/// developer-tool widget ever made, and worse, it broke rules this project
/// had already written down. `GLASS-REDESIGN.md` lists coloured ambient
/// backdrops under *dead ends*; `NodeCard.swift` rejected a bright ring
/// because it "read as neon paint". A saturated stripe across the top of a
/// black plate is that same mistake at a smaller size.
///
/// So: no border, no gradient, no rainbow. A flat near-black ground, one
/// typeface, and colour only on the status glyph — where it is the only thing
/// carrying meaning.
enum CT {

    // MARK: - Ground

    /// Flat, and darker than the app's own bed. A widget sits on a wallpaper,
    /// so a plate with a visible edge reads as a box someone drew; a plate
    /// with none reads as a hole cut in the screen.
    static let bed = Color(red: 0.039, green: 0.043, blue: 0.055)

    static let text = Color(red: 0.898, green: 0.933, blue: 0.976)
    static let dim = Color(red: 0.400, green: 0.478, blue: 0.612)
    static let faint = Color(red: 0.271, green: 0.322, blue: 0.416)

    static let ready = Color(red: 0.400, green: 0.859, blue: 0.561)
    static let working = Color(red: 0.420, green: 0.820, blue: 1.000)
    static let attention = Color(red: 0.969, green: 0.580, blue: 0.278)
    static let danger = Color(red: 1.000, green: 0.360, blue: 0.360)

    static func tint(_ phase: ContermSnapshot.Phase) -> Color {
        switch phase {
        case .connected: return ready
        case .connecting: return working
        case .closed: return faint
        case .failed: return danger
        }
    }

    static func tint(_ kind: ContermSnapshot.Signal.Kind) -> Color {
        switch kind {
        case .agentWaiting: return attention
        case .hostDown: return danger
        case .sessionLost: return working
        case .note: return dim
        }
    }

    /// Status as a character, so it sits on the same grid as everything else
    /// instead of floating beside the text as a dot someone added.
    static func glyph(_ phase: ContermSnapshot.Phase) -> String {
        switch phase {
        case .connected: return "●"
        case .connecting: return "◌"
        case .closed: return "○"
        case .failed: return "✕"
        }
    }

    static func glyph(_ kind: ContermSnapshot.Signal.Kind) -> String {
        switch kind {
        case .agentWaiting: return "✦"
        case .hostDown: return "✕"
        case .sessionLost: return "⚡"
        case .note: return "·"
        }
    }

    // MARK: - Type
    //
    // One family, monospaced, because the product is a terminal and because
    // a column of times only lines up if the digits are the same width.

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The vertical rhythm. Terminal rows are a fixed height and everything
    /// here sits on the same one, which is most of why it reads as ordered.
    static func line(_ size: CGFloat) -> CGFloat { (size * 1.45).rounded() }

    // MARK: - Pieces

    /// The ground, with terminal padding and nothing else.
    struct Screen<Content: View>: View {
        var padding: CGFloat = 15
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CT.bed)
        }
    }

    /// `~ %` and what was "typed" after it. The line that says what this is.
    struct Prompt: View {
        var command: String
        var size: CGFloat = 10

        var body: some View {
            HStack(spacing: 5) {
                Text("~")
                    .foregroundStyle(CT.faint)
                Text("%")
                    .foregroundStyle(CT.dim)
                Text(command)
                    .foregroundStyle(CT.dim)
                    .lineLimit(1)
            }
            .font(CT.mono(size, .semibold))
        }
    }

    /// The block cursor. Solid, sitting on the text baseline, exactly as wide
    /// as a character cell.
    struct Cursor: View {
        var size: CGFloat = 12
        var color: Color = CT.ready

        var body: some View {
            Rectangle()
                .fill(color)
                .frame(width: size * 0.58, height: size * 1.12)
        }
    }

    /// One session, as a line of output: glyph, name, and a right-aligned
    /// clock. The clock ticks itself, drawn by the system.
    struct SessionLine: View {
        var session: ContermSnapshot.Session
        var size: CGFloat = 12.5

        var body: some View {
            HStack(spacing: 0) {
                Text(CT.glyph(session.phase))
                    .font(CT.mono(size, .bold))
                    .foregroundStyle(CT.tint(session.phase))
                    .frame(width: size * 1.3, alignment: .leading)
                Text(session.alias)
                    .font(CT.mono(size, .semibold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if session.ordinal > 1 {
                    Text(" #\(session.ordinal)")
                        .font(CT.mono(size * 0.85, .medium))
                        .foregroundStyle(CT.faint)
                }
                Spacer(minLength: 6)
                Text(session.startedAt, style: .timer)
                    .font(CT.mono(size, .medium))
                    .foregroundStyle(CT.dim)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: size * 4.4, alignment: .trailing)
            }
            .frame(height: CT.line(size))
        }
    }

    /// One signal, same grid.
    struct SignalLine: View {
        var signal: ContermSnapshot.Signal
        var size: CGFloat = 12

        var body: some View {
            HStack(spacing: 0) {
                Text(CT.glyph(signal.kind))
                    .font(CT.mono(size, .bold))
                    .foregroundStyle(CT.tint(signal.kind))
                    .frame(width: size * 1.3, alignment: .leading)
                Text(signal.title)
                    .font(CT.mono(size, .semibold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                if let detail = signal.detail {
                    Text("  \(detail)")
                        .font(CT.mono(size * 0.9, .medium))
                        .foregroundStyle(CT.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: CT.line(size))
        }
    }

    /// The whole fleet as a row of characters.
    ///
    /// A small widget cannot hold a name-and-time column without truncating
    /// every row to "sibche-p…", which tells you nothing. One glyph per
    /// session tells you how many and what shape they are in, costs four
    /// characters, and cannot truncate.
    struct Fleet: View {
        var sessions: [ContermSnapshot.Session]
        var size: CGFloat = 12

        var body: some View {
            HStack(spacing: size * 0.28) {
                ForEach(Array(sessions.prefix(8))) { session in
                    Text(CT.glyph(session.phase))
                        .font(CT.mono(size, .bold))
                        .foregroundStyle(CT.tint(session.phase))
                }
                if sessions.count > 8 {
                    Text("+\(sessions.count - 8)")
                        .font(CT.mono(size * 0.8, .medium))
                        .foregroundStyle(CT.faint)
                }
            }
        }
    }

    /// A rule, the way a terminal draws one.
    struct Rule: View {
        var body: some View {
            Rectangle()
                .fill(CT.faint.opacity(0.28))
                .frame(height: 1)
        }
    }

    // MARK: - Helpers

    static func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1fM", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0fK", Double(n) / 1024) }
        return "\(n)B"
    }
}
