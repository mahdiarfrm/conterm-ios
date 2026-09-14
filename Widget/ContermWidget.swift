import ActivityKit
import SwiftUI
import WidgetKit

/// The Dynamic Island and Lock Screen presentation of a live SSH session.
///
/// The faces live in `Shared/SessionActivityFace.swift`, where the app's
/// gallery can render them too; this file only mounts them in the regions
/// the system offers. The ground is the one chosen in Settings, read from
/// the snapshot the app leaves for the widgets.
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
    private var palette: GroundPalette {
        CT.palette(ContermSnapshotStore.read().ground)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionFace.Banner(attributes: context.attributes, state: context.state,
                               palette: palette)
                .activityBackgroundTint(palette.flat)
                .activitySystemActionForegroundColor(CT.text)
        } dynamicIsland: { context in
            let keyline = SessionFace.keyline(context.state, palette: palette)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SessionFace.Leading(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionFace.Trailing(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionFace.Bottom(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                SessionFace.CompactMark(color: keyline)
            } compactTrailing: {
                SessionFace.CompactClock(attributes: context.attributes)
            } minimal: {
                SessionFace.CompactMark(color: keyline)
            }
            .keylineTint(keyline)
        }
    }
}
