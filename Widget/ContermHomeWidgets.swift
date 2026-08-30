import SwiftUI
import WidgetKit

/// The WidgetKit wiring. Deliberately thin.
///
/// Everything about how these look lives in `ContermWidgetFaces`, which the
/// app compiles too — so the design is worked on by running the app's gallery
/// rather than by installing a widget and squinting at a home screen. All
/// this file does is fetch a snapshot and hand it over.
struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: ContermSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : ContermSnapshotStore.read()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: ContermSnapshotStore.read())
        // One entry, refreshed on a slow cadence. Everything that changes
        // quickly on these faces — the uptime clocks — is drawn ticking by
        // the system from a fixed start date, so it stays right without
        // costing a single refresh. The app reloads timelines itself when a
        // session opens or closes, which is when the rest actually changes.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct ContermStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.conterm.ios.status", provider: SnapshotProvider()) { entry in
            ContermFaceRouter(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { CT.bed }
        }
        .configurationDisplayName("Conterm")
        .description("Live sessions, and anything waiting on you.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// Picks the face for the family it was given.
struct ContermFaceRouter: View {
    @Environment(\.widgetFamily) private var family
    var snapshot: ContermSnapshot

    var body: some View {
        switch family {
        case .systemSmall: SmallFace(snapshot: snapshot)
        case .systemMedium: MediumFace(snapshot: snapshot)
        case .systemLarge, .systemExtraLarge: LargeFace(snapshot: snapshot)
        case .accessoryCircular: CircularFace(snapshot: snapshot)
        case .accessoryRectangular: RectangularFace(snapshot: snapshot)
        case .accessoryInline: InlineFace(snapshot: snapshot)
        @unknown default: SmallFace(snapshot: snapshot)
        }
    }
}
