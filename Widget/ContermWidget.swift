import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island and Lock Screen presentation of a live SSH session.
///
/// The design brief here is narrower than for a screen: it is read at a
/// glance, from the corner of your eye, while you are doing something else.
/// So each size answers as few questions as it can get away with — the
/// compact forms answer only *is it still up*, and the expanded layout
/// spends its room on where, how long, and how much has come back.
///
/// The elapsed time is the one piece that carries its weight for free.
/// `Text(style: .timer)` ticks on its own, drawn by the system, so a session
/// looks alive between updates without any of them being spent on it.
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
                .activityBackgroundTint(Palette.bed)
                .activitySystemActionForegroundColor(Palette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Gem(phase: context.state.phase, size: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(context.attributes.hostAlias)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                if context.attributes.ordinal > 1 {
                                    Text("#\(context.attributes.ordinal)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Palette.dim)
                                }
                            }
                            Text(context.state.phase.label)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.tint(context.state.phase))
                        }
                    }
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        elapsed(context, size: 16)
                        Label(bytes(context.state.bytesIn), systemImage: "arrow.down")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.dim)
                            .labelStyle(.titleAndIcon)
                    }
                    .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail ?? subtitle(context))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .padding(.horizontal, 2)
                }
            } compactLeading: {
                Gem(phase: context.state.phase, size: 8)
                    .padding(.leading, 2)
            } compactTrailing: {
                // The one number worth the sliver of room beside the camera:
                // how long this has been up. It is also the only thing here
                // that changes on its own, so the pill never looks frozen.
                elapsed(context, size: 13)
                    .padding(.trailing, 2)
            } minimal: {
                Gem(phase: context.state.phase, size: 8)
            }
            .keylineTint(Palette.tint(context.state.phase))
        }
    }

    // MARK: - Lock screen

    private func lockScreen(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Gem(phase: context.state.phase, size: 10)
                Text(context.attributes.hostAlias)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if context.attributes.ordinal > 1 {
                    Text("#\(context.attributes.ordinal)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 8)
                Text(context.state.phase.label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Palette.tint(context.state.phase))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Palette.tint(context.state.phase).opacity(0.16)))
            }

            Text(context.state.detail ?? subtitle(context))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)
                .truncationMode(.head)

            HStack(spacing: 14) {
                stat("uptime") { elapsed(context, size: 13) }
                stat("received") {
                    Text(bytes(context.state.bytesIn))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func stat<Content: View>(
        _ label: String, @ViewBuilder value: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Palette.dim.opacity(0.75))
            value()
        }
    }

    // MARK: - Parts

    /// Counts up on its own. A stopped session freezes at the moment it
    /// stopped, which is the honest thing for it to show.
    private func elapsed(
        _ context: ActivityViewContext<SessionActivityAttributes>,
        size: CGFloat
    ) -> some View {
        Group {
            switch context.state.phase {
            case .connecting, .connected:
                Text(context.attributes.startedAt, style: .timer)
            case .closed, .failed:
                Text(context.attributes.startedAt, style: .timer)
                    .foregroundStyle(Palette.dim)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Palette.text)
        // A timer that resizes as its digits change makes the whole pill
        // twitch once a second, so it gets a width it cannot outgrow.
        .frame(minWidth: size * 3.1, alignment: .trailing)
        .lineLimit(1)
    }

    private func subtitle(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> String {
        context.state.title ?? context.attributes.target
    }

    private func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f kB", Double(n) / 1024) }
        return "\(n) B"
    }
}

/// The status dot, with a soft halo so it reads as lit rather than printed.
private struct Gem: View {
    let phase: SessionActivityAttributes.ContentState.Phase
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Palette.tint(phase))
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(Palette.tint(phase).opacity(0.35), lineWidth: size * 0.5))
            .shadow(color: Palette.tint(phase).opacity(0.6), radius: size * 0.45)
            .padding(size * 0.25)
    }
}

/// Conterm's status palette. Repeated rather than shared because the widget
/// can't import the app's design layer, and four colours are not worth a
/// third target to hold them.
private enum Palette {
    static let bed = Color(red: 0.05, green: 0.055, blue: 0.075)
    static let text = Color(red: 0.92, green: 0.96, blue: 1.0)
    static let dim = Color(red: 0.46, green: 0.56, blue: 0.74)

    static func tint(_ phase: SessionActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .connecting: return Color(red: 0.42, green: 0.82, blue: 1.00)
        case .connected:  return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .closed:     return Color(red: 0.46, green: 0.56, blue: 0.74)
        case .failed:     return Color(red: 1.00, green: 0.36, blue: 0.36)
        }
    }
}
