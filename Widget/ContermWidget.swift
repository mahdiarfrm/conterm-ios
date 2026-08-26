import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island and Lock Screen presentation of a live SSH session.
///
/// The design brief for this surface is narrower than for a screen: it is
/// read at a glance, from the corner of your eye, while you are doing
/// something else. So it answers exactly one question in each size — *is it
/// still up* — and only spends the expanded layout on where and how long.
@main
struct ContermWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            lockScreen(context)
                // The system paints its own background; a dark one keeps the
                // card reading as Conterm rather than as a system card.
                .activityBackgroundTint(Color(red: 0.05, green: 0.055, blue: 0.075))
                .activitySystemActionForegroundColor(Color(red: 0.92, green: 0.96, blue: 1.0))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        gem(context.state.phase)
                        Text(context.attributes.hostAlias)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint(context.state.phase))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.detail ?? subtitle(context))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Label(bytes(context.state.bytesIn), systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                gem(context.state.phase)
            } compactTrailing: {
                Text(context.attributes.hostAlias)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: 68)
            } minimal: {
                gem(context.state.phase)
            }
            .keylineTint(tint(context.state.phase))
        }
    }

    // MARK: - Lock screen

    private func lockScreen(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> some View {
        HStack(spacing: 11) {
            gem(context.state.phase)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(context.attributes.hostAlias)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    if context.attributes.ordinal > 1 {
                        Text("#\(context.attributes.ordinal)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(context.state.detail ?? subtitle(context))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.phase.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint(context.state.phase))
                Text(bytes(context.state.bytesIn))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func subtitle(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> String {
        context.state.title ?? context.attributes.target
    }

    // MARK: - Parts

    private func gem(_ phase: SessionActivityAttributes.ContentState.Phase) -> some View {
        Circle()
            .fill(tint(phase))
            .frame(width: 9, height: 9)
            .shadow(color: tint(phase).opacity(0.7), radius: 4)
    }

    /// Conterm's status palette. Repeated rather than shared because the
    /// widget can't import the app's design layer, and three colours are not
    /// worth a third target to hold them.
    private func tint(_ phase: SessionActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .connecting: return Color(red: 0.42, green: 0.82, blue: 1.00)
        case .connected:  return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .closed:     return Color(red: 0.46, green: 0.56, blue: 0.74)
        case .failed:     return Color(red: 1.00, green: 0.36, blue: 0.36)
        }
    }

    private func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1fMB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0fkB", Double(n) / 1024) }
        return "\(n)B"
    }
}
