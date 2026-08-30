import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island and Lock Screen presentation of a live SSH session.
///
/// Same language as the widgets: monospaced throughout, status as a character
/// rather than as a dot beside the text, no borders and no decoration. The
/// Island is small enough that any ornament is the whole design, so there
/// isn't any — a status glyph, a name, a clock.
///
/// The elapsed time is the one piece that carries its weight for free.
/// `Text(style: .timer)` ticks on its own, drawn by the system, so a session
/// looks alive between updates without any of them being spent on it.
@main
struct ContermWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContermStatusWidget()
        SessionLiveActivity()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(CT.bed)
                .activitySystemActionForegroundColor(CT.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Text(glyph(context))
                            .font(CT.mono(14, .bold))
                            .foregroundStyle(tint(context))
                        Text(context.attributes.hostAlias)
                            .font(CT.mono(15, .bold))
                            .foregroundStyle(CT.text)
                            .lineLimit(1)
                        if context.attributes.ordinal > 1 {
                            Text("#\(context.attributes.ordinal)")
                                .font(CT.mono(11, .medium))
                                .foregroundStyle(CT.faint)
                        }
                    }
                    .padding(.leading, 3)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(CT.mono(15, .semibold))
                        .foregroundStyle(CT.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: 62, alignment: .trailing)
                        .padding(.trailing, 3)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 0) {
                        Text(context.state.detail ?? subtitle(context))
                            .font(CT.mono(11, .medium))
                            .foregroundStyle(CT.dim)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        Text("\(CT.bytes(context.state.bytesIn)) in")
                            .font(CT.mono(11, .medium))
                            .foregroundStyle(CT.faint)
                    }
                    .padding(.top, 3)
                    .padding(.horizontal, 3)
                }
            } compactLeading: {
                Text(glyph(context))
                    .font(CT.mono(13, .bold))
                    .foregroundStyle(tint(context))
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(CT.mono(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(CT.text)
                    .frame(minWidth: 48, alignment: .trailing)
            } minimal: {
                Text(glyph(context))
                    .font(CT.mono(13, .bold))
                    .foregroundStyle(tint(context))
            }
            .keylineTint(tint(context))
        }
    }

    // MARK: - Lock screen

    private func lockScreen(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CT.Prompt(command: "ssh \(context.attributes.hostAlias)", size: 10)
                .padding(.bottom, 7)

            HStack(spacing: 6) {
                Text(glyph(context))
                    .font(CT.mono(15, .bold))
                    .foregroundStyle(tint(context))
                Text(context.state.phase.label)
                    .font(CT.mono(15, .semibold))
                    .foregroundStyle(CT.text)
                if context.attributes.ordinal > 1 {
                    Text("#\(context.attributes.ordinal)")
                        .font(CT.mono(11, .medium))
                        .foregroundStyle(CT.faint)
                }
                Spacer(minLength: 8)
                Text(context.attributes.startedAt, style: .timer)
                    .font(CT.mono(15, .semibold))
                    .foregroundStyle(CT.text)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                Text(context.state.detail ?? subtitle(context))
                    .font(CT.mono(11, .medium))
                    .foregroundStyle(CT.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(CT.bytes(context.state.bytesIn)) in")
                    .font(CT.mono(11, .medium))
                    .foregroundStyle(CT.faint)
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Parts

    private func subtitle(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> String {
        context.state.title ?? context.attributes.target
    }

    private func phase(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> ContermSnapshot.Phase {
        switch context.state.phase {
        case .connecting: return .connecting
        case .connected: return .connected
        case .closed: return .closed
        case .failed: return .failed
        }
    }

    private func glyph(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> String {
        CT.glyph(phase(context))
    }

    private func tint(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> Color {
        CT.tint(phase(context))
    }
}
