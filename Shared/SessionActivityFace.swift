import SwiftUI

/// The Live Activity's faces as plain views, so the app's gallery can show
/// them and the extension can mount them. The banner on the lock screen is
/// a panel: the host, the phase, the clock large, the traffic as small bars
/// and as two numbers, and where the shell is. The island's regions are
/// the same parts, rearranged to the shape it gives them.
///
/// Every clock here sits in a fixed frame, and that is not fussiness. A
/// `Text` drawn in the timer style asks for the width of the longest time
/// it could ever show, hours included, and the island sizes its pill to
/// what the compact views ask for. Left to itself the clock stretched the
/// pill across most of the screen. A frame the width of `mm:ss` keeps the
/// pill the shape the system meant; a session past the hour scales its
/// digits down inside the same frame instead of pushing the walls out.
enum SessionFace {
    typealias State = SessionActivityAttributes.ContentState

    static func phase(_ state: State) -> ContermSnapshot.Phase {
        switch state.phase {
        case .connecting: return .connecting
        case .connected: return .connected
        case .closed: return .closed
        case .failed: return .failed
        }
    }

    static func tint(_ state: State) -> Color { CT.tint(phase(state)) }

    /// The ring around the island, and the compact mark: the brand while
    /// the shell is up, the status colour only when it is not.
    static func keyline(_ state: State, palette: GroundPalette) -> Color {
        switch state.phase {
        case .connected: return palette.lights.first ?? CT.ready
        case .connecting: return CT.working
        case .closed: return CT.idle
        case .failed: return CT.danger
        }
    }

    static func subtitle(_ attributes: SessionActivityAttributes, _ state: State) -> String {
        state.detail ?? state.title ?? attributes.target
    }

    /// The elapsed time, ticking on its own, held to a fixed width.
    ///
    /// `width` is what `mm:ss` needs at `size`; beyond the hour the digits
    /// shrink to fit rather than the frame growing.
    struct Clock: View {
        var since: Date
        var size: CGFloat
        var width: CGFloat
        var alignment: Alignment = .trailing

        var body: some View {
            Text(since, style: .timer)
                .font(CT.ui(size, .bold))
                .foregroundStyle(CT.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .frame(width: width, alignment: alignment)
        }
    }

    // MARK: - Lock screen and banner

    struct Banner: View {
        var attributes: SessionActivityAttributes
        var state: State
        var palette: GroundPalette = .crimson

        var body: some View {
            ZStack {
                CT.Ground(palette: palette)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        CT.Gem(color: SessionFace.tint(state), size: 9)
                        Text(attributes.hostAlias)
                            .font(CT.ui(18, .bold))
                            .foregroundStyle(CT.text)
                            .lineLimit(1)
                        if attributes.ordinal > 1 {
                            Text("\(attributes.ordinal)")
                                .font(CT.ui(10, .bold))
                                .foregroundStyle(CT.dim)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.white.opacity(0.14)))
                        }
                        Spacer(minLength: 8)
                        CT.Chip(lit: true) {
                            Text(state.phase.label)
                                .font(CT.ui(10.5, .bold))
                                .foregroundStyle(CT.text)
                        }
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        Clock(since: attributes.startedAt, size: 36, width: 118,
                              alignment: .leading)
                        Spacer(minLength: 0)
                        traffic
                    }

                    if !state.pulse.isEmpty {
                        CT.Bars(values: state.pulse, height: 22)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CT.faint)
                        Text(SessionFace.subtitle(attributes, state))
                            .font(CT.ui(12, .medium))
                            .foregroundStyle(CT.dim)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 15)
            }
        }

        private var traffic: some View {
            HStack(spacing: 14) {
                CT.Readout(value: CT.bytes(state.bytesIn), label: "in",
                           symbol: "arrow.down", size: 15)
                CT.Readout(value: CT.bytes(state.bytesOut), label: "out",
                           symbol: "arrow.up", size: 15)
            }
        }
    }

    // MARK: - Island, expanded

    /// The three expanded regions share one horizontal inset so the leading
    /// and trailing columns line up with the bottom row's edges. The system
    /// already keeps the content clear of the island's walls; this is only
    /// the optical margin inside that.
    static let expandedInset: CGFloat = 4

    struct Leading: View {
        var attributes: SessionActivityAttributes
        var state: State

        var body: some View {
            HStack(spacing: 8) {
                CT.Gem(color: SessionFace.tint(state), size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(attributes.hostAlias)
                            .font(CT.ui(16, .bold))
                            .foregroundStyle(CT.text)
                            .lineLimit(1)
                        if attributes.ordinal > 1 {
                            Text("\(attributes.ordinal)")
                                .font(CT.ui(10, .bold))
                                .foregroundStyle(CT.dim)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                    Text(state.phase.label)
                        .font(CT.ui(11, .semibold))
                        .foregroundStyle(SessionFace.tint(state))
                }
            }
            .padding(.leading, SessionFace.expandedInset)
            .padding(.top, 2)
        }
    }

    struct Trailing: View {
        var attributes: SessionActivityAttributes
        var state: State

        var body: some View {
            VStack(alignment: .trailing, spacing: 1) {
                Clock(since: attributes.startedAt, size: 19, width: 62)
                Text("up")
                    .font(CT.ui(11, .semibold))
                    .foregroundStyle(CT.faint)
            }
            .padding(.trailing, SessionFace.expandedInset)
            .padding(.top, 2)
        }
    }

    struct Bottom: View {
        var attributes: SessionActivityAttributes
        var state: State

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 14) {
                    CT.Readout(value: CT.bytes(state.bytesIn), label: "in",
                               symbol: "arrow.down", size: 16)
                    CT.Readout(value: CT.bytes(state.bytesOut), label: "out",
                               symbol: "arrow.up", size: 16)
                    CT.Bars(values: state.pulse, height: 24)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CT.faint)
                    Text(SessionFace.subtitle(attributes, state))
                        .font(CT.ui(12, .medium))
                        .foregroundStyle(CT.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, SessionFace.expandedInset)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }

    // MARK: - Island, compact

    /// The mark at the left of the compact island, and the whole of the
    /// minimal one: the prompt, lit in the keyline colour. No padding of its
    /// own; the system already stands the compact views off the cutout, and
    /// anything added here widens the pill.
    struct CompactMark: View {
        var color: Color

        var body: some View {
            Image(systemName: "apple.terminal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
        }
    }

    /// The clock at the right of the compact island. Its frame is the width
    /// of `mm:ss` at this size; see `Clock` for why it is fixed.
    struct CompactClock: View {
        var attributes: SessionActivityAttributes

        var body: some View {
            Clock(since: attributes.startedAt, size: 13, width: 40)
        }
    }
}
