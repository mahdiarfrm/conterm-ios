import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island and Lock Screen presentation of a live SSH session.
///
/// Same language as the widgets, which is the Mac app's: a near-black ground
/// with one soft wash of brand red, flat glass chips with a top-lit rim,
/// rounded SF for names and monospaced digits for the clock. Colour means
/// state and nothing else.
///
/// The expanded island is deliberately *tall*. The system sizes it to its
/// content, and the compact form already answers "is it up" — so the expanded
/// one is the place to breathe: a real header, the numbers on their own row
/// with labels, and where the session actually is along the bottom. A cramped
/// expanded island is one you never bother opening twice.
///
/// The elapsed time carries its weight for free: `Text(style: .timer)` is
/// drawn ticking by the system, so a session looks alive between updates
/// without spending any of the refresh budget it is allowed.
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
                    HStack(spacing: 9) {
                        CT.Gem(color: tint(context), size: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(context.attributes.hostAlias)
                                    .font(CT.ui(17, .bold))
                                    .foregroundStyle(CT.text)
                                    .lineLimit(1)
                                if context.attributes.ordinal > 1 {
                                    Text("\(context.attributes.ordinal)")
                                        .font(CT.ui(10, .bold))
                                        .foregroundStyle(CT.faint)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(.white.opacity(0.08)))
                                }
                            }
                            Text(context.state.phase.label)
                                .font(CT.ui(11.5, .semibold))
                                .foregroundStyle(tint(context))
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(CT.ui(19, .semibold))
                            .foregroundStyle(CT.text)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(minWidth: 78, alignment: .trailing)
                        Text("\(CT.bytes(context.state.bytesIn)) in")
                            .font(CT.ui(11, .medium))
                            .foregroundStyle(CT.faint)
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .frame(height: 1)
                            .padding(.top, 10)
                            .padding(.bottom, 9)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(CT.faint)
                            Text(context.state.detail ?? subtitle(context))
                                .font(CT.ui(12, .medium))
                                .foregroundStyle(CT.dim)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.bottom, 4)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                CT.Gem(color: tint(context), size: 8)
                    .padding(.leading, 3)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(CT.ui(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(CT.text)
                    .frame(minWidth: 50, alignment: .trailing)
                    .padding(.trailing, 3)
            } minimal: {
                CT.Gem(color: tint(context), size: 8)
            }
            .keylineTint(tint(context))
        }
    }

    // MARK: - Lock screen

    private func lockScreen(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> some View {
        ZStack {
            CT.Ground()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    CT.Gem(color: tint(context), size: 9)
                    Text(context.attributes.hostAlias)
                        .font(CT.ui(17, .bold))
                        .foregroundStyle(CT.text)
                        .lineLimit(1)
                    if context.attributes.ordinal > 1 {
                        Text("\(context.attributes.ordinal)")
                            .font(CT.ui(10, .bold))
                            .foregroundStyle(CT.faint)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    Spacer(minLength: 8)
                    CT.Chip(tint: tint(context)) {
                        Text(context.state.phase.label)
                            .font(CT.ui(10.5, .semibold))
                            .foregroundStyle(CT.text)
                    }
                }

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(CT.ui(24, .semibold))
                        .foregroundStyle(CT.text)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("\(CT.bytes(context.state.bytesIn)) in")
                        .font(CT.ui(11.5, .medium))
                        .foregroundStyle(CT.faint)
                    Spacer(minLength: 0)
                }

                Text(context.state.detail ?? subtitle(context))
                    .font(CT.ui(12, .medium))
                    .foregroundStyle(CT.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
        }
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

    private func tint(
        _ context: ActivityViewContext<SessionActivityAttributes>
    ) -> Color {
        CT.tint(phase(context))
    }
}
